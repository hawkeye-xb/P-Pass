// #1072 acceptance 3 (engine side): an incompatible version stops the round without counting
// anything, without touching the pairing, and without starting a transfer when the handshake
// already said so. Counter-proof: classifying NeedsUpdate as an ItemFailure turns attempts to 1
// and the order to FAILED — the delivery test below goes red.
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.proto.OutdatedSide
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class C1072VersionMismatchEngineTest {

    @Test
    fun `an incompatible hello waits for the update with no foreground service and no transfer`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.probeResult = ProbeResult.NeedsUpdate(OutdatedSide.DESKTOP)
        rig.trigger()
        assertEquals("握手就停：不申请前台服务", 0, rig.foreground.acquires)
        assertTrue("握手就停：不发起传输", rig.delivery.requests.isEmpty())
        assertEquals(WaitReason.DESKTOP_OUTDATED, rig.engine.view.value.waitReason)
        assertEquals(GlobalState.WAITING, rig.engine.view.value.state)
        assertEquals(1, rig.pending())
        rig.close()
    }

    @Test
    fun `a version refusal mid-round counts nothing and leaves the photo resumable`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.script += { DeliveryOutcome.NeedsUpdate(OutdatedSide.PHONE) }
        rig.trigger()
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals("不计失败次数", 0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(WaitReason.PHONE_OUTDATED, rig.engine.view.value.waitReason)
        assertEquals("没有重试第二次（单张失败才立即重试）", 1, rig.delivery.requests.size)
        rig.close()
    }

    // #1069 sign-off: a request the desktop could not use is not the photo's fault.
    // Counter-proof: treating PhoneError like an ItemFailure retries once and counts — attempts 1, red.
    @Test
    fun `a phone-side error stops the round, backs off and counts nothing`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.script += { DeliveryOutcome.PhoneError("rejected:bad_request") }
        rig.trigger()
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals("不计失败次数", 0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals("不立即重试", 1, rig.delivery.requests.size)
        assertEquals(WaitReason.UNEXPECTED_ERROR, rig.engine.view.value.waitReason)
        assertEquals("走退避探测", 1, rig.scheduler.unreachableProbes)
        rig.close()
    }

    @Test
    fun `desktop internal error is a peer failure - not counted, says so`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.script += { DeliveryOutcome.PeerFailure(PeerFailureKind.DESKTOP_INTERNAL, "internal") }
        rig.trigger()
        assertEquals(OrderState.TRANSFERRING, rig.state(1))
        assertEquals(0, rig.store.currentForMedia(1)!!.attempts)
        assertEquals(WaitReason.DESKTOP_INTERNAL, rig.engine.view.value.waitReason)
        rig.close()
    }

    @Test
    fun `an outdated phone waits for the user, an outdated desktop keeps probing`() {
        assertEquals(WakePlan.AwaitsUser, wakePlanOf(WaitReason.PHONE_OUTDATED) { error("unused") })
        assertEquals(WakePlan.RetryProbes, wakePlanOf(WaitReason.DESKTOP_OUTDATED) { error("unused") })
    }
}
