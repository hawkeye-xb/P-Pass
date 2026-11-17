# Windows 安装失败后服务恢复复验（#1735，#1063 收尾）

> 用不共享句柄（`FILE_SHARE_NONE`）占住 `ppf-daemon.exe` 制造「安装器替换文件失败」，分别验证
> 「服务原本在运行」「用户已主动停止」「无占用对照」三组，并做去掉文件占用的反证。
> 结论：**用例1 发现产品缺陷——释放句柄后 daemon 不会自动恢复；已新开 Bug 卡 #1817。**
> 执行环境是 perMachine 服务模式（`%Program Files%\P-Pass` + Windows 服务 `P-Pass`），会话已提权
> （High integrity），安装器 `/S` 静默执行、不弹 UAC。

## 结论摘要

| 用例 | 结果 | 证据要点 |
|---|---|---|
| 1 服务运行 + 锁文件 → 安装失败 | ❌ **产品缺陷** | `update-failed` = `install-failed` + `service=1`（安装器「尝试恢复」）；但释放锁后 `svc=Stopped`、daemon 不在跑，`sc failure restart/5000` 不重试（无 Event 7032），daemon 不恢复 |
| 2 用户停过 + 锁文件 → 安装失败 | ✅ | `update-failed` = `install-failed` + `service=0`；`wanted-state` 仍 `stopped`；采样 5/10/15s daemon 没被拉起；无新增计划任务/HKCU Run 自启 |
| 3 无占用对照 → 正常安装 | ✅ | daemon 换成候选 `0.11.4-test.1`、服务 `Running`、diag 应答、`update-failed` 被清掉 |
| 4 反证（去掉文件占用，E2） | ✅ | 不锁文件重跑用例1 ⇒ 安装成功、不再写 `update-failed` ⇒ 「应失败」3 条判据变红；故障注入有效 |

## 环境

| 项 | 值 |
|---|---|
| 机器 | Windows 11 x64（本机，perMachine 服务模式安装） |
| 起点 | `P-Pass` 服务 `Running`（StartType Automatic），`wanted-state=running`，daemon/桌面 exe 都是 `0.11.4-test.1` |
| base 安装包 | `P-Pass_0.11.2-test.3_x64-setup.exe`（sha256 `26a9c7ad…`） |
| 候选安装包 | `P-Pass_0.11.4-test.1_x64-setup.exe`（sha256 `6ba983a0…`） |
| 执行 | `E3_LOCKED_WIN=1 tools/e3/run win/update-failed-recovery --evidence evidence/manual/2026-11-17-update-failed-recovery` |
| 判定 | `judge(main)` 用例1 三条「应恢复」FAIL；`judge(counter)` 反证三条「应失败」FAIL；`verdict=FAIL`（缺陷） |

## 机制与根因（验证依据）

安装器钩子 `apps/desktop/src-tauri/windows/installer-hooks.nsh` 的 `POSTINSTALL` 在 `File` 覆盖后用
`ppf-daemon.exe --version --json` 复查是否真换成了目标版本；文件被独占时复查进程起不来（`$0 != 0`）→ 走
`UpdateFailureRecover`：读 `%ProgramData%\P-Pass\wanted-state`，用户没停过就 `sc failure … restart/5000` +
`sc start` 并写 `service=1`，用户停过（`stopped`）就不恢复、写 `service=0`。

**根因**：`UpdateFailureRecover` 的 `sc start` 在「替换失败」后立即执行，此时占用 `ppf-daemon.exe` 的句柄
还没释放，`sc start` 因二进制不可读（sharing violation，Event 7000）失败；而 `sc failure` 的 `restart` action
只覆盖「服务崩溃/启动后异常退出」，**不覆盖「start 失败」**（实测 Event 7000 后 60s 无 Event 7032，无重试）。
`service=1` 记录的是「尝试过恢复」，不检查 `sc start` 结果，也不代表恢复成功。

## 逐条结果

### 用例 1：服务原本在运行 + 文件替换失败（发现缺陷）

1. `ensure_running` 后，用 `CreateFileW(share=0, FILE_SHARE_NONE)` 独占 `ppf-daemon.exe`。
2. 装候选（`/S`）→ `update-failed` = `install-failed` + `service=1`（安装器识别失败、尝试恢复）。
3. 失败现场（锁还占着）：`svc_state=Stopped`、`daemon_pid=` 空、`daemon_file_version=` 空（读不出）。
   安装器的 `sc start` 失败：Event 7000（"The process cannot access the file because it is being used by another process"）。
4. 释放锁（`Stop-Process` 杀独占进程）后**不手动 `Start-Service`**，等 30s：`svc_state` 仍 `Stopped`、
   `daemon_pid=` 仍空；`diag export` 回 `daemon_reachable:false`。**daemon 没有恢复**——卡要求「释放句柄后
   daemon 恢复运行」不成立，是产品缺陷（详见 #1817）。

### 用例 2：用户已主动停止 + 文件替换失败

1. 写 `wanted-state=stopped` + `Stop-Service`，确认 `svc=Stopped`、daemon 不在跑。
2. 独占 `ppf-daemon.exe`，装候选 → `update-failed` = `install-failed` + `service=0`。
3. 释放锁后采样 5/10/15s：`pid=` 空、`svc=Stopped`、`wanted=stopped`，daemon 一次都没被拉起。
4. 无新增自启：`task_state=` 空、`run_value=no`；`wanted-state` 仍是 `stopped`。

### 用例 3：对照组，正常覆盖安装

无占用装候选 → `daemon_file_version=0.11.4-test.1`、`inst_exe_version=0.11.4-test.1`、`svc_state=Running`、
daemon 在跑、diag 应答、`update_failed_present=no`。失败用例没把正常路径判红。

### 用例 4：反证（去掉文件占用，E2）

`counter` 不锁文件重跑用例1 ⇒ 安装成功、不写 `update-failed`。`judge(counter)` 在「update-failed 存在」
「service=1」「版本仍是 base」这 3 条上 FAIL，证明 `FILE_SHARE_NONE` 故障注入有效——去掉占用，「应失败」这回事就不成立。

## 观察

- **半装状态**：只锁 `ppf-daemon.exe` 时，`p-pass-desktop.exe` 仍会被换成候选，失败后桌面壳 `0.11.4-test.1`、
  daemon `0.11.2-test.3` 并存；`update-failed` 横幅 + 「重试」可再次安装补齐 daemon。
- **`sc failure restart/5000` 不重试 start 失败**：Event 7000（sharing violation）后 60s 无 Event 7032，服务不回来；
  这是用例1 缺陷的直接原因。
- **退出码**：NSIS 失败路径仍返回 `exit=0`，失败只靠 `update-failed` 标记识别。
- daemon.log 里有「找不到照片库」警告，是此前 E3 会话把旧照片库挪走后遗留的机器状态，与本卡无关。

## 证据

- 脚本（可重复执行）：`tools/e3/scenarios/win/update-failed-recovery.sh`。
- 原始证据（本机，gitignore 的 `evidence/` 下）：`evidence/manual/2026-11-17-update-failed-recovery/win-update-failed-recovery/`
  - 三组：`main/case-running/`（失败/服务运行）、`main/case-stopped/`（失败/用户停止）、`main/case-normal/`（正常对照）。
  - 判定：`judge-main.txt`（用例1 三条「应恢复」FAIL）、`judge-counter.txt`（反证三条「应失败」FAIL）、`verdict.txt`（FAIL）、`run.log`。
- 产品缺陷另开 Bug 卡：#1817。
