// #843：订单库 v3 → v4 只加列、不删表。已确认的行是「哪些照片传过、传的是哪份字节」的唯一记录；
// 删表重建会让全部照片重新导入，拿到位置权限后带 GPS 的照片在桌面多出一份。
package com.hawkeyexb.ppass.backup.order

import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LOC843SchemaUpgradeDeviceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val name = "loc843-upgrade-test.db"

    @After
    fun cleanup() {
        context.deleteDatabase(name)
    }

    // 反证：onUpgrade 仍是删表重建 → 升级后 currentForMedia(1) 为 null，红。
    @Test
    fun upgradingFromV3KeepsEveryRowAndMarksThemRedacted() {
        context.deleteDatabase(name)
        // 先按现行 schema 建库、写一行已确认，再把它退回成 v3 的样子（去掉新列、版本号改 3）。
        SqliteOrderStore.open(context, name).apply {
            insert(NewOrder(1, "100:10", 7, "h1", OrderState.CONFIRMED, "e1", locationRedacted = false))
            close()
        }
        SQLiteDatabase.openDatabase(context.getDatabasePath(name).path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
            db.execSQL("ALTER TABLE orders DROP COLUMN location_redacted")
            db.version = 3
        }

        val store = SqliteOrderStore.open(context, name)
        try {
            val row = store.currentForMedia(1)!!
            assertEquals(OrderState.CONFIRMED, row.state)
            assertEquals("h1", row.contentHash)
            assertTrue("v3 的行都是在没有位置权限时读的", row.locationRedacted)
            val fresh = store.insert(NewOrder(2, "200:20", 7, "h2", OrderState.CONFIRMED, "e1", locationRedacted = false))
            assertFalse(store.get(fresh.id)!!.locationRedacted)
        } finally {
            store.close()
        }
    }
}
