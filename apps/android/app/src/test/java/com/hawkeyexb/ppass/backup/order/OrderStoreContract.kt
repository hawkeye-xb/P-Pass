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

    // AUDIT-06 (#460): the outbox pages by an increasing seq that survives acknowledging earlier events, so the
    // dispatcher can walk past events the daemon refuses instead of re-reading the same oldest page.
    @Test
    fun `the audit outbox pages by an increasing seq that acknowledging earlier events does not disturb`() {
        val store = newStore(clock)
        (1..5).forEach { store.appendAudit(AuditRecord("ev$it", "k", null, it.toLong())) }
        val first = store.pendingAuditAfter(0L, 2)
        assertEquals(listOf("ev1", "ev2"), first.map { it.record.eventId })
        assertTrue(first[0].seq < first[1].seq)
        store.acknowledgeAudit(setOf("ev3"))
        val second = store.pendingAuditAfter(first.last().seq, 2)
        assertEquals(listOf("ev4", "ev5"), second.map { it.record.eventId })
        assertTrue(second[0].seq > first.last().seq)
        assertEquals(emptyList<SequencedAudit>(), store.pendingAuditAfter(second.last().seq, 2))
        store.appendAudit(AuditRecord("ev6", "k", null, 6L))
        assertEquals(listOf("ev6"), store.pendingAuditAfter(second.last().seq, 2).map { it.record.eventId })
        assertEquals(listOf("ev1", "ev2", "ev4", "ev5", "ev6"), store.pendingAudit(10).map { it.eventId })
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

    // #459：标记是 MediaStore 的观察结果，不是一次传输的结局——不动 updated_at（「最近成功」与横幅水位按它算），
    // 只对 CONFIRMED 生效，值没变返回 false。
    // 反证：setSourceMissing 照旧写 updated_at_ms → lastConfirmedAtMs 跳到 9_000，红。
    @Test
    fun `source missing flag only applies to confirmed rows and never moves updated_at`() {
        val store = newStore(clock)
        val kept = store.insert(newOrder(1, OrderState.CONFIRMED))
        val gone = store.insert(newOrder(2, OrderState.CONFIRMED))
        val settled = store.insert(newOrder(3, OrderState.SKIPPED_SOURCE_MISSING))
        now = 9_000L
        assertTrue(store.setSourceMissing(gone.id, true))
        assertFalse("值没变", store.setSourceMissing(gone.id, true))
        assertFalse("不是 CONFIRMED", store.setSourceMissing(settled.id, true))
        assertFalse(store.get(settled.id)!!.sourceMissing)
        assertEquals(1_000L, store.get(gone.id)!!.updatedAtMs)
        assertEquals(1_000L, store.lastConfirmedAtMs())
        assertEquals(1L, store.countSourceMissingSkipped(afterMs = 0L))
        assertEquals(1L, store.countConfirmedPresent(setOf(7L)))
        assertTrue(store.setSourceMissing(gone.id, false))
        assertEquals(2L, store.countConfirmedPresent(setOf(7L)))
        assertEquals(1_000L, store.get(gone.id)!!.updatedAtMs)
        assertEquals(kept, store.get(kept.id))
    }

    // #459：同一个 key 只追加一次；审计被桌面确认删掉之后也不重复。
    // 反证：appendAuditOnce 不记 key、直接追加 → 第二次返回 true、outbox 里 2 条，红。
    @Test
    fun `append audit once records a key only once even after the outbox is acknowledged`() {
        val store = newStore(clock)
        val first = AuditRecord("ev-1", "reconciliation_resolved", null, 1_000L, mapOf("disposition" to "UNRECOVERABLE"))
        assertTrue(store.appendAuditOnce("unrecoverable:1:e1", first))
        assertFalse(store.appendAuditOnce("unrecoverable:1:e1", first.copy(eventId = "ev-2")))
        assertEquals(listOf("ev-1"), store.pendingAudit(10).map { it.eventId })
        store.acknowledgeAudit(setOf("ev-1"))
        assertFalse(store.appendAuditOnce("unrecoverable:1:e1", first.copy(eventId = "ev-3")))
        assertTrue(store.appendAuditOnce("unrecoverable:1:e2", first.copy(eventId = "ev-4")))
        assertEquals(listOf("ev-4"), store.pendingAudit(10).map { it.eventId })
    }

    // AUDIT-07 (#499)：未闭合那一轮的身份（round_id）是落库的账本事实——开了就在，关了就清，
    // 关轮时终态事实与清标记同一步生效。
    // 反证：closeRound 只清标记不写终态（或反过来）→ 下面的断言成对地红。
    @Test
    fun `the open round marker lives from round start until its terminal fact is appended`() {
        val store = newStore(clock)
        assertNull(store.openRoundId())
        store.openRound("round-1")
        assertEquals("round-1", store.openRoundId())
        // 逐张事实带的就是它（每一张都挂同一次操作）。
        val item = AuditRecord("ev-item", "flow.item.confirmed", store.openRoundId(), 1_500L, mapOf("itemRef" to "media:1"))
        store.appendAudit(item)
        assertEquals(listOf("round-1"), store.pendingAudit(10).map { it.roundId })
        val finished = AuditRecord("ev-round", "flow.round.finished", "round-1", 2_000L, mapOf("confirmed" to "1"))
        store.closeRound(finished)
        assertNull("关轮 = 标记清掉", store.openRoundId())
        assertEquals("终态与逐张事实在同一条 outbox、终态在后", listOf("ev-item", "ev-round"), store.pendingAudit(10).map { it.eventId })
        // 一轮什么都没碰过：关轮不发终态，只清标记。
        store.openRound("round-2")
        store.closeRound(null)
        assertNull(store.openRoundId())
        assertEquals(2, store.pendingAudit(10).size)
    }

    // AUDIT-07 (#499)：换桌面那套账一起作废——旧桌面的未闭合轮不能在新桌面上补终态。
    @Test
    fun `changing desktops drops the open round marker`() {
        val store = newStore(clock)
        store.claimOwner("desk-a", 0L)
        store.openRound("round-1")
        assertTrue(store.claimOwner("desk-b", 0L))
        assertNull(store.openRoundId())
    }
}

class InMemoryOrderStoreContractTest : OrderStoreContract() {
    override fun newStore(clock: () -> Long): OrderStore = InMemoryOrderStore(clock)
}
