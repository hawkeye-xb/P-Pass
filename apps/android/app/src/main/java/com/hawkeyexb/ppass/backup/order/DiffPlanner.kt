// ARCH-12 (#416) / ARCH-13 (#417): MediaStore × order 差集规划。纯函数：不写库、不碰 ContentResolver，
// 只把两条已排序的流归并成一串「该做什么」。算 hash 与按 hash 查 order 都由调用方注入。
package com.hawkeyexb.ppass.backup.order

/** 差集规划的产出。规划器只分类，落库由 [DiffApplier]、传输由循环决定。 */
sealed interface DiffAction {
    val mediaId: Long

    /** 新内容，待传。[previous] 是该 media_id 此前的当前行（CHANGED 时非空）。 */
    data class Upload(val snapshot: MediaSnapshot, val contentHash: String, val reason: Reason, val previous: Order?) : DiffAction {
        override val mediaId get() = snapshot.mediaId
    }

    /**
     * hash 已经存在于 order（MediaStore 重建、文件移动、同内容另存）。
     * [existing] 是持有该 hash 的行（按 id 升序），[current] 是该 media_id 自己的当前行（可能为 null）。
     * #416 裁决 3：新增一行、不搬迁旧行（见 [DiffApplier]）。
     */
    data class KnownContent(val snapshot: MediaSnapshot, val contentHash: String, val existing: List<Order>, val current: Order?) : DiffAction {
        override val mediaId get() = snapshot.mediaId
    }

    /** 同一个 media_id、内容没变（hash 相同，或只换了相册）：只更新版本/映射，不传。 */
    data class MappingOnly(val snapshot: MediaSnapshot, val order: Order) : DiffAction {
        override val mediaId get() = snapshot.mediaId
    }

    /** 版本变了，但用户对这张照片已有明确决定（[OrderState.isUserDecided]）：不算 hash、不产出待传。 */
    data class Suppressed(val snapshot: MediaSnapshot, val order: Order) : DiffAction {
        override val mediaId get() = snapshot.mediaId
    }

    /** 读不出内容（被删、无权限）：#416 裁决 9——按单张失败处理，计入次数。 */
    data class Unhashable(val snapshot: MediaSnapshot, val error: Exception, val current: Order?) : DiffAction {
        override val mediaId get() = snapshot.mediaId
    }

    /** #416 裁决 1：照片还在 MediaStore 里，但所在相册已不在范围内，而它的 order 还没有结局 → CANCELLED_BY_SCOPE。 */
    data class OutOfScope(val snapshot: MediaSnapshot, val order: Order) : DiffAction {
        override val mediaId get() = snapshot.mediaId
    }

    /**
     * 同一版本重新变为可传：
     * - SKIPPED_SOURCE_MISSING 的照片又出现在 MediaStore（从回收站恢复，#416 裁决 5）
     * - CANCELLED_BY_SCOPE 的照片所在相册重新纳入范围（#415 裁决 5）
     */
    data class Readmit(val snapshot: MediaSnapshot, val order: Order) : DiffAction {
        override val mediaId get() = snapshot.mediaId
    }

    /** 带 `source_missing` 标记的行，原图又出现了：清掉标记（#416 裁决 2 的反向）。 */
    data class Reappeared(val snapshot: MediaSnapshot, val order: Order) : DiffAction {
        override val mediaId get() = snapshot.mediaId
    }

    /** order 里有、MediaStore（全量）里确实没有，且还没被记过（不是 SKIPPED_SOURCE_MISSING、没打标记）。 */
    data class Gone(val order: Order) : DiffAction {
        override val mediaId get() = order.mediaId
    }

    enum class Reason { NEW, CHANGED }
}

/**
 * 差集规划器。
 *
 * 慢路径分**两遍**，调用方必须按顺序执行、并在两遍之间把第一遍的动作落库：
 * 1. [planPresent]：new / changed → 算 hash → Upload / KnownContent / MappingOnly / ...
 * 2. [planGone]：重新打开两条流，产出 Gone
 *
 * 为什么不一遍做完：MediaStore 重建后新 `_id` 通常都比旧的大，一遍归并会先走到旧 `_id`
 * 判 Gone，再走到新 `_id` 才发现 hash 相同。两遍之后，第二遍看到的已是第一遍新插入的行，
 * [DiffApplier.applyGone] 才能认出「这份内容换了个 `_id` 还在」、删掉旧行。
 *
 * 两条输入流都必须按 media_id **严格升序**（order 流每个 media_id 只给当前那一行，见
 * [OrderStore.readCurrentOrders]），否则抛 [IllegalStateException]——归并的正确性全靠排序一致。
 * 规划过程是惰性的：两边各只持有当前一行，不会把任何一边整个读进内存。
 *
 * [inScope]：这个相册现在在不在备份范围内。快照是全量的（#416 裁决 1），范围判断在这里做，
 * 并且**先于算 hash**——范围外的照片一次 hash 都不算（D-06）。
 */
class DiffPlanner(
    private val hasher: (MediaSnapshot) -> String,
    private val ordersWithHash: (String) -> List<Order>,
    private val inScope: (bucketId: Long) -> Boolean = { true },
) {
    /** 慢路径第一遍。 */
    fun planPresent(snapshots: Sequence<MediaSnapshot>, currentOrders: Sequence<Order>): Sequence<DiffAction> =
        merge(snapshots, currentOrders).mapNotNull { (snapshot, order) ->
            if (snapshot == null) null else classify(snapshot, order)
        }

    /** 慢路径第二遍：必须在第一遍的动作落库之后，用重新打开的流调用。 */
    fun planGone(snapshots: Sequence<MediaSnapshot>, currentOrders: Sequence<Order>): Sequence<DiffAction.Gone> =
        merge(snapshots, currentOrders).mapNotNull { (snapshot, order) ->
            if (snapshot == null && order != null && order.state != OrderState.SKIPPED_SOURCE_MISSING && !order.sourceMissing) {
                DiffAction.Gone(order)
            } else {
                null
            }
        }

    /**
     * 快路径：快照按 generation 排序而不是按 `_id`，所以不归并，逐张查当前行。
     * 快路径不产出 Gone（它看不到消失的照片），那是慢路径的事。
     */
    fun planFastPath(snapshots: Sequence<MediaSnapshot>, currentFor: (Long) -> Order?): Sequence<DiffAction> =
        snapshots.mapNotNull { classify(it, currentFor(it.mediaId)) }

    /** 单张分类；null = 没变化，什么都不用做。 */
    fun classify(snapshot: MediaSnapshot, current: Order?): DiffAction? {
        // 原图重新出现：先清标记。与范围无关——标记描述的是「原图在不在」。
        if (current != null && current.sourceMissing && current.sourceVersion == snapshot.sourceVersion) {
            return DiffAction.Reappeared(snapshot, current)
        }
        if (!inScope(snapshot.bucketId)) {
            // 范围外：只有还没结局的 order 需要收尾；其余（没有 order、已有结局）一概不看、不算 hash。
            if (current != null && current.state.isOpen) return DiffAction.OutOfScope(snapshot, current)
            // #418：已确认的照片被挪进了范围外的相册——只改映射里的 bucket_id，不算 hash。否则这一行永远
            // 带着旧相册号，英雄区的 m（按相册数的已确认数）会一直比 n（MediaStore 实时计数）多一张。
            if (current != null && current.state == OrderState.CONFIRMED &&
                current.sourceVersion == snapshot.sourceVersion && current.bucketId != snapshot.bucketId
            ) {
                return DiffAction.MappingOnly(snapshot, current)
            }
            return null
        }
        if (current != null && current.sourceVersion == snapshot.sourceVersion) {
            return when {
                current.state == OrderState.SKIPPED_SOURCE_MISSING || current.state == OrderState.CANCELLED_BY_SCOPE ->
                    DiffAction.Readmit(snapshot, current)
                current.bucketId != snapshot.bucketId -> DiffAction.MappingOnly(snapshot, current)
                else -> null
            }
        }
        if (current != null && current.state.isUserDecided) return DiffAction.Suppressed(snapshot, current)
        val hash = try {
            hasher(snapshot)
        } catch (e: Exception) {
            return DiffAction.Unhashable(snapshot, e, current)
        }
        if (current != null && current.contentHash == hash) return DiffAction.MappingOnly(snapshot, current)
        val existing = ordersWithHash(hash)
        if (existing.isNotEmpty()) return DiffAction.KnownContent(snapshot, hash, existing, current)
        return DiffAction.Upload(
            snapshot = snapshot,
            contentHash = hash,
            reason = if (current == null) DiffAction.Reason.NEW else DiffAction.Reason.CHANGED,
            previous = current,
        )
    }

    /** 按 media_id 归并：每一步给出 (快照?, 当前行?)，两边相等时配成一对。 */
    private fun merge(snapshots: Sequence<MediaSnapshot>, orders: Sequence<Order>): Sequence<Pair<MediaSnapshot?, Order?>> = sequence {
        val s = strictlyAscending(snapshots.iterator(), "MediaStore snapshot") { it.mediaId }
        val o = strictlyAscending(orders.iterator(), "current orders") { it.mediaId }
        var snap = s.nextOrNull()
        var order = o.nextOrNull()
        while (snap != null || order != null) {
            when {
                order == null || (snap != null && snap.mediaId < order.mediaId) -> {
                    yield(snap to null)
                    snap = s.nextOrNull()
                }
                snap == null || order.mediaId < snap.mediaId -> {
                    yield(null to order)
                    order = o.nextOrNull()
                }
                else -> {
                    yield(snap to order)
                    snap = s.nextOrNull()
                    order = o.nextOrNull()
                }
            }
        }
    }

    private class StrictIterator<T>(private val inner: Iterator<T>, private val label: String, private val key: (T) -> Long) {
        private var last: Long? = null

        fun nextOrNull(): T? {
            if (!inner.hasNext()) return null
            val item = inner.next()
            val k = key(item)
            val prev = last
            check(prev == null || k > prev) { "$label must be strictly ascending by media_id: $k after $prev" }
            last = k
            return item
        }
    }

    private fun <T> strictlyAscending(inner: Iterator<T>, label: String, key: (T) -> Long) = StrictIterator(inner, label, key)
}
