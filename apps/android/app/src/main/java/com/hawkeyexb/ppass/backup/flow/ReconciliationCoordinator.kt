// ARCH-09: coordinate one bounded reconciliation page.
package com.hawkeyexb.ppass.backup.flow

import kotlin.coroutines.cancellation.CancellationException

/**
 * 本轮要问桌面的那一页，外加"该有活干却排不出页"的故障标记。
 * [page] 为空且 [stalled] 为真 = 筛选判据坏了，见 [AuditKinds.RECONCILIATION_STALLED]。
 */
data class ReconciliationPlan(
    val page: List<TransferItem>,
    val stalled: Boolean,
) {
    val hashes: List<String> get() = page.mapNotNull { it.contentHash }.distinct()
}

/** 桌面与本地源都问完之后的结果，交给写者线程落账。 */
data class ReconciliationOutcome(
    val plan: ReconciliationPlan,
    /** 桌面回的"我没有的"那些 contentHash。 */
    val missing: Set<String>,
    /** 仅对 [missing] 里的项解析过的本地源存在性，按 `sourceRef` 索引。 */
    val sourcePresence: Map<String, SourcePresence>,
)

/**
 * 回答唯一一个手机自己答不了的问题：**我以为传成功的那些，桌面上还在吗。**
 *
 * ## 为什么必须有这个东西
 *
 * 备份扫描是一条只进不退的水位线（`DiscoveryCursor`），扫过的照片不会再
 * 进入视野；就算回头看见了，`commitDiscoveryPage` 也会因为 `stableId` 已在
 * 账本里而跳过。所以账本上那句「这张我传成功了」**没有任何东西会去推翻它**
 * ——桌面上的副本没了，手机永远不知道。这个类就是那个"去推翻它"的人。
 *
 * ## 产品规则（MOB-87，验收人定调）
 *
 * > 手机上还有源 → 桌面上就必须有。桌面为什么没有，不问。
 *
 * **不做归因。** 不区分"桌面用户主动删的"和"文件意外没了"：做了归因，
 * 桌面误删就会被判成"故意"而不补传，手机上那份后来再被清理 → 彻底丢失，
 * 备份的稳定性正好死在这个分支上。想让备份里没有某张照片，去手机上删。
 *
 * ## 三段式：为什么不写成一个方法
 *
 * 生产账本是单写者强制的（`SingleThreadLedgerWrites`），而问桌面要走网络、
 * 问本地源要走 ContentResolver——都不能占着写者线程。所以拆成
 * [planPage]（纯读）→ 调用方在 IO 上探测 → [applyOutcome]（写者线程）。
 * [reconcilePage] 是把三段串起来的便捷入口，给测试和单线程场景用。
 */
class ReconciliationCoordinator(private val ledger: DiscoveryLedgerStore) {
    /** 纯读：本轮该核实哪一页。不碰账本写入，任何线程都能调。 */
    fun planPage(): ReconciliationPlan {
        val snapshot = ledger.load()
        val confirmed = snapshot.items
            .filter { item ->
                item.pairingEpoch == snapshot.pairingEpoch &&
                    item.deliveryState == DeliveryState.CONFIRMED &&
                    item.contentHash != null
            }
            .sortedBy { it.queueSequence }
        if (confirmed.isEmpty()) {
            // 「没东西可对」和「有东西但被判据滤光了」在这里分道：后者是故障。
            val stalled = snapshot.items.any { it.deliveryState == DeliveryState.CONFIRMED }
            return ReconciliationPlan(emptyList(), stalled)
        }
        return ReconciliationPlan(pageFrom(confirmed, snapshot.reconcileCursor), stalled = false)
    }

    /**
     * 写者线程：把桌面的回答落进账本，补传该补的，推进游标。
     *
     * [ReconciliationPlan.stalled] 为真时只落一条审计就返回——**不抛**。
     * 对账是收敛手段，一轮失败等下一轮，不能把备份搞停（同 daemon 侧
     * `reconcile.rs:125` 的纪律）。
     */
    fun applyOutcome(outcome: ReconciliationOutcome) {
        if (outcome.plan.page.isEmpty()) {
            if (outcome.plan.stalled) recordStall()
            return
        }
        val reconciliation = RemoteReconciliation(ledger)
        outcome.plan.page.forEach { item ->
            val hash = checkNotNull(item.contentHash)
            if (hash in outcome.missing) {
                val source = outcome.sourcePresence[item.sourceRef] ?: SourcePresence.UNKNOWN
                reconciliation.recordRemoteMissing(hash, source)
            } else {
                reconciliation.recordRemotePresent(hash)
            }
        }
        // 游标停在本页最后一项。走到账本尾部时，下一轮 [pageFrom] 找不到
        // 「比游标大」的项，自然回到 0 从头再来——**循环，不是水位线**。
        // 桌面上的照片随时可能消失，核实过一次不代表永远还在；「过滤掉已
        // PRESENT 的项」那种写法首轮之后核对页永久为空，再也不复查。
        ledger.update { it.copy(reconcileCursor = outcome.plan.page.last().queueSequence) }
        requeueRecoverable()
    }

    /**
     * 串起三段的便捷入口：规划 → 探测 → 落账。
     *
     * 只能在允许写账本的线程上调（测试、或已在写者线程上）。生产路径用
     * [planPage] / [applyOutcome]，把探测留在 IO 上。
     *
     * @param remoteMissing 拿一页 contentHash 问桌面，回"我没有的那些"。
     * @param sourcePresence 手机本地那张原图还在不在。
     */
    suspend fun reconcilePage(
        remoteMissing: suspend (List<String>) -> Set<String>,
        sourcePresence: suspend (String) -> SourcePresence,
    ) {
        val plan = planPage()
        if (plan.page.isEmpty()) {
            applyOutcome(ReconciliationOutcome(plan, emptySet(), emptyMap()))
            return
        }
        val outcome = probe(plan, remoteMissing, sourcePresence) ?: return
        applyOutcome(outcome)
    }

    /**
     * IO 段：问桌面、问本地源。
     *
     * 桌面离线/不可达 → 返回 null，**这轮不对账，游标不推进，下一轮重试
     * 同一页**。绝不落 [AuditKinds.RECONCILIATION_STALLED]——那条是留给
     * 「有 CONFIRMED 却排不出页」的真故障的，让离线把它刷成噪音就等于把
     * 这个信号毁掉。
     */
    suspend fun probe(
        plan: ReconciliationPlan,
        remoteMissing: suspend (List<String>) -> Set<String>,
        sourcePresence: suspend (String) -> SourcePresence,
    ): ReconciliationOutcome? {
        if (plan.page.isEmpty()) return null
        val missing = try {
            remoteMissing(plan.hashes)
        } catch (cancellation: CancellationException) {
            // 协程取消不是"桌面不可达"，原样往上抛，别把取消吞掉。
            throw cancellation
        } catch (unreachable: Exception) {
            return null
        }
        val sources = plan.page
            .filter { it.contentHash in missing }
            .map { it.sourceRef }
            .distinct()
            .associateWith { ref -> sourcePresence(ref) }
        return ReconciliationOutcome(plan, missing, sources)
    }

    /**
     * 桌面缺了、手机源还在 → 退回队列补传，**无提示**。
     *
     * 为什么是"原地翻回 QUEUED"而不是"新发一条"：`commitDiscoveryPage` 按
     * `stableId` 去重，同一张照片第二次根本进不来。原地翻是安全的——
     * `StrictConsumer.headOf` 在 `uploadCursor` 为 null 时取
     * `firstOrNull { QUEUED }`，而 `items` 恒按 `queueSequence` 排序，
     * 翻回去的老项会被自然选中；`acceptCompletionReceipt` 里
     * `next = items.firstOrNull { QUEUED }` 同理，游标回退到老序号不丢头。
     *
     * 手机端零新增 UI：补传走首页已有的备份状态显示，跟传新照片没有区别。
     * 该被警告的是在那台电脑上删东西的人，警告已经在桌面侧（MOB-29）。
     */
    private fun requeueRecoverable() {
        ledger.update { snapshot ->
            if (snapshot.items.none { it.disposition == RecoveryDisposition.NEEDS_DECISION }) {
                return@update snapshot
            }
            snapshot.copy(
                items = snapshot.items.map { item ->
                    if (item.disposition == RecoveryDisposition.NEEDS_DECISION) {
                        item.copy(
                            deliveryState = DeliveryState.QUEUED,
                            // 决定已经做了（自动补传），不再"待用户决定"。
                            disposition = RecoveryDisposition.NONE,
                            remotePresence = RemotePresence.UNKNOWN,
                            sourcePresence = SourcePresence.UNKNOWN,
                            // 旧回执作废——桌面上那份已经不在了。
                            completionReceiptId = null,
                            // 重传是全新的尝试，不该背上一轮的失败次数。
                            attemptCount = 0,
                        )
                    } else {
                        item
                    }
                },
            )
        }
    }

    private fun recordStall() {
        ledger.update { current ->
            val confirmedTotal = current.items.count { it.deliveryState == DeliveryState.CONFIRMED }
            if (confirmedTotal == 0) {
                return@update current
            }
            current.appendAudit(
                AuditKinds.RECONCILIATION_STALLED,
                roundId = current.currentRoundId,
                payload = mapOf(
                    "confirmedTotal" to confirmedTotal.toString(),
                    "ledgerEpoch" to current.pairingEpoch.value,
                ),
            )
        }
    }

    private fun pageFrom(confirmed: List<TransferItem>, cursor: Long): List<TransferItem> {
        if (confirmed.size <= REMOTE_PRESENCE_PAGE_SIZE) return confirmed
        val start = confirmed.indexOfFirst { it.queueSequence > cursor }.takeIf { it >= 0 } ?: 0
        return (confirmed.drop(start) + confirmed.take(start)).take(REMOTE_PRESENCE_PAGE_SIZE)
    }
}
