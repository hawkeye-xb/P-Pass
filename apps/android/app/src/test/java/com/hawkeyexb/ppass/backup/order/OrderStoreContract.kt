// ARCH-12 (#416) → #413: OrderStore 契约（order 事实 + 跳过名单意图 + 游标）。任何实现都要过这一套。
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
    fun `insert assigns strictly increasing ids and the current row is the newest one per photo`() {
        val store = newStore(clock)
        val a = store.insert(newOrder(10))
        now = 2_000L
        val b = store.insert(newOrder(10, OrderState.PENDING, version = "v2"))
        assertTrue(b.id > a.id)
        assertEquals(1_000L, a.createdAtMs)
        assertEquals(b, store.currentForMedia(10))
        assertEquals(listOf(b.id), store.currentInStates(setOf(OrderState.PENDING, OrderState.TRANSFERRING)).map { it.id })
        assertEquals(emptyList<Order>(), store.currentInStates(setOf(OrderState.PENDING), afterId = b.id))
    }

    @Test
    fun `transition is compare-and-set and writes attempts, hash, G, S and audit in the same step`() {
        val store = newStore(clock)
        store.saveVolumeState(VolumeState("external", 0L, 0L, "v"))
        val o = store.insert(newOrder(1, hash = null))
        assertFalse(store.transition(o.id, setOf(OrderState.PENDING), OrderState.CONFIRMED, advance = GenerationAdvance("external", 9)))
        assertEquals(0L, store.volumeState("external")!!.generation)
        val audit = AuditRecord("ev1", "k", null, 1L)
        assertTrue(
            store.transition(
                o.id, setOf(OrderState.TRANSFERRING), OrderState.FAILED,
                countAttempt = true, contentHash = "abc", advance = GenerationAdvance("external", 9, 3), scanTo = 42, audit = audit,
            ),
        )
        val row = store.get(o.id)!!
        assertEquals(OrderState.FAILED, row.state)
        assertEquals(1, row.attempts)
        assertEquals("abc", row.contentHash)
        assertEquals(VolumeState("external", 9L, 3L, "v"), store.volumeState("external"))
        assertEquals(42L, store.scanState().cursor)
        assertEquals(listOf(audit), store.pendingAudit(10))
    }

    @Test
    fun `G advances lexicographically by generation then media id and never goes back`() {
        val store = newStore(clock)
        store.advanceGeneration(GenerationAdvance("v", 5, 10))
        store.advanceGeneration(GenerationAdvance("v", 5, 3))
        assertEquals(10L, store.volumeState("v")!!.generationMediaId)
        store.advanceGeneration(GenerationAdvance("v", 4, 99))
        assertEquals(5L, store.volumeState("v")!!.generation)
        store.advanceGeneration(GenerationAdvance("v", 6, 1))
        assertEquals(6L to 1L, store.volumeState("v")!!.let { it.generation to it.generationMediaId })
    }

    @Test
    fun `the scan cursor lifecycle - dirty from zero, only moves forward, finish clears it`() {
        val store = newStore(clock)
        assertEquals(ScanState(false, 0L), store.scanState())
        store.markScanDirty()
        store.advanceScan(5)
        store.advanceScan(3)
        assertEquals(ScanState(true, 5L), store.scanState())
        store.markScanDirty()
        assertEquals(ScanState(true, 0L), store.scanState())
        store.finishScan()
        assertEquals(ScanState(false, 0L), store.scanState())
    }

    @Test
    fun `cancel remaining writes the skip list and skips open orders but leaves photos settled since the dialog`() {
        val store = newStore(clock)
        val open = store.insert(newOrder(1))
        store.insert(newOrder(2, OrderState.CONFIRMED))
        store.insert(newOrder(4, OrderState.CONFIRMED, version = "old"))
        val result = store.cancelRemaining(
            listOf(SkipTarget(1, "v1", 7), SkipTarget(2, "v1", 7), SkipTarget(3, "v1", 8), SkipTarget(4, "v1", 7)),
        )
        assertEquals(SkipResult(written = 3, ordersSkipped = 1, untouched = 1), result)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(open.id)!!.state)
        assertTrue(store.isSkipped(1) && store.isSkipped(3) && store.isSkipped(4))
        assertFalse(store.isSkipped(2))
        assertEquals(listOf(1L, 3L, 4L), store.readSkipList { it.toList() })
        assertEquals(1L, store.countSkipped(setOf(8L)))
        assertEquals("「已跳过」报名单", 3L, store.countCurrentByState(null)[OrderState.SKIPPED_BY_USER])
    }

    @Test
    fun `cancel remaining is one transaction`() {
        val store = newStore(clock)
        val open = store.insert(newOrder(1))
        try {
            store.cancelRemaining(listOf(SkipTarget(1, "v1", 7), SkipTarget(-1, "v1", 7)))
            fail("a bad target must abort the batch")
        } catch (_: IllegalArgumentException) {
        }
        assertEquals(OrderState.TRANSFERRING, store.get(open.id)!!.state)
        assertFalse(store.isSkipped(1))
    }

    @Test
    fun `restore empties the skip list and marks the scan dirty`() {
        val store = newStore(clock)
        store.cancelRemaining(listOf(SkipTarget(1, "v1", 7), SkipTarget(2, "v1", 7)))
        assertEquals(2, store.restoreSkipped())
        assertEquals(0L, store.countSkipped())
        assertEquals(ScanState(true, 0L), store.scanState())
        assertNull(store.countCurrentByState(null)[OrderState.SKIPPED_BY_USER])
    }

    @Test
    fun `retry failed turns current failed rows back to pending and keeps their attempts`() {
        val store = newStore(clock)
        val o = store.insert(newOrder(1))
        store.transition(o.id, setOf(OrderState.TRANSFERRING), OrderState.FAILED, countAttempt = true)
        assertEquals(1, store.retryFailed())
        assertEquals(OrderState.PENDING, store.get(o.id)!!.state)
        assertEquals(1, store.get(o.id)!!.attempts)
    }

    @Test
    fun `changing desktops clears facts and cursors but keeps the skip list and lifts the id floor`() {
        val store = newStore(clock)
        assertFalse(store.claimOwner("desk-a", idFloor = 100))
        val o = store.insert(newOrder(1))
        assertTrue(o.id > 100)
        store.cancelRemaining(listOf(SkipTarget(2, "v1", 7)))
        store.saveVolumeState(VolumeState("v", 3, 3, "x"))
        assertFalse(store.claimOwner("desk-a", idFloor = 5_000))
        assertTrue(store.claimOwner("desk-b", idFloor = 5_000))
        assertNull(store.get(o.id))
        assertNull(store.volumeState("v"))
        assertTrue(store.scanState().dirty)
        assertTrue(store.isSkipped(2))
        assertTrue(store.insert(newOrder(3)).id > 5_000)
    }

    @Test
    fun `ui counts read current rows and confirmed-present`() {
        val store = newStore(clock)
        store.insert(newOrder(1, OrderState.CONFIRMED))
        val gone = store.insert(newOrder(2, OrderState.CONFIRMED))
        store.setSourceMissing(gone.id, true)
        store.insert(newOrder(3, OrderState.FAILED))
        assertEquals(2L, store.countCurrentByState(setOf(7L))[OrderState.CONFIRMED])
        assertEquals(1L, store.countConfirmedPresent(setOf(7L)))
        assertEquals(0L, store.countConfirmedPresent(emptySet()))
        assertEquals(listOf(1L, 2L, 3L), store.readCurrentOrders { rows -> rows.map { it.mediaId }.toList() })
        assertEquals(2, store.confirmedWithHashAfter(0L, 10).size)
    }
}

class InMemoryOrderStoreContractTest : OrderStoreContract() {
    override fun newStore(clock: () -> Long): OrderStore = InMemoryOrderStore(clock)
}
