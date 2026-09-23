// ARCH-12 (#416) / ARCH-13 (#417): 测试用 order 存储。与 SqliteOrderStore 共用 OrderStoreContract。
//
// 事务语义靠「拷贝一份、全部成功才替换」实现：写到一半抛异常时原表一行不变，
// 这样「批量跳过是单事务」的契约测试才能真的红（原地改的实现测不出回滚）。
package com.hawkeyexb.ppass.backup.order

class InMemoryOrderStore(private val clock: () -> Long = System::currentTimeMillis) : OrderStore {
    private var rows: Map<Long, Order> = emptyMap()
    private var lastId = 0L
    private var volumes: Map<String, VolumeState> = emptyMap()
    private var audits: List<AuditRecord> = emptyList()
    private var owner: String? = null

    /** 故障注入：非 null 时，下一次事务在提交前抛出它（测试「崩在写入中途」）。 */
    @Volatile
    var failNextCommit: RuntimeException? = null

    private class Tx(
        var rows: MutableMap<Long, Order>,
        var lastId: Long,
        var volumes: MutableMap<String, VolumeState>,
        var audits: MutableList<AuditRecord>,
    )

    @Synchronized
    private fun <T> inTransaction(block: Tx.() -> T): T {
        val tx = Tx(LinkedHashMap(rows), lastId, LinkedHashMap(volumes), audits.toMutableList())
        val result = tx.block()
        failNextCommit?.let {
            failNextCommit = null
            throw it
        }
        rows = tx.rows
        lastId = tx.lastId
        volumes = tx.volumes
        audits = tx.audits
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
        volumes[advance.volumeName] = VolumeState(
            advance.volumeName,
            maxOf(prev?.fastPathGeneration ?: Long.MIN_VALUE, advance.generation),
            prev?.mediaStoreVersion,
        )
    }

    private fun Tx.audit(audit: AuditRecord?) {
        if (audit != null) audits += audit
    }

    private fun currentIn(snapshot: Map<Long, Order>, mediaId: Long): Order? =
        snapshot.values.filter { it.mediaId == mediaId }.maxByOrNull { it.id }

    private fun isCurrent(o: Order): Boolean = currentIn(rows, o.mediaId)?.id == o.id

    override fun insert(order: NewOrder, advance: GenerationAdvance?, audit: AuditRecord?): Order = inTransaction {
        val row = insertRow(order, clock())
        advance(advance)
        audit(audit)
        row
    }

    @Synchronized
    override fun get(id: Long): Order? = rows[id]

    @Synchronized
    override fun currentForMedia(mediaId: Long): Order? = currentIn(rows, mediaId)

    @Synchronized
    override fun ordersWithHash(hash: String): List<Order> =
        rows.values.filter { it.contentHash == hash }.sortedBy { it.id }

    override fun <R> readCurrentOrders(block: (Sequence<Order>) -> R): R {
        // 与 SQLite 实现同样的键集语义：每一步取「media_id 比上一个大」的最小 media_id 的当前行。
        val seq = sequence {
            var after = Long.MIN_VALUE
            while (true) {
                val next = synchronized(this@InMemoryOrderStore) {
                    val mediaId = rows.values.map { it.mediaId }.filter { it > after }.minOrNull()
                    mediaId?.let { currentIn(rows, it) }
                } ?: break
                yield(next)
                after = next.mediaId
            }
        }
        return block(seq)
    }

    @Synchronized
    override fun currentInStates(states: Set<OrderState>, limit: Int): List<Order> =
        rows.values.filter { it.state in states && isCurrent(it) }.sortedBy { it.id }.take(limit)

    @Synchronized
    override fun confirmedWithHashAfter(afterId: Long, limit: Int): List<Order> =
        rows.values.filter { it.state == OrderState.CONFIRMED && it.contentHash != null && it.id > afterId && isCurrent(it) }
            .sortedBy { it.id }.take(limit)

    override fun transition(
        id: Long,
        expected: Set<OrderState>,
        to: OrderState,
        countAttempt: Boolean,
        advance: GenerationAdvance?,
        audit: AuditRecord?,
    ): Boolean = inTransaction {
        val row = rows[id]
        if (row == null || row.state !in expected) {
            false
        } else {
            rows[id] = row.copy(state = to, attempts = row.attempts + if (countAttempt) 1 else 0, updatedAtMs = clock())
            advance(advance)
            audit(audit)
            true
        }
    }

    override fun updateMapping(id: Long, mediaId: Long, sourceVersion: String, bucketId: Long): Boolean {
        require(sourceVersion.isNotBlank()) { "sourceVersion must not be blank" }
        return inTransaction {
            val row = rows[id]
            if (row == null) {
                false
            } else {
                rows[id] = row.copy(mediaId = mediaId, sourceVersion = sourceVersion, bucketId = bucketId, updatedAtMs = clock())
                true
            }
        }
    }

    override fun setContentHash(id: Long, hash: String): Boolean {
        require(hash.isNotBlank()) { "hash must not be blank" }
        return inTransaction {
            val row = rows[id]
            if (row == null || row.contentHash != null) {
                false
            } else {
                rows[id] = row.copy(contentHash = hash, updatedAtMs = clock())
                true
            }
        }
    }

    override fun setSourceMissing(id: Long, missing: Boolean, audit: AuditRecord?): Boolean = inTransaction {
        val row = rows[id]
        if (row == null) {
            false
        } else {
            rows[id] = row.copy(sourceMissing = missing, updatedAtMs = clock())
            audit(audit)
            true
        }
    }

    override fun delete(id: Long): Boolean = inTransaction { rows.remove(id) != null }

    override fun skipByUser(targets: List<SkipTarget>, pairingEpoch: String, audit: AuditRecord?): SkipResult = inTransaction {
        val now = clock()
        var inserted = 0
        var updated = 0
        var untouched = 0
        for (target in targets) {
            require(target.mediaId > 0) { "mediaId must be positive, got ${target.mediaId}" }
            val current = currentIn(rows, target.mediaId)
            when {
                current == null -> {
                    insertRow(NewOrder(target.mediaId, target.sourceVersion, target.bucketId, target.contentHash, OrderState.SKIPPED_BY_USER, pairingEpoch), now)
                    inserted++
                }
                current.state.isOpen -> {
                    rows[current.id] = current.copy(state = OrderState.SKIPPED_BY_USER, updatedAtMs = now)
                    updated++
                }
                else -> untouched++
            }
        }
        audit(audit)
        SkipResult(inserted, updated, untouched)
    }

    @Synchronized
    override fun volumeState(volumeName: String): VolumeState? = volumes[volumeName]

    override fun saveVolumeState(state: VolumeState) {
        inTransaction { volumes[state.volumeName] = state }
    }

    override fun advanceGeneration(advance: GenerationAdvance) {
        inTransaction { advance(advance) }
    }

    @Synchronized
    override fun volumeNames(): List<String> = volumes.keys.sorted()

    @Synchronized
    override fun countCurrentByState(bucketIds: Set<Long>?): Map<OrderState, Long> =
        rows.values.filter { isCurrent(it) && (bucketIds == null || it.bucketId in bucketIds) }
            .groupingBy { it.state }.eachCount().mapValues { it.value.toLong() }

    @Synchronized
    override fun lastConfirmedAtMs(): Long =
        rows.values.filter { it.state == OrderState.CONFIRMED && isCurrent(it) }.maxOfOrNull { it.updatedAtMs } ?: 0L

    @Synchronized
    override fun countSourceMissingSkipped(afterMs: Long, upToMs: Long): Long =
        rows.values.count {
            it.state == OrderState.SKIPPED_SOURCE_MISSING && it.updatedAtMs > afterMs && it.updatedAtMs <= upToMs && isCurrent(it)
        }.toLong()

    override fun appendAudit(audit: AuditRecord) {
        inTransaction { audit(audit) }
    }

    @Synchronized
    override fun pendingAudit(limit: Int): List<AuditRecord> = audits.take(limit)

    override fun acknowledgeAudit(eventIds: Set<String>) {
        inTransaction { audits.removeAll { it.eventId in eventIds } }
    }

    override fun claimOwner(ownerKey: String, idFloor: Long): Boolean {
        val cleared = inTransaction {
            if (owner == ownerKey) return@inTransaction null
            val cleared = owner != null
            if (cleared) {
                rows.clear()
                volumes.clear()
                audits.clear()
            }
            lastId = maxOf(lastId, idFloor, rows.keys.maxOrNull() ?: 0L)
            cleared
        } ?: return false
        synchronized(this) { owner = ownerKey }
        return cleared
    }

    /** 测试直读：所有行（含非当前行）。 */
    @Synchronized
    fun allRows(): List<Order> = rows.values.sortedBy { it.id }

    @Synchronized
    fun audits(): List<AuditRecord> = audits
}
