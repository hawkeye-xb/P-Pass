// #522（MOB-119）：dataSync 额度**确定**耗尽、之后没回过前台期间，后台触发不再调 startForegroundService；
// 回前台（或人在场）后复位；过了系统复位点 / 重启过设备就照常申请。另外钉住 acquire 的日志：被拒写被拒 + 原因，
// 真超时才写 no verdict。
//
// 「确定」只认系统抛出的 "Time limit already exhausted"（AOSP android15 ActiveServices 在「上次超时后没回过 TOP、
// 最近一次会话开始不到 24h」时抛）。onTimeout 和说不清原因的拒绝都不是闸门（#413）。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 与系统异常同名（生产按类名匹配，API 31 以下没有这个类）。 */
private class ForegroundServiceStartNotAllowedException(message: String) : IllegalStateException(message)

private val timeLimit = ForegroundServiceStartNotAllowedException("Time limit already exhausted for foreground service type dataSync")
private val otherRefusal = ForegroundServiceStartNotAllowedException("startForegroundService() not allowed due to mAllowStartForeground false")

class C522FgsBudgetSkipTest {

    // ---------------------------------------------------------------- 纯判据

    private val grant = BootInstant(bootCount = 3, elapsedMs = 10_000L)
    private val refused = BootInstant(bootCount = 3, elapsedMs = 20_000L)
    private val exhausted = FgsBudgetFacts(lastGrantAt = grant, exhaustedRefusalAt = refused)
    private val resetAt = grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS - FGS_BUDGET_RESET_MARGIN_MS

    @Test
    fun `skip only while the system refusal stands, in the same boot, before the reset point`() {
        assertNotNull(fgsBudgetSkipReason(exhausted, BootInstant(3, 30_000L)))
        assertNotNull(fgsBudgetSkipReason(exhausted, BootInstant(3, resetAt - 1)))
        assertNull("到了系统复位点必须真去申请", fgsBudgetSkipReason(exhausted, BootInstant(3, resetAt)))
        assertNull("重启过（开机序号变了）", fgsBudgetSkipReason(exhausted, BootInstant(4, 30_000L)))
        assertNull("读不到系统时钟", fgsBudgetSkipReason(exhausted, null))
        assertNull("没有明确拒绝", fgsBudgetSkipReason(exhausted.copy(exhaustedRefusalAt = null), BootInstant(3, 30_000L)))
        assertNull("不知道窗口起点", fgsBudgetSkipReason(exhausted.copy(lastGrantAt = null), BootInstant(3, 30_000L)))
        assertNull("起点是上一次开机的", fgsBudgetSkipReason(exhausted.copy(lastGrantAt = BootInstant(2, 1L)), BootInstant(3, 30_000L)))
        assertNull(
            "拒绝早于最近一次授予（不该出现，按拿不准处理）",
            fgsBudgetSkipReason(FgsBudgetFacts(lastGrantAt = refused, exhaustedRefusalAt = grant), BootInstant(3, 30_000L)),
        )
        assertNull("拒绝之后回过前台（进程内事实）", fgsBudgetSkipReason(exhausted, BootInstant(3, 30_000L), BootInstant(3, 25_000L)))
        assertNotNull("前台在拒绝之前，不算", fgsBudgetSkipReason(exhausted, BootInstant(3, 30_000L), BootInstant(3, 15_000L)))
        assertNotNull("上一次开机的前台，不算", fgsBudgetSkipReason(exhausted, BootInstant(3, 30_000L), BootInstant(2, 25_000L)))
        assertNull("没有确定被拒 = 不必说明", fgsBudgetDecision(FgsBudgetFacts(lastGrantAt = grant), BootInstant(3, 30_000L)))
    }

    // ---------------------------------------------------------------- 落盘

    @Test
    fun `budget facts survive a process restart, a grant clears the refusal, foreground clears it too`() {
        val d = Files.createTempDirectory("c522").toFile()
        FlowControlStore(d).recordFgsGrant(grant)
        FlowControlStore(d).recordBudgetRefusal(refused)
        assertEquals("进程重启后仍在（系统的额度账在进程外）", exhausted, FlowControlStore(d).fgsBudgetFacts())

        assertTrue(FlowControlStore(d).clearBudgetRefusal())
        assertEquals(FgsBudgetFacts(lastGrantAt = grant), FlowControlStore(d).fgsBudgetFacts())
        assertFalse("没记着时清除返回 false（不写多余的日志）", FlowControlStore(d).clearBudgetRefusal())

        FlowControlStore(d).recordBudgetRefusal(refused)
        val later = BootInstant(3, 99_000L)
        FlowControlStore(d).recordFgsGrant(later)
        assertEquals(FgsBudgetFacts(lastGrantAt = later), FlowControlStore(d).fgsBudgetFacts())
        d.deleteRecursively()
    }

    @Test
    fun `an older control file without budget fields reads as no facts`() {
        val d = Files.createTempDirectory("c522").toFile()
        File(d, FlowControlStore.FILE_NAME).writeText("""{"paused":false,"fgsBlocked":"BUDGET_EXHAUSTED","fgsBlockedAtMs":5}""")
        assertEquals(FgsBudgetFacts(), FlowControlStore(d).fgsBudgetFacts())
        d.deleteRecursively()
    }

    // ---------------------------------------------------------------- 什么算「确定被拒」

    @Test
    fun `only the system time-limit refusal is recorded as a certain budget refusal`() {
        val c = FakeControl()
        assertEquals(FgsBlockReason.START_REFUSED, noteFgsRefusal(c, otherRefusal, refused))
        assertNull(c.budget.exhaustedRefusalAt)
        assertEquals(FgsBlockReason.BUDGET_EXHAUSTED, noteFgsRefusal(c, timeLimit, refused))
        assertEquals(refused, c.budget.exhaustedRefusalAt)
    }

    // ---------------------------------------------------------------- 引擎闸门

    /** 先成功一轮（记下窗口起点），再让系统明确说额度耗尽，停在「确定被拒」上。 */
    private fun Rig.exhaust() {
        boot = grant
        photo(1, generation = 1)
        trigger()
        assertEquals(OrderState.CONFIRMED, state(1))
        foreground.grant = false
        foreground.refusal = timeLimit
        boot = refused
        photo(2, generation = 2)
        trigger()
        assertEquals(refused, control.budget.exhaustedRefusalAt)
        assertEquals(2, foreground.startForegroundServiceCalls)
    }

    // 反证：去掉 FlowEngine 里的闸门 → 第 3 次触发照样调 startForegroundService，红。
    @Test
    fun `background triggers skip the start while the budget is certainly exhausted, and say why`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.boot = BootInstant(3, 30_000L)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        rig.trigger(TriggerReason.PERIODIC)
        rig.trigger(TriggerReason.NETWORK_CHANGE)
        assertEquals("确定耗尽期间后台触发不得再申请", 2, rig.foreground.startForegroundServiceCalls)
        assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
        assertEquals(FgsBlockReason.BUDGET_EXHAUSTED, rig.control.block)
        assertEquals(3, rig.logs.count { it.contains("skipping startForegroundService: dataSync budget exhausted") })
        rig.close()
    }

    // 反证：onAppForeground 不清「确定被拒」→ 回前台后的后台触发仍被跳过，红。
    @Test
    fun `coming to the foreground resets it and background triggers request again`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.boot = BootInstant(3, 30_000L)
        // 回前台那一轮没走到申请（桌面此刻不可达）：之后的后台触发也必须恢复申请。
        rig.probeResult = ProbeResult.Unreachable
        rig.engine.onAppForeground()
        rig.settle()
        assertEquals(2, rig.foreground.startForegroundServiceCalls)
        assertNull(rig.control.budget.exhaustedRefusalAt)
        assertTrue(rig.logs.any { it.startsWith("foreground budget: app came to the foreground") })

        rig.probeResult = ProbeResult.Reachable("e1")
        rig.foreground.grant = true
        rig.trigger(TriggerReason.UNREACHABLE_PROBE)
        assertEquals("回过前台之后的后台触发必须真去申请", 3, rig.foreground.startForegroundServiceCalls)
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        rig.close()
    }

    // ---------------------------------------------------------------- 额度复位唤醒

    // 耗尽后 App 自己登记一个一次性唤醒，定在「最近一次授予 + 24h + 余量」。
    // #409：跳过的触发也进「等待中」，按「必有唤醒」不变式同样登记——唯一名 + REPLACE，算出的是**同一个绝对时刻**，
    // 所以重登记不会把唤醒往后推（原意「一次耗尽只对应一个复位唤醒」由「绝对时刻不变」守住）。
    // 反证：去掉登记 → 0 次，红；跳过路径按「现在 + 24h」登记（往后推）→ 绝对时刻不等，红；延迟少了余量 → 值不等，红。
    @Test
    fun `a certain exhaustion registers exactly one reset wake just past the system reset point`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        val expected = grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS - refused.elapsedMs
        assertEquals(listOf(expected), rig.scheduler.budgetResetWakes)
        assertTrue(rig.logs.any { it.contains("one-off wake registered in ${expected / 60_000}min") })
        rig.boot = BootInstant(3, 30_000L)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        rig.trigger(TriggerReason.PERIODIC)
        rig.trigger(TriggerReason.NETWORK_CHANGE)
        val wakeAt = grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS
        assertEquals("跳过的三次触发各自重登记（必有唤醒）", 4, rig.scheduler.budgetResetWakes.size)
        assertEquals(
            "重登记指向同一个复位点，不往后推",
            listOf(wakeAt, wakeAt, wakeAt),
            rig.scheduler.budgetResetWakes.drop(1).map { 30_000L + it },
        )
        rig.close()
    }

    // 唤醒到点（已过系统复位点）按普通后台触发走：真去申请、续传。
    @Test
    fun `the reset wake at its due time requests the foreground service and resumes`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.boot = BootInstant(3, refused.elapsedMs + rig.scheduler.budgetResetWakes.single())
        rig.foreground.grant = true
        rig.trigger(TriggerReason.BUDGET_RESET)
        assertEquals(3, rig.foreground.startForegroundServiceCalls)
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        rig.close()
    }

    // 说不清原因的拒绝 / onTimeout 不登记（不是「确定耗尽」）；重启后首个触发直接申请，不另登记。
    // 反证：登记不看判据（每次被拒都登记）→ 红。
    @Test
    fun `no reset wake for unexplained refusals, and none needed after a reboot`() = runTest {
        val rig = Rig(this)
        rig.boot = grant
        rig.photo(1, generation = 1)
        rig.foreground.grant = false
        rig.foreground.refusal = otherRefusal
        rig.trigger()
        assertEquals(emptyList<Long>(), rig.scheduler.budgetResetWakes)

        val rebooted = Rig(this)
        rebooted.exhaust()
        rebooted.boot = BootInstant(4, 5_000L)
        rebooted.foreground.refusal = otherRefusal
        rebooted.trigger()
        assertEquals("重启后不跳过", 3, rebooted.foreground.startForegroundServiceCalls)
        assertEquals("重启后不另登记", 1, rebooted.scheduler.budgetResetWakes.size)
        rig.close()
        rebooted.close()
    }

    // 回前台清除登记。反证：resetBudgetRefusal 不撤唤醒 → 0 次，红。
    @Test
    fun `coming to the foreground cancels the reset wake`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.probeResult = ProbeResult.Unreachable
        rig.engine.onAppForeground()
        rig.settle()
        assertEquals(1, rig.scheduler.budgetResetWakeCancels)
        rig.engine.onAppForeground()
        rig.settle()
        assertEquals("没记着时不重复撤", 1, rig.scheduler.budgetResetWakeCancels)
        rig.close()
    }

    // 引擎在回前台那一刻没起来（runtimeFor 超时）也不能漏：进程内的前台事实同样让后台触发恢复申请，并说明原因。
    // 反证：fgsBudgetDecision 不看 lastForegroundAt → 仍跳过，红。
    @Test
    fun `a foreground seen only in-process still lets background triggers request, and says why`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.boot = BootInstant(3, 30_000L)
        rig.appForegroundAt = BootInstant(3, 25_000L)
        rig.trigger()
        assertEquals(3, rig.foreground.startForegroundServiceCalls)
        assertTrue(rig.logs.any { it.contains("requesting anyway: app came to the foreground since") })
        rig.close()
    }

    // 读不到系统时钟 = 拿不准：照常申请，但要留痕（不静默降级）。
    @Test
    fun `an unreadable system clock never skips and is logged`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.boot = null
        rig.trigger()
        assertEquals(3, rig.foreground.startForegroundServiceCalls)
        assertTrue(rig.logs.any { it.contains("requesting anyway: system clock (BOOT_COUNT) unavailable") })
        rig.close()
    }

    // 反证：闸门不看 userPresent → 手动触发被跳过，红。
    @Test
    fun `user-present triggers are never skipped and reset the refusal`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.boot = BootInstant(3, 30_000L)
        rig.foreground.grant = true
        rig.trigger(TriggerReason.MANUAL)
        assertEquals(3, rig.foreground.startForegroundServiceCalls)
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        assertNull(rig.control.budget.exhaustedRefusalAt)
        rig.close()
    }

    // 反证：跳过不设上限（去掉 resetAt 判断）→ 过了 24h 仍跳过，红。
    @Test
    fun `past the system reset point the first background trigger requests again`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.boot = BootInstant(3, resetAt - 1)
        rig.trigger()
        assertEquals(2, rig.foreground.startForegroundServiceCalls)
        rig.boot = BootInstant(3, resetAt)
        rig.foreground.grant = true
        rig.trigger()
        assertEquals("恢复后的第一次后台触发一定重新尝试", 3, rig.foreground.startForegroundServiceCalls)
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        rig.close()
    }

    // 反证：不比开机序号 → 重启后仍跳过，红。
    @Test
    fun `after a device reboot background triggers request again`() = runTest {
        val rig = Rig(this)
        rig.exhaust()
        rig.boot = BootInstant(4, 30_000L)
        rig.trigger()
        assertEquals(3, rig.foreground.startForegroundServiceCalls)
        rig.close()
    }

    // #413 原意保持：说不清原因的拒绝、onTimeout 都不是闸门。
    // 反证：把 START_REFUSED 或 onTimeout 也记成「确定被拒」→ 下一次后台触发被跳过，红。
    @Test
    fun `unexplained refusals and onTimeout alone never gate the next trigger`() = runTest {
        val rig = Rig(this)
        rig.boot = grant
        rig.photo(1, generation = 1)
        rig.foreground.grant = false
        rig.foreground.refusal = otherRefusal
        rig.trigger()
        rig.trigger()
        assertEquals(2, rig.foreground.startForegroundServiceCalls)

        rig.foreground.grant = true
        rig.foreground.refusal = null
        rig.trigger()
        rig.engine.onForegroundLost(FgsBlockReason.BUDGET_EXHAUSTED)
        rig.settle()
        rig.photo(2, generation = 2)
        rig.trigger()
        assertEquals("onTimeout 之后下一次仍真去申请（系统可能直接复位）", 4, rig.foreground.startForegroundServiceCalls)
        rig.close()
    }

    // ---------------------------------------------------------------- acquire 的日志如实

    // 反证：把 awaitFgsVerdict 改回「拿不到 Granted 就当超时」（旧的 `?: false`）→ Refused 被写成 no verdict，红。
    @Test
    fun `an explicit refusal is logged as refused with its reason, not as a missing verdict`() = runTest {
        val verdict = CompletableDeferred<FgsVerdict>()
        val waiting = async { awaitFgsVerdict(verdict, AndroidForegroundLease.VERDICT_TIMEOUT_MS) }
        runCurrent()
        verdict.complete(FgsVerdict.Refused(FgsBlockReason.BUDGET_EXHAUSTED, timeLimit.message!!))
        val outcome = waiting.await()
        assertEquals(FgsVerdict.Refused(FgsBlockReason.BUDGET_EXHAUSTED, timeLimit.message!!), outcome)
        val line = fgsNotGrantedLog(outcome, AndroidForegroundLease.VERDICT_TIMEOUT_MS)
        assertTrue(line, line.contains("refused by the system (BUDGET_EXHAUSTED: Time limit already exhausted"))
        assertFalse(line, line.contains("no verdict"))
    }

    @Test
    fun `only a real timeout is logged as no verdict`() = runTest {
        val never = CompletableDeferred<FgsVerdict>()
        val waiting = async { awaitFgsVerdict(never, 6_000L) }
        advanceTimeBy(5_999L)
        runCurrent()
        assertFalse(waiting.isCompleted)
        advanceTimeBy(2L)
        runCurrent()
        val outcome = waiting.await()
        assertNull(outcome)
        assertEquals("foreground: no verdict within 6000ms; treating as refused", fgsNotGrantedLog(outcome, 6_000L))
    }

    // ---------------------------------------------------------------- 接线门禁（源文本，只钉「接线还在」）

    private fun source(path: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) dir = dir.parentFile ?: error("apps/android not found")
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$path").readText()
            .lines()
            .filterNot { val t = it.trimStart(); t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") }
            .joinToString("\n")
    }

    @Test
    fun `the lease and the service are wired to the honest verdict and the budget facts`() {
        val src = source("backup/flow/FlowTransferForegroundService.kt")
        val acquire = src.substringAfter("override suspend fun acquire()").substringBefore("override fun isHeld()")
        assertTrue(acquire.contains("awaitFgsVerdict(verdict, verdictTimeoutMs)"))
        assertTrue(acquire.contains("Log.w(TAG, fgsNotGrantedLog(outcome, verdictTimeoutMs))"))
        assertTrue(acquire.contains("noteFgsRefusal(control, refusal, androidBootInstant(app))"))
        assertFalse("不得再把被拒和超时合成一个 false", acquire.contains("?: false"))
        val service = src.substringAfter("class FlowTransferForegroundService")
        assertTrue(service.contains("waiting?.complete(FgsVerdict.Refused(reason, refusal.message.orEmpty()))"))
        assertTrue(service.contains("noteFgsRefusal(FlowForegroundHandoff.control, refusal, androidBootInstant(this))"))
        assertTrue(service.contains("FlowForegroundHandoff.control?.recordFgsGrant(androidBootInstant(this))"))
        val onTimeout = service.substringAfter("override fun onTimeout(").substringBefore("override fun onDestroy")
        assertFalse("onTimeout 不是「确定被拒」", onTimeout.contains("recordBudgetRefusal"))
        val runtime = source("backup/flow/AndroidFlowRuntime.kt")
        assertTrue("运行时要把真实的系统时钟交给引擎", runtime.contains("bootClock = { androidBootInstant(app) }"))
        assertTrue(runtime.contains("appForegroundAt = { FlowForegroundHandoff.lastAppForegroundAt },"))
        val onForeground = runtime.substringAfter("internal fun onFlowAppForeground(").substringBefore("thread(")
        assertTrue("回前台的事实要在拿运行时之前同步记下", onForeground.contains("FlowForegroundHandoff.lastAppForegroundAt = androidBootInstant(app)"))
        val worker = source("backup/BackupWorker.kt")
        val wake = worker.substringAfter("override fun scheduleBudgetResetWake(").substringBefore("override fun cancelBudgetResetWake(")
        assertTrue("一次性、唯一名、新替旧", wake.contains("enqueueUniqueWork(") && wake.contains("BUDGET_RESET_WAKE_WORK_NAME") && wake.contains("ExistingWorkPolicy.REPLACE"))
        assertTrue(wake.contains("backupWorkRequest(") && wake.contains("reason = TriggerReason.BUDGET_RESET") && wake.contains("initialDelayMs = delayMs"))
        assertFalse("不得复用周期任务（WorkManager 会推迟提前强跑的周期任务）", wake.contains("Periodic"))
        assertTrue(worker.substringAfter("override fun cancelBudgetResetWake(").contains("cancelUniqueWork(BUDGET_RESET_WAKE_WORK_NAME)"))
    }
}
