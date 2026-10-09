// #409 / #652 追加验收：新增的唤醒必须有界、不形成频繁唤醒。同一等待原因反复进入等待（连续多轮桌面不健康 /
// FGS 被拒 / 确定耗尽期间的跳过），登记的唤醒不累加：探测梯一条最多 3 拍 × 10 分钟、走完就停；额度复位唤醒 24h 内只有一个。
//
// JVM 里没有 WorkManager，这里用 [UniqueWorkModel] 按 WorkManager 文档的 unique work 语义建模
// （KEEP：同名还有没结束的——排着的或正在跑的——就什么都不做，否则插入新的；REPLACE：取消旧的、插入新的；
// 链上前一个结束后，后一个的 initialDelay 才开始算），把真引擎接在上面跑，到点就以 UNREACHABLE_PROBE / BUDGET_RESET
// 触发它。生产写法（一条 KEEP 链、REPLACE 单槽）由下面的源文本门禁钉住；真 WorkManager 的行为见 PR 里的 E3 workdb 取证。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private const val MINUTE = 60_000L
private const val HOUR = 60 * MINUTE

/**
 * WorkManager unique work 的模型（只建本测试用到的三类）：
 * - 探测梯：[ladderAsChain] = true 时是生产写法——一条名叫 ladder 的 KEEP 链（3 步、每步前一步结束后 10 分钟）；
 *   false 时是 0.9.10 及更早的写法——三条各自独立的 KEEP（`-1/-2/-3`，登记时起 10 / 20 / 30 分钟），留作反证。
 * - 额度复位唤醒：单槽 REPLACE。
 * - 约束唤醒：单槽 REPLACE（这里不让它到点，只数槽位）。
 */
private class UniqueWorkModel(private val ladderAsChain: Boolean = true) : WakeScheduler {
    var now = 0L

    private class Work(val name: String, var dueAt: Long?, val reason: TriggerReason) {
        var running = false
        var finished = false
        val active get() = !finished
    }

    /** 每个唯一名下当前的那条（链按顺序存）。 */
    private val chains = LinkedHashMap<String, MutableList<Work>>()

    /** 实际到点、真去叫醒引擎的唤醒（时刻 → 原因）。 */
    val fired = mutableListOf<Pair<Long, TriggerReason>>()

    private fun active(name: String) = chains[name]?.any { it.active } == true

    private fun keep(name: String, works: List<Work>) {
        if (active(name)) return
        chains[name] = works.toMutableList()
    }

    private fun replace(name: String, work: Work) {
        chains[name]?.forEach { it.finished = true }
        chains[name] = mutableListOf(work)
    }

    override fun scheduleUnreachableProbes() {
        if (ladderAsChain) {
            keep(LADDER, List(3) { i -> Work(LADDER, if (i == 0) now + 10 * MINUTE else null, TriggerReason.UNREACHABLE_PROBE) })
        } else {
            for (i in 1..3) keep("$LEGACY$i", listOf(Work("$LEGACY$i", now + 10 * MINUTE * i, TriggerReason.UNREACHABLE_PROBE)))
        }
    }

    override fun cancelUnreachableProbes() {
        chains.filterKeys { it == LADDER || it.startsWith(LEGACY) }.values.flatten().forEach { it.finished = true }
    }

    override fun scheduleWhenConditionsMet(reason: WaitReason) = replace(CONSTRAINT, Work(CONSTRAINT, null, TriggerReason.CONSTRAINTS_MET))

    override fun scheduleBudgetResetWake(delayMs: Long) = replace(BUDGET, Work(BUDGET, now + delayMs, TriggerReason.BUDGET_RESET))

    override fun cancelBudgetResetWake() {
        chains[BUDGET]?.forEach { it.finished = true }
    }

    /** 此刻还排着、会到点的唤醒（不含已结束的）。 */
    fun pending(prefix: String): List<Long> =
        chains.filterKeys { it.startsWith(prefix) }.values.flatten().filter { it.active && !it.running }.map { it.dueAt ?: -1L }

    /** 把模型时钟推到 [until]，途中到点的任务逐个「跑」：标记 running → [run] 叫醒引擎 → 结束，链上下一步开始计时。 */
    fun advanceTo(until: Long, run: (TriggerReason) -> Unit) {
        while (true) {
            val next = chains.values.flatten().filter { it.active && !it.running && it.dueAt != null && it.dueAt!! <= until }
                .minByOrNull { it.dueAt!! } ?: break
            now = next.dueAt!!
            next.running = true
            fired += now to next.reason
            run(next.reason)
            next.running = false
            next.finished = true
            chains[next.name]?.firstOrNull { it.active && it.dueAt == null }?.dueAt = now + 10 * MINUTE
        }
        now = until
    }

    companion object {
        const val LADDER = "ladder"
        const val LEGACY = "probe-"
        const val CONSTRAINT = "constraint"
        const val BUDGET = "budget"
    }
}

class C409WakeBoundedTest {

    private fun TestScope.rigOn(model: UniqueWorkModel): Rig = Rig(this, wakes = model)

    private fun Rig.runWake(reason: TriggerReason) {
        trigger(reason)
    }

    // 桌面一直不健康（盘满），App 在后台：进入等待一次之后推 6 小时。探测梯只响 3 拍、都在头 30 分钟内，之后再不自己醒。
    // 期间每 2 分钟一次相册变化（同一个等待原因反复进入）也不会累加：同一时刻排着的探测最多 1 条梯子。
    // 反证：模型换成旧写法（三条独立 KEEP）→ 每拍跑完被下一拍重新插入，6 小时里响几十拍，红。
    @Test
    fun `a desktop that stays unhealthy gets one ladder of at most three probes, not a stream`() = runTest {
        val model = UniqueWorkModel()
        val rig = rigOn(model)
        rig.photo(1, generation = 1)
        rig.probeResult = ProbeResult.Reachable("e1", DesktopHealth(freeBytes = 0L, libraryWritable = false))
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(WaitReason.DESKTOP_STORAGE_FULL, rig.control.wait)

        // 头 20 分钟：同一个等待原因反复进入（相册变化每 2 分钟一次），梯子不累加。
        var t = 0L
        while (t < 20 * MINUTE) {
            t += 2 * MINUTE
            model.advanceTo(t) { rig.runWake(it) }
            rig.trigger(TriggerReason.MEDIA_CHANGE)
            assertEquals(WaitReason.DESKTOP_STORAGE_FULL, rig.control.wait)
            assertTrue("同一时刻排着的探测最多一条梯子（3 步）：${model.pending("ladder")}", model.pending("ladder").size <= 3)
        }
        model.advanceTo(6 * HOUR) { rig.runWake(it) }

        val probes = model.fired.filter { it.second == TriggerReason.UNREACHABLE_PROBE }
        assertEquals("一条梯子最多 3 拍：$probes", 3, probes.size)
        assertTrue("都在登记后约 30 分钟内：$probes", probes.all { it.first <= 32 * MINUTE })
        assertEquals("走完就停，没有排着的", emptyList<Long>(), model.pending("ladder"))
        assertEquals(WaitReason.DESKTOP_STORAGE_FULL, rig.control.wait)
        assertEquals(0, rig.foreground.startForegroundServiceCalls)
        rig.close()
    }

    // 连续多轮 FGS 被拒（说不清原因）：同上，一条梯子最多 3 拍。
    @Test
    fun `repeated unexplained refusals get one ladder of at most three probes`() = runTest {
        val model = UniqueWorkModel()
        val rig = rigOn(model)
        rig.photo(1, generation = 1)
        rig.foreground.grant = false
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        rig.trigger(TriggerReason.NETWORK_CHANGE)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
        model.advanceTo(6 * HOUR) { rig.runWake(it) }
        val probes = model.fired.filter { it.second == TriggerReason.UNREACHABLE_PROBE }
        assertEquals("一条梯子最多 3 拍：$probes", 3, probes.size)
        assertEquals("3 次初始 + 3 拍探测各申请一次，没有更多", 6, rig.foreground.startForegroundServiceCalls)
        assertEquals(emptyList<Long>(), model.pending("ladder"))
        rig.close()
    }

    // 确定耗尽期间，后台触发一再被跳过、每次都重登记复位唤醒：24h 内排着的复位唤醒始终只有一个，且到点时刻不变。
    @Test
    fun `the budget reset wake stays a single pending wake at one fixed time within 24h`() = runTest {
        val model = UniqueWorkModel()
        val rig = rigOn(model)
        val grant = BootInstant(3, 10_000L)
        rig.boot = grant
        rig.photo(1, generation = 1)
        rig.trigger()
        rig.photo(2, generation = 2)
        rig.foreground.grant = false
        rig.foreground.refusal = ForegroundServiceStartNotAllowedException("Time limit already exhausted for foreground service type dataSync")
        rig.boot = BootInstant(3, 20_000L)
        rig.trigger()
        assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
        val resetAt = grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS
        // 模型时钟与系统额度时钟对齐：model.now = boot.elapsedMs - 20_000。
        val offset = 20_000L
        assertEquals(listOf(resetAt - offset), model.pending("budget"))

        // 之后 23 小时，每 10 分钟一次后台触发（全被跳过、各自重登记）：排着的复位唤醒始终一个、时刻不变。
        var t = 0L
        while (t < 23 * HOUR) {
            t += 10 * MINUTE
            model.advanceTo(t) { reason -> rig.boot = BootInstant(3, model.now + offset); rig.runWake(reason) }
            rig.boot = BootInstant(3, t + offset)
            rig.trigger(TriggerReason.MEDIA_CHANGE)
            assertEquals(listOf(resetAt - offset), model.pending("budget"))
        }
        assertEquals("跳过期间不申请", 2, rig.foreground.startForegroundServiceCalls)
        assertEquals("复位唤醒还没到点", 0, model.fired.count { it.second == TriggerReason.BUDGET_RESET })

        // 到点：唤醒恰好一次，真去申请、续传。
        rig.foreground.grant = true
        rig.foreground.refusal = null
        model.advanceTo(25 * HOUR) { reason -> rig.boot = BootInstant(3, model.now + offset); rig.runWake(reason) }
        assertEquals(1, model.fired.count { it.second == TriggerReason.BUDGET_RESET })
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        rig.close()
    }

    // onTimeout 之后反复进入 FGS_BLOCKED（被收走 → 下一次触发又被收走……）：复位唤醒同样只有一个排着。
    @Test
    fun `repeated foreground losses keep a single pending reset wake`() = runTest {
        val model = UniqueWorkModel()
        val rig = rigOn(model)
        rig.boot = BootInstant(3, 10_000L)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        repeat(5) { i ->
            rig.boot = BootInstant(3, 10_000L + i * HOUR)
            rig.trigger(TriggerReason.MEDIA_CHANGE)
            rig.engine.onForegroundLost(FgsBlockReason.BUDGET_EXHAUSTED)
            rig.settle()
            assertEquals(WaitReason.FGS_BLOCKED, rig.control.wait)
            assertEquals("第 ${i + 1} 次：排着的复位唤醒只有一个", 1, model.pending("budget").size)
        }
        rig.close()
    }

    // ---------------------------------------------------------------- 生产写法门禁（源文本）

    private fun source(path: String): String {
        var dir = java.io.File(System.getProperty("user.dir"))
        while (!java.io.File(dir, "apps/android").isDirectory) dir = dir.parentFile ?: error("apps/android not found")
        return java.io.File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$path").readText()
            .lines()
            .filterNot { val t = it.trimStart(); t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") }
            .joinToString("\n")
    }

    // 反证：探测梯改回三条独立 KEEP（enqueueUniqueWork 前缀 + i）或 REPLACE → 红。
    @Test
    fun `production registers the ladder as one KEEP chain and the reset wake as a single REPLACE slot`() {
        val worker = source("backup/BackupWorker.kt")
        val ladder = worker.substringAfter("override fun scheduleUnreachableProbes()").substringBefore("override fun cancelUnreachableProbes()")
        assertTrue(ladder, ladder.contains("beginUniqueWork(UNREACHABLE_PROBE_LADDER_WORK_NAME, ExistingWorkPolicy.KEEP"))
        assertTrue(ladder, ladder.contains(".then(") && ladder.contains("List(UNREACHABLE_PROBE_COUNT)"))
        assertTrue(ladder, !ladder.contains("enqueueUniqueWork(") && !ladder.contains("REPLACE"))
        assertTrue(worker.contains("const val UNREACHABLE_PROBE_COUNT = 3"))
        assertTrue(worker.contains("const val UNREACHABLE_PROBE_INTERVAL_MINUTES = 10L"))
        val cancel = worker.substringAfter("override fun cancelUnreachableProbes()").substringBefore("override fun scheduleWhenConditionsMet(")
        assertTrue("撤梯子；升级前留下的三条也一并撤", cancel.contains("cancelUniqueWork(UNREACHABLE_PROBE_LADDER_WORK_NAME)") && cancel.contains("UNREACHABLE_PROBE_WORK_PREFIX"))
        val budget = worker.substringAfter("override fun scheduleBudgetResetWake(").substringBefore("override fun cancelBudgetResetWake(")
        assertTrue(budget.contains("BUDGET_RESET_WAKE_WORK_NAME") && budget.contains("ExistingWorkPolicy.REPLACE"))
    }

    /** 与系统异常同名（生产按类名匹配）。 */
    private class ForegroundServiceStartNotAllowedException(message: String) : IllegalStateException(message)
}
