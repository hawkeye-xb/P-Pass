package com.hawkeyexb.ppass.backup.picked

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * #1272 挑几张传：用户在系统照片选择器里挑的照片的订单。
 *
 * 和自动备份的 order 表**结构上隔离**（单独的库文件）：对账（#459）、首页待办计数、范围、跳过名单都碰不到它。
 * 手选的照片永远不写进备份范围；这里只存「现在要送过去的这几张」，送完即结束。
 * 只存 URI 和元数据，不复制原图——轮到时才读（一次挑上百张，先复制会占满手机空间）。
 */
enum class PickedState(val wire: String) {
    PENDING("pending"),
    TRANSFERRING("transferring"),
    DELIVERED("delivered"),

    /** 电脑上已有同内容（按内容哈希去重），没有再传字节。 */
    ALREADY_THERE("already_there"),

    /** 没传成：原图读不到 / 被删 / 桌面拒收。结果句里写明，让用户重新挑。 */
    FAILED("failed"),
    ;

    val open: Boolean get() = this == PENDING || this == TRANSFERRING

    companion object {
        fun of(wire: String): PickedState = entries.firstOrNull { it.wire == wire } ?: FAILED
    }
}

data class NewPicked(
    val uri: String,
    val fileName: String,
    val mimeType: String,
    val sizeBytes: Long,
    val captureAtMs: Long,
)

data class PickedItem(
    val id: Long,
    val batchId: Long,
    val uri: String,
    val fileName: String,
    val mimeType: String,
    val sizeBytes: Long,
    val captureAtMs: Long,
    val state: PickedState,
) {
    /** 线上的 queue_sequence。与自动备份 order 的行 id 分在两段，桌面按 (pairing, queue_sequence) 记交付，不许撞。 */
    val queueSequence: Long get() = SEQUENCE_BASE + id

    companion object {
        const val SEQUENCE_BASE: Long = 1L shl 40
    }
}

/** 最近一批的统计，大卡片的进度和结果句由它算。 */
data class PickedBatchSummary(
    val batchId: Long,
    val total: Int,
    val open: Int,
    val delivered: Int,
    val alreadyThere: Int,
    val failed: Int,
) {
    val settled: Int get() = total - open
}

interface PickedStore {
    /** 一次挑选 = 一批。返回批号；空列表不建批（返回 0）。 */
    fun addBatch(items: List<NewPicked>): Long

    /** 下一张要传的：先续上传输中的（进程被杀后），再按挑选顺序取待传的。没有 = null。 */
    fun nextOpen(): PickedItem?

    fun hasOpen(): Boolean

    fun mark(id: Long, state: PickedState)

    /** 最近一批；从没挑过 = null。 */
    fun latestBatch(): PickedBatchSummary?

    /** 用户看过结果后清掉已结束的行（保留未结束的）。 */
    fun clearSettled()

    /** 断开配对：全部清空，返回被清掉的 URI（调用方释放授权）。挑给旧电脑的不许传给下一台。 */
    fun clearAll(): List<String>
}

class SqlitePickedStore private constructor(private val helper: Helper) : PickedStore {

    private class Helper(context: Context, name: String?) : SQLiteOpenHelper(context, name, null, VERSION) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                "CREATE TABLE picked (id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id INTEGER NOT NULL, uri TEXT NOT NULL," +
                    " file_name TEXT NOT NULL, mime_type TEXT NOT NULL, size_bytes INTEGER NOT NULL," +
                    " capture_at_ms INTEGER NOT NULL, state TEXT NOT NULL)",
            )
            db.execSQL("CREATE INDEX picked_state ON picked(state, id)")
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }

    private val db: SQLiteDatabase get() = helper.writableDatabase

    @Synchronized
    override fun addBatch(items: List<NewPicked>): Long {
        if (items.isEmpty()) return 0L
        return db.inTransaction {
            val batch = (rawQuery("SELECT COALESCE(MAX(batch_id), 0) + 1 FROM picked", null).use { c -> c.moveToFirst(); c.getLong(0) })
            for (item in items) {
                insertOrThrow(
                    "picked",
                    null,
                    ContentValues().apply {
                        put("batch_id", batch)
                        put("uri", item.uri)
                        put("file_name", item.fileName)
                        put("mime_type", item.mimeType)
                        put("size_bytes", item.sizeBytes)
                        put("capture_at_ms", item.captureAtMs)
                        put("state", PickedState.PENDING.wire)
                    },
                )
            }
            batch
        }
    }

    @Synchronized
    override fun nextOpen(): PickedItem? =
        db.rawQuery(
            "SELECT id, batch_id, uri, file_name, mime_type, size_bytes, capture_at_ms, state FROM picked" +
                " WHERE state IN ('transferring','pending') ORDER BY (state = 'transferring') DESC, id LIMIT 1",
            null,
        ).use { c ->
            if (!c.moveToFirst()) {
                null
            } else {
                PickedItem(c.getLong(0), c.getLong(1), c.getString(2), c.getString(3), c.getString(4), c.getLong(5), c.getLong(6), PickedState.of(c.getString(7)))
            }
        }

    @Synchronized
    override fun hasOpen(): Boolean =
        db.rawQuery("SELECT 1 FROM picked WHERE state IN ('transferring','pending') LIMIT 1", null).use { it.moveToFirst() }

    @Synchronized
    override fun mark(id: Long, state: PickedState) {
        db.execSQL("UPDATE picked SET state = ? WHERE id = ?", arrayOf(state.wire, id))
    }

    @Synchronized
    override fun latestBatch(): PickedBatchSummary? =
        db.rawQuery(
            "SELECT batch_id, COUNT(*), SUM(state IN ('pending','transferring')), SUM(state = 'delivered')," +
                " SUM(state = 'already_there'), SUM(state = 'failed') FROM picked" +
                " WHERE batch_id = (SELECT MAX(batch_id) FROM picked) GROUP BY batch_id",
            null,
        ).use { c ->
            if (!c.moveToFirst()) null else PickedBatchSummary(c.getLong(0), c.getInt(1), c.getInt(2), c.getInt(3), c.getInt(4), c.getInt(5))
        }

    @Synchronized
    override fun clearSettled() {
        db.execSQL("DELETE FROM picked WHERE state NOT IN ('pending','transferring')")
    }

    @Synchronized
    override fun clearAll(): List<String> {
        val uris = db.rawQuery("SELECT uri FROM picked", null).use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }
        db.execSQL("DELETE FROM picked")
        return uris
    }

    private inline fun <T> SQLiteDatabase.inTransaction(block: SQLiteDatabase.() -> T): T {
        beginTransaction()
        try {
            val result = block()
            setTransactionSuccessful()
            return result
        } finally {
            endTransaction()
        }
    }

    companion object {
        private const val VERSION = 1
        const val DB_NAME = "picked-uploads.db"

        fun open(context: Context): SqlitePickedStore = SqlitePickedStore(Helper(context.applicationContext, DB_NAME))
    }
}
