// ARCH-12 (#416) / ARCH-13 (#417) → #413: 测试用 order 存储 + 跳过名单。与 SqliteOrderStore 共用 OrderStoreContract。
//
// 事务语义靠「拷贝一份、全部成功才替换」实现：写到一半抛异常时原表一行不变，
// 这样「取消剩余是单事务」的契约测试才能真的红（原地改的实现测不出回滚）。
package com.hawkeyexb.ppass.backup.order

class InMemoryOrderStore(private val clock: () -> Long = System::currentTimeMillis) : OrderStore {
    private var state = State()

    private data class Skip(val bucketId: Long, val sourceVersion: String)

    private data class State(
        val rows: Map<Long, Order> = emptyMap(),
        val lastId: Long = 0L,
        val volumes: Map<String, VolumeState> = emptyMap(),
        val scan: ScanState = ScanState(dirty = false, cursor = 0L),
        val skips: Map<Long, Skip> = emptyMap(),
        val audits: List<AuditRecord> = emptyList(),
        val owner: String? = null,
    )

    /** 故障注入：非 null 时，下一次事务在提交前抛出它（测试「崩在写入中途」）。 */
    @Volatile
    var failNextCommit: RuntimeException? = null

    /**
     * 故障注入（O-07）：下一次**推进了 G** 的事务在提交前崩溃。原子实现里 G 与 CONFIRMED 同一事务，
     * 所以两者一起不在；把 G 拆成单独一次写入的实现会留下「CONFIRMED 但 G 没推进」。
     */
    @Volatile
    var crashWhenGenerationMoves = false

    private class Tx(s: State) {
        val rows = LinkedHashMap(s.rows)
        var lastId = s.lastId
        val volumes = LinkedHashMap(s.volumes)
        var scan = s.scan
        val skips = java.util.TreeMap(s.skips)
        val audits = s.audits.toMutableList()
        var owner = s.owner

        fun freeze() = State(rows, lastId, volumes, scan, skips, audits, owner)
    }

    @Synchronized
    private fun <T> inTransaction(block: Tx.() -> T): T {
        val tx = Tx(state)
        val result = tx.block()
        failNextCommit?.let {
            failNextCommit = null
            throw it
        }
        if (crashWhenGenerationMoves && tx.volumes != state.volumes) {
            crashWhenGenerationMoves = false
            throw IllegalStateException("crash while committing a G advance")
        }
        state = tx.freeze()
        return result
    }

    private fun Tx.insertRow(order: NewOrder, now: Long): Order {
        lastId += 1
        val row = Order(lastId, order.mediaId, order.sourceVersion, order.bucketId, order.contentHash, order.state, 0, order.pairingEpoch, now, now)
        rows[row.id] = row
        return row
    }

    private fun Tx.advance(advance: GenerationAdvance?) {
        advance ?: return
        val prev = volumes[advance.volumeName]
        val later = prev == null || advance.generation > prev.generation ||
            (advance.generation == prev.generation && advance.mediaId > prev.generationMediaId)
        if (later) volumes[advance.volumeName] = VolumeState(advance.volumeName, advance.generation, advance.mediaId, prev?.mediaStoreVersion)
    }

    private fun Tx.scanTo(cursor: Long?) {
        cursor ?: return
        scan = scan.copy(cursor = maxOf(scan.cursor, cursor))
    }

    private fun Tx.current(mediaId: Long): Order? = rows.values.filter { it.mediaId == mediaId }.maxByOrNull { it.id }

    private fun currentRows(): List<Order> = state.rows.values.groupBy { it.mediaId }.map { (_, v) -> v.maxBy { it.id } }

    override fun insert(order: NewOrder, advance: GenerationAdvance?, scanTo: Long?, audit: AuditRecord?): Order = inTransaction {
        val row = insertRow(order, clock())
        advance(advance)
        scanTo(scanTo)
        audit?.let { audits += it }
        row
    }

    override fun get(id: Long): Order? = state.rows[id]

    override fun currentForMedia(mediaId: Long): Order? = state.rows.values.filter { it.mediaId == mediaId }.maxByOrNull { it.id }

    override fun <R> readCurrentOrders(block: (Sequence<Order>) -> R): R = block(currentRows().sortedBy { it.mediaId }.asSequence())

    override fun currentInStates(states: Set<OrderState>, afterId: Long, limit: Int): List<Order> =
        currentRows().filter { it.state in states && it.id > afterId }.sortedBy { it.id }.take(limit)

    override fun confirmedWithHashAfter(afterId: Long, limit: Int): List<Order> =
        currentRows().filter { it.state == OrderState.CONFIRMED && it.contentHash != null && it.id > afterId }.sortedBy { it.id }.take(limit)

    override fun transition(
        id: Long,
        expected: Set<OrderState>,
        to: OrderState,
        countAttempt: Boolean,
        contentHash: String?,
        advance: GenerationAdvance?,
        scanTo: Long?,
        audit: AuditRecord?,
    ): Boolean = inTransaction {
        val row = rows[id] ?: return@inTransaction false
        if (row.state !in expected) return@inTransaction false
        rows[id] = row.copy(
            state = to,
            attempts = if (countAttempt) row.attempts + 1 else row.attempts,
            contentHash = row.contentHash ?: contentHash,
            updatedAtMs = clock(),
        )
        advance(advance)
        scanTo(scanTo)
        audit?.let { audits += it }
        true
    }

    override fun setSourceMissing(id: Long, missing: Boolean, audit: AuditRecord?): Boolean = inTransaction {
        val row = rows[id] ?: return@inTransaction false
        rows[id] = row.copy(sourceMissing = missing, updatedAtMs = clock())
        audit?.let { audits += it }
        true
    }

    override fun isSkipped(mediaId: Long): Boolean = mediaId in state.skips

    override fun <R> readSkipList(block: (Sequence<Long>) -> R): R = block(state.skips.keys.sorted().asSequence())

    override fun countSkipped(bucketIds: Set<Long>?): Long =
        state.skips.values.count { bucketIds == null || it.bucketId in bucketIds }.toLong()

    override fun cancelRemaining(targets: List<SkipTarget>, audit: AuditRecord?): SkipResult = inTransaction {
        val now = clock()
        var written = 0
        var ordersSkipped = 0
        var untouched = 0
        for (target in targets) {
            require(target.mediaId > 0) { "mediaId must be positive, got ${target.mediaId}" }
            val current = current(target.mediaId)
            if (current != null && current.state.isSettled && current.sourceVersion == target.sourceVersion) {
                untouched++
                continue
            }
            if (target.mediaId !in skips) {
                skips[target.mediaId] = Skip(target.bucketId, target.sourceVersion)
                written++
            }
            if (current != null && current.state.isOpen) {
                rows[current.id] = current.copy(state = OrderState.SKIPPED_BY_USER, updatedAtMs = now)
                ordersSkipped++
            }
        }
        audit?.let { audits += it }
        SkipResult(written, ordersSkipped, untouched)
    }

    override fun restoreSkipped(audit: AuditRecord?): Int = inTransaction {
        val n = skips.size
        skips.clear()
        scan = ScanState(dirty = true, cursor = 0L)
        audit?.let { audits += it }
        n
    }

    override fun volumeState(volumeName: String): VolumeState? = state.volumes[volumeName]

    override fun saveVolumeState(state: VolumeState) = inTransaction { volumes[state.volumeName] = state }

    override fun advanceGeneration(advance: GenerationAdvance) = inTransaction { advance(advance) }

    override fun scanState(): ScanState = state.scan

    override fun markScanDirty() = inTransaction { scan = ScanState(dirty = true, cursor = 0L) }

    override fun advanceScan(cursor: Long) = inTransaction { scanTo(cursor) }

    override fun finishScan() = inTransaction { scan = ScanState(dirty = false, cursor = 0L) }

    override fun retryFailed(audit: AuditRecord?): Int = inTransaction {
        val failed = rows.values.groupBy { it.mediaId }.map { (_, v) -> v.maxBy { it.id } }.filter { it.state == OrderState.FAILED }
        failed.forEach { rows[it.id] = it.copy(state = OrderState.PENDING, updatedAtMs = clock()) }
        audit?.let { audits += it }
        failed.size
    }

    override fun countCurrentByState(bucketIds: Set<Long>?): Map<OrderState, Long> {
        val out = currentRows()
            .filter { bucketIds == null || it.bucketId in bucketIds }
            .filter { it.state != OrderState.SKIPPED_BY_USER }
            .groupingBy { it.state }.eachCount().mapValues { it.value.toLong() }
            .toMutableMap()
        val skipped = countSkipped(bucketIds)
        if (skipped > 0) out[OrderState.SKIPPED_BY_USER] = skipped
        return out
    }

    override fun countConfirmedPresent(bucketIds: Set<Long>?): Long =
        currentRows().count { it.state == OrderState.CONFIRMED && !it.sourceMissing && (bucketIds == null || it.bucketId in bucketIds) }.toLong()

    override fun lastConfirmedAtMs(): Long = currentRows().filter { it.state == OrderState.CONFIRMED }.maxOfOrNull { it.updatedAtMs } ?: 0L

    override fun countSourceMissingSkipped(afterMs: Long, upToMs: Long): Long =
        currentRows().count { it.state == OrderState.SKIPPED_SOURCE_MISSING && it.updatedAtMs > afterMs && it.updatedAtMs <= upToMs }.toLong()

    override fun appendAudit(audit: AuditRecord) = inTransaction { audits += audit }

    override fun pendingAudit(limit: Int): List<AuditRecord> = state.audits.take(limit)

    override fun acknowledgeAudit(eventIds: Set<String>) {
        inTransaction { audits.removeAll { it.eventId in eventIds } }
    }

    override fun claimOwner(ownerKey: String, idFloor: Long): Boolean = inTransaction {
        if (owner == ownerKey) return@inTransaction false
        val cleared = owner != null
        if (cleared) {
            rows.clear()
            volumes.clear()
            audits.clear()
            scan = ScanState(dirty = true, cursor = 0L)
        }
        lastId = maxOf(idFloor, rows.keys.maxOrNull() ?: 0L)
        owner = ownerKey
        cleared
    }
}
