# iOS 隐私清单与 App Store 隐私标签

#937 的隐私部分。这里写两样东西的口径和代码证据：随 App 打包的隐私清单
`apps/ios/PPass/Resources/PrivacyInfo.xcprivacy`，以及在 App Store Connect 里填的「App 隐私」问卷（隐私营养标签）。
两者和官网隐私政策、审核备注必须说同一件事，改其中一处就要核对另外三处。

核于 main `1d7f6159`（2026-10-26）。

## 1. 结论

| 项 | 填法 |
|---|---|
| 隐私标签 | **Data Not Collected**（不收集数据） |
| 追踪（Tracking） | 否；`NSPrivacyTracking = false`，无追踪域名 |
| 清单里的「收集的数据类型」 | 空 |
| 需要理由的 API | UserDefaults `CA92.1`、系统启动时间 `35F9.1`、文件时间戳 `C617.1` |

## 2. 为什么是「不收集数据」

Apple 对「收集」的定义：数据离开设备，并且开发者或其第三方合作方能在超出实时处理所需的时间内访问它。
按这个定义逐条核对 iOS App 的数据流：

| 数据 | 去向 | 项目方能否访问 | 证据 |
|---|---|---|---|
| 照片和视频 | 用户自己配对的电脑，经 iroh 端到端加密传输 | 不能 | `apps/ios/PPass/Live/LiveTransport.swift`、`crates/transport/src/provider.rs` |
| 设备名 | 随配对请求发给用户自己的电脑 | 不能 | `apps/ios/PPass/Live/LivePairing.swift:314`。没有 user-assigned-device-name entitlement，iOS 16 起返回的是「iPhone」这类通用名 |
| 配对身份密钥 | 钥匙串，仅本机，不同步 iCloud | 不能 | `LiveTransport.swift`：`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`、`kSecAttrSynchronizable = false` |
| 诊断日志 | 只写本机容器，落盘前脱敏；只能由用户复制导出 | 不能（除非用户自己发来） | `apps/ios/PPass/Diagnostics/AppLog.swift`、`DiagnosticsScreen.swift` |
| 电量 | 只在本机用于电量策略 | 不能 | `LiveBackend.swift` 的 `batteryLevel` / `batteryState` |
| 通知 | 本地通知，没有 APNs，没有 device token | — | `FailureNotifier.swift`；entitlements 里没有 `aps-environment` |

另外：

- iOS 代码里没有任何 HTTP 请求（`URLSession` / `URLRequest` 零命中），没有第三方 Swift 依赖，没有分析、广告、崩溃上报 SDK，没有 IDFA、ATT 或 `identifierForVendor`。唯一的网络出口是 Rust iroh。
- **relay 与地址发现**：直连不通时，加密数据经 number 0 运营的公共 relay 转发（iOS 用 iroh 的 N0 预设，`crates/transport/src/iroh_impl.rs`）。relay 能看到 IP 地址和设备公钥，看不到内容，不存储转发的数据（官网隐私政策已写明）。这属于为完成连接而做的实时处理，不构成「收集」。IP 地址也不在 Apple 的数据类型列表里。
- 照片的 iCloud 下载是 PhotoKit 替用户从 Apple 取回自己的原图，不是本 App 往外传。

**什么情况下要改成「收集」**：凡是新增了会把数据发到项目方服务器的功能（例如统计或崩溃上报），即使是 opt-in 也要重新填问卷，同时改清单里的 `NSPrivacyCollectedDataTypes` 和官网隐私政策。

## 3. 需要理由的 API（Required Reason API）

两路来源都扫：Swift 源码，以及 Rust 静态库 `libtransport.a` 的未定义符号。Rust 的 `std::fs::metadata` 底层就是 `stat`，读源码看不出来，只能看符号。

| 类别 | 理由 | 用到的地方 |
|---|---|---|
| UserDefaults | `CA92.1`：读写只给本 App 用的数据 | `MediaViewer.swift:421-427`（「已存回相册」的去重表）；`RootView.swift:10`、`FakeBackend.swift:15`、`PPassApp.swift:160`（截图与演示用的启动参数） |
| 系统启动时间 | `35F9.1`：计算 App 内事件之间的时间间隔 | `FlowEngine.swift:96`、`DeliveryPort.swift:197` 的单调时钟（`systemUptime`），只用于超时与间隔，不上传 |
| 文件时间戳 | `C617.1`：访问 App 容器内文件的时间戳、大小等元数据 | Swift：`DeviceIdentity.swift:120` 的 `attributesOfItem`（判断文件是否存在）。Rust：`libtransport.a` 引用 `stat` / `fstat` / `fstatat` / `lstat`，用于导出到容器临时目录的原图和 blobs 库的变化检测（`crates/transport/src/provider.rs`） |

不涉及：磁盘空间（无 `statfs` / `statvfs` / `volumeAvailableCapacity`）、活动键盘。
`libtransport.a` 还引用了 `clock_gettime`、`sysctl`、`sysctlbyname`，它们不在 Apple 的 required-reason 列表里。

PhotoKit 的 `PHAsset.creationDate` / `modificationDate` 是照片元数据，不属于文件时间戳类别。

### 漂移门禁

`tools/ios/check-privacy-manifest.py` 在 ci-ios 上做两件事：先跑反证（`--self-test`），再扫 Swift 源码和刚构建出的 `libtransport.a`。用到了某个类别却没声明，就红。
本机复跑需要能读 rustc 产物的 `llvm-nm`。Xcode 自带的 nm 读不了新版 rustc 的目标文件，会报 `Unknown attribute kind`。

```bash
rustup component add llvm-tools
NM="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/^host: //p')/bin/llvm-nm"
python3 tools/ios/check-privacy-manifest.py --nm "$NM" \
  --lib apps/ios/TransportFFITests/Generated/TransportFFI.xcframework/ios-arm64/libtransport.a
```

清单有没有真的打进 App 包，由 App 测试 `PrivacyManifestTests` 核对。

## 4. 与审核环境的口径（#1088）

隐私标签描述的是正式产品：照片只在用户自己的设备之间传输。审核环境是例外，审核员配对的那台「电脑」是我们部署的演示服务器，审核员备份的照片会临时存在上面。
这一点要写进审核备注，标签不用改。审核备注里的隐私段落用下面这段：

> Privacy note for the review environment: in normal use, photos are sent only to the user's own computer and never to our servers. For this review only, the "computer" you pair with is a demo server we operate, so any photos you back up during review are stored there temporarily. The demo server is wiped (pairings, stored files and device identity) when the review ends.

## 5. 提审前还要处理

- **官网隐私政策没有 iOS**：`site/src/pages/privacy.astro` 的适用范围只写了网站、桌面端和 Android，也没有 iOS 权限说明。App Store Connect 要求填隐私政策网址，提审前这一页必须覆盖 iOS（相册、相机、本地网络、通知、后台任务）。#517 管这一页的改写，但它原定上架当天才切换；隐私页这部分要提前到提审前上线。
- **App Group entitlement 还在**：存储根已经不用它了（见 `apps/ios/project.yml` 的注释），但签名里仍然声明着。它不影响隐私标签，去留另议。
- **人工复核**：上传 build 后，在 Xcode Organizer 里对 Archive 执行 Generate Privacy Report，确认报告里的类别与本页一致。
