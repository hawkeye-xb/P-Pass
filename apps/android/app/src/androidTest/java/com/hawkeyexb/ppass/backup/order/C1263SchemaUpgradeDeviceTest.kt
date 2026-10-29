// #1263：订单库 v5 → v6 只加列（orders / skip_list.date_added_sec）、不删表；计数按范围的开始时间过滤。
package com.hawkeyexb.ppass.backup.order

import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class C1263SchemaUpgradeDeviceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val name = "c1263-upgrade-test.db"

    @After
    fun cleanup() {
        context.deleteDatabase(name)
    }

    // 反证：onUpgrade 对 5→6 仍删表重建 → 升级后 currentForMedia(1) 为 null，红；toOrder 读错列 → dateAddedSec 不对，红。
    @Test
    fun upgradingFromV5KeepsEveryRowAndCountsFilterByTime() {
        context.deleteDatabase(name)
        SqliteOrderStore.open(context, name).apply {
            insert(NewOrder(1, "100:10", 7, "h1", OrderState.CONFIRMED, "e1"))
            cancelRemaining(listOf(SkipTarget(3, "300:30", 7)))
            close()
        }
        SQLiteDatabase.openDatabase(context.getDatabasePath(name).path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
            db.execSQL("ALTER TABLE orders DROP COLUMN date_added_sec")
            db.execSQL("ALTER TABLE skip_list DROP COLUMN date_added_sec")
            db.version = 5
        }

        val store = SqliteOrderStore.open(context, name)
        try {
            val old = store.currentForMedia(1)!!
            assertEquals(OrderState.CONFIRMED, old.state)
            assertEquals("v5 的行记 0", 0L, old.dateAddedSec)
            val fresh = store.insert(NewOrder(2, "200:20", 7, "h2", OrderState.CONFIRMED, "e1", dateAddedSec = 5_000L))
            assertEquals(5_000L, store.get(fresh.id)!!.dateAddedSec)

            assertEquals("全部：两行都算", 2L, store.countConfirmedPresent(setOf(7L), null))
            assertEquals("从今天起：只算今天进相册的", 1L, store.countConfirmedPresent(setOf(7L), 1_000L))
            assertEquals(1L, store.countCurrentByState(setOf(7L), 1_000L)[OrderState.CONFIRMED])
            assertEquals("v5 跳过名单的行也记 0", 1L, store.countSkipped(setOf(7L), null))
            assertEquals(0L, store.countSkipped(setOf(7L), 1_000L))
            store.cancelRemaining(listOf(SkipTarget(4, "400:40", 7, dateAddedSec = 6_000L)))
            assertEquals(1L, store.countSkipped(setOf(7L), 1_000L))
        } finally {
            store.close()
        }
    }
}
