// #439：桌面服务停过又回来，App 一直在前台——前台心跳确认桌面可达时要叫醒循环，
// 不能让人对着「连不上存储电脑，连上后自动接着备份」等 10 分钟的探测。
// 心跳每 30 秒一拍，所以它只在「等待中（桌面不可达）」时才算触发，其他状态一律不动。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.transport.applyHeartbeatOutcome
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class C439DesktopReachableWakeTest {

    // 路径失败 → 等待中（桌面不可达）；桌面回来后心跳一拍 → 同一张续传完成，等待原因清掉。
    // 反证：onDesktopReachable 不调 onTrigger → 没有第二次传输，这张一直停在传输中，红。
    @Test
    fun `a reachable heartbeat while waiting for the desktop resumes the in-flight photo`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.script += { DeliveryOutcome.PathFailure("desktop_unreachable:local_aborted") }
        rig.trigger()
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals(WaitReason.DESKTOP_UNREACHABLE, rig.control.wait)
        assertEquals(1, rig.delivery.requests.size)

        rig.engine.onDesktopReachable()
        rig.settle()

        assertEquals("the same order resumes on the heartbeat, not a new one", 2, rig.delivery.requests.size)
        assertEquals(rig.delivery.requests[0].orderId, rig.delivery.requests[1].orderId)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertNull(rig.control.wait)
        rig.close()
    }

    // 不在「等待中（桌面不可达）」时，心跳不是触发源：有待传也不起循环、不探测（那是 MEDIA_CHANGE 等触发的事）。
    // 反证：去掉 waitReason 判断 → 心跳把这张传了，requests = 2、probes 增加，红。
    @Test
    fun `a heartbeat outside the unreachable wait is not a trigger`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.trigger()
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertNull(rig.control.wait)
        val probesBefore = rig.probes

        rig.photo(2, generation = 2) // 新照片，但还没有任何触发
        rig.engine.onDesktopReachable()
        rig.settle()

        assertEquals(1, rig.delivery.requests.size)
        assertEquals(probesBefore, rig.probes)
        rig.close()
    }

    // 接线：心跳成功才通知，失败不通知。
    // 反证：applyHeartbeatOutcome 不调 onReachable → 计数为 0，红。
    @Test
    fun `only a successful heartbeat notifies reachability`() {
        var calls = 0
        applyHeartbeatOutcome(null, Result.success(Unit)) { calls++ }
        applyHeartbeatOutcome(null, Result.failure<Unit>(RuntimeException("unreachable"))) { calls++ }
        assertEquals(1, calls)
    }
}
