// ARCH-12 (#416): order 存储的 android.database.sqlite 实现。不引入 Room 等任何新依赖。
//
// 这个文件刻意写得「一眼能审完」：每个方法一条或几条手写 SQL，写操作全部包在
// beginTransaction / setTransactionSuccessful / endTransaction 里。它在 JVM 单测里跑不了
// （android.database.sqlite 需要真机），契约由 InMemoryOrderStore 在 JVM 上跑，
// 这份实现由 src/androidTest 下的 SqliteOrderStoreDeviceTest 在设备上跑。
package com.hawkeyexb.ppass.backup.order

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

class SqliteOrderStore private constructor(
    private val helper: SQLiteOpenHelper,
    private val clock: () -> Long,
) : OrderStore {

    companion object {
        const val DEFAULT_DB_NAME = "backup-orders.db"
        private const val SCHEMA_VERSION = 1
        private const val PAGE_SIZE = 256

        /** App 的正式库。[name] 为 null 时是纯内存库（设备测试用，不碰 App 数据）。 */
        fun open(context: Context?, name: String? = DEFAULT_DB_NAME, clock: () -> Long = System::currentTimeMillis): SqliteOrderStore =
            SqliteOrderStore(Helper(context, name), clock)

        private val ALL_STATES = OrderState.entries.joinToString(",") { "'${it.name}'" }

        private val SCHEMA = listOf(
            """
            CREATE TABLE orders (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                media_id        INTEGER NOT NULL,
                source_version  TEXT    NOT NULL,
                bucket_id       INTEGER NOT NULL,
                content_hash    TEXT,
                state           TEXT    NOT NULL CHECK (state IN ($ALL_STATES)),
                attempts        INTEGER NOT NULL DEFAULT 0,
                pairing_epoch   INTEGER NOT NULL,
                created_at_ms   INTEGER NOT NULL,
                updated_at_ms   INTEGER NOT NULL
            )
            """.trimIndent(),
            // (media_id, id)：既是 media_id 索引，也让「每个 media_id 取 id 最大的一行」走索引。
            "CREATE INDEX orders_media_id ON orders (media_id, id)",
            "CREATE INDEX orders_content_hash ON orders (content_hash)",
            """
            CREATE TABLE volume_state (
                volume_name          TEXT    PRIMARY KEY,
                fast_path_generation INTEGER NOT NULL,
                media_store_version  TEXT
            )
            """.trimIndent(),
        )

        private const val COLUMNS =
            "id, media_id, source_version, bucket_id, content_hash, state, attempts, pairing_epoch, created_at_ms, updated_at_ms"

        /** 每个 media_id 当前的那一行 = 该 media_id 下 id 最大的行。按 media_id 键集分页。 */
        private const val CURRENT_PAGE_SQL =
            "SELECT $COLUMNS FROM orders o WHERE o.media_id > ? " +
                "AND o.id = (SELECT MAX(id) FROM orders WHERE media_id = o.media_id) " +
                "ORDER BY o.media_id ASC LIMIT $PAGE_SIZE"
    }

    private class Helper(context: Context?, name: String?) : SQLiteOpenHelper(context, name, null, SCHEMA_VERSION) {
        override fun onCreate(db: SQLiteDatabase) {
            SCHEMA.forEach(db::execSQL)
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // 只有 v1。以后升级在这里写迁移；#413「迁移」段：目前没有正式用户，旧账本直接清空。
            error("no migration from $oldVersion to $newVersion")
        }
    }

    private val db: SQLiteDatabase get() = helper.writableDatabase

    fun close() = helper.close()

    private inline fun <T> inTransaction(block: SQLiteDatabase.() -> T): T {
        val d = db
        d.beginTransaction()
        try {
            val result = d.block()
            d.setTransactionSuccessful()
            return result
        } finally {
            d.endTransaction()
        }
    }

    private fun Cursor.toOrder(): Order = Order(
        id = getLong(0),
        mediaId = getLong(1),
        sourceVersion = getString(2),
        bucketId = getLong(3),
        contentHash = if (isNull(4)) null else getString(4),
        state = OrderState.valueOf(getString(5)),
        attempts = getInt(6),
        pairingEpoch = getLong(7),
        createdAtMs = getLong(8),
        updatedAtMs = getLong(9),
    )

    private fun queryOrders(sql: String, vararg args: String): List<Order> =
        db.rawQuery(sql, args).use { c ->
            val out = ArrayList<Order>(c.count)
            while (c.moveToNext()) out += c.toOrder()
            out
        }

    private fun SQLiteDatabase.insertRow(order: NewOrder, now: Long): Long {
        val values = ContentValues().apply {
            put("media_id", order.mediaId)
            put("source_version", order.sourceVersion)
            put("bucket_id", order.bucketId)
            put("content_hash", order.contentHash)
            put("state", order.state.name)
            put("attempts", 0)
            put("pairing_epoch", order.pairingEpoch)
            put("created_at_ms", now)
            put("updated_at_ms", now)
        }
        // insertOrThrow：失败抛异常，事务随之回滚（insert() 会吞掉错误返回 -1）。
        return insertOrThrow("orders", null, values)
    }

    override fun insert(order: NewOrder): Order {
        val id = inTransaction { insertRow(order, clock()) }
        return checkNotNull(get(id)) { "inserted order $id not readable" }
    }

    override fun get(id: Long): Order? =
        queryOrders("SELECT $COLUMNS FROM orders WHERE id = ?", id.toString()).firstOrNull()

    override fun currentForMedia(mediaId: Long): Order? =
        queryOrders("SELECT $COLUMNS FROM orders WHERE media_id = ? ORDER BY id DESC LIMIT 1", mediaId.toString()).firstOrNull()

    override fun ordersWithHash(hash: String): List<Order> =
        queryOrders("SELECT $COLUMNS FROM orders WHERE content_hash = ? ORDER BY id ASC", hash)

    override fun <R> readCurrentOrders(block: (Sequence<Order>) -> R): R {
        // 每页一次查询、查完即关游标，所以 Sequence 里不挂着打开的 Cursor；
        // block 里写库也安全：键集分页只往 media_id 更大的方向走，读过的不会再出现。
        val rows = sequence {
            var after = Long.MIN_VALUE
            while (true) {
                val page = queryOrders(CURRENT_PAGE_SQL, after.toString())
                yieldAll(page)
                if (page.size < PAGE_SIZE) break
                after = page.last().mediaId
            }
        }
        return block(rows)
    }

    override fun transition(id: Long, expected: Set<OrderState>, to: OrderState, countAttempt: Boolean): Boolean {
        if (expected.isEmpty()) return false
        val placeholders = expected.joinToString(",") { "?" }
        val attemptsSql = if (countAttempt) ", attempts = attempts + 1" else ""
        val sql = "UPDATE orders SET state = ?, updated_at_ms = ?$attemptsSql WHERE id = ? AND state IN ($placeholders)"
        return inTransaction {
            compileStatement(sql).use { st ->
                st.bindString(1, to.name)
                st.bindLong(2, clock())
                st.bindLong(3, id)
                expected.forEachIndexed { i, s -> st.bindString(4 + i, s.name) }
                st.executeUpdateDelete() == 1
            }
        }
    }

    override fun updateMapping(id: Long, mediaId: Long, sourceVersion: String, bucketId: Long): Boolean {
        require(sourceVersion.isNotBlank()) { "sourceVersion must not be blank" }
        return inTransaction {
            compileStatement(
                "UPDATE orders SET media_id = ?, source_version = ?, bucket_id = ?, updated_at_ms = ? WHERE id = ?",
            ).use { st ->
                st.bindLong(1, mediaId)
                st.bindString(2, sourceVersion)
                st.bindLong(3, bucketId)
                st.bindLong(4, clock())
                st.bindLong(5, id)
                st.executeUpdateDelete() == 1
            }
        }
    }

    override fun skipByUser(targets: List<SkipTarget>, pairingEpoch: Long): SkipResult = inTransaction {
        val now = clock()
        var inserted = 0
        var updated = 0
        var untouched = 0
        // 逐条执行预编译语句，不拼 IN (…)：API 26 的 SQLite 绑定变量上限是 999。
        compileStatement(
            "UPDATE orders SET state = '${OrderState.SKIPPED_BY_USER.name}', updated_at_ms = ? WHERE id = ?",
        ).use { skip ->
            for (target in targets) {
                require(target.mediaId > 0) { "mediaId must be positive, got ${target.mediaId}" }
                val current = rawQuery(
                    "SELECT id, state FROM orders WHERE media_id = ? ORDER BY id DESC LIMIT 1",
                    arrayOf(target.mediaId.toString()),
                ).use { c -> if (c.moveToFirst()) c.getLong(0) to OrderState.valueOf(c.getString(1)) else null }
                when {
                    current == null -> {
                        insertRow(
                            NewOrder(target.mediaId, target.sourceVersion, target.bucketId, target.contentHash, OrderState.SKIPPED_BY_USER, pairingEpoch),
                            now,
                        )
                        inserted++
                    }
                    current.second.isOpen -> {
                        skip.bindLong(1, now)
                        skip.bindLong(2, current.first)
                        skip.executeUpdateDelete()
                        updated++
                    }
                    else -> untouched++
                }
            }
        }
        SkipResult(inserted, updated, untouched)
    }

    override fun volumeState(volumeName: String): VolumeState? =
        db.rawQuery(
            "SELECT volume_name, fast_path_generation, media_store_version FROM volume_state WHERE volume_name = ?",
            arrayOf(volumeName),
        ).use { c ->
            if (c.moveToFirst()) VolumeState(c.getString(0), c.getLong(1), if (c.isNull(2)) null else c.getString(2)) else null
        }

    override fun saveVolumeState(state: VolumeState) {
        inTransaction {
            val values = ContentValues().apply {
                put("volume_name", state.volumeName)
                put("fast_path_generation", state.fastPathGeneration)
                put("media_store_version", state.mediaStoreVersion)
            }
            replaceOrThrow("volume_state", null, values)
        }
    }

    override fun volumeNames(): List<String> =
        db.rawQuery("SELECT volume_name FROM volume_state ORDER BY volume_name ASC", null).use { c ->
            val out = ArrayList<String>(c.count)
            while (c.moveToNext()) out += c.getString(0)
            out
        }
}
