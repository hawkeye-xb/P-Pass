# Windows 安装失败后服务恢复复验（#1735，#1063 收尾）

> 用独占句柄占住 `ppf-daemon.exe` 制造「安装器替换文件失败」，分别验证「服务原本在运行」「用户已主动停止」「无占用对照」三组，并做「不恢复服务」的反证。
> 结论：**三组都符合预期，恢复语义正确，未发现产品缺陷。**
> 恢复机制（真机实测）：恢复 = 安装器 `UpdateFailureRecover` 里的一次性 `sc start`，二进制可读即能拉起旧版；
> `sc failure … restart/5000` 只补回崩溃自动重启，不重试 start 失败（Event 7000 sharing violation 后 60s 无 Event 7032）。
> 执行环境是 perMachine 服务模式（`%Program Files%\P-Pass` + Windows 服务 `P-Pass`），会话已提权（High integrity），安装器 `/S` 静默执行、不弹 UAC。

## 结论摘要

| 用例 | 结果 | 证据要点 |
|---|---|---|
| 1 服务运行 + 只占写（`FILE_SHARE_READ`）→ 替换失败 | ✅ | `update-failed` = `install-failed` + `service=1`；安装器 `sc start` 拉起旧版 daemon（pid 21028）、diag `daemon_reachable:true`、daemon 仍是 base `0.11.2-test.3` |
| 2 用户停过 + 全占（`FILE_SHARE_NONE`）→ 替换失败 | ✅ | `update-failed` = `install-failed` + `service=0`；`wanted-state` 仍 `stopped`；采样 5/10/15s daemon 没被拉起；无新增计划任务/HKCU Run 自启 |
| 3 无占用对照 → 正常安装 | ✅ | daemon 换成候选 `0.11.4-test.1`、daemon pid 6728、diag 应答、`update-failed` 被清掉 |
| 4 反证（不恢复服务，E2） | ✅ | 全占锁 + 不手动 `Start-Service` ⇒ `sc start` 也失败、daemon 不恢复 ⇒ 「应恢复」3 条判据（daemon 在跑 / IPC / 服务在运行）变红 |

## 环境

| 项 | 值 |
|---|---|
| 机器 | Windows 11 x64（本机，perMachine 服务模式安装） |
| 起点 | `P-Pass` 服务 `Running`（StartType Automatic），`wanted-state=running`，daemon/桌面 exe 都是 `0.11.4-test.1` |
| base 安装包 | `P-Pass_0.11.2-test.3_x64-setup.exe`（sha256 `26a9c7ad…`） |
| 候选安装包 | `P-Pass_0.11.4-test.1_x64-setup.exe`（sha256 `6ba983a0…`） |
| 执行 | `E3_LOCKED_WIN=1 tools/e3/run win/update-failed-recovery --evidence evidence/manual/2026-11-17-update-failed-recovery`（10:33 起，约 5 分钟，含 base/候选多次真实安装） |
| 判定 | `judge(main)` 17/17 全 ok；`judge(counter)` 3 条「应恢复」FAIL（反证变红）；`verdict=PASS` |

## 机制简述（验证依据）

安装器钩子 `apps/desktop/src-tauri/windows/installer-hooks.nsh` 的 `POSTINSTALL` 在 `File` 覆盖后用
`ppf-daemon.exe --version --json` 复查是否真换成了目标版本；复查失败（进程起不来或版本不符）→ 走
`UpdateFailureRecover`：读 `%ProgramData%\P-Pass\wanted-state`，用户没停过就 `sc failure … restart/5000` +
`sc start` 并写 `service=1`，用户停过（`stopped`）就不恢复、写 `service=0`。

关键（真机实测，2026-11-17）：恢复 = 一次性 `sc start`，且不检查结果（`service=1` 记录「尝试过恢复」而非「恢复成功」）；
那句 `sc failure … restart/5000` 只补回 PREINSTALL 清掉的崩溃自动重启，**不会重试 start 失败**。所以：
- 只占写（`FILE_SHARE_READ`，share=1）：`File` 覆盖失败（写/删被拒），但 `--version` 复查和 `sc start` 能读 → 「替换失败 + 服务被 sc start 拉起旧版」。
- 全占（`FILE_SHARE_NONE`，share=0）：`File` 覆盖、`--version`、`sc start` 全失败 → 「替换失败 + 服务起不来」，释放锁后也没人再拉起。

## 逐条结果

### 用例 1：服务原本在运行 + 替换失败（只占写）

1. `ensure_running` 后用 `CreateFileW(share=FILE_SHARE_READ)` 只占写 `ppf-daemon.exe`（可读/执行，不可写/删）。
2. 装候选（`/S`）→ NSIS `File` 覆盖 daemon 失败（写被拒），桌面壳 `p-pass-desktop.exe` 正常换成候选；
   `--version` 复查读到旧版 → `UpdateFailureRecover` → `sc start` 成功拉起旧版 daemon。
3. `update-failed` = `install-failed` + `service=1`；`install.txt` 记 `exit=0`（NSIS 失败也不改退出码，靠标记识别）。
4. 释放锁 → 采样：`svc_state=Running`、`daemon_pid=21028`、`daemon_file_version=0.11.2-test.3`（仍 base）、
   diag `{"daemon_reachable":true}`。**全程没有手动 `Start-Service`**——恢复归因到安装器的 `sc start`。

### 用例 2：用户已主动停止 + 替换失败（全占）

1. 写 `wanted-state=stopped`（产品里「用户停过」的正本）+ `Stop-Service`，确认 `svc=Stopped`、daemon 不在跑。
2. 全占（`FILE_SHARE_NONE`）`ppf-daemon.exe`，装候选 → `update-failed` = `install-failed` + `service=0`。
3. 释放锁后采样 5/10/15s：`pid=` 空、`svc=Stopped`、`wanted=stopped`，daemon 一次都没被拉起。
4. 无新增自启：`task_state=` 空、`run_value=no`；`wanted-state` 仍是 `stopped`，安装器没把用户选择改回 `running`。

### 用例 3：对照组，正常覆盖安装

无占用装候选 → `daemon_file_version=0.11.4-test.1`、`inst_exe_version=0.11.4-test.1`、`svc_state=Running`、
`daemon_pid=6728`、diag 应答、`update_failed_present=no`。失败用例没把正常路径判红。

### 用例 4：反证（不恢复服务，E2）

`counter` 用全占（`FILE_SHARE_NONE`）锁 + **不手动 `Start-Service`** 重跑用例 1 ⇒ `sc start` 也因二进制不可读而失败，
释放锁后 daemon 仍不被拉起。`judge(counter)` 在「恢复后 daemon 在运行」「恢复后 IPC 可应答」「恢复后服务在运行」
这 3 条上 FAIL（其余沿用主路径证据仍 ok），证明主路径的「恢复」确实归因到安装器 `sc start`，而不是测试手动拉的。

## 观察（不阻塞，未开卡）

- **半装状态**：只锁 `ppf-daemon.exe` 时，`p-pass-desktop.exe` 仍会被换成候选，失败后桌面壳 `0.11.4-test.1`、
  daemon `0.11.2-test.3` 并存；`update-failed` 横幅 + 「重试」可再次安装补齐 daemon。这是「只 daemon 文件替换失败」的预期结果，不是缺陷。
- **全占时服务不自动恢复**：`FILE_SHARE_NONE` 下 `sc start` 失败（Event 7000，sharing violation）后，SCM 不触发
  `restart/5000` 重试（无 Event 7032），服务一直停着——二进制不可读就无法执行，属物理限制；`service=1` 记录的是
  「尝试过恢复」，用户靠 `update-failed` 横幅 + 重试补齐。
- **退出码**：NSIS 失败路径仍返回 `exit=0`，失败只靠 `update-failed` 标记识别。
- daemon.log 里有「找不到照片库」警告，是此前 E3 会话把旧照片库挪走后遗留的机器状态，与本卡无关。

## 证据

- 脚本（可重复执行）：`tools/e3/scenarios/win/update-failed-recovery.sh`。
- 原始证据（本机，gitignore 的 `evidence/` 下）：`evidence/manual/2026-11-17-update-failed-recovery/win-update-failed-recovery/`
  - 三组：`main/case-running/`（失败/服务运行）、`main/case-stopped/`（失败/用户停止）、`main/case-normal/`（正常对照）。
  - 每组含 `install.txt`（安装器）、`*-update-failed.txt`（标记）、`*-state.txt`（服务/版本/自启状态）、
    `diag-export.json`（IPC）、`*-daemon.log`（服务日志尾）、`stopped-samples.txt`（用例 2 采样）。
  - 判定：`judge-main.txt`（17 ok）、`judge-counter.txt`（3 FAIL 反证）、`verdict.txt`（PASS）、`run.log`（全程）。
