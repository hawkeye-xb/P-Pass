// ARCH-13 (#417): 把慢路径的差集动作落进 order 表。
//
// DiffPlanner 只分类；「分类之后 order 表该变成什么样」全在这里，每条动作一个事务。
package com.hawkeyexb.ppass.backup.order

import com.hawkeyexb.ppass.backup.flow.AuditKinds
import java.util.UUID

/** 一遍慢路径落了什么——给日志和测试看。 */
data class ApplyStats(
    var queued: Int = 0,
    var knownConfirmed: Int = 0,
    var remapped: Int = 0,
    var readmitted: Int = 0,
    var cancelledByScope: Int = 0,
    var failed: Int = 0,
    var sourceMissingSkipped: Int = 0,
    var sourceMissingFlagged: Int = 0,
    var sourceReappeared: Int = 0,
    var deletedMoved: Int = 0,
)

class DiffApplier(
    private val store: OrderStore,
    private val pairingEpoch: () -> String,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private fun audit(kind: String, payload: Map<String, String>) =
        AuditRecord(UUID.randomUUID().toString(), kind, null, clock(), payload)

    /** 慢路径第一遍的一条动作。 */
    fun applyPresent(action: DiffAction, stats: ApplyStats = ApplyStats()) {
        when (action) {
            is DiffAction.Upload -> {
                // 慢路径找到的新内容（多半是快路径漏掉的）：物化成 QUEUED，取件顺序 ②。
                store.insert(action.snapshot.toNewOrder(action.contentHash, OrderState.QUEUED))
                stats.queued++
            }
            is DiffAction.KnownContent -> {
                // #416 裁决 3：新增一行、不搬旧行。只有当这份内容真的有一行 CONFIRMED 时，
                // 「桌面已经有了」才成立——hash 只挂在 FAILED/未完结的行上时，桌面未必有它，
                // 按 #416 裁决 8 当作待传，靠桌面按内容去重。
                val confirmed = action.existing.any { it.state == OrderState.CONFIRMED }
                store.insert(action.snapshot.toNewOrder(action.contentHash, if (confirmed) OrderState.CONFIRMED else OrderState.QUEUED))
                if (confirmed) stats.knownConfirmed++ else stats.queued++
            }
            is DiffAction.MappingOnly -> {
                store.updateMapping(action.order.id, action.snapshot.mediaId, action.snapshot.sourceVersion, action.snapshot.bucketId)
                stats.remapped++
                // 同内容、新版本，但这张曾被判「原图没了 / 移出范围」：它现在又在范围里了。
                if (store.transition(action.order.id, READMITTABLE, OrderState.QUEUED)) stats.readmitted++
            }
            is DiffAction.Suppressed -> Unit
            is DiffAction.Unhashable -> {
                // #416 裁决 9：按单张失败处理、计入次数。
                val current = action.current
                if (current != null && current.state.isOpen) {
                    store.transition(current.id, OPEN, OrderState.FAILED, countAttempt = true)
                } else {
                    val row = store.insert(action.snapshot.toNewOrder(null, OrderState.FAILED))
                    store.transition(row.id, setOf(OrderState.FAILED), OrderState.FAILED, countAttempt = true)
                }
                stats.failed++
            }
            is DiffAction.OutOfScope -> {
                if (store.transition(action.order.id, OPEN, OrderState.CANCELLED_BY_SCOPE)) stats.cancelledByScope++
            }
            is DiffAction.Readmit -> {
                if (store.transition(action.order.id, READMITTABLE, OrderState.QUEUED)) stats.readmitted++
            }
            is DiffAction.Reappeared -> {
                if (store.setSourceMissing(action.order.id, false)) stats.sourceReappeared++
            }
            is DiffAction.Gone -> error("Gone belongs to the second pass; use applyGone")
        }
    }

    /**
     * 慢路径第二遍。[gone] 必须是**这一遍**的全部 Gone（判断「hash 还在另一条现存行上」要排除它们）。
     *
     * - hash 仍在另一条现存的当前行上（MediaStore 重建、文件移动）：删掉这条旧行，不标记、
     *   不算「已从手机删除」（#416 裁决 3）。
     * - 还没结局：SKIPPED_SOURCE_MISSING。
     * - 已有结局（CONFIRMED 等）：状态不改，只打 `source_missing` 标记（#416 裁决 2）。
     */
    fun applyGone(gone: List<DiffAction.Gone>, stats: ApplyStats = ApplyStats()) {
        val goneIds = gone.mapTo(HashSet()) { it.order.id }
        for (action in gone) {
            val row = store.get(action.order.id) ?: continue
            if (row.contentHash != null && hashLivesElsewhere(row, goneIds)) {
                if (store.delete(row.id)) stats.deletedMoved++
                continue
            }
            if (row.state.isOpen) {
                if (store.transition(
                        row.id,
                        OPEN,
                        OrderState.SKIPPED_SOURCE_MISSING,
                        audit = audit(AuditKinds.ITEM_SOURCE_MISSING, mapOf("queueSequence" to row.id.toString())),
                    )
                ) {
                    stats.sourceMissingSkipped++
                }
            } else {
                if (store.setSourceMissing(
                        row.id,
                        true,
                        audit = audit(
                            AuditKinds.ITEM_SOURCE_MISSING,
                            mapOf("queueSequence" to row.id.toString(), "state" to row.state.name),
                        ),
                    )
                ) {
                    stats.sourceMissingFlagged++
                }
            }
        }
    }

    private fun hashLivesElsewhere(row: Order, goneIds: Set<Long>): Boolean =
        store.ordersWithHash(checkNotNull(row.contentHash)).any { other ->
            other.id != row.id &&
                other.mediaId != row.mediaId &&
                other.id !in goneIds &&
                !other.sourceMissing &&
                other.state != OrderState.SKIPPED_SOURCE_MISSING &&
                store.currentForMedia(other.mediaId)?.id == other.id
        }

    private fun MediaSnapshot.toNewOrder(hash: String?, state: OrderState) =
        NewOrder(mediaId, sourceVersion, bucketId, hash, state, pairingEpoch())

    companion object {
        val OPEN: Set<OrderState> = OrderState.entries.filter { it.isOpen }.toSet()
        val READMITTABLE: Set<OrderState> = setOf(OrderState.SKIPPED_SOURCE_MISSING, OrderState.CANCELLED_BY_SCOPE)
    }
}
