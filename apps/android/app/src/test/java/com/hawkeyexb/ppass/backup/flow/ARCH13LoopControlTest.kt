// ARCH-13 (#417) E2：Case Matrix C 组（逐张循环与消费控制）的契约测试。
//
// 真实的 FlowEngine + InMemoryOrderStore + FakeMedia；传输、FGS、调度、桌面探测是计数的假端口。
// 故障类判据都附反证（写在测试上方）；反证输出见 #417 报告。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH13LoopControlTest {

    // C-01：传输中暂停 → 退出循环、释放 FGS；当前这张保持可续传（PAUSED）；下一张不开始。
    // 反证：pause() 不 cancel 循环（删掉 cycleJob?.cancelAndJoin()）→ 放行后第二张照样开始，红。
    @Test
    fun `C-01 pause mid-transfer stops the loop, releases the foreground service and keeps the order resumable`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.delivery.hold = true
        rig.trigger()
        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)
        assertTrue(rig.foreground.held)

        rig.engine.pause()
        rig.settle()
        rig.delivery.release()
        rig.settle()

        assertEquals("no second photo after pause", listOf(1L), rig.delivery.deliveredMediaIds)
        assertEquals(listOf(rig.store.currentForMedia(1)!!.id), rig.delivery.cancelled)
        assertEquals(OrderState.PAUSED, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(1, rig.foreground.releases)
        assertTrue(!rig.foreground.held)
        rig.close()
    }

    // C-02：暂停后任何触发都不发、不申请 FGS、连桌面都不探。
    // 反证：删掉 onTrigger 里的暂停检查（与 runCycle 开头的第二道）→ 触发起循环，acquires/deliveries > 0，红。
    @Test
    fun `C-02 while paused no trigger of any kind sends, probes or requests the foreground service`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.engine.pause()
        rig.settle()
        TriggerReason.entries.forEach { rig.trigger(it) }
        rig.engine.onAppForeground()
        rig.engine.onNetworkChanged()
        rig.settle()

        assertEquals(0, rig.delivery.requests.size)
        assertEquals(0, rig.foreground.acquires)
        assertEquals(0, rig.probes)
        assertTrue(rig.control.pausedFlag)
        rig.close()
    }

    // C-03：Continue 后的取件顺序：① 未完成 → ② QUEUED → ③ 快路径下一张。
    // 反证：pickNext 先走快路径（把 fastPathStep 提到 currentInStates 之前）→ 顺序变成 3 在前，红。
    @Test
    fun `C-03 continue resumes the unfinished order first, then queued, then the fast path`() = runTest {
        val rig = Rig(this)
        val fresh = rig.photo(3, generation = 30)
        val queued = rig.photo(2, generation = 1)
        val half = rig.photo(1, generation = 2)
        rig.store.advanceGeneration(com.hawkeyexb.ppass.backup.order.GenerationAdvance(com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME, 5))
        rig.order(queued, OrderState.QUEUED)
        rig.order(half, OrderState.PAUSED)
        rig.control.pausedFlag = true

        rig.engine.continueFlow()
        rig.settle()

        assertEquals(listOf(half.mediaId, queued.mediaId, fresh.mediaId), rig.delivery.deliveredMediaIds)
        assertEquals(listOf(OrderState.CONFIRMED, OrderState.CONFIRMED, OrderState.CONFIRMED), listOf(1L, 2L, 3L).map { rig.state(it) })
        rig.close()
    }

    // C-04：条件不满足（仅 Wi‑Fi 却在移动网络 / 电量低 / 桌面不可达）→ worker 里就停，不申请 FGS，登记对应唤醒。
    // 反证：把 waitReasonOf 检查挪到 foreground.acquire() 之后 → acquires = 1，红。
    @Test
    fun `C-04 unmet conditions never request the foreground service and register the matching wake`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)

        rig.conditions = Conditions(wifiOnly = true, onUnmetered = false)
        rig.trigger()
        assertEquals(WaitReason.WIFI, rig.engine.status.value.waitReason)
        assertEquals(listOf(WaitReason.WIFI), rig.scheduler.constraintWakes)

        rig.conditions = Conditions(batteryLow = true)
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(WaitReason.BATTERY, rig.engine.status.value.waitReason)
        rig.probeResult = ProbeResult.Unreachable
        rig.trigger(TriggerReason.MANUAL) // 人在场不查电量，但桌面这时不可达
        assertEquals(WaitReason.DESKTOP_UNREACHABLE, rig.engine.status.value.waitReason)
        rig.conditions = Conditions()

        assertEquals(0, rig.foreground.acquires)
        assertEquals(0, rig.delivery.requests.size)
        rig.close()
    }

    // #417 重点场景：桌面不可达时不申请 FGS，也不给单张计次；登记 3 次间隔 10 分钟的探测。
    // 反证：删掉 Unreachable 分支的 return（直接进入申请 FGS 与传输）→ acquires / deliveries > 0，红。
    @Test
    fun `desktop unreachable - no foreground service, no attempt counted, probes scheduled`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        val paused = rig.order(p, OrderState.PAUSED)
        rig.probeResult = ProbeResult.Unreachable

        rig.trigger()
        rig.trigger(TriggerReason.NETWORK_CHANGE)

        assertEquals(0, rig.foreground.acquires)
        assertEquals(0, rig.delivery.requests.size)
        assertEquals(OrderState.PAUSED, rig.store.get(paused.id)!!.state)
        assertEquals("no attempt counted", 0, rig.store.get(paused.id)!!.attempts)
        assertEquals(WaitReason.DESKTOP_UNREACHABLE, rig.engine.status.value.waitReason)
        assertEquals(2, rig.scheduler.unreachableProbes)

        rig.probeResult = ProbeResult.Reachable("e1")
        rig.trigger(TriggerReason.UNREACHABLE_PROBE)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertTrue(rig.scheduler.probesCancelled > 0)
        rig.close()
    }

    // C-05 / #417 重点：等待 Wi‑Fi 时释放 FGS——传输中切到移动网络，循环停、FGS 放、这张可续传、不计次数。
    // 反证：onNetworkChanged 不停循环（只当作一次触发）→ FGS 一直持有、releases = 0，红。
    @Test
    fun `C-05 losing wifi mid-transfer releases the foreground service and keeps the order resumable`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.conditions = Conditions(wifiOnly = true, onUnmetered = true)
        rig.delivery.hold = true
        rig.trigger()
        assertTrue(rig.foreground.held)

        rig.conditions = Conditions(wifiOnly = true, onUnmetered = false)
        rig.engine.onNetworkChanged()
        rig.settle()

        assertEquals(1, rig.foreground.releases)
        assertTrue(!rig.foreground.held)
        assertEquals(OrderState.PAUSED, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(listOf(WaitReason.WIFI), rig.scheduler.constraintWakes)

        rig.conditions = Conditions(wifiOnly = true, onUnmetered = true)
        rig.delivery.release()
        rig.trigger(TriggerReason.CONSTRAINTS_MET)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        rig.close()
    }

    // C-06：3 张一次触发——整个循环只申请一次 FGS，传完释放一次。
    // 反证：把 foreground.acquire() 挪进 loop 的每张里 → acquires = 3，红。
    @Test
    fun `C-06 one foreground service for the whole loop, released once after the last photo`() = runTest {
        val rig = Rig(this)
        (1L..3L).forEach { rig.photo(it, generation = it) }
        rig.trigger()
        assertEquals(listOf(1L, 2L, 3L), rig.delivery.deliveredMediaIds)
        assertEquals(1, rig.foreground.acquires)
        assertEquals(1, rig.foreground.releases)
        assertEquals(LoopPhase.IDLE, rig.engine.status.value.phase)
        rig.close()
    }

    // C-07：每张开始前重检条件与 FGS 有效性。
    // 反证：删掉 loop 里每张前的 waitReasonOf / isHeld 检查 → 第二张照样开始，红。
    @Test
    fun `C-07 conditions and the foreground service are re-checked before every photo`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.conditions = Conditions(wifiOnly = true, onUnmetered = true)
        rig.delivery.onStart = { if (it.details.snapshot.mediaId == 1L) rig.conditions = Conditions(wifiOnly = true, onUnmetered = false) }
        rig.trigger()
        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.CONFIRMED, rig.state(1))

        rig.conditions = Conditions()
        rig.delivery.onStart = { rig.foreground.held = false }
        rig.photo(3, generation = 3)
        rig.trigger()
        assertEquals("FGS lost after #2: #3 not started", listOf(1L, 2L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // C-08 / #414：FGS 被拒只尝试 1 次，没有递归；之后的后台触发不再调用 startForegroundService；
    // 回到前台清掉事实后恢复。
    // 反证：acquire 失败后不记 recordFgsBlock → 之后每次触发都再调一次，startForegroundServiceCalls = 4，红。
    @Test
    fun `C-08 a refused foreground start is tried exactly once and not again until the app is in the foreground`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.foreground.grant = false

        rig.trigger()
        repeat(3) { rig.trigger(TriggerReason.MEDIA_CHANGE) }

        assertEquals(1, rig.foreground.startForegroundServiceCalls)
        assertEquals(FgsBlockReason.START_REFUSED, rig.control.block)
        assertEquals(WaitReason.FGS_BLOCKED, rig.engine.status.value.waitReason)
        assertEquals(0, rig.delivery.requests.size)

        rig.foreground.grant = true
        rig.engine.onAppForeground()
        rig.settle()
        assertEquals(2, rig.foreground.startForegroundServiceCalls)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        rig.close()
    }

    // #414 重点：FGS 超时（onTimeout）→ 停循环、记事实；之后不再调用 start。
    // 反证：onForegroundLost 不 recordFgsBlock → 下一次触发又调 startForegroundService，红。
    @Test
    fun `after a foreground timeout nothing calls start again until the app is in the foreground`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.delivery.hold = true
        rig.trigger()
        assertEquals(1, rig.foreground.startForegroundServiceCalls)

        rig.engine.onForegroundLost(FgsBlockReason.BUDGET_EXHAUSTED)
        rig.settle()
        rig.delivery.release()
        repeat(3) { rig.trigger(TriggerReason.PERIODIC) }

        assertEquals(1, rig.foreground.startForegroundServiceCalls)
        assertEquals(FgsBlockReason.BUDGET_EXHAUSTED, rig.control.block)
        assertEquals(OrderState.PAUSED, rig.state(1))
        assertEquals(1, rig.foreground.releases)
        rig.close()
    }

    // #417 重点：暂停之后，没有任何发送，也没有任何 FGS 申请——包括暂停路径自己（#414 的递归链）。
    @Test
    fun `pausing never requests the foreground service itself`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.engine.pause()
        rig.engine.pause()
        rig.settle()
        assertEquals(0, rig.foreground.acquires)
        assertEquals(0, rig.foreground.startForegroundServiceCalls)
        rig.close()
    }

    // C-09：单张失败立即重试 1 次；仍失败记 FAILED（计 1 次），循环继续下一张。
    // 反证：删掉 process 里的「ItemFailure → 再 deliverOnce 一次」→ #1 只被请求一次，红。
    @Test
    fun `C-09 an item failure is retried once immediately, then recorded FAILED and the loop moves on`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.photo(3, generation = 3)
        rig.delivery.script += { DeliveryOutcome.ItemFailure("read") }
        rig.delivery.script += { r -> FakeDelivery.confirmed(r) }
        rig.delivery.script += { DeliveryOutcome.ItemFailure("read") }
        rig.delivery.script += { DeliveryOutcome.ItemFailure("read") }

        rig.trigger()

        assertEquals(listOf(1L, 1L, 2L, 2L, 3L), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals(OrderState.FAILED, rig.state(2))
        assertEquals(1, rig.store.currentForMedia(2)!!.attempts)
        assertEquals(OrderState.CONFIRMED, rig.state(3))
        rig.close()
    }

    // C-10（引擎侧）：路径失败 → 保持可续传、不计次数、退出循环、释放 FGS、登记探测。
    // 传输侧「3 分钟无新字节判路径失败」见 ARCH13DeliveryPortTest。
    // 反证：把 PathFailure 当 ItemFailure 处理（fail(...)）→ 状态 FAILED、attempts=1，红。
    @Test
    fun `C-10 a path failure keeps the order resumable, counts nothing and ends the loop`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.delivery.script += { DeliveryOutcome.PathFailure("byte_stall") }

        rig.trigger()

        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.PAUSED, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(1, rig.foreground.releases)
        assertEquals(1, rig.scheduler.unreachableProbes)
        assertEquals(WaitReason.DESKTOP_UNREACHABLE, rig.engine.status.value.waitReason)
        rig.close()
    }

    // C-12 / #415 裁决 3：对端失败（storage_failed）→ 退出循环、不计次数、等下一次唤醒。
    // 反证：同 C-10，把 PeerFailure 当单张失败 → FAILED，红。
    @Test
    fun `C-12 a peer failure ends the loop without counting an attempt`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.delivery.script += { DeliveryOutcome.PeerFailure("storage_failed") }

        rig.trigger()

        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.PAUSED, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(WaitReason.PEER_REFUSED, rig.engine.status.value.waitReason)
        rig.close()
    }

    // D-02：循环在跑时再来 3 次触发——只有一个循环，FGS 只申请一次，不重复传。
    // 反证：onTrigger 不看 cycleJob.isActive（每次都起一轮）→ acquires > 1 / 重复请求，红。
    @Test
    fun `D-02 triggers during a running loop coalesce into it`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        rig.trigger()
        repeat(3) { rig.trigger(TriggerReason.MEDIA_CHANGE) }
        assertEquals(1, rig.delivery.requests.size)
        rig.delivery.release()
        rig.settle()
        assertEquals(listOf(1L), rig.delivery.deliveredMediaIds)
        assertEquals(1, rig.foreground.acquires)
        rig.close()
    }

    // 进程重启：上一条进程遗留的 TRANSFERRING 降回 PAUSED，按 ① 续传。
    @Test
    fun `a TRANSFERRING order left by a dead process is resumed first`() = runTest {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        val leftover = rig.order(p, OrderState.TRANSFERRING)
        rig.settle() // Rig 构造时已排队的 start() 在这里执行
        assertEquals(OrderState.PAUSED, rig.store.get(leftover.id)!!.state)
        rig.trigger()
        assertEquals(listOf(1L, 2L), rig.delivery.deliveredMediaIds)
        rig.close()
    }
}
