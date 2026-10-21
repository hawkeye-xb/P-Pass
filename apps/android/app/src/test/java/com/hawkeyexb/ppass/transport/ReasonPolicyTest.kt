// #1072 acceptance 1 + 2: every reason in the Rust registry has an explicit control-flow class and
// phone-side wording, per the #1069 sign-off table (one table for offer / status rejections and
// `flow.failed` pushes alike; hello probe and heartbeat keep their own narrower verdicts).
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.flow.DaemonDesktopProbe
import com.hawkeyexb.ppass.backup.flow.DeliveryOutcome
import com.hawkeyexb.ppass.backup.flow.DesktopRejectedException
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.FlowReceiptClient
import com.hawkeyexb.ppass.backup.flow.PairingEpoch
import com.hawkeyexb.ppass.backup.flow.PeerFailureKind
import com.hawkeyexb.ppass.backup.flow.ProbeResult
import com.hawkeyexb.ppass.backup.flow.WaitReason
import com.hawkeyexb.ppass.backup.flow.classifyDeliveryFailure
import com.hawkeyexb.ppass.backup.flow.classifyPushedFailure
import com.hawkeyexb.ppass.backup.flow.waitReasonTextRes
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Reason
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.RespError
import com.hawkeyexb.ppass.ui.pairRefusalDetailRes
import com.hawkeyexb.ppass.ui.outdatedTextRes
import java.io.File
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReasonPolicyTest {

    /** The table, written out once more by hand: a change to [reasonClassOf] must change this too. */
    private val pinned: Map<Reason, ReasonClass> = mapOf(
        Reason.NOT_PAIRED to ReasonClass.PAIRING_LOST,
        Reason.REVOKED to ReasonClass.PAIRING_LOST,
        Reason.EPOCH_MISMATCH to ReasonClass.PAIRING_LOST,
        Reason.ROLE_FORBIDDEN to ReasonClass.PAIRING_LOST,
        Reason.PHONE_OUTDATED to ReasonClass.OUTDATED,
        Reason.DESKTOP_OUTDATED to ReasonClass.OUTDATED,
        Reason.UNSUPPORTED_METHOD to ReasonClass.OUTDATED,
        Reason.STORAGE_FULL to ReasonClass.STORAGE_FULL,
        Reason.LIBRARY_UNAVAILABLE to ReasonClass.LIBRARY_UNAVAILABLE,
        Reason.STORAGE_FAILED to ReasonClass.STORAGE_FAILED,
        Reason.INTERNAL to ReasonClass.DESKTOP_INTERNAL,
        Reason.FETCH_FAILED to ReasonClass.PATH,
        Reason.GRANT_NOT_FOUND to ReasonClass.GRANT_OUT_OF_STEP,
        Reason.GRANT_CONFLICT to ReasonClass.GRANT_OUT_OF_STEP,
        Reason.BAD_REQUEST to ReasonClass.PHONE_ERROR,
        Reason.NOT_FOUND to ReasonClass.PHONE_ERROR,
        Reason.BACKUP_FAILED to ReasonClass.PHONE_ERROR,
        Reason.CANCELLED to ReasonClass.PHONE_ERROR,
        Reason.PAIR_TOKEN_INVALID to ReasonClass.PHONE_ERROR,
        Reason.UNKNOWN to ReasonClass.PHONE_ERROR,
    )

    private fun registry(): List<String> {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "crates/proto/tests/snapshots").isDirectory) dir = dir.parentFile!!
        val text = File(dir, "crates/proto/tests/snapshots/snapshots__reasons_registry.snap").readText()
        val body = text.split("---", limit = 3)[2].trim()
        return ProtoJson.decodeFromJsonElement(ListSerializer(RespError.serializer()), Json.parseToJsonElement(body))
            .map { it.reason }
    }

    // ── acceptance 1: exhaustive ────────────────────────

    @Test
    fun `every registered reason has an explicit class, and the table is pinned`() {
        val wire = registry()
        assertEquals(19, wire.size)
        for (r in wire) {
            val kind = Reason.fromWire(r)
            assertFalse("Rust reason $r is not mirrored", kind == Reason.UNKNOWN)
            assertNotNull("no pinned class for $r", pinned[kind])
        }
        for (kind in Reason.entries) assertEquals(kind.name, pinned[kind], reasonClassOf(kind))
        assertEquals(Reason.entries.toSet(), pinned.keys)
    }

    @Test
    fun `every class a reason can land on has phone-side wording`() {
        // PAIRING_LOST → the existing red card; storage → the existing waiting lines; PATH → unreachable line.
        assertNotNull(waitReasonTextRes(WaitReason.DESKTOP_STORAGE_FULL, null))
        assertNotNull(waitReasonTextRes(WaitReason.DESKTOP_LIBRARY_UNAVAILABLE, null))
        assertNotNull(waitReasonTextRes(WaitReason.DESKTOP_STORAGE_ERROR, null))
        assertNotNull(waitReasonTextRes(WaitReason.DESKTOP_UNREACHABLE, null))
        // DESKTOP_INTERNAL → "P-Pass on the computer ran into an error"; PHONE_ERROR → the generic backoff line.
        assertEquals(R.string.state_waiting_desktop_internal, waitReasonTextRes(WaitReason.DESKTOP_INTERNAL, null))
        assertNotNull(waitReasonTextRes(WaitReason.UNEXPECTED_ERROR, null))
        // OUTDATED → one sentence per side (status card + pairing body).
        assertEquals(R.string.state_waiting_phone_outdated, outdatedTextRes(OutdatedSide.PHONE))
        assertEquals(R.string.state_waiting_desktop_outdated, outdatedTextRes(OutdatedSide.DESKTOP))
        assertEquals(R.string.state_waiting_phone_outdated, waitReasonTextRes(WaitReason.PHONE_OUTDATED, null))
        assertEquals(R.string.state_waiting_desktop_outdated, waitReasonTextRes(WaitReason.DESKTOP_OUTDATED, null))
        // Pairing: one detail line per cause, and an unknown reason gets the generic one — never blank.
        val details = PairRefusal.entries.map(::pairRefusalDetailRes)
        assertEquals(PairRefusal.entries.size, details.toSet().size)
        assertEquals(R.string.error_generic, pairRefusalDetailRes(pairRefusalOf(Reason.UNKNOWN)))
        assertEquals(R.string.pair_refused_detail_token_invalid, pairRefusalDetailRes(pairRefusalOf(Reason.PAIR_TOKEN_INVALID)))
    }

    @Test
    fun `the new wording exists in both languages`() {
        val names = listOf(
            "pair_refused_detail_token_invalid", "pair_refused_detail_denied", "pair_refused_detail_expired",
            "pair_refused_detail_restarted", "error_generic", "pair_needs_update_title",
            "state_waiting_phone_outdated", "state_waiting_desktop_outdated", "state_waiting_desktop_internal",
        )
        for (dir in listOf("values", "values-zh")) {
            val xml = File("src/main/res/$dir/strings.xml").readText()
            for (n in names) assertTrue("$dir missing $n", Regex("""name="$n">[^<]+<""").containsMatchIn(xml))
        }
    }

    // ── acceptance 2: the sign-off table on every delivery channel ──

    private fun rejected(reason: String) = classifyDeliveryFailure(DesktopRejectedException(reason, "flow.offer"))

    /** The conclusion for [reason] on a delivery channel; the same table for rejections and pushes. */
    private fun expected(reason: String, channel: String): DeliveryOutcome = when (reason) {
        "not_paired", "revoked", "epoch_mismatch", "role_forbidden" -> DeliveryOutcome.PairingLost
        "phone_outdated" -> DeliveryOutcome.NeedsUpdate(OutdatedSide.PHONE)
        "desktop_outdated", "unsupported_method" -> DeliveryOutcome.NeedsUpdate(OutdatedSide.DESKTOP)
        "storage_full" -> DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_FULL, reason)
        "library_unavailable" -> DeliveryOutcome.PeerFailure(PeerFailureKind.LIBRARY_UNAVAILABLE, reason)
        "storage_failed" -> DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_ERROR, reason)
        "internal" -> DeliveryOutcome.PeerFailure(PeerFailureKind.DESKTOP_INTERNAL, reason)
        "fetch_failed" -> DeliveryOutcome.PathFailure(reason)
        // 待拍板：维持 v2 之前——被拒 = err.not_authorized（配对失效），推送 = guard_mismatch（单张失败）。
        "grant_not_found", "grant_conflict" ->
            if (channel == "rejected") DeliveryOutcome.PairingLost else DeliveryOutcome.ItemFailure("$channel:$reason")
        else -> DeliveryOutcome.PhoneError("$channel:$reason")
    }

    @Test
    fun `offer and status rejections follow the sign-off table`() {
        for (r in registry() + "from_the_future") assertEquals(r, expected(r, "rejected"), rejected(r))
    }

    @Test
    fun `flow failed pushes follow the same table`() {
        for (r in registry() + "from_the_future") assertEquals(r, expected(r, "pushed"), classifyPushedFailure(r))
    }

    @Test
    fun `only a problem with the photo itself is counted - nothing the phone or desktop got wrong`() {
        val counted = (registry() + "from_the_future").filter {
            rejected(it) is DeliveryOutcome.ItemFailure || classifyPushedFailure(it) is DeliveryOutcome.ItemFailure
        }
        // grant_* pushes stay counted only until their handling is signed off (#1072).
        assertEquals(listOf("grant_not_found", "grant_conflict"), counted)
    }

    @Test
    fun `a lost pairing is recorded from a push as well as from a rejection`() {
        val loss = FlowDeliveryPairingLoss()
        loss.record(PairingEpoch("e1"), com.hawkeyexb.ppass.backup.flow.FlowPushedFailureException("epoch_mismatch"))
        assertTrue(loss.isLost(PairingEpoch("e1")))
        val other = FlowDeliveryPairingLoss()
        other.record(PairingEpoch("e1"), com.hawkeyexb.ppass.backup.flow.FlowPushedFailureException("grant_conflict"))
        other.record(PairingEpoch("e1"), DesktopRejectedException("internal", "flow.offer"))
        assertFalse(other.isLost(PairingEpoch("e1")))
    }

    private fun rejectingHello(reason: String) = object : FlowReceiptClient {
        override suspend fun currentPairingEpoch(): String? = error("unused")
        override suspend fun probeHello(trace: (CallTrace) -> Unit): Hello = throw DesktopRejectedException(reason, "hello")
        override suspend fun offer(request: FlowFetchRequest) = FlowStatusReply(state = "active")
        override suspend fun status(tuple: FlowTupleRef) = FlowStatusReply(state = "active")
        override suspend fun suspendFetch(tuple: FlowTupleRef) = Unit
    }

    private val pairing = Pairing(daemonNodeId = "d", daemonAddrToken = "unused", storageDeviceName = "desk", pairingEpoch = "e1")

    private suspend fun probe(reason: String, loss: FlowDeliveryPairingLoss = FlowDeliveryPairingLoss()) =
        DaemonDesktopProbe(pairing = { pairing }, desktopFor = { rejectingHello(reason) }, pairingLoss = loss).probe()

    @Test
    fun `hello probes - pairing lost for not_paired and revoked, unreachable otherwise`() = runTest {
        assertEquals(ProbeResult.PairingLost, probe("not_paired"))
        assertEquals(ProbeResult.PairingLost, probe("revoked"))
        for (r in listOf("internal", "bad_request", "from_the_future")) {
            assertEquals(r, ProbeResult.Unreachable, probe(r))
        }
    }

    @Test
    fun `heartbeat - pairing lost for not_paired and revoked, reachable for other rejections`() {
        fun beat(reason: String): Pair<Int, Int> {
            var reachable = 0
            var lost = 0
            applyHeartbeatOutcome(null, Result.success(Resp(ok = false, error = RespError("X", reason))), onPairingLost = { lost++ }) { reachable++ }
            return reachable to lost
        }
        assertEquals(0 to 1, beat("not_paired"))
        assertEquals(0 to 1, beat("revoked"))
        assertEquals(1 to 0, beat("internal"))
        assertEquals(1 to 0, beat("from_the_future"))
    }

    // ── version: decided at the handshake, before anything else ──

    @Test
    fun `an incompatible version is never pairing lost and never counted`() = runTest {
        val loss = FlowDeliveryPairingLoss()
        assertEquals(ProbeResult.NeedsUpdate(OutdatedSide.PHONE), probe("phone_outdated", loss))
        assertEquals(ProbeResult.NeedsUpdate(OutdatedSide.DESKTOP), probe("desktop_outdated", loss))
        assertFalse("版本不兼容不点亮配对失效红卡", loss.isLost(PairingEpoch("e1")))
        assertEquals(DeliveryOutcome.NeedsUpdate(OutdatedSide.PHONE), rejected("phone_outdated"))
        assertEquals(DeliveryOutcome.NeedsUpdate(OutdatedSide.DESKTOP), rejected("desktop_outdated"))
        assertEquals(DeliveryOutcome.NeedsUpdate(OutdatedSide.DESKTOP), rejected("unsupported_method"))
        var reachable = 0
        var lost = 0
        applyHeartbeatOutcome(null, Result.success(Resp(ok = false, error = RespError("VERSION_MISMATCH", "desktop_outdated"))), onPairingLost = { lost++ }) { reachable++ }
        assertEquals("心跳遇到版本不兼容：既不算可达（不叫醒引擎），也不算配对失效", 0 to 0, reachable to lost)
    }
}
