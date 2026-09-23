// ARCH-12 (#416) / ARCH-13 (#417): order 存储的 android.database.sqlite 实现。不引入 Room 等任何新依赖。
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
import org.json.JSONObject

class SqliteOrderStore private constructor(
    private val helper: SQLiteOpenHelper,
    private val clock: () -> Long,
) : OrderStore {

    companion object {
        const val DEFAULT_DB_NAME = "backup-orders.db"

        /**
         * v2（#417）：加 QUEUED 状态、`source_missing` 列、审计 outbox 与 meta 表，
         * `pairing_epoch` 改成 TEXT。v1 只在 #416 的集成分支上存在过、从未接入生产，
         * 没有要保留的数据，所以升级 = 删表重建（#413「迁移」段）。
         */
        private const val SCHEMA_VERSION = 2
        private const val PAGE_SIZE = 256

        /** App 的正式库。[name] 为 null 时是纯内存库（设备测试用，不碰 App 数据）。 */
        fun open(context: Context?, name: String? = DEFAULT_DB_NAME, clock: () -> Long = System::currentTimeMillis): SqliteOrderStore =
            SqliteOrderStore(Helper(context, name), clock)

        private val ALL_STATES = OrderState.entries.joinToString(",") { "'${it.name}'" }

        private val TABLES = listOf("orders", "volume_state", "audit_outbox", "meta")

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
                pairing_epoch   TEXT    NOT NULL,
                created_at_ms   INTEGER NOT NULL,
                updated_at_ms   INTEGER NOT NULL,
                source_missing  INTEGER NOT NULL DEFAULT 0
            )
            """.trimIndent(),
            // (media_id, id)：既是 media_id 索引，也让「每个 media_id 取 id 最大的一行」走索引。
            "CREATE INDEX orders_media_id ON orders (media_id, id)",
            "CREATE INDEX orders_content_hash ON orders (content_hash)",
            "CREATE INDEX orders_state ON orders (state, id)",
            """
            CREATE TABLE volume_state (
                volume_name          TEXT    PRIMARY KEY,
                fast_path_generation INTEGER NOT NULL,
                media_store_version  TEXT
            )
            """.trimIndent(),
            """
            CREATE TABLE audit_outbox (
                seq            INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id       TEXT    NOT NULL UNIQUE,
                kind           TEXT    NOT NULL,
                round_id       TEXT,
                occurred_at_ms INTEGER NOT NULL,
                payload        TEXT    NOT NULL
            )
            """.trimIndent(),
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        )

        private const val COLUMNS =
            "id, media_id, source_version, bucket_id, content_hash, state, attempts, pairing_epoch, created_at_ms, updated_at_ms, source_missing"

        /** 「o 是它那个 media_id 的当前行」。 */
        private const val IS_CURRENT = "o.id = (SELECT MAX(id) FROM orders WHERE media_id = o.media_id)"

        /** 每个 media_id 当前的那一行 = 该 media_id 下 id 最大的行。按 media_id 键集分页。 */
        private const val CURRENT_PAGE_SQL =
            "SELECT $COLUMNS FROM orders o WHERE o.media_id > ? AND $IS_CURRENT ORDER BY o.media_id ASC LIMIT $PAGE_SIZE"

        private const val OWNER_KEY = "owner"
    }

    private class Helper(context: Context?, name: String?) : SQLiteOpenHelper(context, name, null, SCHEMA_VERSION) {
        override fun onCreate(db: SQLiteDatabase) {
            SCHEMA.forEach(db::execSQL)
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            TABLES.forEach { db.execSQL("DROP TABLE IF EXISTS $it") }
            onCreate(db)
        }

        override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = onUpgrade(db, oldVersion, newVersion)
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
        pairingEpoch = getString(7),
        createdAtMs = getLong(8),
        updatedAtMs = getLong(9),
        sourceMissing = getInt(10) != 0,
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
            put("source_missing", 0)
        }
        // insertOrThrow：失败抛异常，事务随之回滚（insert() 会吞掉错误返回 -1）。
        return insertOrThrow("orders", null, values)
    }

    private fun SQLiteDatabase.writeAdvance(advance: GenerationAdvance?) {
        advance ?: return
        // 不用 UPSERT（ON CONFLICT … DO UPDATE 要 SQLite 3.24，API 26 带的是 3.18）。
        val updated = compileStatement(
            "UPDATE volume_state SET fast_path_generation = MAX(fast_path_generation, ?) WHERE volume_name = ?",
        ).use { st ->
            st.bindLong(1, advance.generation)
            st.bindString(2, advance.volumeName)
            st.executeUpdateDelete()
        }
        if (updated == 0) {
            execSQL(
                "INSERT INTO volume_state (volume_name, fast_path_generation, media_store_version) VALUES (?, ?, NULL)",
                arrayOf<Any>(advance.volumeName, advance.generation),
            )
        }
    }

    private fun SQLiteDatabase.writeAudit(audit: AuditRecord?) {
        audit ?: return
        val values = ContentValues().apply {
            put("event_id", audit.eventId)
            put("kind", audit.kind)
            put("round_id", audit.roundId)
            put("occurred_at_ms", audit.occurredAtMs)
            put("payload", JSONObject(audit.payload).toString())
        }
        insertOrThrow("audit_outbox", null, values)
    }

    override fun insert(order: NewOrder, advance: GenerationAdvance?, audit: AuditRecord?): Order {
        val id = inTransaction {
            val id = insertRow(order, clock())
            writeAdvance(advance)
            writeAudit(audit)
            id
        }
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

    override fun currentInStates(states: Set<OrderState>, limit: Int): List<Order> {
        if (states.isEmpty()) return emptyList()
        val list = states.joinToString(",") { "'${it.name}'" }
        return queryOrders("SELECT $COLUMNS FROM orders o WHERE o.state IN ($list) AND $IS_CURRENT ORDER BY o.id ASC LIMIT $limit")
    }

    override fun confirmedWithHashAfter(afterId: Long, limit: Int): List<Order> =
        queryOrders(
            "SELECT $COLUMNS FROM orders o WHERE o.state = '${OrderState.CONFIRMED.name}' AND o.content_hash IS NOT NULL " +
                "AND o.id > ? AND $IS_CURRENT ORDER BY o.id ASC LIMIT $limit",
            afterId.toString(),
        )

    override fun transition(
        id: Long,
        expected: Set<OrderState>,
        to: OrderState,
        countAttempt: Boolean,
        advance: GenerationAdvance?,
        audit: AuditRecord?,
    ): Boolean {
        if (expected.isEmpty()) return false
        val placeholders = expected.joinToString(",") { "?" }
        val attemptsSql = if (countAttempt) ", attempts = attempts + 1" else ""
        val sql = "UPDATE orders SET state = ?, updated_at_ms = ?$attemptsSql WHERE id = ? AND state IN ($placeholders)"
        return inTransaction {
            val changed = compileStatement(sql).use { st ->
                st.bindString(1, to.name)
                st.bindLong(2, clock())
                st.bindLong(3, id)
                expected.forEachIndexed { i, s -> st.bindString(4 + i, s.name) }
                st.executeUpdateDelete() == 1
            }
            if (changed) {
                writeAdvance(advance)
                writeAudit(audit)
            }
            changed
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

    override fun setContentHash(id: Long, hash: String): Boolean {
        require(hash.isNotBlank()) { "hash must not be blank" }
        return inTransaction {
            compileStatement("UPDATE orders SET content_hash = ?, updated_at_ms = ? WHERE id = ? AND content_hash IS NULL").use { st ->
                st.bindString(1, hash)
                st.bindLong(2, clock())
                st.bindLong(3, id)
                st.executeUpdateDelete() == 1
            }
        }
    }

    override fun setSourceMissing(id: Long, missing: Boolean, audit: AuditRecord?): Boolean = inTransaction {
        val changed = compileStatement("UPDATE orders SET source_missing = ?, updated_at_ms = ? WHERE id = ?").use { st ->
            st.bindLong(1, if (missing) 1 else 0)
            st.bindLong(2, clock())
            st.bindLong(3, id)
            st.executeUpdateDelete() == 1
        }
        if (changed) writeAudit(audit)
        changed
    }

    override fun delete(id: Long): Boolean = inTransaction {
        delete("orders", "id = ?", arrayOf(id.toString())) == 1
    }

    override fun skipByUser(targets: List<SkipTarget>, pairingEpoch: String, audit: AuditRecord?): SkipResult = inTransaction {
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
        writeAudit(audit)
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

    override fun advanceGeneration(advance: GenerationAdvance) {
        inTransaction { writeAdvance(advance) }
    }

    override fun volumeNames(): List<String> =
        db.rawQuery("SELECT volume_name FROM volume_state ORDER BY volume_name ASC", null).use { c ->
            val out = ArrayList<String>(c.count)
            while (c.moveToNext()) out += c.getString(0)
            out
        }

    override fun countCurrentByState(bucketIds: Set<Long>?): Map<OrderState, Long> {
        if (bucketIds != null && bucketIds.isEmpty()) return emptyMap()
        val bucketFilter = bucketIds?.let { " AND o.bucket_id IN (${it.joinToString(",")})" }.orEmpty()
        return db.rawQuery("SELECT o.state, COUNT(*) FROM orders o WHERE $IS_CURRENT$bucketFilter GROUP BY o.state", null).use { c ->
            val out = LinkedHashMap<OrderState, Long>()
            while (c.moveToNext()) out[OrderState.valueOf(c.getString(0))] = c.getLong(1)
            out
        }
    }

    override fun lastConfirmedAtMs(): Long =
        db.rawQuery("SELECT MAX(o.updated_at_ms) FROM orders o WHERE o.state = '${OrderState.CONFIRMED.name}' AND $IS_CURRENT", null).use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else 0L
        }

    override fun countSourceMissingSkipped(afterMs: Long, upToMs: Long): Long =
        db.rawQuery(
            "SELECT COUNT(*) FROM orders o WHERE o.state = '${OrderState.SKIPPED_SOURCE_MISSING.name}' " +
                "AND o.updated_at_ms > ? AND o.updated_at_ms <= ? AND $IS_CURRENT",
            arrayOf(afterMs.toString(), upToMs.toString()),
        ).use { c -> if (c.moveToFirst()) c.getLong(0) else 0L }

    override fun appendAudit(audit: AuditRecord) {
        inTransaction { writeAudit(audit) }
    }

    override fun pendingAudit(limit: Int): List<AuditRecord> =
        db.rawQuery("SELECT event_id, kind, round_id, occurred_at_ms, payload FROM audit_outbox ORDER BY seq ASC LIMIT $limit", null).use { c ->
            val out = ArrayList<AuditRecord>(c.count)
            while (c.moveToNext()) {
                val json = JSONObject(c.getString(4))
                val payload = json.keys().asSequence().associateWith { json.getString(it) }
                out += AuditRecord(c.getString(0), c.getString(1), if (c.isNull(2)) null else c.getString(2), c.getLong(3), payload)
            }
            out
        }

    override fun acknowledgeAudit(eventIds: Set<String>) {
        if (eventIds.isEmpty()) return
        inTransaction {
            compileStatement("DELETE FROM audit_outbox WHERE event_id = ?").use { st ->
                for (id in eventIds) {
                    st.bindString(1, id)
                    st.executeUpdateDelete()
                }
            }
        }
    }

    override fun claimOwner(ownerKey: String, idFloor: Long): Boolean = inTransaction {
        val previous = rawQuery("SELECT value FROM meta WHERE key = ?", arrayOf(OWNER_KEY)).use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
        if (previous == ownerKey) return@inTransaction false
        val cleared = previous != null
        if (cleared) {
            execSQL("DELETE FROM orders")
            execSQL("DELETE FROM volume_state")
            execSQL("DELETE FROM audit_outbox")
        }
        // sqlite_sequence 由 AUTOINCREMENT 表自动建出；手写一行把起点抬上去。
        execSQL("DELETE FROM sqlite_sequence WHERE name = 'orders'")
        val maxId = rawQuery("SELECT IFNULL(MAX(id), 0) FROM orders", null).use { c -> c.moveToFirst(); c.getLong(0) }
        execSQL("INSERT INTO sqlite_sequence (name, seq) VALUES ('orders', ?)", arrayOf(maxOf(idFloor, maxId)))
        execSQL("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arrayOf(OWNER_KEY, ownerKey))
        cleared
    }
}
