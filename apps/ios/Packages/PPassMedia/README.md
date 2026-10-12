# PPassMedia

iOS 媒体层（Swift 本地包，最低 iOS 16）：PhotoKit 相册枚举、变更水位、原始字节读取、授权状态。
规划见 [iOS 兼容规划 I3 段](../../../../docs/product/2026-09-21-ios-compat-plan.md)；Android 语义源是
`apps/android/.../backup/MediaScanner.kt` 与 `backup/order/MediaSnapshotSource.kt`。

本包不实现 BLAKE3（从 XCFramework 来，经 protocol 注入），不持有账本，不做 UI。

## 结构

| 目录 | 内容 |
|---|---|
| `Sources/PPassMedia/Library` | `PhotoLibraryReading`（只读相册库的协议）与 PhotoKit 实现 `PhotoKitLibrary` |
| `Sources/PPassMedia/Albums` | `AlbumCatalog`（可选相册列表）、`AlbumScope`（范围并集与计数） |
| `Sources/PPassMedia/Originals` | `OriginalFetcher`（原图 → 临时文件，流式、可取消、所有退出路径清理）、`PhotoKitOriginalSource`（`requestData`，允许走网络）、`OriginalFetchFailure`（D4 分类） |
| `Sources/PPassMedia/Access` | `PhotoAccessLevel`（授权档位）、`PhotoAccessPresentation`（首页表达：数字/章/告示 key/动作）、`BackgroundUploadGate`（建后台上传 job 的闸门） |
| `Sources/PPassMedia/Changes` | `ChangeHistoryReading` + `PhotoKitChangeHistory`（`PHPersistentChangeToken`）、`ChangeDiscovery` / `ChangeWindow`（G 的取法与推进）、`ChangeTokenStore`（G 落盘） |
| `Tests/PPassMediaTests` | 纯逻辑单测，跑在 fake 上，不需要授权 |
| `IntegrationHost/` | 真 PhotoKit 集成测试：XcodeGen 生成的最小宿主 App + 宿主式测试 bundle |
| `scripts/test.sh` | 一条命令跑完两套测试（建专用模拟器 → erase → 现造素材并 addmedia → 设授权 → 测） |

## 怎么跑

```
apps/ios/Packages/PPassMedia/scripts/test.sh
```

需要 Xcode、`xcodegen`、`ffmpeg`。素材全部现场生成（ffmpeg testsrc / sips 转 HEIC），不用任何真实照片。
脚本只动名为 `PPassMedia-Test` 的专用模拟器，跑完关机。

### 为什么集成测试要宿主 App

SwiftPM 包的测试在模拟器上跑在 `xctest` 工具进程里，没有 bundle 身份，TCC 直接拒绝相册访问
（`kTCCErrorDomain Code=2 "Unable to construct an identity to kTCCServicePhotos"`），`simctl privacy` 也无从授予。
标准做法是给测试 bundle 配宿主 App，测试以宿主的 bundle id（`com.hawkeyexb.ppass.mediatest.host`）拿授权。

### 为什么授权不只用 `simctl privacy grant`

本机实测（Xcode 26.6，iOS 26.4 runtime）：`simctl privacy grant photos` 写进模拟器 TCC.db 的行是
`auth_value=2, auth_version=1`，App 读到的是 `.notDetermined`、一张照片都取不到；把 `auth_version` 改成 2 后读到
`.authorized`。`auth_value=3` 是部分授权（`.limited`），`0` 是拒绝。`scripts/sim-photos-auth.sh` 封装了这一步，
三档都能在模拟器上稳定复现。

## 与 MediaStore 的语义差异（IOS-08 登记）

Android 的相册 = `MediaStore` bucket（`BUCKET_ID` / `BUCKET_DISPLAY_NAME`，按文件所在目录划分）。iOS 的相册 =
`PHAssetCollection`。两者不是一一对应，下面逐条写清差异和本包的处理方式。

### ① 一张照片可以同时属于多个相册 → 范围计数改为并集

- **MediaStore**：bucket 互斥，一张照片只在一个 bucket 里。范围计数 = 所选 bucket 计数之和。
- **PhotoKit**：一张照片可以同时在「最近项目」、「个人收藏」和若干用户相册里。
- **处理**：`MediaAlbum.count` 只表示这个相册自己有多少项，**不能相加**。范围内照片由 `AlbumScope` 按
  `localIdentifier` 取所选相册的并集。ARCH-01 待办现算公式「范围内照片 − 跳过名单 − 已确认」里的「范围内照片」在
  iOS 上就是这个并集，首页的分母也是它。
- **口径变化**（对照 FIX-T6 三元组口径；ARCH-01 之后三元组已改为待办现算，分母同理）：Android 上
  「已选相册计数之和 = 范围内总数」恒成立，iOS 上不成立。模拟器实测：相册 trip 有 2 项、family 有 2 项，两个都选时
  范围是 3 项（h1.heic 两个相册都有）。任何把相册 count 相加当作范围总数的写法在 iOS 上都是错的。
- 相册之间移动照片：Android 是改 `BUCKET_ID`，照片离开原 bucket；iOS 只是增减集合成员，照片本身不变。范围只是查询条件，
  所以两边的结论一样：移进已选相册的照片进入待办，移出的不再算待办，已确认的保持已确认。

### ② 智能相册收不收

MediaStore 没有智能相册的概念。PhotoKit 的智能相册由系统按媒体类型或标记自动维护。

- **必须收「最近项目」（`smartAlbumUserLibrary`，列在最前）**。iOS 上相机拍的照片不在任何用户相册里，只在「最近项目」里。
  Android 有 Camera bucket 承担这件事，iOS 没有对应物，不收就永远选不到相机照片。图库为空时也列出它。
- **用户相册**（`albumRegular`，以及 iTunes/Finder 同步来的、导入的相册）：全部列出，空相册也列，与「照片」App 一致；
  文件夹里的相册也会枚举到（模拟器实测）。顺序保持「照片」App 里用户自己的顺序，不像 Android 那样按名字排序。
- **按媒体类型划分的智能相册**（个人收藏、视频、自拍、实况、人像、全景、延时、慢动作、电影效果、空间、连拍、截屏、录屏、
  动图、长曝光、RAW）：只列非空的，与「照片」App「媒体类型」一栏一致。白名单与顺序见
  `AlbumCatalog.selectableSmartSubtypes`。
- **不收**：
  - 「已隐藏」（`smartAlbumAllHidden`）。隐藏项在任何相册里都不计数（`includeHiddenAssets = false`），也不进范围。
  - 「最近删除」。它不是公开子类型，模拟器上 `fetchAssetCollections(.smartAlbum, .any)` 也枚举不到；即便某个系统版本
    枚举出来，白名单也会挡住。
  - 「最近添加」（滚动时间窗口，选了它范围会随时间自己变化）、`smartAlbumGeneric`、`smartAlbumUnableToUpload`。
  - iCloud 共享相簿（`albumCloudShared`）与「我的照片流」：里面的内容不是本机图库的原图。
  - 白名单以外的任何未知子类型。默认不收，新出现的系统相册要先登记再放开。

### ③ 空名相册与系统相册的本地化名字

- **MediaStore**：`BUCKET_DISPLAY_NAME` 可能为空，Android 保留 null，由 UI 本地化（`bucketNameOrNull`）。
- **PhotoKit**：智能相册的 `localizedTitle` 由系统按**进程的本地化**给出，本包原样透传，不自己翻译。
  App 要拿到中文名，Info.plist 必须声明对应的本地化（`CFBundleLocalizations` 含 `zh-Hans`），这件事归 App 线。
  用户相册的名字就是用户起的名字。
- **空名**：`title` 为 nil、空串或全空白时，`MediaAlbum.title` 一律是 nil，由 UI 显示本地化的「未命名相册」，与 Android
  做法一致。另外，PhotoKit 不允许建无名相册：标题为空串、空格或全角空格时都返回 `3300 changeNotSupported`（模拟器实测）。
  空名主要是防御 iTunes 同步相册或旧数据。

### ④ 其他实现差异

- **id 类型**：Android bucket id 是 `Long`；iOS 是 `localIdentifier`（String），只在本机稳定，跨设备或恢复备份后不保证。
  范围持久化（IOS-12）存的就是这个 String。
- **封面**：Android 用 `DATE_ADDED`（加入 MediaStore 的时间）最新的一项；iOS 没有公开的「加入图库时间」，改用相册内
  `creationDate`（拍摄时间）最新的一项。对于后来才导入的老照片，两边选出的封面可能不同。取不到封面（空相册）时为 nil，
  UI 显示空白封面，不影响选择（对齐 UX-10）。
- **计数口径**：只算图片和视频，音频不算，隐藏项不算。用真实 fetch 的 `count`，不用 `estimatedAssetCount`
  （对智能相册会返回 `NSNotFound`）。

## 发现游标 G（IOS-09）

ARCH-01 的 G：「只服务新照片，只在新照片提交时推进；补传不推进」。Android 上 G 是 `GENERATION_MODIFIED`（一个可以比较大小的整数），
iOS 上是归档后的 `PHPersistentChangeToken`。

| | Android | iOS |
|---|---|---|
| G 的载体 | `Long`，可以比较大小 | 不透明字节（`NSKeyedArchiver` 安全编码），只能判断是否相等 |
| 取新照片 | `generation > G`，`LIMIT 1` | `fetchPersistentChanges(since: G)`，只看 `insertedLocalIdentifiers` |
| 推进 | 提交时把 G 设成这张照片的 generation | `ChangeWindow.advance(isSettled:)`：推进到最远的那次变更，要求它及之前插入的照片都已了结 |
| 不倒退 | 整数单调 | G 只能是起点，或者系统返回序列里的某个 token，结构上无法倒退；删除和更新不挡 G |
| G 缺失 | 从 `maxGeneration` 起步 | 从 `currentChangeToken` 起步；此前的照片交给对账扫描 |
| 失效 | 无（MediaStore 重建另有处理） | 3105 token 过期 / 3210 明细缺失 / 存盘字节解不出 → `Discovery.rescan`：先把 G 设成重启点（失败之后、重扫之前取），再对范围全量重扫，按内容哈希判重收敛 |

只看 inserted 的原因：照片入库后系统做分析，会再产生 updated 事件；把老照片加进相册也只产生 updated 事件（模拟器实测）。
这两种都不是新照片。范围变化（老照片进了已选相册）由对账扫描负责，不归 G 管，这一点与 Android 相同。

**模拟器上真的造出了 3105**：在旧图库里写入较长的历史，存下 token；erase 模拟器后重建一个历史较短的图库，拿旧 token 去读，
系统返回 `PHPhotosErrorDomain 3105`。随后的全量重扫中，旧内容按字节判重全部跳过，只有 erase 之后新建的照片需要传。
erase 之后所有 localIdentifier 都变了，所以这个结果只能靠内容判重得出，靠 id 或计数都得不出。

**风险（实测发现，登记）**：token 不绑定是哪个图库。如果旧 token 的位置还落在新图库的历史范围内，`fetchPersistentChanges`
**不报错**，会返回新图库「从那个位置之后」的变更，等于 G 静默错位，可能漏掉一段新照片。会出现这种情况的场景：设备恢复、
图库重建之后，App Group 里的 G 还留着。PhotoKit 没有公开的图库标识可供比对，所以兜底仍然是对账扫描（范围内全量，按内容哈希判重）。
它必须定期跑，不能只在 3105 时才跑。这一条交给 PPassCore 的调度去落实。

## 取原始字节（IOS-11）

按 #311 D4（对齐 Immich）：备份轮里需要某张照片时，用 `PHAssetResourceManager.requestData` 读原图，并设
`isNetworkAccessAllowed = true`。原图不在本机（iCloud「优化存储」）时由系统从 iCloud 拉取。字节边到边写进临时目录，
用完就删。只在备份轮内调用，备份轮本身受 Wi-Fi 和电量约束，这里不另外判断蜂窝网络。

- **取哪一份**：图片取 `.photo`，视频取 `.video`，都是未经编辑的原始文件。编辑后的渲染结果不取，实况照片的配对视频不取（MOB-79），
  RAW+JPEG 取 JPEG。与 Android 的差异：Android 上编辑往往直接改写文件或另存一份，读到的是编辑后的字节；iOS 的编辑不改原图，
  我们备份的是**未编辑的原图**，与 Immich 默认做法一致。要不要另外备份编辑后的版本，是产品决定，本包没有做。
- **哈希**：本包不实现 BLAKE3。`fetchAndHash` 接收一个注入的 `hashFile: (URL) -> String`，生产上用 PPassCore
  `ContentHasher.blake3Hex(ofFileAt:)`（来自 XCFramework，对文件流式计算）。
- **失败分类**（`OriginalFetchFailure`，对接 PPassCore `ImportResult`）：

  | 情况 | 分类 | 处置 |
  |---|---|---|
  | 照片已不在图库 | `sourceMissing` | 源已删，不计次 |
  | `NSURLErrorDomain`（取消除外）、`PHPhotosError` 3169、断网或超时类 POSIX 错误（沿 `NSUnderlyingErrorKey` 链找） | `network` | 等待中（原图不可得），不计次 |
  | `PHPhotosError` 3305、写盘空间不足（`NSFileWriteOutOfSpaceError` / `ENOSPC`） | `localStorageFull` | 不计次；PPassCore 需要补一个等待原因 |
  | 3302 / 3303 / 3306 / 3164、没有原图资源、认不出来的错误 | `unavailable` | 失败，计次 |
  | Task 被取消（PhotoKit 回 3072） | 抛 `CancellationError` | 停止下载、删除临时文件 |

  认不出来的错误一律归 `unavailable`，不猜成网络问题。猜错了这张照片会一直卡在队头，既不计次也不推进 G。
- **清理**：失败、取消、哈希出错都会在抛出前删掉本次目录；`FetchedOriginal` 被释放时也会删（兜底）；每轮开始调用
  `purgeLeftovers()` 清掉崩溃残留。
- **实测**：addmedia 进去的 JPEG、HEIC、MP4，取出的字节与原文件逐字节一致。但 App 用 `addResource(with:data:)` 写入的 JPEG
  会被图库改写（本地实测多出约 60 字节）。所以「原始字节」指的是图库里此刻存的那一份。对去重来说，要紧的是同一资源反复读出的字节
  稳定（已实测），这样哈希才稳定。

## 相册授权三档（IOS-10）

沿用 MOB-02 / MOB-94 的结论，不重新讨论：部分授权**不是要支持的形态**，UI 只把用户引导到完整授权；拿不到完整权限时，首页不显示备份数字（不出假 0/0），也不盖「都存好了」的章。

| 档位（`authorizationStatus(for: .readWrite)`） | 数字 / 章 | 后台上传通道 | 告示 | 按钮 |
|---|---|---|---|---|
| `.authorized` → `full` | 显示 | 可能可用（还要看闸门） | 无 | — |
| `.limited` → `limited` | 不显示 | 不可用 | `photo_access.limited.*`：要说「现在只能前台备份」 | 去设置 |
| `.denied` → `denied` | 不显示 | 不可用 | `photo_access.denied.*` | 去设置 |
| `.restricted` → `restricted` | 不显示 | 不可用 | `photo_access.restricted.*`：设备管理限制，用户自己改不了 | 无 |
| `.notDetermined` → `notDetermined` | 不显示 | 不可用 | `photo_access.request.*` | 弹系统授权框 |

- **只认 `authorizationStatus(for: .readWrite)`**。模拟器实测：部分授权时它返回 `.limited`(4)，旧 API `authorizationStatus()` 返回
  `.authorized`(3)。用旧 API 会把部分授权当成完整授权，首页就会出现假数字和「都存好了」的章。反证跑过：换成旧 API 后，limited 档的集成测试读到 `full`。
- 「去设置」的跳转由 App 线用 `UIApplication.openSettingsURLString` 执行，本包不依赖 UIKit。
- **后台上传闸门** `BackgroundUploadGate`：系统版本 ≥ iOS 26.1、完整授权、`PHPhotoLibrary.uploadJobExtensionEnabled` 为真，三个条件全满足才允许建
  `PHAssetResourceUploadJob`；任一不满足，调用方不得尝试建 job。后台上传本轮挂起（IOS-15），闸门先立住。模拟器上这个开关读出来是 false。
- 与 Android 的差异：Android 部分授权只是可见范围变小，后台照跑；iOS 部分授权下后台上传通道整个不可用（`PHPhotoLibrary.h` 要求完整相册权限），
  所以告示必须说「只能前台备份」，不能只说范围变小。

**建议文案**（本包只出 key；文案要由 i18n 线落进 `assets/i18n`，改之前先给用户确认）：

| key | 中文 | English |
|---|---|---|
| `photo_access.limited.title` | 只授权了部分照片 | Only some photos are accessible |
| `photo_access.limited.body` | 现在只能在打开 App 时备份，而且只备份你选中的那些照片。允许访问全部照片，才能完整备份。 | Backup only runs while the app is open, and only for the photos you selected. Allow access to all photos for a complete backup. |
| `photo_access.denied.title` | 拿不到相册权限 | No photo access |
| `photo_access.denied.body` | 备份需要访问相册。现在一张照片都读不到，所以什么都没在备份。去设置里允许访问全部照片。 | Backup needs access to your photos. Right now it can't read any, so nothing is being backed up. Allow access to all photos in Settings. |
| `photo_access.restricted.title` | 相册访问受限 | Photo access is restricted |
| `photo_access.restricted.body` | 这台 iPhone 的设置（如屏幕使用时间或设备管理）不允许访问相册，备份无法进行。 | This iPhone's settings (such as Screen Time or device management) don't allow photo access, so backup can't run. |
| `photo_access.request.title` | 需要照片权限 | Photo access needed |
| `photo_access.request.body` | 备份需要访问你的照片和视频。请在接下来的系统提示里选择「允许访问所有照片」。 | Backup needs access to your photos and videos. Choose "Allow Full Access" in the next prompt. |
| `photo_access.request.action` | 继续 | Continue |
| `photo_access.open_settings` | 去设置 | Open Settings |

## 验证覆盖

| 内容 | 测试 | 证据等级 |
|---|---|---|
| 空相册、无名相册、仅视频相册；封面；隐藏/最近删除不可选；智能相册取舍与顺序；并集计数；空范围不查询 | `Tests/PPassMediaTests/AlbumCatalogTests.swift`（fake） | E2 |
| 灌入的 JPEG/HEIC/MP4 与建出的相册（重叠、空、仅视频、文件夹内）逐条对上；「已隐藏」不可选；并集计数；无名相册建不出来 | `IntegrationHost/Tests/AlbumEnumerationIT.swift`（模拟器真 PhotoKit） | E3（模拟器） |
| 与「照片」App 并排截图、与 Android BucketScreen 对照 | — | 真机待补 |
| G：起步、只看 inserted、推进规则、删改不倒退、拍了又删不挡、3105/3210/坏字节走重扫且重启点取在失败之后、其他错误不重扫、落盘原子替换、坏文件不当「没有 G」、按哈希而非计数收敛 | `Tests/PPassMediaTests/ChangeDiscoveryTests.swift`（fake） | E2 |
| token 归档、落盘、读回后直接喂 `fetchPersistentChanges`；新建一张后增量里只有它，提交后 G 前移、再读为空；进相册不算新照片；坏 token 走重扫后能接着增量 | `IntegrationHost/Tests/ChangeTokenIT.swift` | E3（模拟器） |
| 真库 3105 + 全量重扫按内容收敛 | `IntegrationHost/Tests/TokenExpiryIT.swift`（两轮，中间 erase） | E3（模拟器） |
| 真机上「新拍一张 → 水位前移 → 出现在待传列表」 | — | 真机待补（需 App 与 PPassCore 接上） |
| 流式写入与扩展名、discard/释放兜底删除、哈希拿到完整文件、断网半截/不可得/空间不足/取消都不留文件、失败分类表、资源选择 | `Tests/PPassMediaTests/OriginalFetcherTests.swift`（fake） | E2 |
| JPEG/HEIC/MP4 取出字节与原文件逐字节一致；照片不存在 → `sourceMissing`；同一资源反复读字节稳定 | `IntegrationHost/Tests/OriginalBytesIT.swift` | E3（模拟器） |
| iCloud 优化存储下的真下载（进度回调与最终哈希）、断网中断 | — | 真机待补（模拟器没有 iCloud 照片） |
| BLAKE3 与 Desktop 一致 | — | 待 #313（XCFramework）接上后补 |
| 档位映射、只有完整授权显示数字和章、部分授权的告示与去设置、各档按钮、key 清单自洽、上传闸门四种情况 | `Tests/PPassMediaTests/PhotoAccessTests.swift`（fake） | E2 |
| 模拟器上依次设成 full / limited / denied / 未决定，读到的档位与首页表达逐档对上；limited 下旧 API 返回 authorized 的事实也钉住 | `IntegrationHost/Tests/AccessLevelIT.swift` | E3（模拟器） |
| 首页三档真机截图、去设置一键跳转 | — | 真机待补（UI 由 App 线做） |

限制：模拟器上没法用 API 造隐藏照片。建好后再隐藏，系统会弹「允许 xx 隐藏这张照片？」确认框，测试会卡住；在创建请求里直接设
`isHidden`，请求不报错，但照片根本没有建出来。所以「隐藏项不计数」由 fake 测试覆盖，真库上只核实「已隐藏」集合本身不可选。
