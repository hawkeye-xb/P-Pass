// MOB-99 (#301)：captureAt 回退链 DATE_TAKEN → DATE_MODIFIED → DATE_ADDED，且 lookup 投影带上 DATE_MODIFIED。
package com.hawkeyexb.ppass.backup.order

import android.database.Cursor
import android.provider.MediaStore
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB99CaptureAtTest {

    // #301 卡面鸿蒙真机实测的那一行：_id=60346 wx_camera_1789878898637.jpg
    private val realModifiedSec = 1_789_878_898L // 2026-09-20 12:34:58，与文件名里的时间戳逐秒吻合
    private val realAddedSec = 1_789_962_757L // 2026-09-21 11:52:37，移动进相册的时刻

    @Test
    fun `datetaken missing - takes date_modified, not the move-in moment`() {
        assertEquals(realModifiedSec * 1000, captureAtMsOf(dateTakenMs = 0, dateModifiedSec = realModifiedSec, dateAddedSec = realAddedSec))
    }

    @Test
    fun `datetaken present - still wins over both`() {
        val taken = 1_700_000_000_123L
        assertEquals(taken, captureAtMsOf(dateTakenMs = taken, dateModifiedSec = realModifiedSec, dateAddedSec = realAddedSec))
    }

    @Test
    fun `all three unknown - still 0 so desktop falls back to its own chain`() {
        assertEquals(0L, captureAtMsOf(dateTakenMs = 0, dateModifiedSec = 0, dateAddedSec = 0))
    }

    @Test
    fun `only date_added known - last resort still used`() {
        assertEquals(realAddedSec * 1000, captureAtMsOf(dateTakenMs = 0, dateModifiedSec = 0, dateAddedSec = realAddedSec))
    }

    @Test
    fun `lookup projection carries DATE_MODIFIED even when snapshot columns do not`() {
        // 快照列故意不含 DATE_MODIFIED：lookup 自己必须把它要进来，而不是碰巧沾 sourceVersion 的光。
        val columns = lookupColumns(listOf(MediaStore.MediaColumns._ID))
        assertTrue(columns.toList().toString(), MediaStore.MediaColumns.DATE_MODIFIED in columns)

        // 用只认这组投影的游标走一遍真实读取路径：漏列会在 getColumnIndexOrThrow 抛错。
        val row = mapOf(
            MediaStore.MediaColumns._ID to 60346L,
            MediaStore.MediaColumns.DATE_TAKEN to 0L,
            MediaStore.MediaColumns.DATE_MODIFIED to realModifiedSec,
            MediaStore.MediaColumns.DATE_ADDED to realAddedSec,
        )
        assertEquals(realModifiedSec * 1000, captureAtMsOf(projectedCursor(columns, row)))
    }

    /** 只暴露 [columns] 这几列的单行游标；不在投影里的列与真 Cursor 一样抛 IllegalArgumentException。 */
    private fun projectedCursor(columns: Array<String>, row: Map<String, Long>): Cursor =
        Proxy.newProxyInstance(Cursor::class.java.classLoader, arrayOf(Cursor::class.java)) { _, method, args ->
            when (method.name) {
                "getColumnIndexOrThrow" -> {
                    val name = args!![0] as String
                    val idx = columns.indexOf(name)
                    require(idx >= 0) { "column '$name' does not exist" }
                    idx
                }
                "getColumnIndex" -> columns.indexOf(args!![0] as String)
                "getLong" -> row[columns[args!![0] as Int]] ?: 0L
                else -> throw UnsupportedOperationException(method.name)
            }
        } as Cursor
}
