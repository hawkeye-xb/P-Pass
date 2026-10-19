# iOS 真机取证与安装（#347）

下面的命令都在本机（iPhone 16，iOS 26.3，Xcode 17F113）跑过并看到输出。`<id>` = `xcrun devicectl list devices` 里的 Identifier。

## 构建、签名、安装、启动

- 列真机：`xcrun devicectl list devices`（`available (paired)` 或 `connected` 才能装）。
- 构建：`cd apps/ios && xcodegen generate && xcodebuild build -project PPass.xcodeproj -scheme PPass -destination 'id=<硬件 UDID>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration -derivedDataPath <dir>`。
  - 硬件 UDID 与 devicectl 标识不同，前者形如 `00008140-…`，`xcodebuild -showdestinations` 能看到。
  - 签名团队写在 `apps/ios/project.yml` 的 `DEVELOPMENT_TEAM[sdk=iphoneos*]`（一处），只对真机 SDK 生效，只用个人团队。
  - 前置：Xcode Settings → Accounts 已登录该团队的 Apple ID。没登录时报 `No Accounts` / `No profiles for 'com.hawkeyexb.ppass' were found`，agent 不能代填 Apple ID 凭据。
- 安装：`xcrun devicectl device install app --device <id> <dir>/Build/Products/Debug-iphoneos/PPass.app`
- 启动（带环境变量）：`xcrun devicectl device process launch --device <id> --terminate-existing --environment-variables '{"K":"V"}' com.hawkeyexb.ppass`
- 启动并看控制台（NSLog 的 `[PPass]` 行直接在终端出来，Ctrl-C / kill 结束）：`xcrun devicectl device process launch --console --terminate-existing --device <id> com.hawkeyexb.ppass`

## 取证

- 列 App 容器文件：`xcrun devicectl device info files --device <id> --domain-type appDataContainer --domain-identifier com.hawkeyexb.ppass`。
  App 容器里能看到 `Library/Logs/ppass.log`、`Documents/e2e/…`（DEBUG 驱动写的）、`tmp/…`；**存储根不在这里**。
- **存储根在 App Group 容器**（`group.com.hawkeyexb.ppass`，每次启动日志有 `storage: using App Group container …`）：`backup-orders.db(-wal/-shm)`、`backup_scope*.json`、
  各类偏好 / 去重 json、`blobs/` 都在里面。`devicectl` 只能取 App 容器，**拉不到 App Group**。
  要看账本：用 DEBUG 驱动 `PPASS_BGTEST_DUMP=1` 启动 App（`devicectl device process launch --environment-variables '{"PPASS_E2E_DIR":"container","PPASS_BGTEST_DUMP":"1"}' …`），
  它把 `backup-orders.db / -wal / -shm` 拷进 App 容器的 `Documents/e2e/db`，再按下一条拉回（`tools/ios/sim-bg-task.sh`、`tools/ios/e3-batch.sh` 都这么做）。
  偏好 / 去重 json 目前没有导出入口，状态以日志为准（#1026 起成功路径也有日志）。
- 拉文件：`xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.hawkeyexb.ppass --source <设备内相对路径> --destination <本机路径>`。
  SQLite 的 WAL 库要把 `.db`、`-wal`、`-shm` 三个文件拉到同一目录再用 `sqlite3 -readonly` 打开，只拉 `.db` 打不开。
- 端到端脚本拿状态就是用这条：App 的 DEBUG 驱动把 `status.json` 写进 `Documents/e2e`，脚本循环拉回（见 `tools/ios/e2e-device.sh`）。
- 不可用：`/usr/bin/log collect --device-udid <硬件 UDID> --last 5m` 要 root（`Must be root to collect logs from attached device`），agent 不用 sudo；
  取日志改用上面的 `--console` 启动，或让用户在终端里用 sudo 跑。zsh 里 `log` 是内建命令，要写 `/usr/bin/log`。

## 后台日志（#955）

- App 把每一行 `[PPass]` 日志同时写进容器内 `Library/Logs/ppass.log`（`AppLog`，前台、BGTask / 静默唤醒拉起都写）。单文件约 1 MB，满了换成 `ppass.log.1`，只保留这 2 份；每行带 ISO8601 毫秒时间戳。写失败不影响业务。
- 每次进程启动第一行是 `process start: pid=… version=… appState=active|inactive|background`（只是原始值，不据此判来源）；
  第一个真实入口到达时另记一行 `launch origin: foreground|background (<任务标识>)`（`LaunchOriginRecorder`）。后台任务被系统拉起时还有 `background task launched (<reason>)`。
- 取回：`tools/ios/pull-logs.sh [设备标识] [尾部行数]`（不给设备就取第一台 connected 的 iPhone），文件落在 `apps/ios/build/device-logs/<时间戳>/`，并打印尾部。
  等价的手工命令：`xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.hawkeyexb.ppass --source Library/Logs/ppass.log --destination <本机路径>`。
- 隐私：不写照片文件名、相册名、配对票据 / peerToken；照片标识只写 8 位 hash 前缀（`LogRedact.id`），落盘前 `LogRedact.scrub` 再兜底抹掉媒体文件名与 ≥32 字符的 ticket / token 串。新增日志行照此口径，不拼文件名与凭据。
- 在真机上触发一次 BGTask：App 已装并启动过、且已配对并开了自动备份（这样才有任务被提交）→ 用 Xcode 附加调试器运行（Debug），暂停后在 LLDB 里执行
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.hawkeyexb.ppass.backup"]` 再继续；
  再 `pull-logs.sh`，应看到 `background task launched`。此命令只在调试器里可用，命令行 / devicectl 触发不了。
  两个任务标识：长任务（BGProcessingTask）`com.hawkeyexb.ppass.backup`，短任务（BGAppRefreshTask，#958）`com.hawkeyexb.ppass.refresh`。
  可重复的短任务场景用 `tools/ios/sim-bg-task.sh short-only | expire | budget`（脚本自己附加 lldb 触发）。
  要看「进程本身被后台拉起」的 `launch origin: background`，需让系统真实调度（锁屏、接电源、等待）；调试器模拟是在已运行进程内触发回调，来源仍是前台。

## 真机回归的日志判定（#939）

- `tools/ios/e3-judge.sh mark` 记下起点；人在手机上操作后，`tools/ios/e3-judge.sh check <阶段>` 拉日志（只看起点之后）并判 PASS / FAIL，可重跑。
- 阶段：`foreground-notice`、`onboarded-at-finish`、`prewarm-park`、`no-inactive-catchup`、`956-offline`、`956-delivered`（顺带读本机桌面库的 device 表）、`onboarding`、`wifi`、`autobackup-on`、`notify-media`、`notify-media-dedupe`、`notify-bgrefresh`。
- 判据都是日志里的成功行（#1026 起成功路径也落日志）；新卡在验收里写明「日志里出现哪一行算通过」，再把它加成一个阶段。

## 本机隔离 daemon 与端到端

- 脚本：`tools/ios/e2e-device.sh`（真机）、`tools/ios/e2e-sim.sh`（模拟器）。两者都用 fake HOME + 临时库 + OS 分配端口（不碰 41145、不碰已装 P-Pass）。
- daemon 必须绑 `0.0.0.0:0`，不能绑 `127.0.0.1:0`：
  - 模拟器上绑 127.0.0.1 时，首次拉取固定卡约 30 秒后 `fetch_failed`（`io: connection lost`），引擎再重试才成功；偶尔重试也不出字节，180 秒超时。
  - 绑 0.0.0.0 后同一台模拟器上首张 0.07 秒送达；真机（局域网）首张不到 1 秒。
  - daemon 日志（`RUST_LOG=info,iroh=debug,noq_proto=debug`）里 `path::selected` 显示：两种绑法一开始都先走 n0 relay，随后切到直连 IP 路径
    （真机 `Ip(10.1.151.23->10.1.151.156:…)`，模拟器 `Ip(10.1.151.23->10.1.151.23:…)`）。绑回环时只有 `127.0.0.1->127.0.0.1` 这一条候选，切换前那次拉取就断了。
  - 根因（#942 / #934 已查清）：iroh 的 `bind_addr("127.0.0.1:0")` 把这个 v4 socket 当成**所有** IPv4 目的地的默认路由。
    provider 的 ticket 只给宿主局域网地址（如 `10.1.151.23`），daemon 从 127.0.0.1 socket 发过去，内核照样投递（是本机地址），
    provider 看到连接来自 `127.0.0.1`。双端日志：daemon 端 `Connection established` 后丢弃 provider 重传的 Initial，
    15 秒 `failed closing path err=LastOpenPath`（path idle）、30 秒 `conn::closed reason=TimedOut`；provider 端
    `PTO expired while unset path_id=0`，最后 `Accepting incoming connection ended with error: timed out`——provider 端握手始终没完成。
    （推断：daemon 后续包的本端地址与首包不一致，provider 无法匹配到这条连接；未在 noq 源码里逐行证实。）
    最小复现不需要模拟器：同机两个 `IrohTransport`，接收端 `bind_addr=127.0.0.1:0`、提供端默认绑定、无 relay，`Blobs::pull` 固定 30.0 秒 `io: connection lost`；
    接收端改 `0.0.0.0:0` 或不设，0.09 秒完成。重试时成时败的原因没再细查（CI 上 G2 测试绿的两次各约 42 秒，推断是首拉 30 秒失败 + 重试成功；那两次 daemon 日志没保留），去掉触发条件后不再出现。
  - 产品不受影响：daemon 默认不设 `bind_addr`（iroh 默认 `0.0.0.0` + `[::]`），手机 provider 也不设；只有显式把 daemon 绑回环、且 provider 与 daemon 在同一台宿主时才触发。
    `tools/ios/test-transport-ffi.sh`（ci-ios）同样改绑 `0.0.0.0:0`。绑回环本来也不隔离：iroh 仍另绑 `[::]:0` 监听所有接口。
- 真机端到端用 `PPASS_E2E_RESET=1`（脚本已带）在启动前清掉 App 存储根。否则上一轮的账本把「已确认」算给了旧的 daemon，新 daemon 的库是空的，却显示 4/4 已备份（实测复现过）。
- 手机里是真照片：脚本只备份张数最少的非空相册（上限 `PPASS_E2E_MAX_ASSETS`，默认 12），只读；「原始字节」的 BLAKE3 由 App 内独立的 PHAssetResourceManager 读取路径算出，与 daemon 库文件用 Rust blake3 独立算出的值比对。
- 首次装机时系统弹窗（相册权限、本地网络权限、信任开发者）要用户在手机上点；脚本不替点，状态卡在 `started` / `access` 就是在等弹窗。
