# iOS 兼容任务规划与独立验证门禁（2026-09-21）

> Base：`main@53df09f6a3c96645fd8e068dbac5132da30a4c7c`（开工前必须重新 fetch；验证前再确认 HEAD）。
> 执行边界：代码、脚本、CI、文档由 agent 在本机或 GitHub 侧完成；后台调度与真实分发只能在 iPhone 真机验证，L3 结论必须回贴真机原始输出。背景上传扩展在模拟器 SDK 里**编译得过**（`iPhoneSimulator.sdk` 同样导出 `PHBackgroundResourceUploadExtension` 与 `PHAssetResourceUploadJob`，已核实），但**运行期系统是否会调度它未一手核实**——只有 Apple 论坛的说法（证据等级 E1），列为 `IOS-03` 的第 0 问。
> 明确跳过：App Store 上架审核、Live Photo 跨端保真、iPad/macCatalyst/visionOS 形态、App 内自更新（TestFlight 取代 `UpdateChecker`）。
> 纪律：不重写配对/账本/Flow 业务语义；平台 `cfg` 的归属按 QA-09 既定规则走；不把「CI 绿」「模拟器绿」当真机绿；不把计划写成已完成事实；不为未选路线预埋抽象。

## 一、目标与非目标

**目标**：iPhone 上达到与 Android 端**同一份业务事实**的状态——可配对、可选相册、可发现、可传输、可浏览、可诊断、可取证，且 ARCH-01 的不变量在 iOS 上要么成立、要么有显式登记的 iOS 变体。

**非目标**：
- 不做「先跑通一张照片」的演示级切片。每张卡的验收标准与 Android 同侧卡对齐（失败预算、暂停语义、取消本轮、换 Desktop 清理）。
- 不复刻 `UpdateChannel` / `UpdateChecker`：侧载 APK 自更新在 iOS 没有对应物，分发走 TestFlight。
- 不复刻源文本断言门禁（`XxxTest` 读 `.kt` 源码断字符串那一类）。它在本仓已三次因与缺陷无关的原因集中变红，iOS 侧契约一律写成对真实文件 IO 的 XCTest。
- Live Photo 保真沿用 MOB-79 结论：现有 asset 表是单文件模型，跨端 Live Photo 需要新的资产关联数据模型，属架构级决策，本轮不做。
- 不在 iOS 端第三次实现 BLAKE3。哈希从同一个 XCFramework 导出，避免再生出一类 `tests/blake3-vectors.json` 漂移。

## 二、开工前必须知道的五条一手事实

全部取自本机 `Xcode 26.6 / iPhoneOS26.5.sdk`（`xcrun --sdk iphoneos --show-sdk-path`），不是文档转述。复核命令附在每条后面。

**F1｜iroh-ffi 有 Swift/XCFramework，但 `iroh-blobs` 明确不在其范围内。**
这与 Android 撞的是同一堵墙，而本仓的答案已经在盘上：`crates/transport --features android-jni` 编出 `libtransport.so`，`AndroidBlobsProvider` 独占一个 endpoint、一次一个 lease、用 `TempTag` 挡住 60s GC。
→ iOS 的传输卡**不是**「接 iroh-ffi」，而是「把 `crates/transport/src/android_blobs.rs` 里与 JNI 无关的 provider 内核抽出来，JNI 作为绑定 #1 保留，新增 UniFFI/C 绑定 #2，产出 `aarch64-apple-ios` + `aarch64-apple-ios-sim` 的 XCFramework」。这一句决定这件事是数周还是数月。

**F2｜iOS 26.1 起有官方后台备份通道，但它只接受 `NSURLRequest`——我们的 QUIC 不可能跑在里面。**
```
Photos.framework/Headers/PHAssetResourceUploadJob.h:39
  @property (strong, readonly) NSURLRequest *destination;
Photos.framework/Headers/PHAssetResourceUploadJobChangeRequest.h
  + createJob(destination: NSURLRequest, resource: PHAssetResource)   // ios(26.1)
  + creationRequestForJob(destination:resource:)                      // ios(26.4)
Photos.swiftmodule/arm64e-apple-ios.swiftinterface:39
  public protocol PHBackgroundResourceUploadExtension : AppExtension {
    func process() -> PHBackgroundResourceUploadProcessingResult
    func notifyTermination() }
```
扩展的职责只是**登记任务**；字节由系统在我们进程之外发出，我们拿不到 socket。
→ **这是 iOS 与 Android 的根本分叉点**，不是一个实现细节。Android 的 FGS + WorkManager 能在后台跑我们自己的 iroh 传输；iOS 上「后台自动备份」与「走 iroh」二选一。第三节给出路线。

**F3｜发现水位有对应物，但多一条 Android 从来不需要的兜底路径。**
```
PHPhotoLibrary.h:114  fetchPersistentChangesSinceToken:error:   API_AVAILABLE(ios(16))
PHPhotoLibrary.h:116  @property currentChangeToken             API_AVAILABLE(ios(16))
PHError.h:42          PHPhotosErrorPersistentChangeTokenExpired = 3105
```
`PHPersistentChangeToken` 是 `MediaStore` `GENERATION_ADDED` 的对位物，但它**会过期**（3105：token 指向的库状态早于可用历史）。`MediaScanner` 的水位模型没有这条分支，iOS 必须有「token 失效 → 全量重扫 + 靠内容哈希去重收敛」的可测路径。

**F4｜iCloud「优化存储」下原图不在本机，系统给了后台下载任务。**
```
PhotosTypes.h:215  PHAssetResourceUploadJobTypeUpload = 0        // 需要时先从 iCloud 下载再上传
PhotosTypes.h:217  PHAssetResourceUploadJobTypeDownloadOnly = 1
PHAssetResourceUploadJobChangeRequest.h
  + creationRequestForDownloadJob(resource:)   // ios(26.4)；系统随后可能再次清除
```
全仓去重建立在「BLAKE3 over 原始字节」上，而 iPhone 上原始字节经常不在本地。前台路径要走 `PHAssetResourceManager` + `isNetworkAccessAllowed`（会走蜂窝、会计流量），后台路径可以用 `DownloadOnly` 任务。**ARCH-01 的账本没有这个状态**，见第五节拍板项 D4。

**F5｜后台任务队列有硬额度与自己的状态机，必须和我们的账本对账。**
```
PHAssetResourceUploadJob.jobLimit                        // 超限 performChanges 报 PHPhotosErrorLimitExceeded = 3307
state: Registered(1) Pending(2) Failed(3) Succeeded(4) Cancelled(5, ios 26.4)
action: Acknowledge(1) Retry(2) Process(3, ios 26.5)
retry(destination:)  // 失败任务只允许重试一次
responseHeaderFields // ios(26.4)：终态可读回服务端响应头
```
`jobLimit` 未确认、系统按自己的节奏与顺序调度、一条失败只给一次重试——**ARCH-01 的「消费者严格一张一张处理」在这条通道上不成立**。`responseHeaderFields` 是唯一能把 Desktop 完成凭据带回手机的缝隙。

## 三、由 F2 推出的三条路线与推荐

| | A｜只前台 + BGProcessingTask | B｜Desktop 增 HTTP 摄取端点 + 背景上传扩展 | C｜A 为主干 + B 作为 iOS 专属后台补传通道 |
|---|---|---|---|
| 传输 | iroh/QUIC，与 Android 同一条 | 系统 HTTP 上传，另一条 | 两条，按前后台切换 |
| 后台自动备份 | 无保证：`BGProcessingTask` 由系统择机（典型是夜间充电），杀 App 即停 | 有，接近 Android 体验 | 有 |
| ARCH-01 不变量 | 原样成立 | 严格单张消费不成立，需 iOS 变体 | 主干原样，补传通道登记变体 |
| Desktop 侧改动 | 0 | 新增 HTTP(S) ingest + 鉴权 + 回执头 | 同 B |
| 未证实的前提 | 无 | 明文/自签能否通过系统上传器的 ATS；本地网络权限是否作用于系统上传器；`jobLimit` 与实际调度频率 | 同 B |

**推荐 C，但 B 的那一半必须先过 spike 才准写生产代码。**
理由：A 单独交付会得到一个「必须手动打开 App 才备份」的照片备份 App，这不是与 Android 同节奏；B 单独交付会让 iOS 走上一条独立传输栈，Desktop 侧的 Flow 语义要分叉两遍。C 把 A 做成地基（语义不分叉、可验证、可发 TestFlight），把 B 隔离成一条能力开关（`Hello.capabilities` 里加一条 `"ios.http-ingest.v1"`，协议版本不动）。

B 的四个未证实前提由 `IOS-03` spike 逐条回答，**spike 未出结论前，任何卡不得宣称 iOS 具备后台自动备份能力**。

## 四、三类环境分工

| 环境 | 作用 | 能证明 | 不能证明 |
|---|---|---|---|
| 本机 Xcode 模拟器 | 写代码、跑 XCTest、UI 布局与状态机回归 | 纯逻辑、账本 IO 往返、UI、i18n、与 daemon 的 iroh 连通（同机）、扩展能否编译链接 | 真实后台调度、iCloud 瘦身、蜂窝/省电行为；扩展能否被系统真正调度（待 `IOS-03` 第 0 问回答） |
| GitHub `macos-*` runner | 构建 XCFramework、`xcodebuild test`、归档产物 | 能否出包、单测是否全绿、产物可复现 | 一切真机行为 |
| iPhone 真机 | L3 验收 | 配对、发现、传输、后台唤醒、扩展调度、取证 | 由前两者代跑 |

## 五、G0 之前必须拍板的六件事

| # | 事项 | 不定它会怎样 |
|---|---|---|
| D1 | **设备与会员**：可用 iPhone 型号 + 系统版本，Apple Developer Program 会员状态（`docs/runbook/h02-apple-signing.md` 已写明没有会员就先不做） | 备忘录里在册的是 Mate 60 与三星，没有 iPhone。没有真机与会员，F2/F5 全部无法验证，agent 会写出没人能装的代码 |
| D2 | **最低系统版本**：后台通道的地板是 iOS 26.1（`creationRequestForJob`/`cancel`/响应头要 26.4，`Process` action 要 26.5）；`PHPersistentChangeToken` 只要 16 | 决定老系统是「降级为前台备份」还是「不支持」，这是产品决策不是工程决策 |
| D3 | **许可证**：仓库是 AGPL-3.0，第三方 App Store 分发与 GPL 家族条款历来冲突（VLC 先例）。历史提交里有第三位作者（106 次提交），重新授权需要其同意 | 代码写完才发现不能上架。TestFlight 同受 Apple ToS 约束，不是绕开手段 |
| D4 | **iCloud 瘦身原图的账本语义**：不在本地算 `WAITING_FOR_CONSTRAINTS` 还是单独一态？允许走蜂窝吗？下载失败消耗失败预算吗？ | ARCH-01 没有这个状态。最容易在后期浮现并作废一批已完成卡的就是它 |
| D5 | **新绑定的平台 `cfg` 归属**：QA-09 把 daemon 的平台分叉收进 `crates/platform/`，而 `android_blobs.rs` 以 feature 形式留在 `crates/transport/`。iOS 绑定按哪条规则放 | 让 reviewer 在 PR 里才发现，等于返工一张传输卡 |
| D6 | **B 路线的 Desktop 端形态**：HTTP ingest 是 daemon 内置还是独立监听？只允许同一 Wi-Fi 网段？鉴权用什么（lease token 需要活满 24h）？ | `IOS-03` spike 要拿它去测，没有它 spike 无法设计 |

## 六、工作分解、卡号与门禁

卡前缀 `IOS-`，与 GitHub Issues 一一对应（`docs/QUEUE.md` 已冻结只读，新工作一律开 issue，模板 `.github/ISSUE_TEMPLATE/task-card.md`）。

### I0｜基线与准入（最先做，串行）

- `IOS-01` 环境基线：`tools/ios/env-check.sh`（Xcode/SDK 版本、`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`、`cargo-make`/`xcodebuild` 可用性、真机 UDID 与系统版本、会员与证书状态）；产出 `docs/ios-dev-baseline.md`，标出「阻塞构建」与「只影响分发体验」两类缺口。
- `IOS-02` D1–D6 决策记录落盘。

**Gate G0**：真机 UDID + 系统版本回贴；`env-check.sh` 完整输出回贴；D1–D6 六条全部有结论（可以是「暂不做」，不可以是空白）。G0 不过不进 I1。

### I1｜背景执行 spike（决定产品天花板，串行紧随 G0）

- `IOS-03` 用一个最小 App + `com.apple.photos.background-upload` 扩展逐条回答（第 1 问先在模拟器上试，其余在真机上）：
  1. 模拟器上 `process()` 到底会不会被系统调度。能，则后续几问的一部分可以在模拟器上先跑，G1 不必全压在真机上；不能，则 G1 完全依赖 D1。
  2. 目的地写成 LAN 明文 `http://192.168.x.x:port` 时，系统上传器是否放行（ATS 由谁裁决、我们的 Info.plist 例外是否作用于系统进程）；自签 HTTPS 是否放行。
  3. 系统上传器是否受「本地网络」权限约束、是否需要用户授权。
  4. `jobLimit` 实测值；`process()` 在真机上的实际触发频率与前置条件（充电/闲置/网络）。
  5. `responseHeaderFields` 能否稳定回传一个 64 hex 的完成凭据。
  6. token 过期（3105）能否人工构造，或只能靠长时间放置观察。
- `IOS-04` spike 结论文档 + 路线 C 的最终裁决（B 半边留下 / 砍掉 / 降级为「仅同网段」）。

**Gate G1**：六问逐条有证据（抓包/日志/截图；除第 1 问外全部来自真机），不接受「应该可以」。B 半边被否 → 计划回落到路线 A，`IOS-1x` 全部改写为前台语义，且产品一页纸必须写明 iOS 不承诺后台自动备份。

### I2｜传输与 FFI（G0 后即可并行开工，不等 G1）

- `IOS-05` 把 `android_blobs.rs` 的 provider 内核抽成平台中立模块，JNI 退化为其一层绑定；**Android 侧行为零变化**是本卡的硬验收（Android JVM 单测数与断言不得下降）。
- `IOS-06` 新增 UniFFI/C 绑定 + `tools/build-ios-transport-xcframework.sh`，产出 device + simulator 双切片 XCFramework；哈希（BLAKE3）与 `crates/proto` 的编解码一并从这里导出，iOS 侧不自己实现。
- `IOS-07` iOS 上的 `FsStore` 路径落在 App Group 容器；60s GC 定时器在 App 挂起期间的行为实测并登记。

**Gate G2**：真机跑通「手机起 provider → Desktop 拉走一张 → 凭据回来」；`cargo test -p transport` 与 Android 侧全部单测仍绿；XCFramework 在模拟器与真机两个切片上都能链接。

### I3｜媒体枚举与授权（与 I2 并行）

- `IOS-08` PhotoKit 相册枚举 → `MediaScanner.Bucket` 对位（含封面、计数、空名相册）。
- `IOS-09` `PHPersistentChangeToken` 水位 + **3105 全量重扫兜底**；契约测试写成对真实 token 序列化往返的 XCTest。
- `IOS-10` `PHAuthorizationStatus.limited` 与 MOB-02/MOB-94 已定的部分授权语义对齐——**沿用既有结论，不重新讨论**：拿不到完整权限时首页说实话，不盖「都存好了」的章。
- `IOS-11` `PHAssetResourceManager` 取原始字节 + `isNetworkAccessAllowed` 策略（按 D4 结论实现）。

**Gate G3**：真机上「新增一张照片 → 水位前移 → 出现在待传列表」闭环；人为构造 token 失效后，重扫收敛且不产生重复传输（靠内容哈希证明，不靠计数）。

### I4｜账本与状态（依赖 I3，不依赖 G1）

- `IOS-12` `DiscoveryLedger` / `backup_scope` / `AutoBackupPrefs` / `PausePrefs` 的 iOS 实现，**从第一天就落在 App Group 容器**（`UserDefaults(suiteName:)` + 容器内 JSON）。后补迁移的代价远高于一开始就放对。
- `IOS-13` ARCH-01 的 04-case-matrix 逐条映射为 XCTest；矩阵里任何一条在 iOS 上不成立的，必须在本卡产出「iOS 变体不变量」的书面登记，不允许静默豁免。

**Gate G4**：case matrix 覆盖率与 Android 侧对齐；换 Desktop、取消本轮、Pause 跨重启三条重启类用例在真机上各跑一遍。

### I5｜调度（依赖 G1 裁决）

- `IOS-14` 前台追赶（对位 `ForegroundCatchupOnResume`）+ `BGProcessingTask` 尽力而为路径。
- `IOS-15`（仅 B 存活时）背景上传扩展：登记任务、`jobLimit` 配额管理、`acknowledge`/`retry(destination:)` 与账本对账、从 `responseHeaderFields` 收凭据。
- `IOS-16`（仅 B 存活时）daemon 侧 HTTP ingest + 鉴权 + 回执头；`Hello.capabilities` 增 `"ios.http-ingest.v1"`，`PROTO_VER` 不动。
- `IOS-17` 「iOS 能承诺什么、不能承诺什么」的用户可见表达（首页文案 + 引导），对位 Android 的电池白名单引导。iOS 没有 FGS、没有开机广播、没有电池白名单三层开关，**不许用文案假装有**。

**Gate G5**：真机放置 24h 不开 App，回贴实际发生的备份条数与系统日志；条数为 0 也是合法结论，但必须如实写进产品一页纸。

### I6｜UI（G0 后即可并行，不阻塞任何门禁）

- `IOS-18` SwiftUI 壳：两 Tab、时间线网格、相册选择、查看器、扫码配对、诊断页。14k 行 Compose 没有一行可复用，可复用的是语义。
- `IOS-19` 设计 token 与语义组件对齐仓库既有规范：二元选择同尺寸、禁用默认库色、结项前必须有真机截图。

**Gate G6**：真机截图逐屏与 Android 对照，差异逐条有理由（平台惯例差异算理由，「来不及做」不算）。

### I7｜i18n 第四消费者（与 I6 并行，越早越好）

- `IOS-20` `assets/i18n/*.json` 目前有三个消费者（`crates/diag/src/keys.rs` 注册表与硬编码计数、Android 逐字节捆绑副本）。iOS 让它变成第四个：iOS bundle 内逐字节副本 + 对位 `bundled_assets_never_drift_from_repo_source` 的漂移测试 + `.github/workflows/ci-ios.yml` 的 paths 要包含 `assets/i18n/**`。

**Gate G7**：故意改一个 key 不同步 iOS 副本 → CI 必须红（反证真跑）。

### I8｜CI、发布与取证（贯穿）

- `IOS-21` `ci-ios.yml`：macOS runner 上构建 XCFramework + `xcodebuild test`；paths 覆盖 `crates/transport/**`、`assets/i18n/**`、`apps/ios/**`。
- `IOS-22` 版本号可判定性：`CFBundleShortVersionString` 只接受最多三段数字，装不下 `0.5.7-test.1`。规则定为 short = `0.5.7`、`CFBundleVersion` = 单调整数（对位 `versionCode`）、完整串写进自定义 Info.plist 键并在诊断页与 `Hello.device_name` 之外的诊断通道可见。构建期由 `PPF_BUILD_VERSION` 注入，与 Android 同源。
- `IOS-23` 真机取证手册 `docs/runbook/ios-device-forensics.md`：`xcrun devicectl` 取设备信息、Xcode Devices 下载 App 容器（对位 Android 的 `run-as` 直读私有目录）、`log collect --device` 取 OSLog、如何把账本 JSON 捞出来比对。**没有这一节，下游 agent 交不出 E3/E4 证据，只会交 E1 散文。**
- `IOS-24` 发布路径：TestFlight 内测流程 + `release.yml` 的 iOS job（`APPLE_*` secret 槽位在 H-02 时已建好，值待补）。

**Gate G8**：一次完整的 tag → CI → TestFlight 内测包 → 真机安装 → 诊断页显示正确完整版本串。

## 七、开工顺序

串行主链（前一个门禁不过不往下走）：

```
G0 设备/会员/Xcode 基线 + D1–D6 拍板
→ I1 背景执行 spike（G1 裁决路线 C 的 B 半边）
→ I5 调度
→ G8 发布闭环
```

G0 之后立刻并行开工、不等 G1 的四条（这是「安排别的 agent」能真并行的部分）：

```
I2 传输/XCFramework · I3 媒体枚举 · I6 SwiftUI 壳 · I7 i18n 第四消费者 + I8 的 ci-ios 骨架
```

I4 账本在 I3 出第一个可用枚举后接上。

## 八、跨端不回归的机制

「跟上节奏」不是靠一次性追平，是靠这三样在后续每张卡上生效：

1. **合同在矩阵里，不在实现里**。`docs/design/2026-08-29-arch01-backup-core/04-case-matrix.zh-CN.md` 是两端共同的验收源；改业务语义先改矩阵，两端同时接。
2. **账本层写真跑的测试**。`AutoBackupPrefs`/`BackupScopeStore`/`DiscoveryLedger` 都是纯文件 IO，两端都能在单测里真的走一遍往返。源文本断言只用来钉「接线还在」，不用来钉行为。
3. **共享资源改动前先查消费者**。`assets/i18n/*.json` 之后会有四个消费者，`crates/transport` 会有两套绑定。改之前 `grep -rn "<文件名>" tools/ justfile .github/workflows/` + 全仓 `include_str!`/`readText()`/Swift 侧 bundle 引用。

## 九、汇报模板

每个大任务结束只报五条：

1. **结论**：能 / 不能 / 有条件能。
2. **用户可见结果**：装上会怎样，失败会怎样，后台放着不管会怎样。
3. **证据**：CI run、真机命令原始输出、哈希、截图/日志文件名，标 E1–E4 等级。
4. **风险与边界**：没验证什么，不能宣称什么。
5. **下一步唯一动作**：需要拍板 / 需要跑哪条命令 / 继续改哪张卡。

## 十、下一动作

基于 `main@53df09f6` 开 `IOS-01`：先回答 D1（有没有 iPhone、什么系统版本、会员状态），这一条不落地，后面 23 张卡都只能停在纸上。
