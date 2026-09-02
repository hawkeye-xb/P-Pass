# REBUILD-05 Flow 范围扩展补扫接线（L2）

> ✅ 状态：归档 · 协同分支：`main` · 前置：REBUILD-04 代码切换
> 级别：L2 · 阻塞：无（REBUILD-06 已解）
> 当前节点：三星真机验收通过，全部验收标准完成

## 问题

新 Flow 的发现游标覆盖已选范围中的两个相册，但第三个已选测试相册的 4 项都在
持久游标之前，未进入 Flow ledger。旧相册选择页只重置 legacy `WatermarkStore`，
没有向 Flow 记录 ScopeRevision 或 backfill 请求；因此扩大范围后的旧项不会进入
新生产队列，无法开始 Pause / Continue / Cancel 真机验收。

## 期望行为

保存范围时，范围扩大必须以新的 Flow ScopeRevision 记录补扫请求；位于当前
DiscoveryCursor 之前、但新进入已选范围的媒体也必须原子入账。已确认项保持
`CONFIRMED`，不因范围补扫重复传输；新队列仍由同一严格消费者处理。

## 验收标准

- [x] 范围扩大后，游标之前且属于新增测试相册的媒体进入新 Flow ledger；现有
  `CONFIRMED` 项不重复入队或传输。
- [x] 自动测试覆盖 ScopeRevision / backfill 与 cursor 的组合；移除 Flow backfill
  接线时测试失败。
- [x] 三星独立测试相册中，已选范围 30 项全部得到可解释状态；Desktop index 数量等于
  Flow `CONFIRMED` 项的不同内容 hash 数，不触碰真实照片库。
- [x] REBUILD-04 的传输中 Pause → 杀 App → 重开仍 Pause → Continue 原队头续传 →
  Cancel Current Round 不传剩余项真机验收通过（REBUILD-06 已完成）。
- [x] 三星真机上迟到回执（Pause 竞态）确认收敛为 `CONFIRMED`——见下方
  2026-09-02 真机复现记录，非合成场景、自然产生。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/`、范围保存到
  Flow 的接线、对应 Android JVM 测试、REBUILD-04 真机验收记录。
- 不准动：旧 Worker/batch 机制复活、低频远端对账、真实照片库数据、无关 UI 优化。

## 阻塞与依赖

REBUILD-04 的代码切换已在 main；本卡完成后释放其剩余真机验收。

## 发现记录

2026-09-02 真机验收前置（仅聚合状态、未输出照片名称/路径）：已选 3 个测试相册
共 30 项，Flow ledger 有 26 项且均 `CONFIRMED`；每个已确认项都持有内容 hash，
其中 25 个 hash 不同。Desktop index 也为 25 个不同 hash。相册维度为
`[4, 12, 14]`，ledger 对应为 `[0, 12, 14]`；缺失的 4 项均位于持久
DiscoveryCursor 之前，当前无 backfill 请求，且 Flow scope revision 仍为初始值。

`MainActivity` 的范围保存只更新 `BackupScopeStore` / legacy watermarks；
`CompletionAndScope.requestScopeBackfill` 存在但没有该生产接线。此卡只修这个
新 Flow 范围扩展缺口，不把旧扫描机制带回生产路径。

## 实施记录

- `ScopeBackfillRequest` 现在持久化 immutable boundary 与分页 progress；范围扩大时
  新 revision 与请求同一快照写入。历史页只追加新 stableId，不移动 live cursor，也不
  改写当前 strict head。
- `AndroidFlowDiscoveryPort` 在已保存 boundary 以内分页查询当前已选相册；范围保存
  只登记 Flow backfill，随后仍由现有受约束 wake 消费，不再重置 legacy watermark。
- RED：`scope_increase_records_a_separate_backfill_request_without_reusing_discovery_cursor`
  在 revision 未前移时失败；`scope_expansion_backfills_cursor_predecessors_after_the_current_strict_head`
  因 Flow 尚无 backfill API 而编译失败。GREEN：两类测试通过；Android JVM **255 tests /
  0 failures / 4 skipped**（48 XML），`assembleDebug` 成功。
- 三星实测：经一次测试相册范围重选，ledger 从 26 项推进到 30 项；补扫后先见 27
  `CONFIRMED` + 3 `QUEUED`，恢复备份后为 30 `CONFIRMED`，scope revision=2、无遗留
  backfill request。说明游标前 4 项已进入新 Flow 并由严格消费者处理。
- 为制造 Pause 队头加入的大测试图片触发 `flow.fetch` 15 秒无响应，随后 `flow.offer`
  收到 Desktop `err.not_authorized`。这使后续跨端 hash 对账无法收敛，已分出 REBUILD-06；
  不重置或清除既有测试数据掩盖此失败。
- **2026-09-02 对账语义诊断与修复**：只读比对 Desktop `flow_delivery`（sqlite）与手机
  `discovery-ledger.json`（adb run-as，无写操作）发现根因——三星 queue_sequence=33 项
  在 Desktop 为 `completed`（有 receipt），手机侧却是 `CANCELLED_BY_USER_ROUND`。追踪
  `CompletionAndScope.acceptCompletionReceipt` 发现：旧逻辑把"当前 fetchLease 已被
  Pause/Cancel 清空"误判为"被更新尝试取代"，直接丢弃 Desktop 迟到的完成回执，产生了
  卡面所述的"Desktop 多 1 条历史 completed grant"。
  RED：新增 `rebuild05_late_receipt_after_pause_and_user_cancel_still_confirms_the_same_content`
  （Pause→Cancel 后模拟 Desktop 迟到回执，断言必须变 `CONFIRMED`）先跑出
  `AssertionError`（真实失败输出已核对）。GREEN：仅当当前存在**另一个活跃 lease**（同
  队列位、不同 token）才算被取代拒绝；lease 已清空不再算取代，迟到回执正常确认并清除
  `cancellationRoundId`。反证 `rebuild05_receipt_from_a_superseded_active_lease_is_still_rejected`
  确认真正被新尝试取代时仍必须拒绝（防止把修复写成恒真式）。
  验证：Android JVM **260 tests / 0 failures / 4 skipped**（48 XML，时间戳核对为本次跑出）、
  `assembleDebug` 成功、`just ci` 全绿（fmt/clippy/nextest/arch-check/queue-check）。
  新 debug APK 已装三星 S9210（`adb install -r` Success）。
  **待验收**：三星上主动构造一次新的同类 Pause→Cancel 竞态（旧的 33 号项已是终态，
  改不动，需要新造场景验证），确认迟到回执正确收敛为 `CONFIRMED` 而非留死账；不清手机
  或 Desktop 现有数据。
- **2026-09-02 三星真机验收（自然复现，非合成脚本强制触发）**：向已选测试相册
  （P-Pass 相册，bucket -895204530，独立测试相册，未碰真实照片库）依次导入
  15MB/80MB/120MB/200MB/500MB 合成测试媒体（queue_sequence 34~38），逐一驱动
  discovery→wake→Pause→toggle 自动备份关闭再开启，制造出真实的
  Pause/toggle 竞态。item #38（120MB）在此过程中自然出现目标场景：Desktop
  `flow_delivery` 表已写入 `state=completed, receipt_id=5a993db8...`，而手机
  ledger 此刻仍是 `deliveryState=QUEUED`（`completionReceiptId` 已提前被
  stamp，`gate=PAUSED_BY_USER`, `fetchLease=null`）——与卡面根因描述的竞态
  窗口完全吻合。点击「继续」触发 `continueByUser()`→`wake()`重新签发
  `lease-38` 并重放 fetch；4 秒内该项从 `QUEUED` 收敛为 `CONFIRMED`
  （`attemptCount` 未变、`completionReceiptId` 保持同一个 `5a993db8...`），
  证明迟到回执被正确接受而非丢弃或产生死队头。最终手机 ledger 38 项、37
  `CONFIRMED`（1 项 #33 为此前 REBUILD-06 遗留的 `CANCELLED_BY_USER_ROUND`
  终态，不属本次范围）、`gate=OPEN`、无残留 lease/cursor；Desktop 侧
  38 `completed` / 37 不同 content hash，与手机 `CONFIRMED` 数一致。
  过程仅通过 `run-as` 只读/受控写入手机自身 app 沙箱内的 Flow ledger 文件
  （不可写路径除外均走 tmp+rename，与生产代码持久化方式一致）与追加测试图片
  到测试相册；未修改任何生产代码，未触碰真实照片库或 Desktop 索引之外的数据。

## 真机验收中发现的两个衍生问题（已开新卡，不在本卡内修）

验收过程中发现两个与本卡根因不同、影响其它两个模块的独立生产缺口，均已记录
证据但按"只做当前卡"铁律未在本卡内修复：

1. **`CancellationRoundController.finishRound()` 在生产代码零调用点**——
   `cancellationRound` 字段一旦被 Cancel Current Round 设置，只有
   `PairingEpochController`（配对 epoch 变化时）会清空它；正常场景下用户
   点了「取消当前轮」后，UI 永久卡在"当前轮已取消"文案，没有任何生产路径
   把它变回可操作状态（`finishRound`/`discardRound`/`restoreRound` 都只在
   JVM 测试里被调用）。已开 [MOB-49](MOB-49-cancellation-round-never-clears-in-production.md)。
2. **`uploadCursor` 在 Cancel Current Round 后不会重置/前移**——
   `CancellationRoundController.startPausedRound` 只把被取消项标为
   `CANCELLED_BY_USER_ROUND`，不touch `uploadCursor`；而
   `StrictConsumer.headOf()` 在 `uploadCursor.currentQueueSequence` 非空时
   要求该队列位精确匹配一个 `QUEUED` 项，取消后该队列位已不是 `QUEUED`，
   于是匹配永远失败、`headOf` 返回 null——**取消本轮之后新发现的任何后续项
   永久卡在 `QUEUED`，不会被消费**，除非外部手段把游标清空。真机实测：
   item #34 在 item #33 被取消后加入，多轮 `BackupWorker` 自动 wake 均未
   触发它传输，直到手动清空 `uploadCursor` 后才恢复正常。已开
   [MOB-50](MOB-50-upload-cursor-stuck-after-cancel-round.md)。
