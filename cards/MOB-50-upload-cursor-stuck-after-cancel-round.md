# MOB-50 取消本轮后 uploadCursor 未重置，后续新项永久卡在 QUEUED（L1）

> ⬜ 状态：未开工 · 协同分支：`main` · 前置：无
> 级别：L1 · 阻塞：无

## 问题

真机验收 REBUILD-05 时发现：`CancellationRoundController.startPausedRound`
把当前 `QUEUED`/`FAILED_NEEDS_USER` 项转为 `CANCELLED_BY_USER_ROUND`，但不
触碰 `DiscoveryLedgerSnapshot.uploadCursor`。而
`StrictConsumer.headOf(snapshot)`（`StrictConsumer.kt`）的逻辑是：如果
`uploadCursor.currentQueueSequence` 非空，就要求**该确切队列位**是一个
`QUEUED` 项，否则返回 null（不会退化为"取第一个 QUEUED 项"）。

取消本轮后，游标停留在被取消项的队列位，而该队列位状态已经是
`CANCELLED_BY_USER_ROUND`，永远不再匹配 `QUEUED`。于是 `headOf` 永远返回
null，**取消本轮之后新发现的任何后续项都不会被消费**，即使它们本身状态是
正常的 `QUEUED`。

真机复现（2026-09-02）：已选测试相册中 item #33 被 Cancel Current Round
取消（`uploadCursor=33`）；随后向同一相册加入新测试媒体，被 discovery
正确写入为 item #34（`QUEUED`）。此后多轮 `BackupWorker` 自动 wake（含
App 重启后的首次 wake）均未让 item #34 进入 `TRANSFERRING`——`fetchLease`
始终为 null、状态原地不动，只有手动清空 `uploadCursor.currentQueueSequence`
后才恢复正常传输。

## 期望行为

Cancel Current Round 完成后，`uploadCursor` 应当能够指向下一个真正
`QUEUED` 的项（或被重置为可以退化查找的状态），使得取消本轮之后新入队的
候选能够被正常消费，不需要任何人工干预。

## 验收标准

- [ ] `CancellationRoundController.startPausedRound`（或 `StrictConsumer`）
  确保取消本轮后，`uploadCursor` 不再钉死在已取消的队列位；新增 JVM 单测
  覆盖"取消本轮 → 新项入队 → 该新项能被正常 wake 消费"这条路径。
- [ ] 反证：还原前的行为（游标不动）必须让新增的测试变红，证明判据不是
  恒真式。
- [ ] 三星真机验证：Pause → Cancel Current Round → 加入新测试媒体 → 正常
  discovery+wake（不重启 App、不手动清状态）后该新媒体能进入
  `TRANSFERRING` 并最终 `CONFIRMED`。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/`
  中 `CancellationRoundController`、`StrictConsumer.headOf` 相关逻辑、对应
  Android JVM 测试。
- 不准动：REBUILD-05 的 backfill/ScopeRevision 逻辑、完成回执处理
  （`CompletionAndScope`）、旧 Worker/batch 机制、真实照片库数据。

## 阻塞与依赖

无。发现于 REBUILD-05 真机验收过程，与该卡根因（迟到回执处理）无关，是
Cancel Current Round 完成后队列游标推进的独立生产缺口。与 MOB-49
（cancellationRound 字段本身不清除）是同一次真机验收发现的两个不同层面
问题：MOB-49 是 UI/状态呈现层，本卡是消费者游标推进层；两者互相独立，
任一张单独修复都不依赖另一张。

---

## 实施记录

<待实施 agent 填写>

## 备注

来源：2026-09-02 REBUILD-05 三星真机验收记录。复现时使用的 item #33/#34
均在独立测试相册（P-Pass 测试专用相册，bucket -895204530）内，未触碰
验收人真实照片库。本卡验收/复现须继续遵守这一约束。
