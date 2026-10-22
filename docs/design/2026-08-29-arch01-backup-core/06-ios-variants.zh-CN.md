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
- **为什么在 iOS 上不成立**：iOS 没有 MediaStore generation。PhotoKit 只按**变更**给令牌（`PHPersistentChangeToken`），一次变更可能新增多张；令牌是不透明字节，不能比大小，还会过期（3105 / 3210）。直接拿令牌当 G，同一批里的每张照片只能共用整批末尾的令牌，提交第 1 张时 G 就越过了整批（#958 真机复现：一次写入 6 张只送达 1 张）。
- **替代不变量：收件箱（取新系统，PPassMedia `Inbox`）**。
  - **定位**：收件箱只服务「发现」这条快速通道，不是事实来源，只是一份「这些 id 按这个顺序出现过」的提示；取到的每一张都要再查相册现状。最终完整由对账保证（以相册真实状态加账本为准），对账不读收件箱。收件箱不认识账本、电脑、对账和引擎，只通过 `MediaSource.changes(after:)` / `currentPosition()` 对外。
  - **存储**：与账本同一个 SQLite 文件，独立的表和连接：`inbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, asset_id TEXT NOT NULL)` 加 `inbox_meta`（存归档后的 `inbox_token`）；不碰 `user_version`；连接在账本之后打开。序号 `AUTOINCREMENT`，删行之后也不复用。
  - **G**：`discovery_state.position` 存收件箱序号（8 字节大端），和 Android 的 `(generation, _id)` 一样只增不减；解不出按 0 处理。
  - **进箱**：`changes(after:)` 需要更多照片时，用 `inbox_token` 读变更历史，**每处理完一条变更提交一个事务**：按 id 排序追加这条变更新增的 id，同时把 `inbox_token` 更新为这条变更的令牌。读到一半被杀，下次从已提交的令牌继续，不重复、不漏。进箱不看备份范围；范围与「照片还在不在」由 App 层 `PhotoMediaSource` 取件时过滤，不够数就往后翻页。只收新增照片，编辑过的、从「最近删除」恢复的交给对账（#968）。
  - **取件与推进**（引擎不改）：`seq > G`，按 seq 逐张取；查不到、范围外跳过并推进 G；只剩短任务窗口时视频建待传记录、G 前进（#958）。只有引擎推进 G，在每张出结局时与 order 状态写在同一个事务里（O-07）；收件箱自己不推进任何东西。单调性仍由引擎保证：G 只沿 `changes` 的返回顺序前进；已有 order 的 lookup 结果不带位置，推不动 G（O-12）；会被重入的计数路径不写 G（I-07）。
  - **G 重置**（首次建立、换电脑、照片库身份变了；引擎 `resetDiscovery`，不改）：`currentPosition()` 没有令牌时取 PhotoKit 当前令牌，返回收件箱当前最大序号（AUTOINCREMENT 高水位，从未进箱为 0），并删掉 `seq <= 它` 的行——这是收件箱唯一删行的地方，取件时不删（计数翻页传进来的位置不是 G）。同时扫描置脏：G 以下的照片、收件箱里没处理的旧行，全部交给对账。首次选择相册时原有的照片走 SCOPE_ADDED 对账，不经过收件箱。
  - **令牌失效**（3105 / 3210 / 存盘字节解不出）：收件箱**不抛错、不动 G**，只把自己的令牌重置为当前令牌并记一行日志（`inbox: change token expired; reset to current, gap left to reconcile`），已进箱的行照常往下取。缺口里没进箱的照片由对账兜底：iOS 的 `preciseDiscovery = false`，每个对账轮都把扫描置脏，长任务或前台会补上。其他错误（例如授权被收回）原样上抛。引擎处理 `DiscoveryCursorExpired` 的那条路（I-06 / I-07）保留，PhotoKit 媒体源不再走到它。
- **测试**：`FlowEngineIOSTests.testDiscoveryOnlyMovesForwardAlongTheSourceOrder`、`FlowEngineTests.testAReconcileScanCommitMovesSAndLeavesGToNewPhotos`、`OrderStoreTests.testAFailureInsideTheWriteRollsBackStateAndCursorTogether`；收件箱语义在引擎下的端到端：`InboxDiscoveryTests`（逐张推进、断点续取、被杀后一致、查不到即跳过、范围、换电脑、重复 id、短任务视频）；收件箱本身：PPassMedia `InboxTests`（进箱顺序与序号、进箱途中被杀、序号不复用、首次初始化、令牌失效、重复 id），真 PhotoKit：`ChangeTokenIT`、`TokenExpiryIT`（模拟器上造出 3105）。

### O-03｜MediaStore 重建后 `_id` 变了、内容没变

- **原条目**：新 `_id` 进入待办，导入算出同一个 hash，offer 时桌面按 hash 回「已有」，传输字节数为 0。
- **为什么在 iOS 上不成立**：没有 MediaStore 重建。对应的 iOS 事件是照片库身份变化（换库 / 从备份恢复）或 `localIdentifier` 变化，以及 token 过期（3105）。
- **真实生效的路径（#904 查证，2026-10-16）**：PhotoKit **没有可用的照片库身份**，`PhotoMediaSource.libraryIdentity()` 恒返回 nil 是契约里的「说不出」（不触发重置），不是待补的占位。「库身份变 → 重置 G」这条路径只在引擎单测里成立；真实起兜底作用的是 `preciseDiscovery = false`：**每个对账轮都把扫描置脏**（`FlowEngine.prepareCursors`），对位 Android API < 30 `preciseGeneration = false` 的同一条路。
  - **查过的候选**：① `PHPhotoLibrary` 无公开标识；② `photoLibraryURL` 是私有 KVC，模拟器上是设备目录，不是库的身份；③ `PHPersistentChangeToken` 的归档里带 Core Data store UUID（`NSPersistentHistoryToken` 字典的键）。③ 实测（模拟器，iOS 26.4）：同一图库多次读取 UUID 不变，但 `simctl erase` 重建图库后 **UUID 仍是同一个**，旧令牌也不报错（TokenExpiryIT 已记录的「不绑定图库」）——认不出换库，且要解析私有归档格式，**否决**。
  - **标准做法**：没有可靠身份时不猜，靠对账扫描（以相册真实状态加账本为准，按内容哈希判重）兜住 G 以下的漏网，代价是多扫一遍元数据，不是丢备份。若之后找到可靠标识（需真机验证设备恢复 / 换机恢复场景），再接到 `libraryIdentity()`。
- **替代不变量**：库身份变 → G 重置、扫描置脏（与 Android「getVersion 变了」同一条路；iOS 上此路径恒不触发，见上）；3105 由收件箱自己把令牌重置为当前令牌、不动 G，缺口交给对账（见 O-01）；内容没变的照片在桌面按 hash 判重，offer 直接回终态，手机侧不等待、不供数。
- **测试**：`FlowEngineIOSTests.testAChangedLibraryIdentityResetsTheCursor`、`FlowEngineIOSTests.testAnExpiredDiscoveryCursorRescansAndConvergesWithoutDuplicates`、`DeliveryPortTests.testTheWireTupleIsTheOrderIdAndATerminalOfferReplyConfirmsWithoutWaiting`。

### D-07｜多个外部卷

- **原条目**：G 按卷分开存、按卷查询；API 26–29 的取件来源待确认。
- **为什么在 iOS 上不成立**：iOS 只有一个系统照片库，没有卷，也没有 API 26–29 那种不精确的 generation。
- **替代不变量**：单库单游标（`discovery_state` 表只有一行）；库身份变化时整体重置的路径在 iOS 上恒不触发（见 O-03），换库由每轮对账扫描兜底。
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

### I-06｜发现游标已过期（3105）

- **原条目**：发现游标（`PHPersistentChangeToken`）过期 → G 重置到当前位置、对账扫描置脏。
- **为什么在 iOS 上不成立**：收件箱（#958，见 O-01）之后，G 不再是令牌，而是收件箱序号；令牌只是收件箱读变更历史的位置。令牌过期不影响 G：已经进箱的行照常往下取，重置 G 反而会把它们白白推给对账。
- **替代不变量**：令牌失效（3105 / 3210 / 存盘字节解不出）时，收件箱不抛错、G 不动，只把自己的令牌重置为当前令牌并记一行日志；之后的新照片照常进箱。缺口里没进箱的照片由对账兜底：PhotoKit 媒体源报 `preciseDiscovery = false`，每个对账轮都把扫描置脏（I-10），按内容哈希判重，已确认的同版本照片不重传。引擎处理 `DiscoveryCursorExpired` 的那条路（重置 G、置脏，O-03 / I-07）保留，PhotoKit 媒体源不再走到它。
- **测试**：`InboxDiscoveryTests.testS6_9_anExpiredTokenLeavesGAloneAndTheGapIsReconciled`、`FlowEngineIOSTests.testAMisplacedCursorIsCaughtByTheNextReconcileRound`、`FlowEngineIOSTests.testAnExpiredDiscoveryCursorRescansAndConvergesWithoutDuplicates`；收件箱本身：PPassMedia 包的 `InboxTests`（令牌失效那一条，在模拟器上跑，不在本注册表的运行时枚举里），模拟器真 3105：`TokenExpiryIT`。

## 矩阵之外的 iOS 登记

这些不是矩阵的某一行，但同样属于「在 iOS 上不成立 / 不移植」，写在这里以免被当成遗漏。

### 源版本（#968）

- **Android**：版本 = `dateModified:size`，两个量都只随文件内容变；版本变了 → 新建一行，旧行记 `SKIPPED_SOURCE_MISSING`。
- **iOS 不能照搬 `modificationDate:size`**（模拟器实测，`ContentVersionIT`）：收藏 / 取消收藏会推进 `PHAsset.modificationDate`（加进相册不会），内容没动。把 size 补成真实值也不够——只要还带修改时间，收藏照样判成新版本、重新取原图（iCloud 优化存储下等于整张重下）。
- **口径**：版本 = 实际备份的那份资源（`selectOriginalResource`：编辑过取 `.fullSizePhoto` / `.fullSizeVideo`）的「资源类型:大小」，大小取 `PHAssetResource` 的 `fileSize`（KVC，**非公开 API**，lookup 早已在用；读库里的元数据，不读文件）。编辑 → 多出渲染资源、大小变；再编辑 → 大小变；还原编辑 → 回到 `.photo`，版本回到原值（桌面按内容哈希判重）；收藏等元数据 → 不变。快照与 lookup 走同一个函数（`readOriginalContent`），引擎按版本相等判定不会错位。
- **与 Android 的差异**：① 两次编辑渲染出的字节数恰好相同时会漏掉新版本（Android 靠修改时间不会漏）；② 取不到 `fileSize`（KVC 失效 / 无资源）时版本降级为「类型:unknown@修改时间」，保守地多取、不漏改，并写日志 `media: source version degraded`，不退回 0。
- **发现时机**：收件箱只收新增、忽略 updated（避开系统分析噪声），所以被编辑的照片由对账轮扫描发现（每轮都扫，见 O-03），不像 Android 随 generation 当场发现。换成内容版本后 updated 事件已无副作用，是否让收件箱收 updated 以对齐 Android 的当场发现，待拍板（另开 issue）。
- **成本**：扫描每张多读一次资源列表与大小，模拟器实测 2.8 ms/张（307 张 849 ms，原先只读 `modificationDate`）；万张级图库每个对账轮约 28 s 的纯元数据读取，待真机复核。
- **待真机**：iCloud 优化存储（原图不在本机）下 `fileSize` 的取值未验证；读不到会走上面的降级并留日志。
- **升级代价**：版本格式变了，旧账本里 `修改时间:0` 的行都对不上，会被当作新版本重取一遍；iOS 尚未对外发版（`release/notes/ios` 不存在），只影响测试机。
- **测试**：`ContentVersionTests`（PPassMedia，纯逻辑）、`ContentVersionIT`（真 PhotoKit：收藏不换版本、编辑换、再编辑再换）。成本数字来自一次性探针（造 300 张后逐张读，未入库：它会把图库历史推长，破坏 `TokenExpiryIT` 对「第二轮变更数少于 40」的前提）。

### 后台上传通道（F5，IOS-15 挂起）

规划 F5 指出：iOS 26.1+ 的后台上传扩展（`PHAssetResourceUploadJob`）有 `jobLimit`、由系统自排序、失败只给一次重试——**「消费者严格一张一张处理」在那条通道上不成立**。本轮只做前台（2026-09-21 定调），PPassCore 里没有这条通道的任何代码，矩阵的逐张不变量在现有实现上全部成立。若 #341 / #342 解挂，接入时必须在本文件为受影响的每一行（至少 D-01、D-02、C-06、C-09、O-09）补一节变体，替代不变量由 `jobLimit` 配额与 `responseHeaderFields` 回执对账给出。

### 一张照片属于多个相册（范围键）

Android 的照片只在一个 bucket（文件夹）里；iOS 的一张照片可以同时在多个相册里。引擎只认一个「范围键」字符串（`MediaSnapshot.bucketId`），由注入的 `inScope` 解释——PPassMedia（#314）用它编码这张照片所属的相册集合，范围判断 = 任一所属相册被选中。order 行记的是建行那一刻的键；之后照片被加进 / 移出相册，行上的键会过时，这与 Android「照片挪了文件夹、行上 bucket 过时」同一类，且准备阶段一律用 lookup 的新快照重判范围。

### 部分授权（#459 的 `mediaAbsenceTrusted`）

「照片库里查不到」只有在完整相册权限下才等于「被删了」。iOS 的 `.limited` 授权下看不见的照片同样查不到，所以 `source_missing` 对账在非完整权限时整步跳过（与 Android 部分授权同一判据，不是新语义）。测试：`FlowEngineIOSTests.testSourcePresenceIsReconciledOnlyWithFullAccess`。

### 前台相册变化监听（#978）

- **Android**：`BackupUiStateHolder` 在持有期间注册 MediaStore `ContentObserver`；变化 → `gateway.onMediaChanged()`（App 可见才触发 `FOREGROUND_MEDIA_CHANGE`，人在场，不查后台开关）+ 重算首页计数 n。后台另有 `MediaWatchJob`（JobScheduler 内容触发 → `MEDIA_CHANGE`）。
- **iOS 对位**：PPassCore `MediaChangeWatcher` 管生命周期，App 层 `PhotoLibraryChangeSource`（`PHPhotoLibraryChangeObserver`）做来源；一次变化由 `ForegroundMediaChange` 处理：先重算首页计数，**在前台**再以 `FOREGROUND_MEDIA_CHANGE` 叫醒引擎（引擎入口 `userPresent`、在跑时合并并重算待办，见 `FlowEngine.recountWhileRunning`）。
  - **生命周期**：配对着且相册授权为完整或部分（limited）才注册；没配对、没问过、拒绝、受限时**不注册并写日志**（`media-change: observer not registered: <原因>`，同一原因只记一次）。断开清单的 `mediaChangeObserver` 行注销；重新配对（`paired`）与每次刷新首页事实（授权晚于启动时补注册）时幂等地恢复。部分授权下系统只通知可见范围内的变化，监听照常工作。
  - 日志特征行：`media-change: observer registered` / `media-change: trigger FOREGROUND_MEDIA_CHANGE` / `media-change: observer unregistered`。
- **平台差异（有意不同，不是遗漏）**：iOS **不会因相册变化唤醒 App**（`BackgroundWakePlanner.swift` 头注释：BGTaskScheduler 只给系统挑的时机，不保证会跑，没有「内容变化触发」的入口），所以没有对位 Android `MediaWatchJob` 的后台路径。后台新增的照片靠回前台的 `APP_FOREGROUND` 追赶、BGProcessingTask 的周期兜底与探测梯发现；仅在前台持有 UI 期间才有「当场开始备份」的体验。
- **测试**：`MediaChangeWatcherTests.testStartRegistersOnceAndIsIdempotent`、`MediaChangeWatcherTests.testUnavailableDoesNotRegisterLogsOnceAndRecovers`、`MediaChangeWatcherTests.testStopUnregistersAndRestartRegistersAgain`、`MediaChangeWatcherTests.testACallbackFromAStaleRegistrationIsIgnored`、`ForegroundMediaChangeTests.testForegroundRecountsThenTriggersTheForegroundReason`、`ForegroundMediaChangeTests.testNotForegroundOnlyRecounts`；App 层 PhotoKit 适配与授权档位判据在 PPassTests 的 PhotoLibraryChangeSourceTests（模拟器上跑，不在本注册表的运行时枚举里）。

### 断开时运行时清理（#974）

- **Android**：`clearFlowRuntime`——关 scope / writer / SQLite，`setAllowedPeer(null)`，`revoke("")`。
- **iOS 对位**：断开清单 `flowRuntime` 行 = `NativeProvider.teardownForDisconnect`：清允许的对端（在飞连接在原生侧关掉）→ 掐在飞传输 → `revoke`（拿掉当前 handler 与全部导入）→ 清 active lease。与 #958 暂停（`FfiBlobProvider.pause`）同一套 stop + revoke 语义；只清对端不 revoke，旧 temp tag / 在飞状态会留到进程结束。断开之后同进程重新配对：`paired` 重新 `setAllowedPeer`，下一张照片重新导入 → 供数，handler 重建，取原图正常。
- **有意不同**：Android 在此还关 scope / writer / SQLite，iOS **不关**——引擎（`FlowEngine`）、账本（`SQLiteOrderStore`）与收件箱是 `LiveBackend` 进程级单例，断开只由 `engine.stopForDisconnect()` 停掉这一轮，账本按「连回同一台桌面 CONFIRMED 仍有效、换一台由 `claimOwner` 清」（#415 裁决 6）保留，重配后不重传已备份的。关账本等于要在重新配对时重建整条引擎，iOS 没有这个需要。
- **清单语义**：`applyDisconnectManifest` 某一行失败不再短路后面的行（所有行跑完后抛第一个错误）；`flowRuntime` 行承担 provider 撤销，不能被「配对文件清不掉」连带跳过。
- **测试**：`DisconnectManifestTests.testARowThatFailsDoesNotSkipTheRuntimeStopsAfterIt`、`DisconnectManifestTests.testDisconnectAppliesEveryRow`；真实 provider 的断开与重新配对在 PPassTests 的 DisconnectProviderTests（模拟器上跑）。

### 通知授权（#975）

- **Android**：Android 13+ 在 onboarding 完成页点任一按钮时问**一次** `POST_NOTIFICATIONS`（`OnboardingNotificationAsk`，#130）：问之前先落盘「已问过」，结果同步回开关（授予 → 开，拒绝 → 关）；老用户升级不问；设置页开关显示 = 偏好 **且** 已授权，拨开时没权限就再弹一次申请框。Android 没有任何「去系统设置」的引导。
- **iOS 对位**：同一份语义——PPassCore `OnboardingNotificationAsk`（同文件名 `onboarding_notification_ask.json`、同字段、同「缺失不问 / 损坏当已问过 / 老用户不问」，断开清单登记为保留）；完成页点「好」时 `LiveEngineAdapter.askNotificationAtOnboarding` 先落盘再弹系统框，结果写回偏好；页面上先显示 `onboarding_notification_note` 一句用途说明。开关显示值 = `NotifyToggle.displayValue(偏好, 授权)`；发通知前读 `UNUserNotificationCenter.notificationSettings`，未授权 / 开关关着**不发、记一行日志**（`notify: <事件> not delivered, enabled=… system authorization=<状态>`），去重状态照常推进、之后打开也不补发（与 Android 一致，#981 起；判定在 PPassCore `decideDefinitiveNotices(deliverable:)`）。
- **三态对照**：

| 系统授权 | 开关显示 | 拨开时 | 通知 |
|---|---|---|---|
| notDetermined | 关（偏好开也显示关） | 弹系统框，结果写回偏好（同 Android 申请回调） | 不发 + 日志 |
| denied | 关，下方多一行「在系统设置里打开」说明 | 跳系统设置里本 App 的通知页 | 不发 + 日志 |
| authorized（含 provisional / ephemeral） | 跟偏好 | 直接写偏好 | 发 |

- **平台差异（有意不同，不是遗漏）**：iOS 系统授权框**只弹一次**（`requestAuthorization` 在 notDetermined 之后不再有界面），所以 `shouldAsk` 额外要求系统仍是 notDetermined，且 denied 时拨开改为**跳系统设置**——Android 在此会再弹申请框（被拒两次后同样没界面，却没有引导）；denied 时多一行 `rule_notify_denied_hint` 是为这条路径服务的 iOS 独有文案。用户从系统设置回来（`sceneBecameActive`）重读授权，开关即时反映。没有 Android 12 及以下「无运行时权限」那一档。
- **测试**：`NotificationAskTests`（PPassCore：只问一次 / 先落盘 / 老用户 / 缺失与损坏 / 开关三态与拨开动作）、`DisconnectManifestTests.testDisconnectAppliesEveryRow`（新行登记）；PPassTests 的 NotificationAndCountsTests（系统状态映射；模拟器上跑）；「未授权不发、状态照常推进、之后不补发」由 `DefinitiveNoticesTests.testUndeliverable*` 覆盖。

### 失败通知的触发集合与去重（#981）

- **Android**（`DefinitiveEventNotices.kt`，#130）：只发三类确定事件，每类一个通知 id、状态变化只发一次、恢复后复位并撤掉旧通知。
  1. 配对失效：去重键 = 配对代号（epoch）；只有「没配对了」或「换了代号」才复位，`isLost` 变 false（进程重启）不算恢复。
  2. 相册权限变差（完整 → 部分 / 无，部分 → 无）：记上次档位，变差才发，回到完整复位；没有基线只记不发；没配对只记。
  3. 后台被停：MOB-28 的中断（同一次开机内监听凭空消失 = force-stop / OEM 清理，按 `detectedAt` 去重），或电池优化被重新打开（true → false，且用户要后台备份）；没有基线只记不发。
  - 单张 / 整体备份失败**不发**（#418）。状态落盘 `definitive_notices.json`（tmp + rename，**没有过期**：靠上述复位条件清）；读坏回到默认基线。开关与系统权限只挡「发出去」，状态照常推进（iOS 同）。评估入口：进程启动 / Worker 结束 / 回前台 / 配对失效变化。
- **iOS 对位**：PPassCore `DefinitiveNotices.swift`（纯判定 + 落盘，文件名与字段同 Android，断开清单登记为保留）；发 / 撤在 `FailureNotifier`。评估入口：`refreshFacts`（启动、回前台、各类刷新）与**后台任务结束时**（短 / 长任务在 `setTaskCompleted` 之前，`PPassBackgroundTasks.register(afterRun:)`），后者对位 Android Worker 结束。不再发「备份出问题」（#981 前 iOS 与 Android 相反）。
  1. 配对失效：同 Android；空代号（待 #966 修复）当没有代号，不拿来去重。
  2. 相册权限：`PhotoAccessLevel` → 三档（full / limited → partial / denied、restricted、notDetermined → none，与首页同口径），规则同 Android。
  3. 后台被停：对位物 = **「后台 App 刷新」从可用变成不可用**（`UIApplication.backgroundRefreshStatus`），且 `AutoBackupPrefs.requested()`；denied / restricted 文案不同（restricted 用户自己改不了）。电池优化 iOS 不存在，故没有 `notif_battery_reenabled_*`。
- **平台差异（有意不同，不是遗漏）**：
  - **MOB-28「后台中断」iOS 没有对位物，不移植**：iOS 上 App 被 force-quit / 被系统杀掉，进程内无从区分，也没有「同一次开机内监听消失」可比的信号（BGTask 由系统调度，不是我们注册的常驻监听）；系统在 force-quit 之后是否还拉起后台任务没有 Apple 文档的明确保证（论坛有相反的报告：[developer.apple.com/forums/thread/793189](https://developer.apple.com/forums/thread/793189)）。「后台执行时间到期」是 iOS 的常态（见 C-05），不是故障，不通知。没有检测手段就不硬凑；英雄卡上的「最近备份」时间是用户能自己发现后台没跑的渠道。
  - 通知点开只打开 App（没有深链进系统设置），所以相册权限通知的正文写 iOS 设置项名字（`IOS.strings` 覆盖 `notif_media_*_body`）；后台刷新通知为 iOS 独有 key（`notif_background_refresh_*`）。
  - **前台展示**：已对齐（#1018）。启动时设 `UNUserNotificationCenterDelegate`，`willPresent` 返回横幅 + 通知中心 + 声音，前台发出的通知照常展示，同 Android。未设代理时 iOS 的默认行为是前台通知既不弹横幅也不进通知中心（2026-10-19 真机实测）。
- **测试**：`DefinitiveNoticesTests`（PPassCore：触发集合只有三类 / 每类的发、不重发、复位、基线 / 未送达只不发、状态照常推进且之后不补发 / 落盘重启不重发与反证 / 文件名字段 / 缺失静默、损坏留日志、写失败抛出）、`DisconnectManifestTests.testDisconnectAppliesEveryRow`（新状态文件登记）。

### 首页计数读库失败（#973）

- **已对齐（#1038）**：两端同一语义——读失败要暴露，不沿用旧值、不当 0。
- **iOS**：`OrderCounts.read`（PPassCore）五个读口任一失败整体抛出；`refreshFacts` 记日志（`home-facts: order counts unreadable: …`）并把事实标为 `countsReadable = false`（计数全是占位 0）。投影层对它一律不给完成度结论：`triplet` 为 nil、`allDone` 为 false、状态行走中性 idle（不出 allSafe，也不据占位 0 出 trouble 红卡），英雄区显示 `hero_counts_unreadable`，「上次成功」不落成「还没成功过」。
- **Android**：`BackupUiStateHolder` 读账本经 `factsOrUnreadable`：`FlowProjection.facts` 抛出 → `FlowProjection.unreadable`（`countsReadable = false`，n 与引擎视图照常带上），记日志（`home-facts: order counts unreadable`，由好转坏时记一次）。`backupUiStateOf` / `flowAllDone` / `flowTripletOf` 对它与 iOS 同样短路，`heroRenderOf` 给 `CountsUnreadable`。运行时还没就绪（gateway 为 null）不是读失败，照旧不发布。回到前台重读一次（`holder.onResume`），所以文案「打开 App 时会再试」两端都成立。
- **没选相册（同批对齐）**：范围从未保存 / 读不到、保存了空集、或已选相册都不存在（#836 口径）→ 空闲时状态行 `state_no_albums`（排在 trouble 之前）；英雄区在三元组为空时看范围存没存：没存 → `backup_scope_none`，存了 → `triplet_unavailable`。Android 此前 `BackupUiState.NoAlbums` 没有生产者，现由 `noAlbumsOf` 接上。
- **测试**：iOS——`OrderCountsTests`（读失败抛出而不是 0）、PPassTests 的 NotificationAndCountsTests / HomeProjectionTests（模拟器上跑；反证组合：引擎视图 pending=0、范围已知、计数不可读）。Android——`UserCommandAndHomeFactsTest`（同一反证组合、未选相册的四种来源与优先级、英雄区六选一的顺序）。

### 后台备份默认值、首次配对完成页与「仅 Wi‑Fi」确认（#982）

- **Android**：`AutoBackupPrefs.autoEnabled` 默认 false；首次配对新电脑先 `setRequested(false)`，完成页给「开启后台备份 / 不开启后台备份」两个按钮由用户选；连回以前连过的电脑按留下的意图恢复；关闭「仅 Wi‑Fi」先弹确认框（移动网络会消耗流量），确认后才保存。
- **iOS 对位**：全新安装后台备份默认**关**（删掉了 `LiveBackend.init` 里的默认置开）；`AutoBackupPrefs.applyOnPairing(knownDesktop:)`（PPassCore）——新电脑清意图、老电脑按意图恢复；完成页换成两个等高按钮，两个按钮都先走通知询问再继续；关「仅 Wi‑Fi」用 `.alert` 确认，点取消不写盘。「连没连过」改在 `onPaired` 标记**之前**判定（此前顺序反了，`firstTime` 恒为 false，首次配对进不了选相册与完成页）。
- **平台差异（有意不同，不是遗漏）**：
  1. **没有 App 内申请后台执行的系统框**。Android「开启」时要去申请电池白名单，被拒则挂起生产者、授权回来再恢复；iOS 的「后台 App 刷新」只能用户自己在系统设置里开，App 弹不出申请。所以 iOS「开启」直接写偏好、**不因后台刷新关着而挂起生产者**（否则还得补一条「授权回来再恢复」的路径）；关着的情况由全局告示说明（`AppModel.backgroundNotice` ← `BackgroundRefreshAvailability.denied` / `.restricted`，对位 Android `NoticeHost` 的 BACKUP_INTERRUPTED）：只在用户要后台备份时出现，不给「知道了」；关掉的给「去处理」跳系统设置里 P-Pass 的页面，被限制的不给按钮；设置 tab 同时亮角标。**与 Android 的差别**：Android 两页顶部都显示；iOS 只放设置页、作为英雄卡下方的一行（用户 2026-10-19 拍板：照片页是浏览用的，顶部不占；浮在顶部会盖住英雄卡），照片页只靠设置 tab 角标。（10-13 的 f57a2942 曾把设置页这块连同固定说明一起删掉，2026-10-19 补回并改为全局告示。）
  **不放常驻说明（#343，用户 2026-10-22 拍板）**：与 Android 一致，首页 / 设置页不放「打开 P-Pass 时备份」这类常驻说明，告示只在出问题时出现；「iOS 后台不保证」的解释归 Q&A。
  2. **文案按 #343 只说能兑现的**：完成页多一句 `background_backup_ios_note`（iOS 可能找机会接着备份，是否执行、何时执行由系统决定，不保证），不写频率、不假装有后台。按钮文案沿用 Android 的 `background_backup_enable` / `background_backup_not_now`。
  3. 前台备份不受这个开关影响：`Conditions.autoBackupEnabled` 为 false 时，`userPresent` 的触发（回前台 / 手动 / 选相册 / 前台相册变化）照常起轮（`FlowTypes.swift` `.disabled` 判定只拦非用户在场的触发）。
- **「连过这台电脑」的落盘时机（#1019，已对齐）**：同 Android `finishOnboarding`（MOB-114），在完成页点任一按钮时才 `markOnboarded`（`BackupEngine.finishOnboarding`），配对成功时不记——配对后、走完首次设置前被杀进程，下次再配这台仍按新电脑走选相册与后台备份选择。记不下来照样进首页，但弹 `setting_save_failed`（后果只是下次重连仍走一遍首次设置）。
- **测试**：PPassCore 的 `PrefsTests`（老 / 新电脑 / 写失败）；PPassTests 的 PairingWiringTests（firstTime 在 onPaired 之前判定，模拟器上跑）与 SettingsFeedbackTests（Wi‑Fi 确认、默认关、完成页选择）。

### provider 预热与空闲回收（#979）

- **Android**（#434）：探测桌面前先 `native.prewarm()`，provider 的 endpoint 与 hello 并行去连 relay；`NetworkIdleReaper`：不在前台、且引擎这一轮结束（`engine.status.phase == IDLE`），等 30 秒宽限期后 `park()` 关掉 endpoint（store 不关），park 回 false（桌面还连着）就隔一个宽限期再试。控制通道 DaemonClient 的 endpoint 同样回收。
- **iOS 对位**：`PrewarmingProbe` 包住 `ControlPlaneProbe`，探测前 `prewarm()`，失败只记日志、serve 时照常自己绑；`ProviderIdleParker`：不在前台（`setActive`）且引擎未持有租约（`ExecutionWindow.observeLease`）就 `park()`，回 false 隔 2 秒再试，直到不再空闲。
- **有意不同**：
  1. **没有 30 秒宽限期**：iOS 退到后台后进程很快被挂起，等不到 30 秒；条件一成立就关，挂起前把 endpoint 放掉。
  2. **控制面 endpoint 不回收**：iOS 的 `CtrlClient` FFI 没有导出 park；补它要改 `crates/transport`（触发 Android / 桌面版本门禁）。iOS 后台进程被挂起后不再收发，Android 那种「后台空跑 endpoint 耗流量」的问题在 iOS 上不成立，暂不补。

### 设置写盘失败与用户命令出错的反馈（#971 / #972）

- **已对齐（#1020）**：两端同一语义——写失败不崩溃、不静默；命令出错要提示，「状态不允许」不是错误。
- **设置写盘**：store 写失败照旧抛出（后台写者靠它暴露问题），界面这一侧统一接住——成功才更新显示值 / 做后续副作用（重排任务、叫醒引擎、申请白名单），失败记日志（`settings: write failed (…)`）、显示值回到盘上的真实值、给一过性提示 `setting_save_failed`；成功也记一行（`settings: saved …`）。iOS 在 `AppModel`（`settingWriteFailed`），Android 在 `SettingsWriter`（`MainActivity` 的仅 Wi‑Fi、后台备份、通知开关、完成页、权限弹窗回调都经过它）。后台备份的「意图 + 生产者」两个字段 Android 改为一次落盘（`AutoBackupPrefs.set`），不会写成半截。
- **相册范围**：读失败与「从未保存」区分——iOS `MediaLibrary.savedScope` 抛出，Android `BackupScopeStore.readScope` 返回 `ScopeRead.Unreadable`（存下的串里有解析不出的段；此前 `mapNotNull` 静默丢掉）；设置行显示 `backup_scope_unreadable`，引擎侧记日志后按空范围，选相册时旧范围按「从未选过」算。写失败（Android 由 `apply` 改为 `commit` 并检查返回值）→ 提示 `scope_save_failed`，不进完成页、不叫醒引擎。
- **用户命令**（再试一次 / 恢复已跳过 / 取消剩余 / 弹框前的快照）：执行出错 → 记日志（`command failed (…)`）+ 提示 `command_failed`；「状态不允许」（iOS `cancelRemaining` 返回 nil；Android 引擎返回 false / null、运行时未就绪）只刷新，那一行随状态收起。成功记 `command … ok`。iOS 在 `AppModel.runCommand`，Android 在 `BackupUiStateHolder.command` / `attemptUserCommand`；Android「再试一次」改为经 gateway 等引擎做完（此前另起线程，出错只进 logcat）。
- **平台差异（客观，不是遗漏）**：
  1. 提示的载体：iOS 用 alert（标题 `notice_title`，iOS 独有），Android 用 UI-12 的 Snackbar（无标题）；提示正文两端共用（Android `strings.xml` 为源）。
  2. Android 的 SharedPreferences 文件损坏时由系统整份当空读出，App 分辨不出——这一种只能当「从未保存」；能分辨的（存下的值解析不出来、读取抛出）一律按读不到。
- **测试**：iOS——`SettingsFeedbackTests`（写失败回滚 + 提示、命令出错提示、状态不允许不报错、范围读失败 ≠ 从未保存）。Android——`SettingsWriteFeedbackTest`（偏好目录只读，真实制造写失败：显示值回到盘上的值、提示、日志；store 照旧抛出；范围三种读法）、`UserCommandAndHomeFactsTest`（命令出错 / 状态不允许 / 取消不算出错；接线门禁）。

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
| 矩阵行（含已废弃） | 63 | 63 + 新增 I 组 10 行 |
| 测试源码里显式写出矩阵 ID 的 | 6（`C-01` `C-02` `C-08` `C-10` `C-11` `O-07`，其余按测试名语义对应） | 73 行全部在注册表里，测试名逐个由运行时枚举核对 |
| 书面登记的变体 / 偏离 / 桌面侧 | —— | 见上面各节（数量由 `CaseMatrixCoverageTests` 打印） |
