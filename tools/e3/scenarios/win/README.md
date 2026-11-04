# Windows 回归场景（e3）

本目录把 `docs/runbook/full-regression-sop.md` §4/§9 里 Windows 上 agent 能独立完成的用例写成
`tools/e3/run` 场景。接口与 mac/android 相同；`tools/e3/run list win` 能看到清单。

## 场景与顺序

场景**有前置顺序**，按下面顺序跑（每行括号是前置）：

| id | 覆盖 | 前置 | 反证 |
|---|---|---|---|
| `win/install-baseline` | R0.1 手机基线 0.10.2；R0.2/R0.3 桌面基线 0.10.1 + 首启向导 | 无 | 装好不启动 App（向导不走），版本/主界面判据变红 |
| `win/pair-backup` | R0.4 配对；R0.5 只选 PPassRegression、40 张逐张 sha256 对账 | install-baseline | 从 `originals/` 删一张再对账，sha256 判据变红（teardown 放回） |
| `win/upgrade-candidate` | R1.1/R1.2/R1.4 覆盖升级到候选，桌面/daemon/手机版本一致，配对/身份/照片不丢 | pair-backup | 用升级前的真实快照跑同一判据，版本判据变红（不降级、不动库） |
| `win/backup-after-upgrade` | R1.5 升级后再 push 8 张，增量 +8、不重复 | upgrade-candidate | 不触发这次备份（用 push 前快照 + 8 张哈希），8 张全部报缺 |
| `win/svc-watchdog` | R3.2 强杀 daemon，1 分钟内拉起（壳开/关各一次） | upgrade-candidate | 禁用计划任务再杀，90s 内没有新进程 |
| `win/svc-stop` | R3.3 停服务 2 分钟不被拉起、任务被删、恢复后回来；R4.1 手机断开后桌面标未配对 | pair-backup | 不执行停止（daemon 一直跑），停服务窗口采样出现 pid |
| `win/w1-console-windows` | W1 启动/自愈/停启服务不闪控制台窗口 | 任一已装状态 | 窗口期内开一个可见控制台，watcher 必须报 CONSOLE |
| `win/w2-autostart` | W2 自启是计划任务（指向安装目录 daemon），无 HKCU Run 值 | 任一已装状态 | 临时写一个 HKCU Run 值，判据变红（teardown 删除） |

## 前置条件

- 本机 `~/.config/ppass/e3.env`（不进 git）：
  - `E3_ANDROID_SERIAL=<三星序列号>`
  - 手机经另一台机器转发 adb 时：`ADB_SERVER_SOCKET=tcp:127.0.0.1:<端口>`（见本机 `local-state.md`）
- 安装包缓存：`$E3_STATE/win/releases/<tag>/`（默认 `v2026.10.7` = 基线 0.10.1/0.10.2，
  `v0.11.0-test.1` = 候选）。用 `gh release download` 备好；场景不联网下载。
- `tools/e3/run` 的 lock 用 `/usr/bin/lockf`；Windows Git Bash 没有时，本机调用加
  `E3_LOCKED_WIN=1` 跳过锁（同一台机器只有一个会话时安全）。

## 安装器与 UAC

安装包是 perMachine（PE manifest `requireAdministrator`）：**提权会话**下场景直接跑安装器
（`run-outside-package.ps1`，绕开 MSIX 虚拟化）。**非提权会话**不能弹 UAC，按 SOP「记下、跳过」处理：

- 默认：`win/install-baseline`、`win/upgrade-candidate` 返回 SKIP，原因写「需要 UAC 提权」；
- 设 `E3_WIN_PROVISION=extract`：用**同一个安装包**里的 `p-pass-desktop.exe` / `ppf-daemon.exe` /
  `uninstall.exe` 解到 `%LOCALAPPDATA%\P-Pass`，并写 HKCU 卸载登记（App 只认安装程序登记的
  `InstallLocation`）。这样能在没有提权的机器上继续跑非安装类用例；**报告必须写明「安装器路径未验证」**。
- 解包依赖 7-Zip 的完整版 `7z.exe`（NSIS 格式）；本机放在 `$E3_STATE/win/tools/7zfull/`。

## 判定数据源

- daemon 的 `diag export`（签名 daemon 自己跑的一次性短进程）：`status.json`（版本/状态/照片数/pid）、
  `devices.json`（配对设备，`paired` / `departed_by`）、`daemon.log`。Windows 常驻 daemon 的 IPC 是
  按用户认证的命名管道，外部脚本（python）会被对端身份校验拒绝，所以不直连 IPC。
- 桌面 UI：`tools/windows/uia-drive.ps1` dump/click；原生确认框按钮是 `CCPushButton`，用
  `lib/common.sh` 的 `win_ui_dialog_click`（置前 + BM_CLICK + PostMessage）。
- 手机 UI：`uiautomator dump` + `tools/e3/lib/ui.py`；配对码从桌面剪贴板取（不落盘、不进证据）。
- 对账：手机 `sha256sum` 与库 `originals/` 全量 sha256。

## 已知 Windows 坑（场景已处理）

- adb 的 `/sdcard/...` 必须加 `MSYS2_ARG_CONV_EXCL='*'`，否则被 Git Bash 改写成 `C:\Program Files\Git\...`。
- `python3` 是 Windows 程序：给 `ui.py` 的路径要 `cygpath -w`，`/tmp` 会被解析成 `C:\tmp`。
- PowerShell 5.1 读带中文的 `.ps1` 要 UTF-8 BOM（`gen-photos.ps1` 已加）。
- 计划任务 P-Pass 带每分钟看门狗：覆盖安装/重置前必须 `Stop-ScheduledTask` 再 `Unregister`，
  否则 daemon 会被拉起来占用 exe 文件。
- `uiautomator` 的文本节点没有兜底空格；按按钮时用 `^文字␟` 这类带 `label` 分隔符的正则，
  避免命中标题（例如「断开连接？」和按钮「断开」）。

## 未覆盖（人工 / 管理员 / 安装器）

- R2.1–R2.5 大批量/断网/崩溃/取回/删除、R3.4 Doze、R4.2–R4.3、R5.1–R5.2 隐私检索、R6 界面观感：
  本卡未写成场景（R3.4/R6.2 按 SOP 归人工）。
- W3（daemon 在跑时覆盖安装）、W5（卸载/重装）：安装器路径，需要 UAC 提权。
- W4 `powercfg /requests`：需要管理员；W6 低磁盘通知：需要接近写满的测试机。
