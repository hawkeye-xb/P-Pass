// #1005：审计 outbox 只搭「这一轮已经连上桌面」的车上报；没连桌面的一轮不为它单独建连接。
// 反证：FlowEngine.drain 里去掉 `if (reachedDesktop)`（每轮都 afterCycle）→ 前两条用例 afterCycles 不为 0，红。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class C1005AuditPiggybackTest {
    @Test
    fun `a cycle with nothing to transfer does not flush the audit outbox`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        rig.afterCycles = 0
        rig.probes = 0

        repeat(5) { rig.trigger(TriggerReason.MEDIA_CHANGE) }
        repeat(5) { rig.trigger(TriggerReason.NETWORK_CHANGE) }

        assertEquals(0, rig.probes)
        assertEquals(0, rig.afterCycles)
        rig.close()
    }

    @Test
    fun `a cycle that could not reach the desktop does not flush the audit outbox`() = runTest {
        val rig = Rig(this)
        rig.probeResult = ProbeResult.Unreachable
        rig.photo(1, generation = 1)

        rig.trigger(TriggerReason.MEDIA_CHANGE)

        assertEquals(1, rig.probes)
        assertEquals(0, rig.afterCycles)
        rig.close()
    }

    // 对照：连上了（传了一张）→ 这一轮结束顺带上报一次，积压不会一直留着。
    @Test
    fun `a cycle that reached the desktop flushes once`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)

        rig.trigger(TriggerReason.MEDIA_CHANGE)

        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals(1, rig.afterCycles)
        rig.close()
    }
}
