# 复测报告：Windows 服务版 + Android v0.10.0-test.14（2026-10-28）

> 对象是 [test.13 全量回归](2026-10-27-full-regression-windows-v0.10.0-test.13.md) 发现的四个问题，修复见 #1240。本轮全部按**全新安装**验证：Windows 版尚未发布，没有要保住数据的已装用户。除清环境重装时的一次 UAC 外，全部由 agent 完成：手机授权与配对确认用 adb 代点，桌面用 UI Automation 代点。
>
> **结论：四个问题都已修好。** test.13 的两个不能发版项（#1238、#1239）复测通过，#1236、#1237 也通过。照片路径在全新安装上走通：三批共 28 张逐张 sha256 对账，零缺失、零重复。另有两条观察，都不阻塞，见文末。

## 结论摘要

| 卡 | 结果 | 说明 |
|---|---|---|
| #1238 停服后回向导 | ✅ | 停服后仍是主界面、显示「启动后台服务」；停服时能打开照片库；重开 App 不回向导、服务不被拉起；从界面能把服务启动回来 |
| #1239 断开要等 | ✅ | 服务停着时点「确认断开」，下一次界面采样就已回到欢迎页；通知在回页之后才超时打日志。服务在线时 1.19 秒内桌面撤销配对 |
| #1236 诊断包缺 daemon.log | ✅ | 在线导出的包里有本轮 daemon.log（含启停记录），脱敏检索零命中；离线导出写明「日志在服务私有目录，只能由在线的服务交出」 |
| #1237 迁移脚本换行 | ✅ | test.14 的 `daemon.exe` 里 41 处建表语句周围都没有 CRLF；全新安装后服务稳定运行，没有崩溃循环 |

## 环境

| 项 | 值 |
|---|---|
| 候选 | `v0.10.0-test.14`（commit `41cfaef8`）。Windows 安装包 sha256 `5dc3c678…`，APK sha256 `22cc2277…`，都从 Release 下载后核对 |
| 电脑 | Windows 11 x64，测试用开发机，插着电 |
| 手机 | 三星 SM-S9210（Galaxy S24），Android 15。`pm clear` 后装候选 APK，versionName `0.10.0-test.14`（67） |
| 起点 | 卸载 P-Pass，删除 `C:\Program Files\P-Pass`、`C:\ProgramData\P-Pass`、库目录、`%LOCALAPPDATA%\com.hawkeyexb.ppass.desktop`（含上一轮为绕开 #1238 补写的用户侧 `config.toml`）后静默安装。手机测试相册 `DCIM/PPassRegression` 清空 |

## 逐条结果

| ID | 结果 | 证据 / 备注 |
|---|---|---|
| A1 全新安装（#1237） | ✅ | 卸载、清目录、`/S` 安装都退出码 0。服务 AUTO_START、`NT SERVICE\P-Pass`，IPC `unconfigured:true`，20 秒后 pid 不变、无崩溃循环。用户目录下没有 `config.toml` |
| A2 手机清装 | ✅ | `pm clear`、`install -r -d` 成功；测试相册 549 个旧文件删除并触发扫描，只动了这一个目录 |
| A3 向导（#1238 存取对应） | ✅ | 三步向导走完，`ONLINE_DIRECT`。非提权读 `C:\ProgramData\P-Pass\config.toml` 成功，内容只有 `data_dir`、`bind_addr`、`relay_urls`；`icacls` 显示 `BUILTIN\Users:(R)`；列目录 `C:\ProgramData\P-Pass` 仍被拒绝 |
| A4 配对 | ✅ | 手动配对串路径，桌面填 6 位码「允许加入」。第一次在 15 秒内没连上（电脑与手机不在同一 /23 网段），重新发起后成功。照片权限「全部允许」，范围只选 `PPassRegression` |
| A5 首批备份 | ✅ | 20 张约 10 秒入库，对账 20/20/20/0/0 |
| B1 停服不回向导（#1238） | ✅ | 设置页「停止后台服务」后：服务 STOPPED，`wanted-state=stopped`，用户目录**没有** `desktop-user-stopped`（只记一份）。界面是主界面：「后台服务已停止，开机不再自动运行」+「启动后台服务」。停服时「打开照片库」打开了 `P-Pass Library`。结束 App 再打开：仍是主界面，90 秒内 9 次采样服务都是 STOPPED。点「启动后台服务」：约 15–16 秒后 RUNNING、`wanted-state=running`、`ONLINE_DIRECT`。+5 张，对账 25/25/25/0/0 |
| B2 诊断包（#1236） | ✅ | 在线 `diag export`：10 个文件，有 `daemon.log`（24 KB，从首启向导到 B1 启停都在），没有 `daemon-log-missing.txt`；`log-sources.txt` 写「`C:\ProgramData\P-Pass\logs\daemon.log` —— 已收入包内」。在线包与离线包按文本和原始字节各检索一遍：配对令牌、手机 NodeId 全长、用户名、测试文件名都是 0 命中。停服后导出：`daemon-log-missing.txt` 写「后台服务以系统服务运行，daemon.log 在服务的私有目录里，只能由在线的服务自己交出来；导出时服务不在线」 |
| B3 R4.1b 停服时断开（#1239） | ✅ | 点「确认断开」后，下一次界面采样（采样本身约 2.2 秒）已是欢迎页。`unpair: … unreachable, not retried` 在 15 秒后才打出，即通知在后台，不挡界面。服务恢复后桌面该设备仍是 paired（主动断开只尽力通知一次，预期） |
| B3 重新配对 | ✅ | 桌面仍信任这台手机，所以重输配对串后不需要在桌面点允许，手机直接回首页（「重连以前连过的电脑」路径，`PAIRING_REPAIRED`）。范围仍是 `PPassRegression`，旧照片不重传 |
| B3 R4.1 在线断开（#1239） | ✅ | `unpair: … acknowledged`，桌面 1.19 秒内 `paired=false`，手机在欢迎页。再配对走「请求重新连接 / 允许重连」。+3 张，对账 28/28/28/0/0 |

## 观察（不阻塞）

1. **向导完成那一刻，系统记一条「服务意外终止」**（SCM 事件 7031）。daemon 写好库位置后按 #1115 的约定以退出码 75 退出，让服务管理器带着库重新拉起；这个约定是给 macOS launchd 设计的，在 Windows 上 SCM 把非零退出当成故障，记 7031，并按失败动作 5 秒后重启。功能上没有问题，但会在系统日志里留一条假崩溃，并占用一次失败动作计数。建议另开卡，改为服务形态下正常报告停止后再由服务管理器拉起。
2. **从界面启动服务约 15–16 秒**才到 RUNNING（两次测量都含工具启动约 1 秒开销）。test.13 上这条路径因为 #1238 走不通，本轮是第一次测到。不影响正确性，值得在后续查一下慢在哪一段。

## 本轮对测试机状态的改动

- 卸载重装 P-Pass，清空 ProgramData、库目录、用户 AppData（一次 UAC）。
- 手机 `pm clear` 后装 test.14；测试相册 `DCIM/PPassRegression` 清空后放入 28 张程序生成的测试图。
- 收尾状态：服务 RUNNING，库 28 张。手机 test.14、已配对、范围只有 `PPassRegression`。测试源图已删，只留 sha256 清单。

## 证据

都在 Windows 回归机 `C:\Users\ethan\ppcheck\t14\<用例号>\`。配对串、全长 NodeId 只存在 `t14\secrets\`，没有进本报告。
