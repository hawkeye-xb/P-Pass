# MOB-50 取消本轮后 uploadCursor 未重置，后续新项永久卡在 QUEUED（L1）

> 🟡 状态：代码完成，待真机验收 · 当前节点：取消轮次原子提交复位失效 cursor；下一步：以隔离测试相册执行 Pause→Cancel→新增媒体→确认 · 协同分支：`main` · 前置：无
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

无代码依赖。按队列真机策略，验收人以隔离测试相册执行本卡及 MOB-49 的组合
端到端验证；不得通过 ADB 写入或清空应用状态替代。

---

## 实施记录

- 2026-09-03：认领。保持 `StrictConsumer.headOf` 的严格游标契约；在 `CancellationRoundController.startPausedRound` 的同一原子提交中，将 cursor 改为映射后第一个 `QUEUED` 项，或无项时 `UploadCursor.INITIAL`。MOB-49 已使取消扫描完成后回到用户暂停态；本卡只处理其独立游标推进缺口。
- 2026-09-03：RED：新增 `FlowRunner` 路径「取消→新候选经账本发现→Continue/wake」测试，未复位 cursor 时新项不能成为严格队头，失败于断言。GREEN：取消的同一原子账本提交从映射后队列计算第一个 `QUEUED` cursor，无项则 `UploadCursor.INITIAL`。反证：暂时删除 cursor 重算后，同一测试再次失败；已恢复。全量 Android JVM 264 tests / 0 failures / 0 errors / 4 skipped，debug APK 与 `just ci` 通过。

## 备注

来源：2026-09-02 REBUILD-05 三星真机验收记录。复现时使用的 item #33/#34
均在独立测试相册（P-Pass 测试专用相册，bucket -895204530）内，未触碰
验收人真实照片库。本卡验收/复现须继续遵守这一约束。
