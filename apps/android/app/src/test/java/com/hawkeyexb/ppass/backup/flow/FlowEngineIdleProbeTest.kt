// #1005：本地已经判得出「没有要传的」时，任何触发都不许去连桌面（不探测、不问 presence、不申请 FGS）。
// 唯一例外是 5h 兜底的 PERIODIC：按设计要问桌面「这些还在吗」，留作对照。
// 反证：让 FlowEngine.hasWork 恒返回 true → 第一条用例的 probes 不为 0，红。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class FlowEngineIdleProbeTest {
    private val repeats = 5

    /** 已经备份过一张、之后什么都没变：账本无待办、无发现、无失败项。 */
    private fun idleRig(rig: Rig): Rig {
        rig.photo(1, generation = 1)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals(0, rig.pending())
        rig.probes = 0
        rig.presenceCalls = 0
        rig.foreground.acquires = 0
        return rig
    }

    @Test
    fun `no trigger reaches the desktop when nothing is left to transfer`() = runTest {
        val rig = idleRig(Rig(this))
        for (reason in TriggerReason.entries - TriggerReason.PERIODIC) {
            repeat(repeats) { rig.trigger(reason) }
            assertEquals("$reason × $repeats 不许探测桌面", 0, rig.probes)
            assertEquals("$reason × $repeats 不许问 presence", 0, rig.presenceCalls)
            assertEquals("$reason × $repeats 不许申请 FGS", 0, rig.foreground.acquires)
        }
        rig.close()
    }

    @Test
    fun `the periodic fallback still asks the desktop, once per trigger`() = runTest {
        val rig = idleRig(Rig(this))
        rig.trigger(TriggerReason.PERIODIC)
        assertEquals(1, rig.probes)
        assertEquals(1, rig.presenceCalls)
        rig.close()
    }
}
