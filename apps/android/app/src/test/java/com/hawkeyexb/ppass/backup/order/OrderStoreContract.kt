// ARCH-12 (#416): OrderStore 契约。任何实现都要过这一套。
//
// JVM 上只有 InMemoryOrderStore 能跑（android.database.sqlite 需要真机）；
// SqliteOrderStore 由 src/androidTest/.../SqliteOrderStoreDeviceTest 在设备上跑同样的用例。
package com.hawkeyexb.ppass.backup.order

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

abstract class OrderStoreContract {
    private var now = 1_000L
    protected val clock: () -> Long = { now }

    abstract fun newStore(clock: () -> Long): OrderStore

    private fun newOrder(mediaId: Long, state: OrderState = OrderState.TRANSFERRING, hash: String? = "h$mediaId", version: String = "v1") =
        NewOrder(mediaId = mediaId, sourceVersion = version, bucketId = 7, contentHash = hash, state = state, pairingEpoch = 3)

    @Test
    fun `insert assigns strictly increasing ids and stamps time`() {
        val store = newStore(clock)
        val a = store.insert(newOrder(10))
        now = 2_000L
        val b = store.insert(newOrder(5))
        assertTrue("ids must strictly increase: ${a.id} then ${b.id}", b.id > a.id)
        assertEquals(1_000L, a.createdAtMs)
        assertEquals(2_000L, b.updatedAtMs)
        assertEquals(0, a.attempts)
        assertEquals(a, store.get(a.id))
        assertNull(store.get(b.id + 1000))
    }

    @Test
    fun `current order for a media id is its newest row`() {
        val store = newStore(clock)
        store.insert(newOrder(10, OrderState.CONFIRMED, "old"))
        val edited = store.insert(newOrder(10, OrderState.TRANSFERRING, "new", version = "v2"))
        assertEquals(edited, store.currentForMedia(10))
        assertNull(store.currentForMedia(11))
    }

    @Test
    fun `current orders stream ascending by media id, one row each, across pages`() {
        val store = newStore(clock)
        // 600 > SQLite 实现的页大小 256，覆盖跨页。倒序插入，证明排序来自存储而不是插入顺序。
        for (m in 600L downTo 1L) store.insert(newOrder(m, OrderState.CONFIRMED, "a$m"))
        for (m in 1L..600L step 3) store.insert(newOrder(m, OrderState.TRANSFERRING, "b$m", version = "v2"))
        val seen = store.readCurrentOrders { it.toList() }
        assertEquals((1L..600L).toList(), seen.map { it.mediaId })
        seen.forEach { o ->
            val expected = if ((o.mediaId - 1) % 3 == 0L) "b${o.mediaId}" else "a${o.mediaId}"
            assertEquals("media ${o.mediaId}", expected, o.contentHash)
        }
    }

    @Test
    fun `writing during the current-orders stream never repeats a media id`() {
        val store = newStore(clock)
        for (m in 1L..300L) store.insert(newOrder(m))
        val seen = store.readCurrentOrders { rows ->
            rows.map { o ->
                // 边读边给已读过的 media_id 插新行（编辑）——不许被再读到一次。
                store.insert(newOrder(o.mediaId, hash = "edit${o.mediaId}", version = "v2"))
                o.mediaId
            }.toList()
        }
        assertEquals((1L..300L).toList(), seen)
    }

    @Test
    fun `orders with hash are found by content`() {
        val store = newStore(clock)
        val a = store.insert(newOrder(1, hash = "same"))
        val b = store.insert(newOrder(2, hash = "same"))
        store.insert(newOrder(3, hash = "other"))
        store.insert(newOrder(4, hash = null))
        assertEquals(listOf(a, b), store.ordersWithHash("same"))
        assertEquals(emptyList<Order>(), store.ordersWithHash("missing"))
    }

    @Test
    fun `transition is compare-and-set and counts attempts in the same write`() {
        val store = newStore(clock)
        val o = store.insert(newOrder(1, OrderState.TRANSFERRING))
        assertFalse(store.transition(o.id, setOf(OrderState.PAUSED), OrderState.CONFIRMED))
        assertEquals(OrderState.TRANSFERRING, store.get(o.id)!!.state)

        now = 5_000L
        assertTrue(store.transition(o.id, setOf(OrderState.TRANSFERRING, OrderState.PAUSED), OrderState.FAILED, countAttempt = true))
        val failed = store.get(o.id)!!
        assertEquals(OrderState.FAILED, failed.state)
        assertEquals(1, failed.attempts)
        assertEquals(5_000L, failed.updatedAtMs)

        assertFalse("unknown id", store.transition(o.id + 99, setOf(OrderState.FAILED), OrderState.CONFIRMED))
        assertFalse("empty expected set", store.transition(o.id, emptySet(), OrderState.CONFIRMED))
    }

    @Test
    fun `update mapping moves media id and version but keeps state and hash`() {
        val store = newStore(clock)
        val o = store.insert(newOrder(1, OrderState.CONFIRMED, "h"))
        assertTrue(store.updateMapping(o.id, mediaId = 101, sourceVersion = "v9", bucketId = 8))
        val moved = store.get(o.id)!!
        assertEquals(101L, moved.mediaId)
        assertEquals("v9", moved.sourceVersion)
        assertEquals(8L, moved.bucketId)
        assertEquals(OrderState.CONFIRMED, moved.state)
        assertEquals("h", moved.contentHash)
        assertNull(store.currentForMedia(1))
        assertFalse(store.updateMapping(o.id + 99, 1, "v", 1))
    }

    // O 组「批量跳过是单事务」：正常路径——没有 order 的插入、未完结的改写、已有结局的不动。
    @Test
    fun `skip by user inserts missing rows, closes open rows, leaves decided rows`() {
        val store = newStore(clock)
        val open = store.insert(newOrder(1, OrderState.PAUSED))
        val failed = store.insert(newOrder(2, OrderState.FAILED))
        val confirmed = store.insert(newOrder(3, OrderState.CONFIRMED))
        val result = store.skipByUser(
            listOf(SkipTarget(1, "v1", 7), SkipTarget(2, "v1", 7), SkipTarget(3, "v1", 7), SkipTarget(4, "v4", 9)),
            pairingEpoch = 5,
        )
        assertEquals(SkipResult(inserted = 1, updated = 2, untouched = 1), result)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(open.id)!!.state)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(failed.id)!!.state)
        assertEquals(OrderState.CONFIRMED, store.get(confirmed.id)!!.state)
        val inserted = store.currentForMedia(4)!!
        assertEquals(OrderState.SKIPPED_BY_USER, inserted.state)
        assertEquals("v4", inserted.sourceVersion)
        assertEquals(5L, inserted.pairingEpoch)
        assertNull(inserted.contentHash)
    }

    // O 组「批量跳过是单事务」：中途一项失败，整批一行都不写。
    @Test
    fun `skip by user is one transaction - a failure mid-batch writes nothing`() {
        val store = newStore(clock)
        val open = store.insert(newOrder(1, OrderState.TRANSFERRING))
        val before = store.readCurrentOrders { it.toList() }
        try {
            store.skipByUser(
                listOf(SkipTarget(1, "v1", 7), SkipTarget(2, "v2", 7), SkipTarget(-1, "bad", 7), SkipTarget(3, "v3", 7)),
                pairingEpoch = 5,
            )
            fail("a non-positive media id must abort the batch")
        } catch (expected: IllegalArgumentException) {
            // 预期
        }
        assertEquals(before, store.readCurrentOrders { it.toList() })
        assertEquals(OrderState.TRANSFERRING, store.get(open.id)!!.state)
        assertNull(store.currentForMedia(2))
        // 回滚之后 id 依然只增不减。
        val next = store.insert(newOrder(9))
        assertTrue(next.id > open.id)
    }

    @Test
    fun `volume state round-trips per volume`() {
        val store = newStore(clock)
        assertNull(store.volumeState("external_primary"))
        store.saveVolumeState(VolumeState("external_primary", 120, "v-a"))
        store.saveVolumeState(VolumeState("0a1b-2c3d", 7, null))
        store.saveVolumeState(VolumeState("external_primary", 130, "v-b"))
        assertEquals(VolumeState("external_primary", 130, "v-b"), store.volumeState("external_primary"))
        assertEquals(VolumeState("0a1b-2c3d", 7, null), store.volumeState("0a1b-2c3d"))
        assertEquals(listOf("0a1b-2c3d", "external_primary"), store.volumeNames())
    }
}

class InMemoryOrderStoreContractTest : OrderStoreContract() {
    override fun newStore(clock: () -> Long): OrderStore = InMemoryOrderStore(clock)
}
