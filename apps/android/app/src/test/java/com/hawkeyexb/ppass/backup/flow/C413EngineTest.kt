// #413 三层模型 + 依赖倒置循环的契约测试：取件优先级、计数互斥、状态机、取消边界、暂停只改意图、
// 旧版本清理、G 只由新照片推进、错误分类、失败重试上限、FGS 之前不读文件。
// 真实的 FlowEngine + InMemoryOrderStore + FakeMedia；导入、传输、FGS、调度、桌面探测是计数的假端口。
// 每条附反证（去掉对应的实现这一条必须红），写在测试上方。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.GenerationAdvance
import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.NewOrder
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.OrderStore
import com.hawkeyexb.ppass.backup.order.SkipTarget
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C413EngineTest {

    // ---------------------------------------------------------------- 取件优先级

    // 固定优先级：遗留续传 → 对账扫描（G 以下）→ 新照片（G 之后）→ 对账补传（待传输 / 失败重试）。
    // 反证：pickNext 把 discoveryStep 挪到 scanStep 之前 → 顺序变成 A, C, B, …，红。
    @Test
    fun `pick order is legacy resume, then the reconcile scan, then new photos, then re-uploads and retries`() = runTest {
        val rig = Rig(this)
        val legacy = rig.photo(1, generation = 1)
        val old = rig.photo(2, generation = 2)
        val fresh = rig.photo(3, generation = 10)
        val reupload = rig.photo(4, generation = 3)
        val failed = rig.photo(5, generation = 4)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 5))
        rig.order(legacy, OrderState.TRANSFERRING)
        rig.order(reupload, OrderState.PENDING)
        val f = rig.order(failed, OrderState.TRANSFERRING)
        rig.store.transition(f.id, setOf(OrderState.TRANSFERRING), OrderState.FAILED, countAttempt = true)
        rig.store.markScanDirty()

        rig.trigger(TriggerReason.APP_FOREGROUND)

        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), rig.delivery.deliveredMediaIds)
        assertTrue((1L..5L).all { rig.state(it) == OrderState.CONFIRMED })
        assertFalse("scan finished", rig.store.scanState().dirty)
        assertEquals(0, rig.pending())
        rig.close()
    }

    // 失败重试只在对账轮；待传输（补传）任何一轮都取。
    // 反证：非对账轮也把 FAILED 放进来源 → MEDIA_CHANGE 这一轮就重传了 #5，红。
    @Test
    fun `failed rows are retried only by a reconcile round`() = runTest {
        val rig = Rig(this)
        val failed = rig.photo(5, generation = 4)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 5))
        val f = rig.order(failed, OrderState.TRANSFERRING)
        rig.store.transition(f.id, setOf(OrderState.TRANSFERRING), OrderState.FAILED, countAttempt = true)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(0, rig.delivery.requests.size)
        assertEquals("no work → no FGS", 0, rig.foreground.acquires)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(listOf(5L), rig.delivery.deliveredMediaIds)
        assertEquals(f.id, rig.delivery.requests.single().orderId)
        rig.close()
    }

    // ---------------------------------------------------------------- G 只由新照片推进

    // 已有 order（遗留续传）提交不推进 G：否则 G 被它的 generation 推高，跳过中间还没取到的新照片。
    // 反证：已有 order 的 Progress 带上 GenerationAdvance(lookup 的 generation) → G 跳到 10，#2 永远取不到，红。
    @Test
    fun `committing an existing order never moves G past a new photo`() = runTest {
        val rig = Rig(this)
        val legacy = rig.photo(1, generation = 10)
        rig.photo(2, generation = 5)
        rig.order(legacy, OrderState.TRANSFERRING)
        val gAtSecond = mutableListOf<Long>()
        rig.delivery.onStart = { if (it.details.snapshot.mediaId == 2L) gAtSecond += rig.generation() }

        rig.trigger()

        assertEquals(listOf(1L, 2L), rig.delivery.deliveredMediaIds)
        assertEquals("the legacy commit left G alone", listOf(0L), gAtSecond)
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        rig.close()
    }

    // 扫描来源提交只推进 S，不推进 G；新照片提交推进 G。
    // 反证：progressOf(SCAN) 也带 GenerationAdvance → 扫到 #1 时 G 变成 20，#3 开始时看到的 G ≠ 30，红。
    @Test
    fun `a reconcile scan commit moves S and leaves G to new photos`() = runTest {
        val rig = Rig(this)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 30))
        rig.photo(1, generation = 20)
        rig.photo(3, generation = 31)
        rig.store.markScanDirty()
        val gAtNew = mutableListOf<Long>()
        rig.delivery.onStart = { if (it.details.snapshot.mediaId == 3L) gAtNew += rig.generation() }

        rig.trigger()

        assertEquals(listOf(1L, 3L), rig.delivery.deliveredMediaIds)
        assertEquals(listOf(30L), gAtNew)
        assertEquals(31L, rig.generation())
        rig.close()
    }

    // 同一次批量写入的多张照片 generation 相同：G 带上 _id，不会把同一拍里还没轮到的一起跳过。
    // 反证：GenerationAdvance 只按 generation 取大（readChangedSince 只用 generation > G）→ #2 永远取不到，红。
    @Test
    fun `photos sharing one generation are all picked`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 7)
        rig.photo(2, generation = 7)
        rig.delivery.script += { DeliveryOutcome.PathFailure("fetch_failed") }
        rig.trigger()
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        rig.trigger()
        assertEquals(listOf(1L, 1L, 2L), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        rig.close()
    }

    // ---------------------------------------------------------------- 计数：精确、互斥、不重复

    // 待办 = 范围内照片 − 跳过名单 − 已有结局。中断的新照片（传输中 + generation > G）两个来源都看得到，只算一次；
    // 脏 / 不脏两条计数路径、取消弹窗的 N 三者相等。
    // 反证：不脏路径不按 media_id 去重（新照片数 + 在途 order 数直接相加）→ 4 ≠ 3，红。
    @Test
    fun `the todo count is exact and each photo is counted once whichever path computes it`() = runTest {
        val rig = Rig(this)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 5))
        val interrupted = rig.photo(10, generation = 10)
        rig.photo(11, generation = 11)
        val confirmed = rig.photo(2, generation = 2)
        val skipped = rig.photo(3, generation = 3)
        rig.photo(4, generation = 12, bucketId = 99)
        val failed = rig.photo(1, generation = 1)
        rig.order(interrupted, OrderState.TRANSFERRING)
        rig.order(confirmed, OrderState.CONFIRMED)
        rig.store.cancelRemaining(listOf(SkipTarget(skipped.mediaId, skipped.snapshot.sourceVersion, 7)))
        val f = rig.order(failed, OrderState.TRANSFERRING)
        rig.store.transition(f.id, setOf(OrderState.TRANSFERRING), OrderState.FAILED, countAttempt = true)
        rig.control.pausedFlag = true

        rig.trigger(TriggerReason.MEDIA_CHANGE) // 暂停中：只重算
        assertEquals("not dirty", 3, rig.pending())
        rig.store.markScanDirty()
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals("dirty (full diff)", 3, rig.pending())
        assertEquals(3, rig.engine.remainingSnapshot().count)
        assertTrue(rig.engine.pendingKnown.value)
        rig.close()
    }

    // 一轮跑完待办归零，且随提交递减；本轮已完成计数。
    @Test
    fun `after a clean round nothing is left and the round counted its photos`() = runTest {
        val rig = Rig(this)
        (1L..3L).forEach { rig.photo(it, generation = it) }
        val seen = mutableListOf<Int>()
        rig.delivery.progress = { _, _ ->
            kotlinx.coroutines.delay(10) // 让视图的收集方跟上
            seen += rig.pending()
        }
        rig.trigger()
        assertEquals(listOf(3, 2, 1), seen)
        assertEquals(0, rig.pending())
        assertEquals(3, rig.engine.view.value.doneThisRound)
        assertEquals(GlobalState.IDLE, rig.engine.view.value.state)
        rig.close()
    }

    // ---------------------------------------------------------------- 状态机

    // pause 只在 RUNNING；暂停后在飞的那张保持「传输中」（没有 PAUSED 状态）、不计次数、释放 FGS；
    // resume 只在 PAUSED，续传同一行（同一个 tuple）。
    // 反证：pause 不看状态 → IDLE 时也写暂停标志，第一条断言红；finally 里把在飞的改成别的状态 → 第二组红。
    @Test
    fun `pause works only while running, keeps the in-flight order transferring, and resume continues the same order`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        assertFalse(rig.engine.pause().also { rig.settle() }.await())
        assertFalse(rig.control.pausedFlag)
        assertFalse("resume in IDLE", rig.engine.resume().also { rig.settle() }.await())

        rig.delivery.hold = true
        rig.trigger()
        assertEquals(GlobalState.RUNNING, rig.engine.view.value.state)
        val first = rig.store.currentForMedia(1)!!
        assertTrue(rig.engine.pause().also { rig.settle() }.await())
        rig.delivery.release()
        rig.settle()

        assertEquals(GlobalState.PAUSED, rig.engine.view.value.state)
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(listOf(first.id), rig.delivery.cancelled)
        assertEquals(1, rig.foreground.releases)
        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)

        assertTrue(rig.engine.resume().also { rig.settle() }.await())
        assertEquals(listOf(1L, 1L, 2L), rig.delivery.deliveredMediaIds)
        assertEquals("resumed on the same tuple", first.id, rig.delivery.requests[1].orderId)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals(GlobalState.IDLE, rig.engine.view.value.state)
        rig.close()
    }

    // cancelRemaining 只在 PAUSED / WAITING；取消后清除暂停标志 → IDLE。
    // 反证：cancelRemaining 不清暂停标志 → state 仍是 PAUSED，红。
    @Test
    fun `cancel works only while paused or waiting and leaves the engine idle and unpaused`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        val idleSnapshot = rig.engine.remainingSnapshot()
        assertNull("IDLE", rig.engine.cancelRemaining(idleSnapshot).also { rig.settle() }.await())

        rig.probeResult = ProbeResult.Unreachable
        rig.trigger()
        assertEquals(GlobalState.WAITING, rig.engine.view.value.state)
        assertEquals("persisted", WaitReason.DESKTOP_UNREACHABLE, rig.control.wait)
        assertEquals(1, rig.engine.cancelRemaining(rig.engine.remainingSnapshot()).also { rig.settle() }.await())
        assertEquals(GlobalState.IDLE, rig.engine.view.value.state)
        assertNull(rig.control.wait)

        rig.photo(2, generation = 2)
        rig.control.pausedFlag = true
        assertEquals(1, rig.engine.cancelRemaining(rig.engine.remainingSnapshot()).also { rig.settle() }.await())
        assertFalse(rig.control.pausedFlag)
        assertEquals(GlobalState.IDLE, rig.engine.view.value.state)
        assertEquals(2L, rig.store.countSkipped())
        rig.close()
    }

    // 取消边界 = 弹窗那一刻：弹窗之后新拍的照片不被跳过；在飞的那张改成用户跳过并丢弃半截。写下的张数 = 弹窗上的 N。
    // 反证：cancelRemaining 在确认时重算目标（todoTargets()）而不是用 snapshot → #3 也被跳过，红。
    @Test
    fun `cancel skips exactly the photos shown in the dialog`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.delivery.hold = true
        rig.trigger()
        val inFlight = rig.store.currentForMedia(1)!!
        rig.engine.pause().await()
        rig.delivery.release()
        rig.settle()

        val snapshot = rig.engine.remainingSnapshot()
        assertEquals(2, snapshot.count)
        rig.photo(3, generation = 3) // 弹窗之后新拍
        val written = rig.engine.cancelRemaining(snapshot).also { rig.settle() }.await()

        assertEquals(snapshot.count, written)
        assertEquals(OrderState.SKIPPED_BY_USER, rig.state(1))
        assertTrue(rig.store.isSkipped(1) && rig.store.isSkipped(2))
        assertFalse(rig.store.isSkipped(3))
        assertEquals(listOf(inFlight.id), rig.delivery.discarded)
        assertEquals(1, rig.pending())

        rig.trigger()
        assertEquals("only the photo taken after the dialog", listOf(1L, 3L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // ---------------------------------------------------------------- 暂停期间只改意图

    // 暂停中：恢复已跳过、勾选新相册都只改意图（名单清空、扫描置脏、待办重算），不探测、不申请 FGS、不读文件；
    // 继续之后，G 以下的恢复照片与新相册的历史照片都由对账扫描取到。
    // 反证：restoreSkipped 只删名单不置脏 → 恢复的 #1 在 G 以下永远取不到，红；暂停中 SCOPE_ADDED 不置脏 → #5 取不到，红。
    @Test
    fun `while paused only intent changes and resuming picks up restored photos and a new album's history`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(5, generation = 2, bucketId = 8) // 新相册里的老照片
        rig.store.cancelRemaining(listOf(SkipTarget(1, rig.media.photos.first { it.mediaId == 1L }.snapshot.sourceVersion, 7)))
        rig.trigger() // 没有待办：G 走过 #1（在名单里）
        assertEquals(0, rig.delivery.requests.size)
        assertTrue(rig.generation() >= 1)
        rig.control.pausedFlag = true

        rig.engine.restoreSkipped().also { rig.settle() }.await()
        rig.media.scope = setOf(7L, 8L)
        rig.trigger(TriggerReason.SCOPE_ADDED)

        assertEquals(0, rig.delivery.requests.size)
        assertEquals(0, rig.probes)
        assertEquals(0, rig.foreground.acquires)
        assertEquals(0, rig.importer.imported.size)
        assertTrue(rig.store.scanState().dirty)
        assertEquals(0L, rig.store.countSkipped())
        assertEquals(2, rig.pending())

        rig.engine.resume().also { rig.settle() }.await()
        assertEquals(listOf(1L, 5L), rig.delivery.deliveredMediaIds)
        assertEquals(0, rig.pending())
        rig.close()
    }

    // ---------------------------------------------------------------- 旧版本 / 源已删

    // 中断期间照片被编辑（MediaStore 版本变了）：旧行「传输中」→ 源已删 + cancel_tuple，不计失败；新版本另起一行。
    // 反证：processExisting 不比版本、直接续传 → 旧行被续传（requests 里出现旧 id），红。
    @Test
    fun `an old version left transferring is dropped as source missing and the new version gets a new row`() = runTest {
        val rig = Rig(this)
        val v1 = rig.photo(1, generation = 1, content = "old")
        val old = rig.order(v1, OrderState.TRANSFERRING)
        rig.media.put(v1.copy(modified = 999, content = "new", generation = 2))

        rig.trigger()

        assertEquals(OrderState.SKIPPED_SOURCE_MISSING, rig.store.get(old.id)!!.state)
        assertEquals(0, rig.store.get(old.id)!!.attempts)
        assertEquals(listOf(old.id), rig.delivery.discarded)
        val fresh = rig.store.currentForMedia(1)!!
        assertNotEquals(old.id, fresh.id)
        assertEquals(OrderState.CONFIRMED, fresh.state)
        assertEquals(listOf(fresh.id), rig.delivery.requests.map { it.orderId })
        rig.close()
    }

    // 版本没跟上但内容变了（导入出来的 hash 与行里记的不符）：同样源已删 + cancel_tuple，放掉这次导入。
    // 反证：去掉 hash 比对 → 旧 tuple 带着新内容续传，requests 非空，红。
    @Test
    fun `a legacy order whose imported hash no longer matches is dropped, discarded and released`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        val old = rig.order(p, OrderState.TRANSFERRING)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 1))
        rig.importer.hashOverride[1] = "blake3:edited"

        rig.trigger()

        assertEquals(OrderState.SKIPPED_SOURCE_MISSING, rig.store.get(old.id)!!.state)
        assertEquals(listOf(old.id), rig.delivery.discarded)
        assertEquals(listOf("blake3:edited"), rig.importer.released)
        assertEquals(0, rig.delivery.requests.size)
        rig.close()
    }

    // 在途的这张所在相册被移出范围：不续传、丢弃半截、从待办消失（范围是查询条件）。
    // 反证：processExisting 不查范围 → 被续传，红。
    @Test
    fun `an in-flight order whose album left the scope is not resumed and its partial is discarded`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        val o = rig.order(p, OrderState.TRANSFERRING)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 1))
        rig.media.scope = setOf(99L)
        rig.trigger()
        assertEquals(0, rig.delivery.requests.size)
        assertEquals(listOf(o.id), rig.delivery.discarded)
        assertEquals(OrderState.PENDING, rig.state(1))
        assertEquals(0, rig.pending())
        rig.close()
    }

    // ---------------------------------------------------------------- 错误分类在引擎里的落点

    // 对端失败：退出循环、不计次数、「传输中」保持、等待原因按种类；路径失败：同上 + 挂探测；源已删：不计失败。
    // 反证：PeerFailure 走 fail() → FAILED / attempts=1，红；SourceMissing 当 ItemFailure → FAILED，红。
    @Test
    fun `peer, path and source-missing outcomes never count a failure`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.script += { DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_FULL, "storage_full") }
        rig.trigger()
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(WaitReason.DESKTOP_STORAGE_FULL, rig.engine.view.value.waitReason)
        assertEquals(GlobalState.WAITING, rig.engine.view.value.state)

        rig.delivery.script += { DeliveryOutcome.PathFailure("fetch_failed") }
        rig.trigger()
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals(WaitReason.DESKTOP_UNREACHABLE, rig.engine.view.value.waitReason)
        assertEquals(1, rig.scheduler.unreachableProbes)

        rig.delivery.script += { DeliveryOutcome.SourceMissing }
        rig.trigger()
        assertEquals(OrderState.SKIPPED_SOURCE_MISSING, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(0, rig.pending())
        rig.close()
    }

    // 桌面不健康（探测带回 library_writable=false）→ 不申请 FGS，等待中（具体原因）。
    @Test
    fun `an unhealthy desktop keeps the loop waiting without the foreground service`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = 1L, libraryWritable = false))
        rig.trigger()
        assertEquals(0, rig.foreground.acquires)
        assertEquals(WaitReason.DESKTOP_LIBRARY_UNAVAILABLE, rig.engine.view.value.waitReason)
        assertEquals(DesktopHealth(1L, libraryWritable = false), rig.engine.view.value.desktopHealth)
        rig.close()
    }

    // ---------------------------------------------------------------- 失败重试上限

    // 单张失败当场重试 1 次 → FAILED（1 次）；兜底对账再试 1 次 → FAILED（2 次）；之后保持失败，不再自动重试。
    // 反证：pickNext 不看 attempts 上限 → 第三轮对账又传，requests = 6，红。
    @Test
    fun `a failing photo is retried once on the spot and once by reconciliation, then stays failed`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        repeat(8) { rig.delivery.script += { DeliveryOutcome.ItemFailure("boom") } }
        rig.trigger()
        assertEquals(2, rig.delivery.requests.size)
        assertEquals(1, rig.store.currentForMedia(1)!!.attempts)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(4, rig.delivery.requests.size)
        assertEquals(OrderStore.MAX_FAILURES, rig.store.currentForMedia(1)!!.attempts)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(4, rig.delivery.requests.size)
        assertEquals(OrderState.FAILED, rig.state(1))
        assertEquals("still todo", 1, rig.pending())
        assertEquals("the same row every time", 1, rig.delivery.requests.map { it.orderId }.distinct().size)
        rig.close()
    }

    // ---------------------------------------------------------------- 对账补传

    // 桌面缺失的已确认照片：新建一行（不复用原 order id——桌面对已完成的同编号直接回完成），在 FGS 之后问。
    // 反证：补传沿用原行 id → requests 里的 id 等于旧 id，红。
    @Test
    fun `a confirmed photo missing on the desktop is re-uploaded on a new row`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        val old = rig.order(p, OrderState.CONFIRMED)
        rig.store.advanceGeneration(GenerationAdvance(LEGACY_VOLUME, 1))
        rig.missingOnDesktop = setOf(p.hash)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(1, rig.presenceCalls)
        val row = rig.store.currentForMedia(1)!!
        assertNotEquals(old.id, row.id)
        assertEquals(listOf(row.id), rig.delivery.requests.map { it.orderId })
        assertEquals(OrderState.CONFIRMED, row.state)
        rig.close()
    }

    // ---------------------------------------------------------------- FGS 之前不读文件 / 不走 presence

    // 入口只读元数据：FGS 被拒、桌面不可达时，一张都不导入，也不问桌面「还在吗」。
    // 反证：把导入挪回入口（旧的「取件时算 hash」）→ imported 非空，红。
    @Test
    fun `nothing is read or asked of the desktop before the foreground service is held`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.order(p, OrderState.CONFIRMED)
        rig.missingOnDesktop = setOf(p.hash)
        rig.foreground.grant = false
        rig.trigger(TriggerReason.APP_FOREGROUND)
        rig.probeResult = ProbeResult.Unreachable
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(0, rig.importer.imported.size)
        assertEquals(0, rig.presenceCalls)
        assertEquals(0, rig.delivery.requests.size)
        rig.close()
    }

    // FGS 被拒 → 等待中；下一次触发照常再申请（不再卡到回前台）；拿到就清受阻原因。
    // 反证：把受阻原因当闸门 → 第二次触发不申请，红。
    @Test
    fun `a refused foreground start waits and the next trigger simply tries again`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.foreground.grant = false
        rig.trigger()
        assertEquals(1, rig.foreground.startForegroundServiceCalls)
        assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
        assertEquals(FgsBlockReason.START_REFUSED, rig.control.block)
        rig.foreground.grant = true
        rig.trigger()
        assertEquals(2, rig.foreground.startForegroundServiceCalls)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertNull(rig.control.block)
        rig.close()
    }

    // onLost（没有任何网络）→ 在飞的这张立即判路径失败：停循环、保持传输中、等待中、挂探测。
    @Test
    fun `losing the network stops the in-flight item as a path failure`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        rig.trigger()
        rig.engine.onNetworkLost()
        rig.settle()
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals(WaitReason.DESKTOP_UNREACHABLE, rig.control.wait)
        assertEquals(1, rig.scheduler.unreachableProbes)
        assertEquals(1, rig.foreground.releases)
        rig.close()
    }

    // G 缺失（新装）：G 从当前最大 generation 起步、扫描置脏，已有照片由扫描按 `_id` 取完。
    @Test
    fun `a fresh install scans the existing library by id and starts G at the newest photo`() = runTest {
        val rig = Rig(this, cursors = false)
        rig.photo(2, generation = 9)
        rig.photo(1, generation = 3)
        rig.trigger()
        assertEquals(listOf(1L, 2L), rig.delivery.deliveredMediaIds)
        assertEquals(9L, rig.generation())
        assertFalse(rig.store.scanState().dirty)
        rig.close()
    }

    // 导入时原图读不到（MediaStore 还列着）：记源已删（同版本即结局），不再算待办，G 照常推进、不计失败。
    // 反证：SourceMissing 不落行（只推进 G）→ 这张永远留在待办里，pending = 1，红。
    @Test
    fun `a listed photo whose file cannot be read is settled as source missing`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.importer.unreadable += 1L
        rig.trigger()
        assertEquals(OrderState.SKIPPED_SOURCE_MISSING, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(0, rig.pending())
        assertEquals(1L, rig.generation())
        rig.close()
    }

    // 导入抛错：当场重试 1 次；仍失败记一次失败（有上限），G 推进，不在这张上打转。
    @Test
    fun `an import that throws twice counts one failure and moves on`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.importer.failures += java.io.IOException("x")
        rig.importer.failures += java.io.IOException("y")
        rig.trigger()
        assertEquals(OrderState.FAILED, rig.state(1))
        assertEquals(1, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(listOf(1L, 1L, 2L), rig.importer.imported)
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        rig.close()
    }

    // ---------------------------------------------------------------- 模拟器回归（W5 报告）

    // 设计 §2：先计数、再查条件。等待中（后台备份关闭）时首页的「待备份」是真实张数，不是 0；等待原因落进持久化。
    // 反证：把计数挪回条件检查之后 → settle 时 pending 还是 0，红。
    @Test
    fun `the count comes before the conditions so a waiting home screen still shows the backlog`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.conditions = Conditions(autoBackupEnabled = false)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(GlobalState.WAITING, rig.engine.view.value.state)
        assertEquals(WaitReason.DISABLED, rig.engine.view.value.waitReason)
        assertEquals(WaitReason.DISABLED, rig.control.wait)
        assertEquals(2, rig.pending())
        rig.close()
    }

    // 检查阶段（还没申请到 FGS）报 RUNNING，不报 IDLE。
    @Test
    fun `the checking phase is reported as running`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        val seen = mutableListOf<GlobalState>()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val probed = FlowEngineProbeHold(gate)
        rig.probeHook = { probed.hold() }
        rig.engine.trigger(TriggerReason.MEDIA_CHANGE)
        rig.settle()
        seen += rig.engine.view.value.state
        gate.complete(Unit)
        rig.settle()
        assertEquals(listOf(GlobalState.RUNNING), seen)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        rig.close()
    }

    // 恢复已跳过之后：MediaProvider 给出重复的行也不崩、照常传完（旧 DiffPlanner 在这里抛过 strictly ascending）。
    // 反证：todoTargets 去掉重复行保护 → 计数多算 1，红。
    @Test
    fun `restore keeps working when the media store repeats a row`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.cancelRemainingNow().also { rig.settle() }.await()
        rig.media.duplicateInScope = setOf(2L)
        rig.engine.restoreSkipped().also { rig.settle() }.await()
        assertEquals(listOf(1L, 2L), rig.delivery.deliveredMediaIds)
        assertEquals(0, rig.pending())
        assertEquals(0, rig.engine.remainingSnapshot().count)
        rig.close()
    }
}

/** 让探测挂在一个闸门上（看检查阶段的视图）。 */
internal class FlowEngineProbeHold(private val gate: kotlinx.coroutines.CompletableDeferred<Unit>) {
    suspend fun hold() = gate.await()
}
