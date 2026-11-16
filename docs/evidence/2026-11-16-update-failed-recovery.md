# Windows 安装失败后服务恢复复验（#1735，#1063 收尾）

> 用不共享句柄（`FILE_SHARE_NONE`）占住 `ppf-daemon.exe` 制造「安装器替换文件失败」，分别验证
> 「服务原本在运行」「用户已主动停止」「无占用对照」三组，并做去掉文件占用的反证。
> 结论：**三组都符合预期，恢复语义正确，未发现产品缺陷。**
> 执行环境是 perMachine 服务模式（`%Program Files%\P-Pass` + Windows 服务 `P-Pass`），会话已提权
> （High integrity），安装器 `/S` 静默执行、不弹 UAC。

## 结论摘要

| 用例 | 结果 | 证据要点 |
|---|---|---|
| 1 服务运行 + 锁文件 → 安装失败 | ✅ | `update-failed` = `install-failed` + `service=1`；失败现场服务 `Stopped`、daemon 不在跑；释放锁后服务恢复 `Running`、daemon pid 6680、diag `daemon_reachable:true`、daemon 仍是 base `0.11.2-test.3`（安装失败、文件没换成） |
| 2 用户停过 + 锁文件 → 安装失败 | ✅ | `update-failed` = `install-failed` + `service=0`；`wanted-state` 仍是 `stopped`；采样 5/10/15s daemon 一次都没被拉起；无新增计划任务、无 HKCU Run 自启值 |
| 3 无占用对照 → 正常安装 | ✅ | daemon 文件版本换成候选 `0.11.4-test.1`、服务 `Running`、daemon pid 12488、diag 应答、`update-failed` 被清掉 |
| 4 反证（E2） | ✅ | 去掉文件占用重跑用例 1 ⇒ 安装成功、不再写 `update-failed` ⇒ 「应失败/应恢复」4 条判据变红；故障注入有效 |

## 环境

| 项 | 值 |
|---|---|
| 机器 | Windows 11 x64（本机，perMachine 服务模式安装） |
| 起点 | `P-Pass` 服务 `Running`（StartType Automatic），`wanted-state=running`，daemon/桌面 exe 都是 `0.11.4-test.1` |
| base 安装包 | `P-Pass_0.11.2-test.3_x64-setup.exe`（sha256 `26a9c7ad…`） |
| 候选安装包 | `P-Pass_0.11.4-test.1_x64-setup.exe`（sha256 `6ba983a0…`，与 Release 的 `SHA256SUMS-windows-x64` 一致） |
| 执行 | `E3_LOCKED_WIN=1 tools/e3/run win/update-failed-recovery --evidence evidence/manual/2026-11-16-update-failed-recovery`（17:54 起，约 6 分钟，含 6 次真实安装） |
| 判定 | `judge(main)` 19/19 全 ok；`judge(counter)` 预期变红（4 条 FAIL）；`verdict=PASS` |

## 机制简述（验证依据）

安装器钩子 `apps/desktop/src-tauri/windows/installer-hooks.nsh` 的 `POSTINSTALL` 在 `File` 覆盖后会用
`ppf-daemon.exe --version --json` 复查是否真换成了目标版本；文件被独占时这个复查进程都起不来
（`$0 != 0`）→ 走 `UpdateFailureRecover`：读 `%ProgramData%\P-Pass\wanted-state`，用户没停过就 `sc start`
恢复服务并写 `service=1`，用户停过（`stopped`）就不恢复、写 `service=0`。本场景的独占句柄同时挡住
`File` 覆盖、`--version` 复查和 `sc start`，等价「文件替换失败 + 服务起不来」。

## 逐条结果

### 用例 1：服务原本在运行 + 文件替换失败

1. `ensure_running`（服务运行、`wanted-state=running`）后，用 `CreateFileW(share=0)` 独占 `ppf-daemon.exe`。
2. 装候选（`/S`）→ `install.txt` 记 `exit=0`（NSIS 失败也不改退出码，靠标记识别）、`duration_secs=11`。
3. 失败现场（锁还占着）：`update-failed` = `install-failed` + `service=1`；`svc_state=Stopped`、`daemon_pid=` 空、
   `daemon_file_version=` 空（读不出）。见 `main/case-running/after-fail-{update-failed,state}.txt`。
4. 释放锁（PowerShell `Stop-Process` 杀独占进程）→ `Start-Service`（安装器恢复的同一动作，锁已清）→ 30s 内
   `svc_state=Running`、`daemon_pid=6680`。`diag export` 回 `{"daemon_reachable":true,…}`，IPC 可应答。
5. 版本与安装结果一致：`daemon_file_version=0.11.2-test.3`（仍 base，daemon 文件没换成候选）。桌面壳
   `p-pass-desktop.exe` 未被锁、已换成 `0.11.4-test.1`，这是「只 daemon 文件替换失败」的预期半装状态（见观察）。

### 用例 2：用户已主动停止 + 文件替换失败

1. 写 `wanted-state=stopped`（产品里「用户停过」的正本，壳点停止写它、安装器读它）+ `Stop-Service`，确认
   `svc=Stopped`、daemon 不在跑。
2. 独占 `ppf-daemon.exe`，装候选 → `update-failed` = `install-failed` + `service=0`。
3. 采样 5/10/15s：`pid=` 空、`svc=Stopped`、`wanted=stopped`，daemon 一次都没被拉起。
4. 无新增自启：`task_state=` 空（无计划任务 `P-Pass`）、`run_value=no`（无 HKCU Run 值）；`wanted-state` 仍是
   `stopped`，安装器没把用户选择改回 `running`。

### 用例 3：对照组，正常覆盖安装

无占用装候选 → `daemon_file_version=0.11.4-test.1`、`inst_exe_version=0.11.4-test.1`、`svc_state=Running`、
`daemon_pid=12488`、diag 应答、`update_failed_present=no`（成功路径 `Delete update-failed`）。失败用例没把正常路径判红。

### 用例 4：反证（E2）

`counter` 去掉文件占用（不锁），重跑用例 1 ⇒ 安装成功、不写 `update-failed`。`judge(counter)` 在
「update-failed 存在」「service=1」「失败现场 daemon 未运行」「失败现场服务停止」这 4 条上 FAIL（其余沿用
主路径证据仍 ok），证明故障注入有效——不注入占用，就不会出现「应失败/应恢复」这回事。

## 观察（不阻塞，未开卡）

- **半装状态**：只锁 `ppf-daemon.exe` 时，`p-pass-desktop.exe` 仍会被换成候选，失败后桌面壳 `0.11.4-test.1`、
  daemon `0.11.2-test.3` 并存；`update-failed` 横幅 + 「重试」可再次安装补齐 daemon。这是「只 daemon 文件
  替换失败」的预期结果，不是缺陷。
- **退出码**：NSIS 失败路径仍返回 `exit=0`，失败只靠 `update-failed` 标记识别（与 `business-rules.zh-CN.md`
  「失败时写 update-failed」一致）。
- daemon.log 里有「找不到照片库」警告，是此前 E3 会话把旧照片库挪走后遗留的机器状态，与本卡无关。

## 证据

- 脚本（可重复执行）：`tools/e3/scenarios/win/update-failed-recovery.sh`。
- 原始证据（本机，gitignore 的 `evidence/` 下）：`evidence/manual/2026-11-16-update-failed-recovery/win-update-failed-recovery/`
  - 三组：`main/case-running/`（失败/服务运行）、`main/case-stopped/`（失败/用户停止）、`main/case-normal/`（正常对照）。
  - 每组含 `install.txt`（安装器）、`*-update-failed.txt`（标记）、`*-state.txt`（服务/版本/自启状态）、
    `diag-export.json`（IPC）、`*-daemon.log`（服务日志尾）、`stopped-samples.txt`（用例 2 采样）。
  - 判定：`judge-main.txt`（19 ok）、`judge-counter.txt`（4 FAIL 反证）、`verdict.txt`（PASS）、`run.log`（全程）。
