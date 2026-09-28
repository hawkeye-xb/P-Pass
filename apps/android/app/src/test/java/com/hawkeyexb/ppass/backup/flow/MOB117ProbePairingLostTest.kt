// #466（MOB-117）：桌面移除这台手机后，每轮先探测就被拒，走不到投递——探测必须自己记下配对失效，红卡才会亮。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.HolderPairingLostState
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.transport.CallTrace
import com.hawkeyexb.ppass.transport.Pairing
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB117ProbePairingLostTest {
    private val pairing = Pairing(daemonNodeId = "d", daemonAddrToken = "unused", storageDeviceName = "desk", pairingEpoch = "e1")

    private fun rejecting(msgKey: String) = object : FlowReceiptClient {
        override suspend fun currentPairingEpoch(): String? = error("probe must use the traced entry point")
        override suspend fun probeHello(trace: (CallTrace) -> Unit): com.hawkeyexb.ppass.proto.Hello =
            throw DesktopRejectedException(msgKey, "hello")
        override suspend fun offer(request: FlowFetchRequest) = FlowStatusReply(state = "active")
        override suspend fun status(tuple: FlowTupleRef) = FlowStatusReply(state = "active")
        override suspend fun suspendFetch(tuple: FlowTupleRef) = Unit
    }

    @Test
    fun `a probe rejected as not authorized lights the pairing-lost card for the current epoch`() = runTest {
        val loss = FlowDeliveryPairingLoss()
        val probe = DaemonDesktopProbe(pairing = { pairing }, desktopFor = { rejecting("err.not_authorized") }, pairingLoss = loss)

        assertEquals(ProbeResult.PairingLost, probe.probe())
        assertTrue("探测判出配对失效却不记，红卡永远不亮（#466）", loss.isLost(PairingEpoch("e1")))

        val card = HolderPairingLostState()
        card.syncFrom(loss, PairingEpoch("e1"))
        assertTrue(card.value.value)
    }

    @Test
    fun `the loss belongs to the epoch that was rejected, not to a later re-pair`() = runTest {
        val loss = FlowDeliveryPairingLoss()
        DaemonDesktopProbe(pairing = { pairing }, desktopFor = { rejecting("err.not_paired") }, pairingLoss = loss).probe()

        assertTrue(loss.isLost(PairingEpoch("e1")))
        assertFalse("重新配对换了 epoch 之后不能还亮着红卡", loss.isLost(PairingEpoch("e2")))
    }

    @Test
    fun `an ordinary rejection does not claim the pairing is lost`() = runTest {
        val loss = FlowDeliveryPairingLoss()
        val probe = DaemonDesktopProbe(pairing = { pairing }, desktopFor = { rejecting("err.library_unavailable") }, pairingLoss = loss)

        assertEquals(ProbeResult.Unreachable, probe.probe())
        assertFalse(loss.isLost(PairingEpoch("e1")))
    }
}
