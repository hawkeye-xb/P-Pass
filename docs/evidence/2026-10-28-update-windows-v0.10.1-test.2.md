# 应用内更新验证：Windows 服务版 v0.10.1-test.1 → test.2（2026-10-28）

> 对象是 #1246 的原场景：**CI 出的包走应用内更新**之后，已配置的机器不能退回首启向导。test.2 来自 `684f1c80`（#1250，含 #1246 / #1249 修复）；test.1 来自 `128d363e`（不含修复）。验证只在电脑上做，「手机」用 test.1 release 自带的 `testclient.exe` 模拟。除应用内更新时安装器的一次 UAC 由人点外，其余全部由 agent 完成（界面用 UI Automation，原生对话框按钮用 `BM_CLICK`）。
>
> **结论：通过。** 更新后 App 直接回到「后台服务运行中」，没有进向导；daemon 与桌面都换成 test.2，服务仍是 `NT SERVICE\P-Pass`；配对与 5 张照片原样保留，sha256 逐张一致；从点「确定」到恢复运行 21.3 秒；全程没有用户身份的 `ppf-daemon`。

## 结论摘要

| 项 | 结果 | 说明 |
|---|---|---|
| ① 不进向导 | ✅ | 新 App 17:18:20 启动，17:18:22.743 `starting → running`；300 个每秒样本里向导 0 次 |
| ② 版本换新 | ✅ | `ppf-daemon --version` 与桌面 exe 都是 `0.10.1-test.2`；服务 RUNNING / AUTO_START / `NT SERVICE\P-Pass`；没有 `update-failed` 标记；`config.toml` 仍有 `BUILTIN\Users:(R)` |
| ③ 数据保留 | ✅ | IPC `ONLINE_DIRECT`、`photo_count` 5、`paired_devices` 1（`W4-testclient` `paired:true`），桌面指纹 `E79C 6BF7` 不变；库里 5 个文件 sha256 与基线逐一比对，0 差异 |
| ④ 没有用户身份 daemon | ✅ | 更新全程 300 个样本，每次用 WMI 查 `ppf-daemon.exe` 的属主，没有一次是登录用户 |
| ⑤ 耗时 / 7031 | 21.3 秒 / 未见记录 | 17:18:01.417 点「确定」→ 17:18:22.743 恢复运行。System 日志里 P-Pass 的 SCM 事件 0 条；但 System 日志最新一条停在 16:38:40，更新期间整个日志没有新事件，所以「没有 7031」只能说明日志里没有记录 |

## 环境

| 项 | 值 |
|---|---|
| 起点 | 卸载后删除 `C:\ProgramData\P-Pass`，全新安装 `v0.10.1-test.1`（安装包 sha256 `f0f69395…1b21`，与 release 的 `SHA256SUMS-windows-x64` 一致），向导走完，服务 RUNNING。全新安装经用户本人在 Windows 会话里同意 |
| 更新目标 | `v0.10.1-test.2`，release 的安装包 sha256 `7cb99697…0cf3`；`test-channel/manifest-windows.json` 指向它 |
| 电脑 | Windows 11 x64，测试用开发机 |
| 手机 | 不用真机。test.1 release 自带的 `testclient.exe`（sha256 `dc862a80…8b65`，与 `SHA256SUMS` 一致）当虚拟设备 |

## 基线（更新前，test.1）

1. IPC `pairing.start` 拿配对串，`testclient pair` 发起配对；按 `tools/ios/sandbox-desk.sh` 里 `desk_auto_allow` 的做法，从客户端打出的 `PAIR_CODE=<6 位> node=<id>` 取验证码，`pairing.confirm {accept, node_id, code}` 确认，桌面答 `decided:true`。
2. `testclient backup --files 5` 推 5 个文件，存储端实收 5 个新 blob。
3. 记录：`ONLINE_DIRECT`、`0.10.1-test.1`、`photo_count` 5、`paired_devices` 1、指纹 `E79C 6BF7`；5 个文件（`originals\df1641d3…\2026\10\IMG_0000.jpg` … `IMG_0004.jpg`，各 16388 字节）：

| 文件 | sha256 |
|---|---|
| IMG_0000.jpg | `d087b5231f9e02782b2012dd092886597ed58173ad16e6cc20d024456660f8a9` |
| IMG_0001.jpg | `b029cb5d7dcb1755cb63be6da2ed29951c7cd9a3f489285b9d2fb2df44df3d82` |
| IMG_0002.jpg | `3ae8ba6c8887da74a075d1c46762c23e0ad75661b9f4829942f6361f9feb63dc` |
| IMG_0003.jpg | `124588aa2941de2f57a0d90dd0343879cc36b7ef040e44c13dbe3cc022b7eacd` |
| IMG_0004.jpg | `91b96366376a6546786ad1a1a5697f5647f907556dd9197d9c6313a1f4007bb7` |

## 更新过程

| 时刻 | 事件 |
|---|---|
| 17:18:01.417 | test.1 App「设置 → 检查更新」弹出「发现新版本 0.10.1-test.2，是否下载并安装？」，点「确定」 |
| 17:18:06 | 界面「正在下载更新… 57%」 |
| 下载完成后 | 安装器弹 UAC，由人在机器旁点掉（agent 的轮询没来得及抓到弹窗） |
| 17:18:20.018 | 新 daemon 启动（IPC `started_at`）；新 App 同一秒起来 |
| 17:18:20.7–20.9 | 新 App 连 daemon 三次未就绪（`err_connect`），属于启动宽限内的正常重试 |
| 17:18:22.743 | `starting → running`，界面「后台服务运行中」 |

每秒样本：更新前 32 个运行中 → 安装期间窗口不在（14 个）→ 新窗口渲染中（5 个）→「正在启动…」（3 个）→ 之后 246 个都是运行中。

## 观察（不阻塞）

1. **点「检查更新」的入口是原生对话框**：按钮在 UI Automation 里是没有 Invoke 模式的 `Pane`（Win32 `Button` 类），自动化只能发 `BM_CLICK`。对人没有影响，记下来给以后的自动化回归用。
2. **System 日志没有新事件**：16:38:40 之后整个 System 日志都没有新记录（沙盒内外查询结果一致），所以本轮无法用 SCM 事件确认有没有 7031，只能说没有记录。上一轮（#1246 修复验证）同类安装记录到了 7031，本轮看不到，原因待查，不影响以上结论。

## 本轮对测试机状态的改动

- P-Pass 现在是 `0.10.1-test.2`，服务 RUNNING，库 5 张（testclient 生成），配对 1 台虚拟设备 `W4-testclient`，App 在主界面。
- 全新安装 test.1 前，原库与壳数据改名为 `*.bak-t101-163802` 留底，没有删除。
- 三星测试机没有动。

## 证据

都在 Windows 回归机 `C:\Users\ethan\ppcheck\t101\`：`fresh.log`（全新安装）、`prep\`（test.1 向导与快照）、`tc\`（testclient 配对 / 备份输出，配对串已脱敏）、`baseline\`（基线 IPC 与 sha256 清单）、`upd\`（`update-start.txt`、`watch-upd.txt` 300 个样本、`user.log`、`snap\`、`library-sha256-after.csv`、`desktop-log-window.txt`、`scm-events.txt`）。
