# ARCH-01 case matrix 的 iOS 落地与变体登记

> 2026-10-13 立档 · 卡 [#339](https://github.com/hawkeye-xb/P-Pass/issues/339)（IOS-13）· 实现在 `apps/ios/Packages/PPassCore`（#890 / #338 / #891）
> 合同源：[`04-case-matrix.zh-CN.md`](04-case-matrix.zh-CN.md)（含新增的「仅 iOS」I 组）· 设计源：[`final-design-413.md`](final-design-413.md)

规则只有一条：**矩阵的每一行在 iOS 上要么有同语义的 XCTest，要么在本文件有一节书面登记，不允许静默豁免。**

这条规则由测试钉住，不靠人记：`apps/ios/Packages/PPassCore/Tests/PPassCoreTests/Flow/CaseMatrixCoverageTests.swift` 解析矩阵与本文件——

- 矩阵里任何一个 ID（含已废弃的、含 I 组）在注册表里找不到 → 红；
- 注册表里引用的测试方法不存在（改名 / 删掉）→ 红（按 XCTest 运行时枚举，不比字符串）；
- 登记为「iOS 变体 / 实现偏离矩阵 / 桌面侧条目」的 ID 在本文件没有对应小节，或本文件里有矩阵不存在的 ID → 红；
- 矩阵标「已废弃」的行必须在注册表里也是已废弃，反之亦然。

## 读法

每一行落在下面五类之一：

| 类别 | 含义 | 本文件 |
|---|---|---|
| 同语义 | iOS 上不变量原样成立，有逐条 XCTest | 不写，只在注册表里列测试名 |
| iOS 变体 | 原条目的机制在 iOS 上不存在或不同；写清为什么不成立、替代不变量是什么、哪条测试钉住替代不变量 | 一节 |
| 实现偏离矩阵 | 不是 iOS 特有：两端实现都与矩阵这一行不一致，已挂号请拍板 | 一节 |
| 桌面侧条目 | 行为发生在桌面；手机侧只负责一半，测的是那一半 | 一节 |
| 已废弃 | 矩阵里本来就标了已废弃 | 不写 |

证据等级：注册表里的测试全部是 E2（host `swift test` + iOS 模拟器 `xcodebuild test` 都跑）；矩阵「真机验收」列的 E3 待 FFI（#313）、PhotoKit 适配（#314 / #335 / #337）与 App 壳（#315）接上后补，不在本文件宣称。

## 逐条登记

### O-01｜新照片按 G 取件、与 G 同一次写入

- **原条目**：`GENERATION_MODIFIED > G LIMIT 1` 取到新照片；状态与 G 的推进同一次写入。
- **为什么在 iOS 上不成立**：iOS 没有 MediaStore generation。新照片的来源是 `PHPersistentChangeToken` 之后的变化；token 是不透明字节，不能比大小，所以 Android 在 SQL 里做的 `G = max(G, …)` 没法照搬。
- **替代不变量**：G 是媒体源给出的不透明位置（token + 批内进度，由 PPassMedia 编码），推进是覆盖写；**单调性由引擎保证**——G 只沿 `changes` 的返回顺序前进（跳过的推进到最后一张跳过的位置，需要动作的那张在结局落库时推进到它自己的位置）；已有 order（遗留续传 / 补传）的 lookup 结果不带位置，结构上推不动 G（O-12）；会被重入的计数路径不写 G（I-07）。结局与 G 仍在同一个 SQLite 事务里（O-07）。
- **测试**：`FlowEngineIOSTests.testDiscoveryOnlyMovesForwardAlongTheSourceOrder`、`FlowEngineTests.testAReconcileScanCommitMovesSAndLeavesGToNewPhotos`、`OrderStoreTests.testAFailureInsideTheWriteRollsBackStateAndCursorTogether`。

### O-03｜MediaStore 重建后 `_id` 变了、内容没变

- **原条目**：新 `_id` 进入待办，导入算出同一个 hash，offer 时桌面按 hash 回「已有」，传输字节数为 0。
- **为什么在 iOS 上不成立**：没有 MediaStore 重建。对应的 iOS 事件是照片库身份变化（换库 / 从备份恢复）或 `localIdentifier` 变化，以及 token 过期（3105）。
- **替代不变量**：库身份变 / 3105 → G 重置、扫描置脏（与 Android「getVersion 变了」同一条路）；内容没变的照片在桌面按 hash 判重，offer 直接回终态，手机侧不等待、不供数。
- **测试**：`FlowEngineIOSTests.testAChangedLibraryIdentityResetsTheCursor`、`FlowEngineIOSTests.testAnExpiredDiscoveryCursorRescansAndConvergesWithoutDuplicates`、`DeliveryPortTests.testTheWireTupleIsTheOrderIdAndATerminalOfferReplyConfirmsWithoutWaiting`。

### D-07｜多个外部卷

- **原条目**：G 按卷分开存、按卷查询；API 26–29 的取件来源待确认。
- **为什么在 iOS 上不成立**：iOS 只有一个系统照片库，没有卷，也没有 API 26–29 那种不精确的 generation。
- **替代不变量**：单库单游标（`discovery_state` 表只有一行），库身份变化时整体重置。
- **测试**：`OrderStoreTests.testDiscoveryPositionIsOverwrittenAndKeepsLibraryIdentity`、`FlowEngineIOSTests.testAChangedLibraryIdentityResetsTheCursor`。

### R-01｜新照片、桌面没有：原图共读 2 次

- **原条目**：引用导入（hash + outboard）1 次 + 供数 1 次；不写副本；Kotlin 侧不再单独算 hash。
- **为什么在 iOS 上不成立**：PhotoKit 不暴露文件路径，没有「引用导入」。iOS 的导入是 `PHAssetResourceManager` 把原始字节写到临时目录（iCloud 优化存储下就是一次下载），FFI 在这一遍里算 BLAKE3 并导入 provider 的仓库；供数读的是仓库，不再碰照片库。
- **替代不变量**：每张新照片**只取一次原始资源**（导入）；Swift 侧不另算 hash；供数不回读照片库。
- **测试**：`CaseMatrixTests.testR01_aNewPhotoIsImportedExactlyOnce`、`FlowEngineIOSTests.testTheEntryNeverTriggersAnICloudDownload`。

### R-02｜新照片、桌面已有：原图读 1 次

- **原条目**：引用导入 1 次，桌面回「已有」即完成。
- **为什么在 iOS 上不成立**：同 R-01，读 = 取一次原始资源。
- **替代不变量**：取一次资源 + 一次 offer，桌面回终态即确认，不供数、不等待。
- **测试**：`CaseMatrixTests.testR01_aNewPhotoIsImportedExactlyOnce`、`DeliveryPortTests.testTheWireTupleIsTheOrderIdAndATerminalOfferReplyConfirmsWithoutWaiting`。

### R-03｜已有 order、桌面已有：原图读 0 次（实现偏离矩阵）

- **原条目**：遗留续传 / 用户恢复 / 对账补传，桌面已有 → 原图读 0 次，hash 从 order 读。
- **偏离**：这不是 iOS 特有的。Android 现行 `FlowEngine.processExisting` 对每一张已有 order 都先重新导入（读 1 次）再比 hash（这一步同时承担「中断期间被原地改写」的检测），iOS 照 Android 实现移植，同样读 1 次。iOS 的代价更大：iCloud 优化存储下这 1 次 = 一次完整下载。
- **处置**：已挂 [#901](https://github.com/hawkeye-xb/P-Pass/issues/901) 请拍板——改矩阵（读 1 次），或两端都改成 0 次（内容改写由供数时的 hash 校验兜住，见 R-05）。拍板前 iOS 与 Android 保持一致。
- **测试（钉住现行实现）**：`FlowEngineTests.testALegacyOrderWhoseImportedHashNoLongerMatchesIsReplacedByANewRow`、`FlowEngineIOSTests.testALegacyOrderWhoseICloudOriginalCannotBeFetchedIsLeftAsItIs`。

### R-04｜引用导入的条件与回退复制

- **原条目**：API 29、路径与 fd 不一致、≤ 16 KiB、`has()` 为 true 时回退复制，读缓冲 1 MiB，算 hash 与供数都流式。
- **为什么在 iOS 上不成立**：没有路径、没有 fd、没有引用导入，只有「写临时文件再导入」这一条路（等价于 Android 的回退复制）。
- **替代不变量**：导入实现（PPassMedia + FFI，#337 / #313）流式读写、内存恒定、完成或取消都删掉临时文件；引擎侧只依赖「导入给出 hash 或明确的失败类别」。这一行的字节级判据属于导入实现的测试，不在 PPassCore。
- **测试（引擎侧的那一半）**：`FlowEngineIOSTests.testLosingTheNetworkDuringAnICloudDownloadCountsNothing`、`FlowEngineTests.testAnImportIsReleasedWhenTheRoundIsCancelledBeforeItIsDelivered`。

### C-01｜暂停：flow.suspend、释放 FGS 与 wakelock

- **原条目**：写暂停标志 → `flow.suspend`（同步、不可取消、约 3 秒内返回）→ 退出循环 → 释放 FGS 与 wakelock。
- **为什么在 iOS 上不成立**：iOS 没有前台服务与 wakelock。
- **替代不变量**：FGS + wakelock 抽象成注入的执行租约（`ExecutionLease`：前台，或 `beginBackgroundTask` 给的时间），一轮只申请一次、退出就释放；`flow.suspend` 在不继承取消的任务里有界（3 秒）发出，取消绝不发 `flow.cancel`。
- **测试**：`FlowEngineTests.testPauseOnlyWhileRunningKeepsTheInFlightOrderAndResumeContinuesIt`、`DeliveryPortTests.testCancellingADeliverySuspendsTheDesktopFetchInsteadOfCancellingIt`、`DeliveryPortTests.testADesktopThatNeverAnswersFlowSuspendCannotHoldThePauseLongerThanTheBound`、`EngineWithPortTests.testPauseSuspendsTheDesktopFetchAndResumeContinuesTheSameTuple`。

### C-05｜条件丢失 / FGS 被收 / 断网

- **原条目**：`flow.suspend`，退出循环、释放 FGS；#18 保持传输中，不计失败；等待中；唤醒后自动续传。
- **为什么在 iOS 上不成立**：「FGS 被系统收回」在 iOS 上是后台执行时间到期。
- **替代不变量**：`onLeaseExpired()` 与 `onNetworkLost()` / `onNetworkChanged()` 走同一条「停循环 → 端口发 suspend → 保持传输中 → 等待中 + 唤醒」；等待原因 `EXECUTION_BLOCKED` 替代 `FGS_BLOCKED`。
- **测试**：`FlowEngineIOSTests.testAnExpiredLeaseStopsTheLoopAndWaits`、`FlowEngineTests.testLosingTheNetworkStopsTheInFlightItemAsAPathFailure`、`FlowEngineIOSTests.testANetworkChangeToCellularStopsTheRunningLoop`。

### C-06｜一轮只申请一次 FGS + wakelock + 一条推送订阅

- **为什么在 iOS 上不成立**：同 C-01，没有 FGS / wakelock。
- **替代不变量**：一轮只 `acquire()` 一次执行租约、只开一条推送会话；取不到下一张后释放。
- **测试**：`CaseMatrixTests.testD03_aPhotoTakenDuringTheLoopIsSentInTheSameLoopUnderOneLease`、`DeliveryPortTests.testOnePushSubscriptionServesAWholeRoundAndTheFirstOfferWaitsForIt`。

### C-08｜后台申请 FGS 被系统拒绝

- **原条目**：全局 = 等待中（`FGS_BLOCKED`）；下次触发照常重试申请，不持久卡死到回前台；Android 15 开机后台启动 dataSync FGS 另做真机实验。
- **为什么在 iOS 上不成立**：没有 FGS，也没有 #522 的 dataSync 额度窗口（开机序号 / elapsedRealtime 那套额度事实不移植）。
- **替代不变量**：租约拿不到 → 等待中（`EXECUTION_BLOCKED`），受阻原因只给 UI 说人话、不是闸门，下一次触发照常再申请；唤醒走探测梯，由 BGTaskScheduler 尽力兑现（#340）。
- **测试**：`FlowEngineTests.testARefusedLeaseWaitsAndTheNextTriggerSimplyTriesAgain`、`FlowEngineIOSTests.testEveryWaitReasonRegistersTheRightWake`。

### C-13｜网络回调 onLost

- **原条目**：网络回调 `onLost` → 立即判路径失败，不等 3 分钟超时。
- **为什么在 iOS 上不成立**：没有 `ConnectivityManager.onLost`。
- **替代不变量**：App 层用 `NWPathMonitor` 的 unsatisfied 调同一个命令 `onNetworkLost()`，语义不变（在飞的这张立即判路径失败、保持传输中、等待中 + 探测）。监听本身属于 App 壳（#340）。
- **测试**：`FlowEngineTests.testLosingTheNetworkStopsTheInFlightItemAsAPathFailure`。

### H-03｜桌面按单张大小预检（桌面侧条目）

- **手机侧的一半**：offer 带这张的 `size_bytes`；桌面以 `storage_full` 拒绝时按对端失败处理（不计次、等待中）。预检本身在 daemon（`crates/daemon`），不在手机。
- **测试**：`DeliveryPortTests.testTheOfferCarriesTheItemSizeAndMetadata`、`DeliveryPortTests.testAnOfferRefusedForSpaceIsAPeerFailure`。

### H-04｜低空间预警（桌面侧条目）

- **手机侧的一半**：从 `hello` 的 `health.free_bytes` 读出 `< 5 GiB` 的预警（只预警、不挡）；盘满线与 daemon 的 `SPACE_RESERVE_BYTES` 同值（读 Rust 源里的常量比对，改一边另一边红）。
- **测试**：`DeliveryPortTests.testAnUnwritableLibraryOnAFullDiskReadsAsStorageFull`、`DeliveryPortTests.testTheCriticallyLowLineMatchesTheDaemonSpaceReserve`。

### H-05｜桌面回收 3 天没续传的半截（桌面侧条目）

- **手机侧的一半**：手机侧不为回收单独写任何东西——那一行保持传输中，下一次续传仍以同一个 tuple offer。能续上**依赖 daemon 对已取消 grant 的 upsert 复活**（Android `FlowEngine` 同一假设，见 #413 裁定 8），这一前提 iOS 侧**没有测**（它是桌面行为）。换桌面时 order 整表清空（P-01），不残留。
- **测试（只覆盖手机侧：续传沿用同一个 tuple、换桌面清表）**：`EngineWithPortTests.testPauseSuspendsTheDesktopFetchAndResumeContinuesTheSameTuple`、`CaseMatrixTests.testP01_changingDesktopsDropsOldProgressButKeepsIntent`。

### X-10｜「取消剩余」在等待中是否可用（矩阵待确认）

- **原条目**：只在已暂停可用（等待中是否可用待确认）。
- **处置**：跟 Android 现行实现——已暂停与等待中都可用，备份中 / 空闲不生效。矩阵这一格仍是「待确认」，拍板后两端一起改。
- **测试**：`FlowEngineTests.testCancelWorksOnlyWhilePausedOrWaitingAndLeavesTheEngineIdle`。

### P-01｜换 Desktop 时跳过名单是否保留（矩阵待确认）

- **原条目**：配置保留；半截与运行归属清理；order 表清空、新 id 起点抬到时间戳之上。跳过名单是否保留待确认。
- **处置**：跟 Android 现行实现（#413 裁定 9）——跳过名单是用户意图，与哪台桌面无关，保留。
- **测试**：`CaseMatrixTests.testP01_changingDesktopsDropsOldProgressButKeepsIntent`、`OrderStoreTests.testChangingDesktopsClearsFactsKeepsSkipListAndLiftsIdFloor`、`DisconnectManifestTests.testDisconnectAppliesEveryRow`。

## 矩阵之外的 iOS 登记

这些不是矩阵的某一行，但同样属于「在 iOS 上不成立 / 不移植」，写在这里以免被当成遗漏。

### 后台上传通道（F5，IOS-15 挂起）

规划 F5 指出：iOS 26.1+ 的后台上传扩展（`PHAssetResourceUploadJob`）有 `jobLimit`、由系统自排序、失败只给一次重试——**「消费者严格一张一张处理」在那条通道上不成立**。本轮只做前台（2026-09-21 定调），PPassCore 里没有这条通道的任何代码，矩阵的逐张不变量在现有实现上全部成立。若 #341 / #342 解挂，接入时必须在本文件为受影响的每一行（至少 D-01、D-02、C-06、C-09、O-09）补一节变体，替代不变量由 `jobLimit` 配额与 `responseHeaderFields` 回执对账给出。

### 一张照片属于多个相册（范围键）

Android 的照片只在一个 bucket（文件夹）里；iOS 的一张照片可以同时在多个相册里。引擎只认一个「范围键」字符串（`MediaSnapshot.bucketId`），由注入的 `inScope` 解释——PPassMedia（#314）用它编码这张照片所属的相册集合，范围判断 = 任一所属相册被选中。order 行记的是建行那一刻的键；之后照片被加进 / 移出相册，行上的键会过时，这与 Android「照片挪了文件夹、行上 bucket 过时」同一类，且准备阶段一律用 lookup 的新快照重判范围。

### 部分授权（#459 的 `mediaAbsenceTrusted`）

「照片库里查不到」只有在完整相册权限下才等于「被删了」。iOS 的 `.limited` 授权下看不见的照片同样查不到，所以 `source_missing` 对账在非完整权限时整步跳过（与 Android 部分授权同一判据，不是新语义）。测试：`FlowEngineIOSTests.testSourcePresenceIsReconciledOnlyWithFullAccess`。

### Android 专属、不移植

| 来源 | 为什么 iOS 不需要 |
|---|---|
| #522 dataSync FGS 额度（开机序号、elapsedRealtime、确定被拒） | iOS 没有前台服务额度；执行租约到期 / 拿不到走 `EXECUTION_BLOCKED` + 探测梯 |
| #843 / #851 拍摄地点被抹、`flow.supersede` 用原图替换旧副本 | PhotoKit 给的原始资源不抹地点；协议镜像保留 `FlowSupersedeRequest` / `Reply` 只为契约测试 |
| API 26–29 / `preciseGeneration` | iOS 16 起 `PHPersistentChangeToken` 精确；token 过期走 I-06 |
| `ConfirmedStore` / `HashCache` / `PausePrefs` 等旧批量管线 | Android 已退役（DisconnectStateManifest 的 RETIRED 行），iOS 从 #413 之后的模型起步 |

## 两端条目数对照

| | Android | iOS |
|---|---|---|
| 矩阵行（含已废弃） | 63 | 63 + 新增 I 组 8 行 |
| 测试源码里显式写出矩阵 ID 的 | 6（`C-01` `C-02` `C-08` `C-10` `C-11` `O-07`，其余按测试名语义对应） | 71 行全部在注册表里，测试名逐个由运行时枚举核对 |
| 书面登记的变体 / 偏离 / 桌面侧 | —— | 见上面各节（数量由 `CaseMatrixCoverageTests` 打印） |
