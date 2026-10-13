# iOS 本地开发环境（新机器照做）

> 先跑 `tools/ios/env-check.sh`：只检查、不安装，逐项告诉你缺什么、怎么装。本文是它每一项的出处与原因。
> 依赖清单来自仓库脚本的实际调用（`tools/ios/*.sh`、`tools/build-ios-transport-xcframework.sh`），不是凭印象列的。

## 1. 需要装的东西

| 东西 | 为什么 | 怎么装 |
|---|---|---|
| macOS + Xcode 26（CI 用 macos-26 镜像，Xcode 26.x） | 构建、模拟器、真机签名 | App Store 装 Xcode；`sudo xcode-select -s /Applications/Xcode.app`；Xcode Settings → Components 下载一个 iOS 模拟器 runtime |
| `xcodegen`（CI 钉 2.45.3） | `PPass.xcodeproj` 由 `apps/ios/project.yml` 生成、不入库 | `brew install xcodegen` |
| `rustup` + 两个 iOS target | 传输 XCFramework（provider / BLAKE3 / 控制面）由 Rust 编出两个切片 | rustup 官网安装（别用 brew 的 rust）；`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`。工具链版本由仓库根 `rust-toolchain.toml` 钉死，进仓库目录自动装 |
| `jq` | `tools/ios/test.sh`、`sim.sh` 解析 simctl 输出 | `brew install jq` |
| `libheif`（brew） | 端到端与传输 FFI 测试要起本机 daemon，它的 media-codec 依赖这个系统库 | `brew install libheif` |
| `ffmpeg`、`sips`、`sqlite3`、`lsof` | 只给端到端 / PPassMedia 集成测试用：现造 jpg/heic/mp4、读 TCC 库、找 daemon 端口。`sips`、`sqlite3`、`lsof` 是 macOS 自带 | `brew install ffmpeg` |
| `just`（可选） | `just ios-gen`、`just ios-strings` 等快捷入口；不装也能直接跑脚本 | `brew install just` |

不需要：CocoaPods、Carthage、Node（iOS 线不用）、任何 Apple 证书文件。

## 2. 一条命令跑测试

```
tools/ios/test.sh              # XcodeGen 生成工程 → 模拟器上 xcodebuild test（App 契约测试）
tools/ios/test-packages.sh     # apps/ios/Packages/* 每个本地包在模拟器上测
tools/ios/test-transport-ffi.sh # 传输 XCFramework + Swift FFI 测试（模拟器 + 本机隔离 daemon）
tools/ios/e2e-sim.sh           # 模拟器端到端：配对 → 选相册 → 前台备份 → daemon 库里 BLAKE3 逐个一致 → 时间线可见
```

- 第一次会先编传输 XCFramework（两个 iOS 切片，冷缓存约十分钟），产物在 `apps/ios/TransportFFITests/Generated/`（不入库）；要强制重编就删这个目录。
- 模拟器由 `tools/ios/sim.sh` 选（最新已装 runtime 上的 iPhone 17，没有就现建）。脚本只关它自己启动的模拟器，你开着的不动。
- 端到端用专用模拟器 `PPassE2E`，daemon 用 fake HOME + 临时库 + OS 分配端口，不碰你本机已装的 P-Pass、不碰 41145 端口。输出与截图在 `apps/ios/build/e2e/`。
- 这些脚本都**不签名到任何团队**（模拟器只做 ad-hoc 签名），所以没有 Apple 账号也能全部跑通。CI（`ci-ios.yml`）跑的就是前三条。

## 3. 真机

只在要装到真机、跑真机端到端（`tools/ios/e2e-device.sh`）时需要：

1. 让团队所有者把你的 Apple ID 邀请进团队 **2WJUWVUJBN**，你在 Xcode → Settings → Accounts 登录该 Apple ID。团队写死在 `apps/ios/project.yml` 的 `DEVELOPMENT_TEAM[sdk=iphoneos*]`，**只用这个团队，不要换成别的团队**。
2. 构建时带 `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`：自动签名会在团队里登记设备、生成描述文件，不用手动做。具体命令、安装、取证见 [runbook/ios-device-forensics.md](runbook/ios-device-forensics.md)。
3. 手机开启开发者模式、信任这台电脑；首次安装弹窗（相册、本地网络、信任开发者）要在手机上点，脚本不替点。

**不需要备份任何 p12 或描述文件。** 签名是自动签名 + 云托管：证书与描述文件由 Apple 侧保管，换机器重新登录 Apple ID 即可；CI 上传 TestFlight 走 App Store Connect API 密钥（只存在 GitHub Secrets），同样不涉及 p12。

## 4. 发 TestFlight（需要时）

正式流程见 [RELEASING.md](RELEASING.md)「iOS / TestFlight」：打 tag，`release.yml` 的 `ios` job 自动归档并上传。
手动验证（不打 tag）：`gh workflow run ci-ios.yml --ref <分支> -f testflight_version=v0.9.13-test.1`，版本必须是 `-test.N` / `-beta.N`；同一个号只能上传一次，失败重试把 N 加一。
本机不需要、也没有 API 密钥；本地只能 `PPF_BUILD_VERSION=… tools/ios/testflight-upload.sh --archive-only` 验证归档与版本号（用你 Xcode 登录的账号签名，不上传）。

## 5. 常见坑

- **模拟器相册授权**：`simctl privacy grant photos` 写进 TCC 库的行是 `auth_version=1`，App 读到的是「未决定」、一张照片也取不到；要把 `auth_version` 改成 2。`apps/ios/Packages/PPassMedia/scripts/sim-photos-auth.sh` 已封装，`auth_value=3` 是部分授权。SwiftPM 包的测试进程没有 bundle 身份，TCC 直接拒绝，所以 PPassMedia 的集成测试要挂宿主 App。详见 [PPassMedia README](../apps/ios/Packages/PPassMedia/README.md)。
- **模拟器切片只有 arm64**：传输 XCFramework 的模拟器切片只编 `aarch64-apple-ios-sim`，工程里 `EXCLUDED_ARCHS[sdk=iphonesimulator*]: x86_64`。Intel Mac（x86_64 模拟器）不支持。
- **链接报 `Undefined symbols _nw_*`**：缺 Network.framework。iroh 依赖的 netdev 要用它；project.yml 与 `PPassTransport` 包都显式链接了 Network / SystemConfiguration / Security，自己新建 target 时别漏。
- **最低 iOS 16**：不许用 iOS 17 才有的 API（`@Observable` 等），状态用 `ObservableObject`。
- **daemon 必须绑 `0.0.0.0:0`**：端到端里绑 `127.0.0.1` 会让首次拉取约 30 秒后失败（根因未查清，见 ios-device-forensics.md）。
- **模拟器全被判不可用（`Unable to find a destination`）**：Xcode 自带的 SDK 比已装模拟器 runtime 新时会这样，`tools/ios/test.sh` 失败时会打印让该 SDK 用已装 runtime 的解法。
- **改了 `assets/i18n`、Android `strings.xml`、`assets/design/tokens.json`**：iOS 有逐字节副本，要跑 `just ios-sync-i18n` / `just ios-strings` / `just ios-tokens` 并提交生成物，否则 ci-ios 红。
- **版本号**：构建号（`CFBundleVersion`）由 `tools/ios/stamp-version.sh` 按 `PPF_BUILD_VERSION` 换算，本地构建回退 `Base.xcconfig` 里的 `PPASS_FALLBACK_VERSION`；上传 TestFlight 绝不能走回退值（会占掉正式版的构建号），脚本已拒绝。
