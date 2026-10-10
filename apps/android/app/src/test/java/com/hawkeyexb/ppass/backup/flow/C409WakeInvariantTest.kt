// #409 / #652：「必有唤醒」不变式——队列里有没传完的、当前又没在传 ⇒ 至少登记着一个会触发的唤醒。
// 例外只有要用户动手的：未配对（NOT_PAIRED）、后台备份关着（DISABLED）。
//
// 结构：引擎所有进入等待的路径只经 FlowEngine.registerWake，唤醒种类只由 wakePlanOf 对 WaitReason 的穷举 when 决定
// （没有 else：新增 WaitReason 不写映射就编译不过）。这里再用表驱动在运行时兜一遍：表必须覆盖全部 WaitReason，
// 每个原因都在真引擎上走一遍，断言假调度器上登记到了对应的唤醒。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test


private const val SIX_HOURS_MS = 6 * 60 * 60 * 1000L

/** 假调度器上登记到的唤醒，按种类归一。 */
private enum class Wake { NONE, CONDITIONS, PROBES, BUDGET_RESET }

private fun FakeScheduler.registered(): Set<Wake> = buildSet {
    if (constraintWakes.isNotEmpty()) add(Wake.CONDITIONS)
    if (unreachableProbes > 0) add(Wake.PROBES)
    if (budgetResetWakes.isNotEmpty()) add(Wake.BUDGET_RESET)
}.ifEmpty { setOf(Wake.NONE) }

class C409WakeInvariantTest {

    /** 与系统异常同名（生产按类名匹配）。嵌套，免得和 C522 的同名私有类撞 JVM 类名。 */
    private class ForegroundServiceStartNotAllowedException(message: String) : IllegalStateException(message)

    private val unexplainedRefusal = ForegroundServiceStartNotAllowedException("startForegroundService() not allowed due to mAllowStartForeground false")

    // ---------------------------------------------------------------- 纯映射

    /** 每个等待原因 → 唤醒种类。FGS_BLOCKED 由调用点给出的来由决定，这里用占位计划验证「交给了 fgsBlocked」。 */
    private val expectedPlan: Map<WaitReason, WakePlan> = mapOf(
        WaitReason.NOT_PAIRED to WakePlan.AwaitsUser,
        WaitReason.DISABLED to WakePlan.AwaitsUser,
        WaitReason.WIFI to WakePlan.WhenConditionsMet(WaitReason.WIFI),
        WaitReason.BATTERY to WakePlan.WhenConditionsMet(WaitReason.BATTERY),
        WaitReason.FGS_BLOCKED to WakePlan.BudgetReset(-1L),
        WaitReason.DESKTOP_UNREACHABLE to WakePlan.RetryProbes,
        WaitReason.DESKTOP_STORAGE_FULL to WakePlan.RetryProbes,
        WaitReason.DESKTOP_LIBRARY_UNAVAILABLE to WakePlan.RetryProbes,
        WaitReason.DESKTOP_STORAGE_ERROR to WakePlan.RetryProbes,
        WaitReason.UNEXPECTED_ERROR to WakePlan.RetryProbes,
    )

    // 反证：把任一个不健康原因映射成 AwaitsUser（#652 的旧行为：settle 后无唤醒）→ 值不等，红；
    // 新增 WaitReason 不进表 → 第一条断言红（编译期另有穷举 when 挡着）。
    @Test
    fun `every wait reason maps to a wake, except the ones that need the user`() {
        assertEquals("表必须覆盖全部 WaitReason", WaitReason.entries.toSet(), expectedPlan.keys)
        for ((reason, plan) in expectedPlan) {
            assertEquals(reason.name, plan, wakePlanOf(reason) { WakePlan.BudgetReset(-1L) })
        }
        val exceptions = WaitReason.entries.filter { wakePlanOf(it) { WakePlan.RetryProbes } == WakePlan.AwaitsUser }
        assertEquals("例外只有要用户动手的", listOf(WaitReason.NOT_PAIRED, WaitReason.DISABLED), exceptions)
    }

    private val grant = BootInstant(bootCount = 3, elapsedMs = 10_000L)

    // 反证：LOST 不按授予时刻算（例如固定 0 或从现在起 24h）→ 第一条值不等，红。
    @Test
    fun `a lost foreground wakes just past last grant plus 24h, or a full window from now when unknown`() {
        val now = BootInstant(3, grant.elapsedMs + SIX_HOURS_MS)
        val facts = FgsBudgetFacts(lastGrantAt = grant)
        assertEquals(
            WakePlan.BudgetReset(grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS - now.elapsedMs),
            fgsBlockedWakePlan(FgsStall.LOST, facts, now),
        )
        val fallback = WakePlan.BudgetReset(FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS)
        assertEquals("读不到系统时钟", fallback, fgsBlockedWakePlan(FgsStall.LOST, facts, null))
        assertEquals("没有授予记录", fallback, fgsBlockedWakePlan(FgsStall.LOST, FgsBudgetFacts(), now))
        assertEquals("授予是上一次开机的", fallback, fgsBlockedWakePlan(FgsStall.LOST, FgsBudgetFacts(lastGrantAt = BootInstant(2, 1L)), now))
        assertEquals("授予晚于现在（不该出现）", fallback, fgsBlockedWakePlan(FgsStall.LOST, FgsBudgetFacts(lastGrantAt = BootInstant(3, now.elapsedMs + 1)), now))
    }

    @Test
    fun `a refusal retries on the probe ladder unless the system said the budget is exhausted`() {
        val now = BootInstant(3, 30_000L)
        assertEquals(WakePlan.RetryProbes, fgsBlockedWakePlan(FgsStall.NOT_GRANTED, FgsBudgetFacts(lastGrantAt = grant), now))
        assertEquals(WakePlan.RetryProbes, fgsBlockedWakePlan(FgsStall.NOT_GRANTED, FgsBudgetFacts(lastGrantAt = grant), null))
        val exhausted = FgsBudgetFacts(lastGrantAt = grant, exhaustedRefusalAt = BootInstant(3, 20_000L))
        assertEquals(
            WakePlan.BudgetReset(grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS - now.elapsedMs),
            fgsBlockedWakePlan(FgsStall.NOT_GRANTED, exhausted, now),
        )
    }

    // ---------------------------------------------------------------- 表驱动：真引擎上每个原因各走一遍

    /** 把引擎驱进 [reason] 的等待（有一张待传、后台触发），返回这时登记到的唤醒。 */
    private fun TestScope.waitFor(reason: WaitReason): Pair<Rig, Set<Wake>> {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        when (reason) {
            WaitReason.NOT_PAIRED -> rig.epoch = null
            WaitReason.DISABLED -> rig.conditions = Conditions(autoBackupEnabled = false)
            WaitReason.WIFI -> rig.conditions = Conditions(wifiOnly = true, onUnmetered = false)
            WaitReason.BATTERY -> rig.conditions = Conditions(batteryLow = true)
            WaitReason.FGS_BLOCKED -> {
                rig.foreground.grant = false
                rig.foreground.refusal = unexplainedRefusal
            }
            WaitReason.DESKTOP_UNREACHABLE -> rig.probeResult = ProbeResult.Unreachable
            WaitReason.DESKTOP_STORAGE_FULL -> rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = 0L, libraryWritable = false))
            WaitReason.DESKTOP_LIBRARY_UNAVAILABLE -> rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = null, libraryWritable = false))
            WaitReason.DESKTOP_STORAGE_ERROR -> rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = null, indexOk = false))
            WaitReason.UNEXPECTED_ERROR -> rig.probeHook = { throw IllegalStateException("unclassified failure in the cycle") }
        }
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals("$reason: 引擎应停在这个等待上", reason, rig.control.wait)
        assertEquals("$reason: 这张还没传", null, rig.state(1)?.takeIf { it == OrderState.CONFIRMED })
        return rig to rig.scheduler.registered()
    }

    private val expectedWake: Map<WaitReason, Set<Wake>> = mapOf(
        WaitReason.NOT_PAIRED to setOf(Wake.NONE),
        WaitReason.DISABLED to setOf(Wake.NONE),
        WaitReason.WIFI to setOf(Wake.CONDITIONS),
        WaitReason.BATTERY to setOf(Wake.CONDITIONS),
        WaitReason.FGS_BLOCKED to setOf(Wake.PROBES),
        WaitReason.DESKTOP_UNREACHABLE to setOf(Wake.PROBES),
        WaitReason.DESKTOP_STORAGE_FULL to setOf(Wake.PROBES),
        WaitReason.DESKTOP_LIBRARY_UNAVAILABLE to setOf(Wake.PROBES),
        WaitReason.DESKTOP_STORAGE_ERROR to setOf(Wake.PROBES),
        WaitReason.UNEXPECTED_ERROR to setOf(Wake.PROBES),
    )

    // 反证（修复前的 main 上实测红）：FGS_BLOCKED（说不清原因的拒绝）与三个不健康原因登记到的是 NONE。
    @Test
    fun `each wait reason, entered on the real engine, leaves the matching wake registered`() = runTest {
        assertEquals("表必须覆盖全部 WaitReason", WaitReason.entries.toSet(), expectedWake.keys)
        val got = WaitReason.entries.associateWith { reason ->
            val (rig, wakes) = waitFor(reason)
            rig.close()
            wakes
        }
        assertEquals(expectedWake, got)
    }

    // ---------------------------------------------------------------- 违反点 1（#409）：FGS 被系统收走

    // 反证（修复前红）：onForegroundLost 只 stopCycle(FGS_BLOCKED) 不登记 → budgetResetWakes 为空。
    @Test
    fun `a foreground taken away by onTimeout registers a one-off wake past last grant plus 24h`() = runTest {
        val rig = Rig(this)
        rig.boot = grant
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        rig.trigger()
        assertEquals(grant, rig.control.budget.lastGrantAt)

        val now = BootInstant(3, grant.elapsedMs + SIX_HOURS_MS)
        rig.boot = now
        rig.engine.onForegroundLost(FgsBlockReason.BUDGET_EXHAUSTED)
        rig.settle()

        assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        val expected = grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS - now.elapsedMs
        assertEquals(listOf(expected), rig.scheduler.budgetResetWakes)
        assertTrue(rig.logs.any { it.contains("one-off wake registered in ${expected / 60_000}min; foreground lost") })
        assertNull("onTimeout 不是「确定被拒」，不得挡更早的触发", rig.control.budget.exhaustedRefusalAt)

        // 保底而已：更早的触发照常去申请（系统可能已直接复位）。
        rig.foreground.grant = true
        rig.delivery.hold = false
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(2, rig.foreground.startForegroundServiceCalls)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertNull(rig.control.wait)
        rig.close()
    }

    // 读不到系统时钟时按保守值：从现在起一个完整窗口 + 余量。
    @Test
    fun `without a readable system clock the lost-foreground wake falls back to a full window from now`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        rig.trigger()
        rig.engine.onForegroundLost(FgsBlockReason.BUDGET_EXHAUSTED)
        rig.settle()
        assertEquals(listOf(FGS_LOST_FALLBACK_WAKE_MS), rig.scheduler.budgetResetWakes)
        rig.close()
    }

    // 竞态：onTimeout 还没传到引擎，循环先在「每张开始前」发现服务不在前台，以 FGS_BLOCKED 退出——同样要登记。
    // 反证（修复前红）：settle(FGS_BLOCKED) 不登记任何唤醒。
    @Test
    fun `the loop noticing the service is gone between photos registers the same wake`() = runTest {
        val rig = Rig(this)
        rig.boot = grant
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.delivery.onStart = { rig.foreground.held = false }
        rig.trigger()
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals("第二张没开始", null, rig.state(2))
        assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
        assertEquals(
            listOf(grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS - grant.elapsedMs),
            rig.scheduler.budgetResetWakes,
        )
        rig.close()
    }

    // ---------------------------------------------------------------- 违反点 2（#409）：申请被拒、不是额度原因

    // 反证（修复前红）：只有「确定耗尽」才登记 → 说不清原因的拒绝之后 unreachableProbes = 0。
    @Test
    fun `an unexplained refusal registers the probe ladder, and the next probe resumes and clears it`() = runTest {
        val rig = Rig(this)
        rig.boot = grant
        rig.photo(1, generation = 1)
        rig.foreground.grant = false
        rig.foreground.refusal = unexplainedRefusal
        rig.trigger()
        assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
        assertEquals(1, rig.scheduler.unreachableProbes)
        assertEquals("不是额度原因，不登记复位唤醒", emptyList<Long>(), rig.scheduler.budgetResetWakes)
        assertEquals("可达但没拿到 FGS：探测梯不撤", 0, rig.scheduler.probesCancelled)

        rig.foreground.grant = true
        rig.foreground.refusal = null
        rig.trigger(TriggerReason.UNREACHABLE_PROBE)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertNull(rig.control.wait)
        assertEquals("#762：传成功才撤探测梯（拿到 FGS 不算恢复）", 1, rig.scheduler.probesCancelled)
        rig.close()
    }

    // ---------------------------------------------------------------- 违反点 3（#652）：桌面不健康

    // 探测带回「文件夹不可写」→ 等待 + 探测梯；桌面恢复后，探测梯那一拍自己续传、等待原因（提示）清掉。
    // 反证（修复前红）：settle(unhealthy) 不登记 → unreachableProbes = 0；且 Reachable 时先撤了探测梯。
    @Test
    fun `an unhealthy desktop registers the probe ladder and the next probe resumes once it recovers`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = null, libraryWritable = false))
        rig.trigger()
        assertEquals(WaitReason.DESKTOP_LIBRARY_UNAVAILABLE, rig.control.wait)
        assertEquals(GlobalState.WAITING, rig.engine.view.value.state)
        assertEquals(1, rig.scheduler.unreachableProbes)
        assertEquals(0, rig.scheduler.probesCancelled)
        assertEquals(0, rig.foreground.startForegroundServiceCalls)

        // 还没恢复：那一拍探测仍不健康，原地等、梯子还在（KEEP，不重置）。
        rig.trigger(TriggerReason.UNREACHABLE_PROBE)
        assertEquals(WaitReason.DESKTOP_LIBRARY_UNAVAILABLE, rig.control.wait)
        assertEquals(0, rig.scheduler.probesCancelled)

        rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = 100L * 1024 * 1024 * 1024))
        rig.trigger(TriggerReason.UNREACHABLE_PROBE)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertNull("等待原因清掉 = 提示消失", rig.control.wait)
        assertEquals(GlobalState.IDLE, rig.engine.view.value.state)
        assertEquals(1, rig.scheduler.probesCancelled)
        rig.close()
    }

    // 传输中桌面报 storage_full（对端失败）→ 同样登记探测梯。反证（修复前红）：unreachableProbes = 0。
    @Test
    fun `a peer failure during transfer registers the probe ladder`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.script += { DeliveryOutcome.PeerFailure(PeerFailureKind.LIBRARY_UNAVAILABLE, "library_unavailable") }
        rig.trigger()
        assertEquals(WaitReason.DESKTOP_LIBRARY_UNAVAILABLE, rig.control.wait)
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals(1, rig.scheduler.unreachableProbes)
        rig.close()
    }

    // #652 验收「前台按某个周期重探（断言探测次数随虚拟时间推进）」：App 在前台、桌面不健康，
    // 心跳每 30 秒一拍，每一拍都重探一次；桌面恢复后的那一拍续传、提示消失。
    // 反证：onDesktopReachable 只认 DESKTOP_UNREACHABLE（修复前）→ probes 不随时间增长，红。
    @Test
    fun `in the foreground the heartbeat re-probes an unhealthy desktop and resumes once it recovers`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = 0L, libraryWritable = false))
        rig.trigger()
        assertEquals(WaitReason.DESKTOP_STORAGE_FULL, rig.control.wait)
        val probesAtStart = rig.probes

        repeat(3) {
            advanceTimeBy(30_000L)
            rig.engine.onDesktopReachable()
            rig.settle()
        }
        assertEquals("每一拍心跳重探一次", probesAtStart + 3, rig.probes)
        assertEquals(WaitReason.DESKTOP_STORAGE_FULL, rig.control.wait)
        assertEquals(0, rig.foreground.startForegroundServiceCalls)

        rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = 100L * 1024 * 1024 * 1024))
        advanceTimeBy(30_000L)
        rig.engine.onDesktopReachable()
        rig.settle()
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertNull(rig.control.wait)
        rig.close()
    }

    // 等待原因来自传输时的对端失败、最近一次探测却报健康（健康探针看不到 originals 写不进）：心跳不叫醒——
    // 否则每 30 秒一拍都会申请 FGS、整张重传、再失败。交给探测梯。
    // 反证：去掉健康快照闸门（心跳对不健康等待一律叫醒）→ probes / acquires / requests 增加，红。
    @Test
    fun `the heartbeat does not re-send while the probe says healthy but delivery keeps failing`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.script += { DeliveryOutcome.PeerFailure(PeerFailureKind.LIBRARY_UNAVAILABLE, "library_unavailable") }
        rig.trigger()
        assertEquals(WaitReason.DESKTOP_LIBRARY_UNAVAILABLE, rig.control.wait)
        val probes = rig.probes
        val acquires = rig.foreground.acquires
        val requests = rig.delivery.requests.size

        repeat(3) {
            advanceTimeBy(30_000L)
            rig.engine.onDesktopReachable()
            rig.settle()
        }
        assertEquals(probes, rig.probes)
        assertEquals(acquires, rig.foreground.acquires)
        assertEquals(requests, rig.delivery.requests.size)
        assertEquals("探测梯仍是它的唤醒", 1, rig.scheduler.unreachableProbes)
        rig.close()
    }

    // #522 的拒绝晚到（等结论超时后服务才记下 "Time limit"）：那一轮按说不清原因走了探测梯；之后探测梯那一拍
    // 走跳过申请，同样要（重）登记复位唤醒——否则探测梯走完就再没有唤醒。
    // 反证：跳过路径改回「不登记」→ budgetResetWakes 为空，红。
    @Test
    fun `a budget refusal recorded late still gets its reset wake on the next skipped trigger`() = runTest {
        val rig = Rig(this)
        rig.boot = grant
        rig.photo(1, generation = 1)
        rig.trigger()
        rig.photo(2, generation = 2)
        rig.foreground.grant = false
        rig.foreground.refusal = null // 等结论超时：引擎只知道「没拿到」
        rig.boot = BootInstant(3, 20_000L)
        rig.trigger()
        assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
        assertEquals(1, rig.scheduler.unreachableProbes)
        assertEquals(emptyList<Long>(), rig.scheduler.budgetResetWakes)

        rig.control.recordBudgetRefusal(BootInstant(3, 21_000L)) // 迟到的服务记下了系统的明确拒绝
        rig.boot = BootInstant(3, 30_000L)
        rig.trigger(TriggerReason.UNREACHABLE_PROBE)
        assertEquals("跳过了申请", 2, rig.foreground.startForegroundServiceCalls)
        assertEquals(
            listOf(grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS - 30_000L),
            rig.scheduler.budgetResetWakes,
        )
        rig.close()
    }

    // ---------------------------------------------------------------- 结构门禁（源文本）

    private fun source(path: String): String {
        var dir = java.io.File(System.getProperty("user.dir"))
        while (!java.io.File(dir, "apps/android").isDirectory) dir = dir.parentFile ?: error("apps/android not found")
        return java.io.File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$path").readText()
            .lines()
            .filterNot { val t = it.trimStart(); t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") }
            .joinToString("\n")
    }

    // 唤醒只在一个地方登记：引擎里 `scheduler.schedule*` 只许出现在 registerWake 里；映射是穷举 when、没有 else。
    // 反证：在 settle / 某个出口旁边再写一句 scheduler.scheduleUnreachableProbes()（旧写法）→ 计数不为 0，红；
    // 给 wakePlanOf 加 else 分支 → 红。
    @Test
    fun `wakes are registered in exactly one place, from an exhaustive mapping`() {
        val engine = source("backup/flow/FlowEngine.kt")
        val register = engine.substringAfter("private fun registerWake(").substringBefore("\n    fun onDesktopReachable(")
        val outside = engine.replace(register, "")
        assertEquals("registerWake 之外不得直接登记唤醒", 0, Regex("""scheduler\.schedule""").findAll(outside).count())
        assertTrue(register.contains("wakePlanOf(reason)"))
        val core = source("backup/flow/FlowCore.kt")
        val mapping = core.substringAfter("internal fun wakePlanOf(").substringBefore("\n}\n")
        assertTrue(mapping.contains("when (reason)"))
        assertTrue("穷举映射不得有 else", !Regex("""\belse\b""").containsMatchIn(mapping))
    }

    // 心跳在其它等待里仍然不是触发源（FGS 受阻、Wi‑Fi、未配对……）。反证：去掉判断 → probes 增加，红。
    @Test
    fun `the heartbeat stays inert in waits that are not about the desktop`() = runTest {
        for (reason in listOf(WaitReason.FGS_BLOCKED, WaitReason.WIFI, WaitReason.NOT_PAIRED, WaitReason.UNEXPECTED_ERROR)) {
            val (rig, _) = waitFor(reason)
            val probes = rig.probes
            val acquires = rig.foreground.acquires
            rig.engine.onDesktopReachable()
            rig.settle()
            assertEquals(reason.name, probes, rig.probes)
            assertEquals(reason.name, acquires, rig.foreground.acquires)
            rig.close()
        }
    }
}
