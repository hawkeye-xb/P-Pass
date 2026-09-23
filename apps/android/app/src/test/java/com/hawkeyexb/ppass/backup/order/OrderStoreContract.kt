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
        NewOrder(mediaId = mediaId, sourceVersion = version, bucketId = 7, contentHash = hash, state = state, pairingEpoch = "e3")

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
            pairingEpoch = "e5",
        )
        assertEquals(SkipResult(inserted = 1, updated = 2, untouched = 1), result)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(open.id)!!.state)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(failed.id)!!.state)
        assertEquals(OrderState.CONFIRMED, store.get(confirmed.id)!!.state)
        val inserted = store.currentForMedia(4)!!
        assertEquals(OrderState.SKIPPED_BY_USER, inserted.state)
        assertEquals("v4", inserted.sourceVersion)
        assertEquals("e5", inserted.pairingEpoch)
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
                pairingEpoch = "e5",
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
    // ---- ARCH-13 (#417) 新增契约 ----

    @Test
    fun `transition carries the generation advance and audit in the same write, or neither`() {
        val store = newStore(clock)
        val o = store.insert(newOrder(1, OrderState.TRANSFERRING))
        val audit = AuditRecord("ev-1", "flow.item.confirmed", null, 1L, mapOf("queueSequence" to o.id.toString()))
        assertFalse(
            "wrong expected state writes nothing",
            store.transition(o.id, setOf(OrderState.PAUSED), OrderState.CONFIRMED, advance = GenerationAdvance("vol", 50), audit = audit),
        )
        assertNull(store.volumeState("vol"))
        assertEquals(emptyList<AuditRecord>(), store.pendingAudit(10))

        assertTrue(store.transition(o.id, setOf(OrderState.TRANSFERRING), OrderState.CONFIRMED, advance = GenerationAdvance("vol", 50), audit = audit))
        assertEquals(50L, store.volumeState("vol")!!.fastPathGeneration)
        assertEquals(listOf(audit), store.pendingAudit(10))
        // G 只增不减。
        store.advanceGeneration(GenerationAdvance("vol", 20))
        assertEquals(50L, store.volumeState("vol")!!.fastPathGeneration)
        store.acknowledgeAudit(setOf("ev-1"))
        assertEquals(emptyList<AuditRecord>(), store.pendingAudit(10))
    }

    @Test
    fun `source missing flag, hash fill and delete`() {
        val store = newStore(clock)
        val confirmed = store.insert(newOrder(1, OrderState.CONFIRMED, "h1"))
        assertTrue(store.setSourceMissing(confirmed.id, true))
        assertTrue(store.get(confirmed.id)!!.sourceMissing)
        assertEquals("flag never rewrites CONFIRMED", OrderState.CONFIRMED, store.get(confirmed.id)!!.state)
        assertTrue(store.setSourceMissing(confirmed.id, false))
        assertFalse(store.get(confirmed.id)!!.sourceMissing)

        val unhashed = store.insert(newOrder(2, OrderState.SKIPPED_BY_USER, hash = null))
        assertTrue(store.setContentHash(unhashed.id, "h2"))
        assertFalse("an existing hash is never overwritten", store.setContentHash(unhashed.id, "other"))
        assertEquals("h2", store.get(unhashed.id)!!.contentHash)

        assertTrue(store.delete(unhashed.id))
        assertFalse(store.delete(unhashed.id))
        assertNull(store.get(unhashed.id))
    }

    @Test
    fun `pick queries only see current rows`() {
        val store = newStore(clock)
        val stale = store.insert(newOrder(1, OrderState.PAUSED, "old"))
        store.insert(newOrder(1, OrderState.CONFIRMED, "new", version = "v2"))
        val paused = store.insert(newOrder(2, OrderState.PAUSED))
        val queued = store.insert(newOrder(3, OrderState.QUEUED))
        val confirmed = store.insert(newOrder(4, OrderState.CONFIRMED))
        assertEquals(listOf(paused), store.currentInStates(setOf(OrderState.PAUSED, OrderState.TRANSFERRING), 10))
        assertTrue(stale !in store.currentInStates(setOf(OrderState.PAUSED), 10))
        assertEquals(listOf(queued), store.currentInStates(setOf(OrderState.QUEUED), 10))
        assertEquals(listOf(4L), store.confirmedWithHashAfter(confirmed.id - 1, 10).map { it.mediaId })
        assertEquals(listOf(1L, 4L), store.confirmedWithHashAfter(0, 10).map { it.mediaId })
        assertEquals(
            mapOf(OrderState.CONFIRMED to 2L, OrderState.PAUSED to 1L, OrderState.QUEUED to 1L),
            store.countCurrentByState(),
        )
        assertEquals(emptyMap<OrderState, Long>(), store.countCurrentByState(setOf(99L)))
    }

    // #418：英雄区的 m 只数原图还在的 CONFIRMED 当前行，按相册过滤。
    // 反证：实现里去掉 source_missing 条件 → present 为 3，红。
    @Test
    fun `confirmed present count skips rows whose source was deleted and honours the album filter`() {
        val store = newStore(clock)
        store.insert(newOrder(1, OrderState.CONFIRMED, "h1"))
        val gone = store.insert(newOrder(2, OrderState.CONFIRMED, "h2"))
        store.insert(newOrder(3, OrderState.CONFIRMED, "h3"))
        store.insert(newOrder(4, OrderState.SKIPPED_BY_USER, null))
        store.insert(newOrder(3, OrderState.TRANSFERRING, "h3b", version = "v2"))
        assertTrue(store.setSourceMissing(gone.id, true))
        assertEquals("row 2 lost its source, row 3's current row is not CONFIRMED", 1L, store.countConfirmedPresent())
        assertEquals(1L, store.countConfirmedPresent(setOf(7L)))
        assertEquals(0L, store.countConfirmedPresent(setOf(99L)))
        assertEquals(0L, store.countConfirmedPresent(emptySet()))
    }

    @Test
    fun `claiming a new owner clears the table and lifts the id floor above old queue sequences`() {
        val store = newStore(clock)
        assertFalse("first owner clears nothing", store.claimOwner("desk-a", idFloor = 1_000_000))
        val first = store.insert(newOrder(1, OrderState.CONFIRMED))
        assertTrue("ids start above the floor: ${first.id}", first.id > 1_000_000)
        assertFalse("same owner keeps everything", store.claimOwner("desk-a", idFloor = 5))
        assertEquals(first, store.get(first.id))

        assertTrue(store.claimOwner("desk-b", idFloor = 2_000_000))
        assertNull(store.get(first.id))
        assertEquals(emptyMap<OrderState, Long>(), store.countCurrentByState())
        assertTrue(store.insert(newOrder(1)).id > 2_000_000)
    }

    // #418：恢复只删当前行为 SKIPPED_BY_USER 的行，一个事务；其它状态与历史行不动。
    // 反证：实现删掉所有 SKIPPED_BY_USER 行（不看是不是当前行）→ media 3 的历史行也没了，红。
    @Test
    fun `restoring skipped photos deletes only current skipped rows, atomically`() {
        val store = newStore(clock)
        store.insert(newOrder(1, OrderState.SKIPPED_BY_USER, null))
        store.insert(newOrder(2, OrderState.CONFIRMED))
        val oldSkip = store.insert(newOrder(3, OrderState.SKIPPED_BY_USER, null))
        store.insert(newOrder(3, OrderState.QUEUED, "h3b", version = "v2"))
        store.insert(newOrder(4, OrderState.SKIPPED_BY_USER, null))
        val audit = AuditRecord("restore-1", "flow.round.controlled", null, 1L, mapOf("action" to "restore"))

        assertEquals(2, store.restoreSkippedByUser(audit))
        assertNull(store.currentForMedia(1))
        assertNull(store.currentForMedia(4))
        assertEquals(OrderState.CONFIRMED, store.currentForMedia(2)!!.state)
        assertEquals("history row of media 3 is untouched", oldSkip, store.get(oldSkip.id))
        assertEquals(listOf("restore-1"), store.pendingAudit(10).map { it.eventId })
        assertEquals(0, store.restoreSkippedByUser())
    }

    @Test
    fun `skip by user covers queued rows too`() {
        val store = newStore(clock)
        val queued = store.insert(newOrder(1, OrderState.QUEUED))
        val result = store.skipByUser(listOf(SkipTarget(1, "v1", 7)), pairingEpoch = "e5")
        assertEquals(1, result.written)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(queued.id)!!.state)
    }
}

class InMemoryOrderStoreContractTest : OrderStoreContract() {
    override fun newStore(clock: () -> Long): OrderStore = InMemoryOrderStore(clock)
}
