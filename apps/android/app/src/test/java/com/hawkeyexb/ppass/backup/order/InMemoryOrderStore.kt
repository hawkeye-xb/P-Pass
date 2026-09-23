// ARCH-12 (#416): 测试用 order 存储。与 SqliteOrderStore 共用 OrderStoreContract。
//
// 事务语义靠「拷贝一份、全部成功才替换」实现：写到一半抛异常时原表一行不变，
// 这样「批量跳过是单事务」的契约测试才能真的红（原地改的实现测不出回滚）。
package com.hawkeyexb.ppass.backup.order

class InMemoryOrderStore(private val clock: () -> Long = System::currentTimeMillis) : OrderStore {
    private var rows: Map<Long, Order> = emptyMap()
    private var lastId = 0L
    private var volumes: Map<String, VolumeState> = emptyMap()

    private class Tx(var rows: MutableMap<Long, Order>, var lastId: Long)

    @Synchronized
    private fun <T> inTransaction(block: Tx.() -> T): T {
        val tx = Tx(LinkedHashMap(rows), lastId)
        val result = tx.block()
        rows = tx.rows
        lastId = tx.lastId
        return result
    }

    private fun Tx.insertRow(order: NewOrder, now: Long): Order {
        lastId += 1
        val row = Order(lastId, order.mediaId, order.sourceVersion, order.bucketId, order.contentHash, order.state, 0, order.pairingEpoch, now, now)
        rows[row.id] = row
        return row
    }

    private fun currentIn(snapshot: Map<Long, Order>, mediaId: Long): Order? =
        snapshot.values.filter { it.mediaId == mediaId }.maxByOrNull { it.id }

    override fun insert(order: NewOrder): Order = inTransaction { insertRow(order, clock()) }

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

    override fun transition(id: Long, expected: Set<OrderState>, to: OrderState, countAttempt: Boolean): Boolean = inTransaction {
        val row = rows[id]
        if (row == null || row.state !in expected) {
            false
        } else {
            rows[id] = row.copy(state = to, attempts = row.attempts + if (countAttempt) 1 else 0, updatedAtMs = clock())
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

    override fun skipByUser(targets: List<SkipTarget>, pairingEpoch: Long): SkipResult = inTransaction {
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
        SkipResult(inserted, updated, untouched)
    }

    @Synchronized
    override fun volumeState(volumeName: String): VolumeState? = volumes[volumeName]

    @Synchronized
    override fun saveVolumeState(state: VolumeState) {
        volumes = volumes + (state.volumeName to state)
    }

    @Synchronized
    override fun volumeNames(): List<String> = volumes.keys.sorted()
}
