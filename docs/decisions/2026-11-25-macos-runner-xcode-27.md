# macOS runner 全仓统一升级为 xcode-27

- 状态：已采纳
- 日期：2026-11-25
- 采纳：产品负责人 2026-11-25 拍板立项升级 `xcode-27`
- 取代：[macOS runner 全仓统一 macos-26](2026-11-06-macos-runner-26.md)
- 关联：#2030（本方案）、#2031（实现卡）、#1477

## 结论

1. 全仓所有 GitHub Actions macOS CI 与发布 job（共 6 处）从 `runs-on: macos-26` 统一升级为 `runs-on: xcode-27`（GitHub 托管的 macOS 27 arm64 + Xcode 27.1+ / iOS 27.1+ SDK 镜像），不再分散保留旧版本。
2. 具体修改位置（由 #2031 实现）：
   - `.github/workflows/release.yml`：`macos-arm64`（桌面打包签名公证）与 `ios`（TestFlight 归档云签名上传）两处；
   - `.github/workflows/ci-ios.yml`：`ios`（模拟器单测/隐私清单/SwiftPM/TransportFFI）与 `testflight`（手动上传）两处；
   - `.github/workflows/ci-rust.yml`：`test-platform-macos` 一处；
   - `.github/workflows/artifacts.yml`：`macos-arm64-bin` 一处；
   - `.github/actionlint.yaml`：在 `self-hosted-runner.labels` 登记 `xcode-27` 标签；
   - `tools/test-macos-runner.sh`：把 `macos-26` 一并划入禁用旧 runner 正则（`macos-(14|15|26|latest)`），断言全仓 `runs-on: xcode-27` 数量 `>= 6`，带正反例反证；
   - `tools/ios/env-check.sh` 与 `docs/ios-dev-setup.md`：同步说明 CI 使用 `xcode-27`（Xcode 27）。
3. 若升级后在 `xcode-27` 预览镜像遇到 GitHub 托管容量排队故障或 Xcode 27 编译器阻塞性上游 bug，允许凭新方案或回滚提交一键整体切回 `macos-26`（2027 年 4 月前 `macos-26` 仅告警不拒收）。

## 背景

2026-11-24 `v0.12.1-test.4`（Release run `45431869915`）在 `macos-26`（Xcode 26.6 + `iphoneos26.5` SDK）上归档上传 TestFlight 时，App Store Connect 返回 `ITMS-90725` 告警：

> `SDK version issue. This app was built with the iOS 26.5 SDK. Starting April 2027, iOS and iPadOS apps must be built with the iOS 27 SDK or later, included in Xcode 27 or later, in order to be uploaded to App Store Connect or submitted for distribution.`

GitHub Actions 当前 `macos-26` 镜像最高仅安装 Xcode 26.6（`iphoneos26.5` SDK），而 Xcode 27（`27.1` 默认 / `27.2` 可选，含 `iphoneos27.1` / `iphoneos27.2` SDK 与 `iPhone 17` 模拟器，底层 OS 为 macOS 27.0.1 arm64）以独立镜像标签 `runs-on: xcode-27` 提供。`.github/workflows/release.yml` 属于 `.github/core-paths.txt` 核心路径，须先合入已采纳方案再实施。

## 理由

- **本质保证**：iOS TestFlight 与 App Store 分发包由 Apple 要求的最新一代 iOS 27 SDK 构建，且 CI 验证环境（`ci-ios`、`ci-rust`）与正式发布构建环境（`release.yml`）使用完全同一代 macOS / Xcode 工具链，杜绝「CI 用旧 SDK 绿、发版用新 SDK 炸」或反向漂移。
- **对齐既有原则**：延续 `2026-11-06-macos-runner-26.md` 确立的「追新不追旧、全仓统一单一 macOS runner 标签」原则，并用 `tools/test-macos-runner.sh` 静态门禁锁死，防止后续 workflow 混回 `macos-26`。
- **兼容性核实**：
  - `tools/ios/sim.sh` 动态选取最新可用 iOS runtime 下的 `iPhone 17` 设备，`xcode-27` 镜像内置 iOS 27.0 / 27.2 的 `iPhone 17` 模拟器，无需硬编码系统版本；
  - `.github/actions/codecs-macos` 缓存键包含 `${ImageOS}`，切到 `xcode-27` 后会自动隔离并重编 `libheif` + `libde265`；
  - 全仓 Rust 与桌面壳使用 `rustls` / Apple Security framework，不链接系统或 Homebrew OpenSSL，不受 `xcode-27` 默认 OpenSSL 3→4 变更影响。

## 后果

- **正面**：消除 TestFlight / App Store 上传的 `ITMS-90725` 告警，提前满足 Apple 2027 年 4 月硬性门槛；全仓 macOS / iOS 构建与测试统一运行在 macOS 27 + Xcode 27 上。
- **代价与风险**：
  - `xcode-27` 目前在 GitHub Actions 仍标为 public preview，偶发排队时间可能略高于 GA 镜像；
  - 首次切换时 `codecs-macos` 与 cargo 缓存按新镜像重热一次；
  - 下一个 test 包（`just release-test`）需实跑确认 `macos-arm64` 的 Developer ID 签名、notarytool 公证、stapler 装订以及 `ios` TestFlight 上传日志不再出现 `ITMS-90725`。

## 备选

- **只把 `release.yml` 的 `ios` job 切成 `xcode-27`，其余留 `macos-26`**：不选。会导致 `ci-ios`（Xcode 26）与发布归档（Xcode 27）编译器及 SDK 代差分裂，Xcode 27 下的编译或行为问题在 PR 门禁抓不到，拖到发版才炸。
- **保持 `macos-26` 等到 2027 年初再切**：产品负责人已拍板现在直接切 `xcode-27` 提前收敛告警并验证新工具链，不留技术债尾巴。
