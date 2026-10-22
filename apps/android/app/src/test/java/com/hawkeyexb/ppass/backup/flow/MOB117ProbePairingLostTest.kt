// #466（MOB-117）：桌面移除这台手机后，每轮先探测就被拒，走不到投递——探测必须自己记下配对失效，红卡才会亮。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.HolderPairingLostState
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.RespError
import com.hawkeyexb.ppass.transport.applyHeartbeatOutcome
import com.hawkeyexb.ppass.transport.CallTrace
import com.hawkeyexb.ppass.transport.Pairing
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class MOB117ProbePairingLostTest {
    private val pairing = Pairing(daemonNodeId = "d", daemonAddrToken = "unused", storageDeviceName = "desk", pairingId = "e1")

    private fun rejecting(reason: String) = object : FlowReceiptClient {
        override suspend fun currentPairingId(): String? = error("probe must use the traced entry point")
        override suspend fun probeHello(trace: (CallTrace) -> Unit): com.hawkeyexb.ppass.proto.Hello =
            throw DesktopRejectedException(reason, "hello")
        override suspend fun offer(request: FlowFetchRequest) = FlowStatusReply(state = "active")
        override suspend fun status(tuple: FlowTupleRef) = FlowStatusReply(state = "active")
        override suspend fun suspendFetch(tuple: FlowTupleRef) = Unit
    }

    @Test
    fun `a probe rejected as not authorized lights the pairing-lost card for the current pairing id`() = runTest {
        val loss = FlowDeliveryPairingLoss()
        val probe = DaemonDesktopProbe(pairing = { pairing }, desktopFor = { rejecting("not_paired") }, pairingLoss = loss)

        assertEquals(ProbeResult.PairingLost, probe.probe())
        assertTrue("探测判出配对失效却不记，红卡永远不亮（#466）", loss.isLost(PairingId("e1")))

        val card = HolderPairingLostState()
        card.syncFrom(loss, PairingId("e1"))
        assertTrue(card.value.value)
    }

    @Test
    fun `the loss belongs to the pid that was rejected, not to a later re-pair`() = runTest {
        val loss = FlowDeliveryPairingLoss()
        DaemonDesktopProbe(pairing = { pairing }, desktopFor = { rejecting("not_paired") }, pairingLoss = loss).probe()

        assertTrue(loss.isLost(PairingId("e1")))
        assertFalse("重新配对换了 pid 之后不能还亮着红卡", loss.isLost(PairingId("e2")))
    }

    @Test
    fun `an ordinary rejection does not claim the pairing is lost`() = runTest {
        val loss = FlowDeliveryPairingLoss()
        val probe = DaemonDesktopProbe(pairing = { pairing }, desktopFor = { rejecting("library_unavailable") }, pairingLoss = loss)

        assertEquals(ProbeResult.Unreachable, probe.probe())
        assertFalse(loss.isLost(PairingId("e1")))
    }

    // 接线门禁：探测只改视图、不写 order（revision 不动），所以 holder 必须在视图订阅里同步红卡，否则记了也不亮。
    @Test
    fun `the home holder syncs the pairing-lost card on every engine view, not only on order writes`() {
        val src = File("src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt").readText()
        val viewCollect = src.substringAfter("g.view.collect").substringBefore("\n    }\n")
        assertTrue("视图订阅里必须同步配对失效（#466）", viewCollect.contains("pairingLostState.syncFrom(flowDeliveryPairingLoss"))
    }

    // ── 前台心跳：打开 App 就能发现，不等下一张新照片 ──

    private fun rejectedHello(key: String) = Result.success(Resp(ok = false, error = RespError(code = "x", reason = key)))

    @Test
    fun `a heartbeat hello rejected as not authorized reports pairing lost and is not counted as reachable`() {
        var reachable = 0
        val lost = mutableListOf<Throwable>()
        applyHeartbeatOutcome(null, rejectedHello("not_paired"), onPairingLost = { lost += it }) { reachable++ }

        assertEquals("被移除不是「桌面回来了」，不能去叫醒引擎", 0, reachable)
        assertEquals(1, lost.size)
        val loss = FlowDeliveryPairingLoss()
        loss.record(PairingId("e1"), lost.single())
        assertTrue("心跳给出的失败必须能点亮红卡", loss.isLost(PairingId("e1")))
    }

    @Test
    fun `other heartbeat answers keep the old reachable semantics`() {
        var reachable = 0
        var lost = 0
        applyHeartbeatOutcome(null, Result.success(Resp(ok = true)), onPairingLost = { lost++ }) { reachable++ }
        applyHeartbeatOutcome(null, rejectedHello("library_unavailable"), onPairingLost = { lost++ }) { reachable++ }
        assertEquals(2, reachable)
        assertEquals(0, lost)
    }

    @Test
    fun `every recorded loss bumps the change signal the home card subscribes to`() {
        val loss = FlowDeliveryPairingLoss()
        val before = loss.changes.value
        loss.record(PairingId("e1"), DesktopRejectedException("not_paired", "hello"))
        loss.record(PairingId("e1"), DesktopRejectedException("backup_failed", "flow.offer"))
        assertEquals(before + 1, loss.changes.value)
    }

    @Test
    fun `the heartbeat is wired to the pairing-loss fact and the holder subscribes to it`() {
        val app = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val beat = app.substringAfter("ForegroundHeartbeat(").substringBefore("\n    }\n")
        assertTrue("心跳必须把 not_authorized 交给红卡（#466）", beat.contains("onPairingLost") && beat.contains("flowDeliveryPairingLoss.record"))
        val holder = File("src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt").readText()
        assertTrue("holder 必须订阅失效事实本身（#466）", holder.contains("flowDeliveryPairingLoss.changes.collect"))
    }
}
