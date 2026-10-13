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

- 列 App 容器文件：`xcrun devicectl device info files --device <id> --domain-type appDataContainer --domain-identifier com.hawkeyexb.ppass`（加 `--subdirectory "Library/Application Support/PPass"` 只看存储根）。
  存储根里能看到 `backup-orders.db(-wal/-shm)`、`backup_scope*.json`、`blobs/iroh-blobs-provider/blobs.db`。
- 拉文件：`xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.hawkeyexb.ppass --source <设备内相对路径> --destination <本机路径>`。
  SQLite 的 WAL 库要把 `.db`、`-wal`、`-shm` 三个文件拉到同一目录再用 `sqlite3 -readonly` 打开，只拉 `.db` 打不开。
- 端到端脚本拿状态就是用这条：App 的 DEBUG 驱动把 `status.json` 写进 `Documents/e2e`，脚本循环拉回（见 `tools/ios/e2e-device.sh`）。
- 不可用：`/usr/bin/log collect --device-udid <硬件 UDID> --last 5m` 要 root（`Must be root to collect logs from attached device`），agent 不用 sudo；
  取日志改用上面的 `--console` 启动，或让用户在终端里用 sudo 跑。zsh 里 `log` 是内建命令，要写 `/usr/bin/log`。

## 本机隔离 daemon 与端到端

- 脚本：`tools/ios/e2e-device.sh`（真机）、`tools/ios/e2e-sim.sh`（模拟器）。两者都用 fake HOME + 临时库 + OS 分配端口（不碰 41145、不碰已装 P-Pass）。
- daemon 必须绑 `0.0.0.0:0`，不能绑 `127.0.0.1:0`：
  - 模拟器上绑 127.0.0.1 时，首次拉取固定卡约 30 秒后 `fetch_failed`（`io: connection lost`），引擎再重试才成功；偶尔重试也不出字节，180 秒超时。
  - 绑 0.0.0.0 后同一台模拟器上首张 0.07 秒送达；真机（局域网）首张不到 1 秒。
  - daemon 日志（`RUST_LOG=info,iroh=debug,noq_proto=debug`）里 `path::selected` 显示：两种绑法一开始都先走 n0 relay，随后切到直连 IP 路径
    （真机 `Ip(10.1.151.23->10.1.151.156:…)`，模拟器 `Ip(10.1.151.23->10.1.151.23:…)`）。绑回环时只有 `127.0.0.1->127.0.0.1` 这一条候选，切换前那次拉取就断了。
    这是日志直接支持的现象；「为什么回环绑定会让第一次拉取断掉」的根因没有再往下查，在 iroh / transport 层，另开 issue 查。
- 真机端到端用 `PPASS_E2E_RESET=1`（脚本已带）在启动前清掉 App 存储根。否则上一轮的账本把「已确认」算给了旧的 daemon，新 daemon 的库是空的，却显示 4/4 已备份（实测复现过）。
- 手机里是真照片：脚本只备份张数最少的非空相册（上限 `PPASS_E2E_MAX_ASSETS`，默认 12），只读；「原始字节」的 BLAKE3 由 App 内独立的 PHAssetResourceManager 读取路径算出，与 daemon 库文件用 Rust blake3 独立算出的值比对。
- 首次装机时系统弹窗（相册权限、本地网络权限、信任开发者）要用户在手机上点；脚本不替点，状态卡在 `started` / `access` 就是在等弹窗。
