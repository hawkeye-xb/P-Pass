// #1072 acceptance 1 + 2: every reason in the Rust registry has an explicit control-flow class and
// phone-side wording, and on every channel a v2 reply reaches the same conclusion the pre-v2
// `msg_key` did — except the rows the reviewer signed off on (grant_not_found / grant_conflict and
// the two cases #1070 split out of GuardMismatch), which are pinned separately below.
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
import com.hawkeyexb.ppass.ui.updateNeededBodyRes
import com.hawkeyexb.ppass.ui.updateNeededTitleRes
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
        Reason.STORAGE_FULL to ReasonClass.STORAGE_FULL,
        Reason.LIBRARY_UNAVAILABLE to ReasonClass.LIBRARY_UNAVAILABLE,
        Reason.STORAGE_FAILED to ReasonClass.STORAGE_FAILED,
        Reason.FETCH_FAILED to ReasonClass.PATH,
        Reason.GRANT_NOT_FOUND to ReasonClass.OTHER,
        Reason.GRANT_CONFLICT to ReasonClass.OTHER,
        Reason.CANCELLED to ReasonClass.OTHER,
        Reason.PAIR_TOKEN_INVALID to ReasonClass.OTHER,
        Reason.UNSUPPORTED_METHOD to ReasonClass.OTHER,
        Reason.BAD_REQUEST to ReasonClass.OTHER,
        Reason.NOT_FOUND to ReasonClass.OTHER,
        Reason.INTERNAL to ReasonClass.OTHER,
        Reason.BACKUP_FAILED to ReasonClass.OTHER,
        Reason.UNKNOWN to ReasonClass.OTHER,
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
        // OUTDATED → the new update prompt, one per side, plus the waiting line.
        for (side in OutdatedSide.entries) {
            assertTrue(updateNeededTitleRes(side) != 0 && updateNeededBodyRes(side) != 0)
        }
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
            "pair_refused_detail_restarted", "error_generic", "update_needed_phone_title", "update_needed_desktop_title",
            "update_needed_phone_body", "update_needed_desktop_body", "pair_needs_update_phone_body",
            "pair_needs_update_desktop_body", "state_waiting_phone_outdated", "state_waiting_desktop_outdated",
        )
        for (dir in listOf("values", "values-zh")) {
            val xml = File("src/main/res/$dir/strings.xml").readText()
            for (n in names) assertTrue("$dir missing $n", Regex("""name="$n">[^<]+<""").containsMatchIn(xml))
        }
    }

    // ── acceptance 2: same conclusion as before v2, channel by channel ──

    private fun rejected(reason: String) = classifyDeliveryFailure(DesktopRejectedException(reason, "flow.offer"))

    @Test
    fun `offer and status rejections keep their pre-v2 outcome`() {
        // err.not_paired / err.not_authorized (revoked, epoch, role) → pairing lost.
        for (r in listOf("not_paired", "revoked", "epoch_mismatch", "role_forbidden")) {
            assertEquals(r, DeliveryOutcome.PairingLost, rejected(r))
        }
        // storage_full / library_unavailable / storage_failed → peer failure (not counted).
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_FULL, "storage_full"), rejected("storage_full"))
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.LIBRARY_UNAVAILABLE, "library_unavailable"), rejected("library_unavailable"))
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_ERROR, "storage_failed"), rejected("storage_failed"))
        // err.unsupported (bad request, internal, not found, …) → one item failed.
        for (r in listOf("bad_request", "internal", "not_found", "backup_failed", "unsupported_method", "pair_token_invalid", "from_the_future")) {
            assertEquals(r, DeliveryOutcome.ItemFailure("rejected:$r"), rejected(r))
        }
    }

    @Test
    fun `signed-off change - a grant out of step is one item, not a lost pairing`() {
        // Before v2 these came as err.not_authorized and lit the "pairing lost" card + notice (#1072 sign-off).
        for (r in listOf("grant_not_found", "grant_conflict", "cancelled")) {
            assertEquals(r, DeliveryOutcome.ItemFailure("rejected:$r"), rejected(r))
        }
        val loss = FlowDeliveryPairingLoss()
        loss.record(PairingEpoch("e1"), DesktopRejectedException("grant_conflict", "flow.offer"))
        assertFalse(loss.isLost(PairingEpoch("e1")))
    }

    @Test
    fun `flow failed pushes keep their pre-v2 outcome - never pairing lost`() {
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_FULL, "storage_full"), classifyPushedFailure("storage_full"))
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.LIBRARY_UNAVAILABLE, "library_unavailable"), classifyPushedFailure("library_unavailable"))
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_ERROR, "storage_failed"), classifyPushedFailure("storage_failed"))
        assertEquals(DeliveryOutcome.PathFailure("fetch_failed"), classifyPushedFailure("fetch_failed"))
        // Before v2: guard_mismatch / cancelled / invalid_request → one item failed. Same now.
        for (r in listOf("epoch_mismatch", "grant_not_found", "grant_conflict", "cancelled", "bad_request", "internal", "from_the_future")) {
            assertEquals(r, DeliveryOutcome.ItemFailure("pushed:$r"), classifyPushedFailure(r))
        }
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
        for (r in listOf("internal", "unsupported_method", "bad_request", "from_the_future")) {
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
        var reachable = 0
        var lost = 0
        applyHeartbeatOutcome(null, Result.success(Resp(ok = false, error = RespError("VERSION_MISMATCH", "desktop_outdated"))), onPairingLost = { lost++ }) { reachable++ }
        assertEquals("心跳遇到版本不兼容：既不算可达（不叫醒引擎），也不算配对失效", 0 to 0, reachable to lost)
    }
}
