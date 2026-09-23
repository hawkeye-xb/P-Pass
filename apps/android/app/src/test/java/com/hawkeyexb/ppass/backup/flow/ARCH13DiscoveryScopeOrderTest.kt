// ARCH-13 (#417) E2：Case Matrix D（发现）、X（取消与改范围）、O（order 与差集）、E（完成凭据）组，
// 走真实的 FlowEngine 端到端。反证写在测试上方，输出见 #417 报告。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.GenerationAdvance
import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.VolumeState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ARCH13DiscoveryScopeOrderTest {

    // ---------------------------------------------------------------- D 组

    // D-01：严格按 generation 升序，新照片不插队（哪怕它先触发）。
    // 反证：快路径查询按 generation 降序 → 20 在前，红。
    @Test
    fun `D-01 photos go strictly by generation, a new photo does not jump the line`() = runTest {
        val rig = Rig(this)
        rig.photo(3, generation = 20)
        rig.photo(1, generation = 10)
        rig.photo(2, generation = 11)
        rig.trigger()
        assertEquals(listOf(1L, 2L, 3L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // D-03：传输期间新拍的照片在同一次循环里被快路径接上，不需要额外触发（没有物化队列）。
    // 反证：循环只消费启动时取出的一批（把 pickNext 换成启动时的快照列表）→ #9 不在本轮，红。
    @Test
    fun `D-03 a photo taken during a transfer is picked up in the same loop`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.onStart = { if (it.details.snapshot.mediaId == 1L) rig.photo(9, generation = 50) }
        rig.trigger()
        assertEquals(listOf(1L, 9L), rig.delivery.deliveredMediaIds)
        assertEquals(1, rig.foreground.acquires)
        rig.close()
    }

    // D-04：G 丢了（清零）而照片多数已 CONFIRMED——快路径按 order 过滤，不重传。
    // 反证：快路径既不看当前行、也不按 hash 查已有 order（classify(snapshot, null) + ordersWithHash 恒空）→ 重传，红。
    @Test
    fun `D-04 losing G re-sends nothing that is already confirmed`() = runTest {
        val rig = Rig(this)
        (1L..3L).forEach { rig.photo(it, generation = it) }
        rig.trigger()
        assertEquals(3, rig.delivery.requests.size)
        rig.store.saveVolumeState(VolumeState(LEGACY_VOLUME, 0L, "v1"))
        rig.trigger()
        assertEquals(3, rig.delivery.requests.size)
        assertEquals(3L, rig.store.volumeState(LEGACY_VOLUME)!!.fastPathGeneration)
        rig.close()
    }

    // D-05：getVersion 变了 → 任何触发都做一次全量对账并记下新版本；快路径漏掉的照片因此被补上。
    // 反证：runCycle 不检测 getVersion（slow 只看 reason）→ #5 永远不传，红。
    @Test
    fun `D-05 a MediaStore version change turns any trigger into a full reconciliation`() = runTest {
        val rig = Rig(this)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 100))
        rig.photo(5, generation = 3) // 在 G 之下：快路径看不见
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals("fast path cannot see it", 0, rig.delivery.requests.size)

        rig.media.versions = mapOf(LEGACY_VOLUME to "v2")
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(listOf(5L), rig.delivery.deliveredMediaIds)
        assertEquals("v2", rig.store.volumeState(LEGACY_VOLUME)!!.mediaStoreVersion)
        rig.close()
    }

    // D-06：2 000 张里只有 3 张变了 → 慢路径只对这 3 张算 BLAKE3。
    // 反证：DiffPlanner.classify 删掉「同版本 → null」的短路 → hash 次数 = 2 000，红。
    @Test
    fun `D-06 the slow path hashes only new or changed photos`() = runTest {
        val rig = Rig(this)
        for (id in 1L..2_000L) {
            val p = rig.photo(id, generation = id)
            if (id > 3) rig.order(p, OrderState.CONFIRMED)
        }
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 2_000))
        rig.media.hashed.clear()
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(listOf(1L, 2L, 3L), rig.media.hashed.sorted())
        assertEquals(listOf(1L, 2L, 3L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // D-07 / #416 裁决 7：G 按卷分开——两个卷各自推进，第二个卷上的照片照样被快路径取到。
    // 反证：fastPathStep 只查 LEGACY_VOLUME（不遍历 volumeNames）→ SD 卡上的照片不传，红。
    @Test
    fun `D-07 the fast path cursor is per volume`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 5)
        rig.photo(2, generation = 3, volume = "1a2b-3c4d")
        rig.trigger()
        assertEquals(setOf(1L, 2L), rig.delivery.deliveredMediaIds.toSet())
        assertEquals(5L, rig.store.volumeState(LEGACY_VOLUME)!!.fastPathGeneration)
        assertEquals(3L, rig.store.volumeState("1a2b-3c4d")!!.fastPathGeneration)
        rig.close()
    }

    // 首次运行（order 表空、getVersion 从没记过）：不在 FGS 之外把整个相册先算一遍 hash，
    // 而是交给快路径按 generation 逐张「算 hash → 建 order → 传」。
    // 反证：删掉 runLocalSlowPath 开头的空表短路 → 申请 FGS 之前已算过 5 次 hash，红。
    @Test
    fun `first run hashes nothing before the foreground service and sends in generation order`() = runTest {
        val rig = Rig(this, reconciled = false)
        var hashedBeforeAcquire = -1
        val realForeground = rig.foreground
        (1L..5L).forEach { rig.photo(6 - it, generation = it) }
        rig.delivery.onStart = { if (hashedBeforeAcquire < 0) hashedBeforeAcquire = rig.media.hashed.size - 1 }
        rig.trigger(TriggerReason.PROCESS_START)
        assertEquals(listOf(5L, 4L, 3L, 2L, 1L), rig.delivery.deliveredMediaIds)
        assertEquals("only the first photo was hashed before sending started", 0, hashedBeforeAcquire)
        assertEquals(1, realForeground.acquires)
        assertEquals("v1", rig.store.volumeState(LEGACY_VOLUME)!!.mediaStoreVersion)
        rig.close()
    }

    // ---------------------------------------------------------------- X 组

    // X-01 / #417 重点：「取消剩余 N 张」——正在传的那张停下并通知桌面丢掉部分数据；剩下的（含 FAILED）
    // 一个事务写 N 条 SKIPPED_BY_USER；FGS 释放；之后慢路径不补传这些照片。
    // 反证：cancelRemaining 只结束循环、不写 skipByUser → 慢路径把 5 张全部补传，红。
    @Test
    fun `X-01 cancel remaining writes N SKIPPED_BY_USER rows and the slow path never re-sends them`() = runTest {
        val rig = Rig(this)
        (1L..5L).forEach { rig.photo(it, generation = it) }
        val failed = rig.photo(6, generation = 6)
        rig.order(failed, OrderState.FAILED)
        rig.delivery.hold = true
        rig.trigger()
        val inFlight = rig.store.currentForMedia(1)!!.id

        val n = rig.engine.cancelRemaining()
        rig.settle()

        assertEquals(6, n.getCompleted())
        assertEquals((1L..6L).map { OrderState.SKIPPED_BY_USER }, (1L..6L).map { rig.state(it) })
        assertEquals(listOf(inFlight), rig.delivery.discarded)
        assertEquals(listOf(inFlight), rig.delivery.cancelled)
        assertEquals(1, rig.foreground.releases)

        rig.delivery.release()
        rig.trigger(TriggerReason.PERIODIC)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals("nothing is sent after cancel", listOf(1L), rig.delivery.deliveredMediaIds)
        assertEquals((1L..6L).map { OrderState.SKIPPED_BY_USER }, (1L..6L).map { rig.state(it) })
        rig.close()
    }

    // X-02：批量写 N 条的事务中途崩溃 → 一条都没有；返回值与实际写入一致。
    // 反证：InMemoryOrderStore 的事务改成原地写（不拷贝）→ 崩溃后留下部分 SKIPPED_BY_USER，红。
    @Test
    fun `X-02 a crash inside the cancel transaction writes nothing`() = runTest {
        val rig = Rig(this)
        (1L..4L).forEach { rig.photo(it, generation = it) }
        rig.store.failNextCommit = IllegalStateException("power loss")
        val n = rig.engine.cancelRemaining()
        rig.settle()
        assertTrue(n.isCancelled || n.getCompletionExceptionOrNull() != null)
        assertTrue((1L..4L).all { rig.state(it) == null })
        rig.close()
    }

    // X-03 / E-03：取消之后新拍的照片照常备份；已确认的不计入 N、仍是 CONFIRMED。
    @Test
    fun `X-03 after cancel a new photo is backed up normally and confirmed photos are untouched`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.trigger()
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        rig.photo(2, generation = 2)
        rig.photo(3, generation = 3)
        rig.probeResult = ProbeResult.Unreachable
        rig.trigger()

        val n = rig.engine.cancelRemaining()
        rig.settle()
        assertEquals(2, n.getCompleted())
        assertEquals(OrderState.CONFIRMED, rig.state(1))

        rig.probeResult = ProbeResult.Reachable("e1")
        rig.photo(4, generation = 4)
        rig.trigger()
        assertEquals(listOf(1L, 4L), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.SKIPPED_BY_USER, rig.state(2))
        rig.close()
    }

    // X-04 / #415 裁决 5：改范围当场不写任何 order；正在传的那张传完；下一张按新范围检查。
    // 反证：prepareExisting / 快路径不按新范围检查（inScope 恒 true）→ #2 仍被传，红。
    @Test
    fun `X-04 shrinking the scope writes nothing now, lets the current photo finish, and applies before the next`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        val other = rig.photo(2, generation = 2, bucketId = 8)
        rig.media.scope = setOf(7L, 8L)
        rig.order(other, OrderState.QUEUED)
        rig.delivery.hold = true
        rig.trigger()
        assertEquals(listOf(2L), rig.delivery.deliveredMediaIds) // ② QUEUED 先
        val before = rig.store.allRows()

        rig.media.scope = setOf(8L) // 去掉相册 7
        rig.settle()
        assertEquals("changing scope writes nothing", before, rig.store.allRows())

        rig.delivery.release()
        rig.settle()
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        assertEquals("the removed album's photo is not started", listOf(2L), rig.delivery.deliveredMediaIds)
        assertNull(rig.state(1))
        rig.close()
    }

    // X-05：暂停后 Continue，续传的是同一行 order（同一个 queue_sequence，桌面按块续传）。
    @Test
    fun `X-05 continue resumes the same order row`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        rig.trigger()
        rig.engine.pause()
        rig.settle()
        rig.delivery.release()
        rig.engine.continueFlow()
        rig.settle()
        assertEquals(2, rig.delivery.requests.size)
        assertEquals(rig.delivery.requests[0].orderId, rig.delivery.requests[1].orderId)
        assertEquals(rig.delivery.requests[0].leaseToken, rig.delivery.requests[1].leaseToken)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        rig.close()
    }

    // X-06：暂停中把它的相册移出范围 → Continue 时这张 CANCELLED_BY_SCOPE，并通知桌面丢掉部分数据。
    // 反证：prepareExisting 删掉 inScope 检查 → 这张被续传完成，红。
    @Test
    fun `X-06 a paused photo whose album left the scope is cancelled on resume and its partial discarded`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        val paused = rig.order(p, OrderState.PAUSED)
        rig.control.pausedFlag = true
        rig.media.scope = setOf(99L)
        rig.engine.continueFlow()
        rig.settle()
        assertEquals(OrderState.CANCELLED_BY_SCOPE, rig.store.get(paused.id)!!.state)
        assertEquals(listOf(paused.id), rig.delivery.discarded)
        assertEquals(0, rig.delivery.requests.size)
        rig.close()
    }

    // X-07：暂停中原图被删 → Continue 时 SKIPPED_SOURCE_MISSING，不当单张失败重试。
    // 反证：prepareExisting 删掉 lookup==null 分支 → 传输端被调用 / 记 FAILED，红。
    @Test
    fun `X-07 a paused photo whose original was deleted becomes SKIPPED_SOURCE_MISSING on resume`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        val paused = rig.order(p, OrderState.PAUSED)
        rig.media.remove(1)
        rig.trigger(TriggerReason.MANUAL)
        assertEquals(OrderState.SKIPPED_SOURCE_MISSING, rig.store.get(paused.id)!!.state)
        assertEquals(0, rig.store.get(paused.id)!!.attempts)
        assertEquals(0, rig.delivery.requests.size)
        rig.close()
    }

    // #415 裁决 5：新增相册立刻跑一次慢路径——历史照片 generation 在 G 之下，快路径看不见。
    // 反证：SCOPE_ADDED.slowPath = false → #1 不传，红。
    @Test
    fun `adding an album triggers a slow path that picks up its old photos`() = runTest {
        val rig = Rig(this)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 100))
        rig.media.scope = setOf(7L)
        rig.photo(1, generation = 5, bucketId = 8)
        rig.trigger()
        assertEquals(0, rig.delivery.requests.size)
        rig.media.scope = setOf(7L, 8L)
        rig.trigger(TriggerReason.SCOPE_ADDED)
        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // ---------------------------------------------------------------- O / E 组

    // O-01 / E-01：快路径新照片 → hash → 建 order → 传输 → CONFIRMED；G 同一次写入推进；确认审计同写。
    @Test
    fun `O-01 a new photo is hashed, gets an order, is sent and confirmed with G and audit in one write`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 7)
        rig.trigger()
        val row = rig.store.currentForMedia(1)!!
        assertEquals(OrderState.CONFIRMED, row.state)
        assertEquals(p.hash, row.contentHash)
        assertEquals(7L, rig.store.volumeState(LEGACY_VOLUME)!!.fastPathGeneration)
        assertTrue(rig.store.audits().any { it.kind == AuditKinds.ITEM_CONFIRMED && it.payload["queueSequence"] == row.id.toString() })
        // queue_sequence / lease_token 用 order 行 id 填（线协议不变）。
        assertEquals(row.id, rig.delivery.requests.single().orderId)
        assertEquals("lease-${row.id}", rig.delivery.requests.single().leaseToken)
        rig.close()
    }

    // O-07：确认写入中途崩溃 → CONFIRMED、G、审计要么都在要么都不在（此时行仍可续传，重启后再传一次）。
    // 反证：把 G 推进从 transition 里拆成随后单独一次 advanceGeneration → 崩溃落在第二次写入，留下「CONFIRMED 但 G 没推进」，红。
    @Test
    fun `O-07 confirmation, G and audit commit together or not at all`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 9)
        rig.delivery.onStart = { rig.store.crashWhenGenerationMoves = true }
        rig.trigger()
        val row = rig.store.currentForMedia(1)!!
        assertFalse(row.state == OrderState.CONFIRMED)
        assertEquals(0L, rig.store.volumeState(LEGACY_VOLUME)!!.fastPathGeneration)
        assertTrue(rig.store.audits().none { it.kind == AuditKinds.ITEM_CONFIRMED })
        rig.close()
    }

    // O-08：已确认的照片桌面上没了、手机原图还在 → 慢路径自动补传（新一行 QUEUED，取件顺序 ②）。
    // 反证：runRemotePresence 只记审计不插 QUEUED → 不补传，红。
    @Test
    fun `O-08 a confirmed photo missing on the desktop is re-sent automatically`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        rig.trigger()
        assertEquals(1, rig.delivery.requests.size)
        rig.missingOnDesktop = setOf(p.hash)
        rig.trigger(TriggerReason.PERIODIC)
        rig.missingOnDesktop = emptySet()
        assertEquals(listOf(1L, 1L), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertTrue(rig.presenceCalls >= 1)
        rig.close()
    }

    // O-11 / #415 裁决 2：桌面缺、手机原图也没了 → 只记审计 unrecoverable，CONFIRMED 不改写。
    @Test
    fun `O-11 missing on both sides only records an unrecoverable audit`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        rig.trigger()
        rig.media.remove(1)
        rig.missingOnDesktop = setOf(p.hash)
        rig.trigger(TriggerReason.PERIODIC)
        val row = rig.store.currentForMedia(1)!!
        assertEquals(OrderState.CONFIRMED, row.state)
        assertTrue(row.sourceMissing)
        assertTrue(rig.store.audits().any { it.payload["disposition"] == "UNRECOVERABLE" && it.payload["contentHash"] == p.hash })
        assertEquals(1, rig.delivery.requests.size)
        rig.close()
    }

    // O-09：FAILED 每次慢路径只重试一次；再失败仍 FAILED；不在同一次慢路径里反复重试。
    // 反证：去掉慢路径第 3 步（FAILED → QUEUED）→ #1 永不再试，红。
    @Test
    fun `O-09 FAILED photos are retried once per slow path`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        val failed = rig.order(p, OrderState.FAILED)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 1))
        repeat(4) { rig.delivery.script += { DeliveryOutcome.ItemFailure("still broken") } }

        rig.trigger(TriggerReason.PERIODIC)
        assertEquals("one retry = one attempt with its immediate re-try", 2, rig.delivery.requests.size)
        assertEquals(OrderState.FAILED, rig.store.get(failed.id)!!.state)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals("non-slow triggers do not retry FAILED", 2, rig.delivery.requests.size)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(4, rig.delivery.requests.size)
        rig.close()
    }

    // O-04：编辑过的照片按新版本传；旧版本的 CONFIRMED 行保留。
    @Test
    fun `O-04 an edited photo is sent as a new version and the old confirmation stays`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1, content = "before")
        rig.trigger()
        val old = rig.store.currentForMedia(1)!!
        rig.media.put(p.copy(modified = p.modified + 1, content = "after", generation = 2))
        rig.trigger()
        assertEquals(OrderState.CONFIRMED, rig.store.get(old.id)!!.state)
        val edited = rig.store.currentForMedia(1)!!
        assertTrue(edited.id > old.id)
        assertEquals(OrderState.CONFIRMED, edited.state)
        assertEquals(com.hawkeyexb.ppass.backup.order.fakeHashOf("after"), edited.contentHash)
        rig.close()
    }
}
