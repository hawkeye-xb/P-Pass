# 应用内更新验证：Windows 服务版 + Android v0.10.0-test.14 → test.15（2026-10-28）

> 两端都从 [test.14 复测](2026-10-28-retest-windows-v0.10.0-test.14.md) 结束时的状态出发（已配对，库 28 张），各自用应用内更新升到 test.15。test.14 与 test.15 的产品代码相同（两个 tag 之间只改了发版 CI 与脚本，#1243），所以本轮验的是**更新路径本身**。
>
> **结论：两端的更新都装上了，数据和配对都在；但 Windows 服务版更新后桌面 App 退回首启向导，不能发版，已开 #1246。** 服务侧符合 #1060 的预期：下载期间服务照常工作，只在安装前停一次（约 8 秒），装完换成新 daemon，期间没有 7031。Android 应用内下载、安装都走通。托盘「导出诊断包」没能点到（BLOCKED），CLI 导出正常。

## 结论摘要

| 项 | 结果 | 说明 |
|---|---|---|
| Windows 检查更新 / 下载（#1060） | ✅ | 发现 0.10.0-test.15；下载期间服务一直 RUNNING、pid 不变 |
| Windows 安装（#1060） | ✅ | 服务只停一次约 8 秒；三处版本号都是 test.15；pid 已换；无 7031；wanted-state 仍 running |
| Windows 更新后界面 | ❌ #1246 | App 重新打开后停在首启向导，重开 App 仍是向导；安装器的 `icacls /reset` 抹掉了 config.toml 的 Users 只读 |
| Windows 数据 | ✅ | 配对仍在；+3 张对账 31/31/31/0/0 |
| 托盘「导出诊断包」（#1063） | ⛔ BLOCKED | 图标在 Win11 溢出区，「显示隐藏的图标」点 3 次未展开，按规程停止 |
| CLI 诊断包 | ✅ | 10 个文件，含 `daemon.log` |
| Android 应用内更新 | ✅ | 下载约 40 秒，系统授权「安装未知应用」后完成安装；仍配对、范围只有 `PPassRegression`；+2 张对账 33/33/33/0/0 |

## 环境

| 项 | 值 |
|---|---|
| 候选 | `v0.10.0-test.15`（commit `6587143f`），发版 run 40637781046 成功。test-channel 清单：Windows 安装包 sha256 `fd19c5e8…`、APK `48249891…`，与 Release 下载的文件一致 |
| 电脑 | Windows 11 x64，测试用开发机。起点：服务版 test.14，服务 RUNNING，`wanted-state=running`，库 28 张 |
| 手机 | 三星 SM-S9210（Galaxy S24），Android 15。起点：test.14（67），已配对，范围只有 `PPassRegression`，28 张 |
| 执行 | U0–U2 的操作由另一个 agent 经 A2A 执行（13:58–14:02），本报告的结论都由本会话按原始证据独立复核；U3、U4 由本会话执行 |

## 逐条结果

| ID | 结果 | 证据 / 备注 |
|---|---|---|
| U0 起点 | ✅ | 桌面 FileVersion、`ppf-daemon --version` 都是 test.14；`wanted-state=running`；手机 paired；对账 28/28/28/0/0；手机 versionName test.14 |
| U1 检查更新与下载 | ✅ | 设置页「检查更新」弹出「发现新版本 0.10.0-test.15，是否下载并安装？」，确定后显示「正在下载更新… 28%」。每秒采样：13:59:19–13:59:54 服务 Running、pid 1800 不变 |
| U2 安装 | ✅（服务）/ ❌（界面） | 采样：13:59:55 StopPending → 13:59:56–14:00:01 Stopped → 14:00:02.9 Running，14:00:03.4 新 pid 10700 可连，之后一直 Running。全程只停一次，约 8 秒。时间窗内 SCM 无任何 P-Pass 事件（无 7031；本机不记 7036）。版本：FileVersion、`--version`、IPC `version` 都是 `0.10.0-test.15`。`wanted-state=running`；用户目录无 `config.toml`、无 `update-failed`，ProgramData 无 `update-failed`。手机仍 paired；+3 张对账 31/31/31/0/0。**桌面 App 在 14:00:02 被重新拉起，但停在首启向导第 1 步**，见下一节 |
| U3 托盘导出诊断包 | ⛔ | 托盘 P-Pass 图标在溢出区。「显示隐藏的图标」UIA Invoke 报 Unsupported Pattern；改用模拟点击（沙盒内、外各一次），光标确已到按钮，但溢出窗口始终 `vis=False`。按规程 3 次即停。未试：Win+B 键盘导航 |
| U3 CLI 诊断包 | ✅ | `ppf-daemon.exe diag export`：README、versions、status、config-summary、log-sources、daemon.log（36 KB）、desktop.log、audit、devices、diag_events。包内 `desktop.log` 仍是升级前的旧文件，与 #1246 一致 |
| U4 Android 应用内更新 | ✅ | 打开 App 即自动弹「发现新版本 v0.10.0-test.15」→「下载安装」→ `PPassUpdate: apk download OK … 46538870 bytes`（约 40 秒）→「立即更新」→ 系统「安装未知应用程序」页，只对 P-Pass 打开「允许权限」→ 14:26:25 `PackageManager: Update package com.hawkeyexb.ppass`。之后 versionName `0.10.0-test.15`（versionCode 仍 67），首页 31/31，存储电脑仍是本机，范围只有 `PPassRegression`。+2 张对账 33/33/33/0/0，桌面 `devices.list` 该手机 `paired=true` |

## #1246：更新后 App 退回首启向导

- 现场：daemon `ONLINE_DIRECT`、库与配对都在，App 却停在向导；结束 App 重新打开仍然如此；新 App 一行 `desktop.log` 都没写。
- 根因：首次向导时 daemon 给 `%ProgramData%\P-Pass\config.toml` 单独授了 `BUILTIN\Users:(R)`（test.14 复测 A3 有这条）；升级时安装器 `icacls "%ProgramData%\P-Pass\*" /reset /T` 把它重置为只继承父目录，之后只补授了 `wanted-state`。壳读不到 config.toml → `configured()` 为 false → 初始状态 `NotConfigured`，连上 daemon 也不转 running → 显示向导。
- 影响：服务版**每次**应用内更新或覆盖安装都会触发。修复方向与验证写在 #1246，待对齐后实施。

## 观察（不阻塞）

1. **Android `versionCode` 没有涨**：test.14 与 test.15 都是 67，覆盖安装照常成功（同号允许）。若以后有渠道按 versionCode 判断新旧，会把这两个版本当成同一个。
2. **手机网络卡死时，手动「检查更新」没有任何反馈**：本轮开始时这台手机的系统网络服务卡住（任何域名都解析失败，`dumpsys connectivity` 超时），点「检查更新」4 分钟以上界面无对话框、无提示。预期应提示「检查更新失败」（REL-07）。可能是 DNS 解析不受 `connectTimeout` 约束、检查一直挂在 Checking；重启手机后网络恢复，未再复现。

## 本轮对测试机状态的改动

- 电脑：P-Pass 经应用内更新升到 test.15（服务 RUNNING，库 33 张）。桌面 App 为查 #1246 重启过一次，目前停在向导，未点「继续」。
- 手机：经应用内更新升到 test.15；P-Pass 获得「安装未知应用」权限。为排查网络：私人 DNS 由 `dns.google` 改为「自动」，PLAUD-CN 关闭「自动重新连接」并改连 PLAUD-OA，Wi-Fi 开关过一次；最后由用户重启手机。测试相册 `DCIM/PPassRegression` 共 33 张程序生成的图。
- 测试源图已删，只留 sha256 清单。

## 证据

都在 Windows 回归机 `C:\Users\ethan\ppcheck\t15\<用例号>\`：服务采样 `U1\service-samples.txt`，复核结果 `U2\verify-*`，托盘尝试 `U3\tray-blocked.txt`，手机界面与日志 `U4\`。配对串与全长 NodeId 没有进本报告。
