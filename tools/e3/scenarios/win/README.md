# Windows 场景（TODO）

接口与 macOS / Android 相同（`tools/e3/run` 的 setup / act / judge / counter）。待收编的现成手段：

- 设备：Windows 回归机（`ssh <主机>`，主机名写在本机 `e3.env` 的 `E3_WIN_HOST`）。设备锁 `tools/e3/lock win`；
  该机同时被别的会话用于修 Windows 问题时，先与对方确认空闲。
- 服务形态 daemon 的判定：服务状态（`Get-Service`）、`C:\ProgramData\P-Pass\logs\daemon.log` 切片、服务管道 IPC
  （服务管道不支持 `pairing.list`，配对数读 `status.paired_devices` 与 `devices.list`）。
- 需要点界面的步骤走 CDP（带 9222 启动 App，经 ssh 隧道连接）。
- 以主人身份或提权执行的步骤用计划任务（交互会话 / RunLevel=Highest），不弹 UAC。

收编时要修的判定脚本误判（test.2 回归报告点名）：

- `t2-elevated.ps1` 的 qprivs 判定：`QPrivs` 只返回一个元素时 PowerShell 把它展开成字符串，`$q[0]` 取到首字符。
  写成 `$q = @(QPrivs ...)` 再取元素。
- §5.2 的正则没考虑日志里的 `verify_service_token: ` 前缀，补上可选前缀再匹配。
