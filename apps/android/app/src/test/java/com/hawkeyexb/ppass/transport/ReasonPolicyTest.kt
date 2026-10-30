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
import com.hawkeyexb.ppass.backup.flow.PairingId
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
import com.hawkeyexb.ppass.ui.pairRefusalErrorCode
import com.hawkeyexb.ppass.ui.pairRefusalTitleRes
import com.hawkeyexb.ppass.ui.outdatedTextRes
import java.io.File
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReasonPolicyTest {

    /** The table, written out once more by hand: a change to [reasonClassOf] must change this too. */
    private val pinned: Map<Reason, ReasonClass> = mapOf(
        Reason.NOT_PAIRED to ReasonClass.PAIRING_LOST,
        Reason.PAIRING_MISMATCH to ReasonClass.PAIRING_LOST,
        // #1119: role_forbidden = paired, but this role may not call that method — never a reason to unpair.
        Reason.ROLE_FORBIDDEN to ReasonClass.ITEM_FAILED,
        Reason.PHONE_OUTDATED to ReasonClass.OUTDATED,
        Reason.DESKTOP_OUTDATED to ReasonClass.OUTDATED,
        Reason.UNSUPPORTED_METHOD to ReasonClass.OUTDATED,
        Reason.STORAGE_FULL to ReasonClass.STORAGE_FULL,
        Reason.LIBRARY_UNAVAILABLE to ReasonClass.LIBRARY_UNAVAILABLE,
        Reason.STORAGE_FAILED to ReasonClass.STORAGE_FAILED,
        Reason.INTERNAL to ReasonClass.DESKTOP_INTERNAL,
        Reason.FETCH_FAILED to ReasonClass.PATH,
        Reason.GRANT_NOT_FOUND to ReasonClass.ITEM_FAILED,
        Reason.GRANT_CONFLICT to ReasonClass.ITEM_FAILED,
        Reason.BAD_REQUEST to ReasonClass.ITEM_FAILED,
        Reason.NOT_FOUND to ReasonClass.ITEM_FAILED,
        Reason.BACKUP_FAILED to ReasonClass.ITEM_FAILED,
        Reason.CANCELLED to ReasonClass.ITEM_FAILED,
        Reason.PAIR_TOKEN_INVALID to ReasonClass.ITEM_FAILED,
        Reason.PAIR_CODE_WRONG to ReasonClass.ITEM_FAILED,
        Reason.UNKNOWN to ReasonClass.ITEM_FAILED,
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
        // DESKTOP_INTERNAL → "P-Pass on the computer ran into an error"; ITEM_FAILED → the existing failed-photo UI.
        assertEquals(R.string.state_waiting_desktop_internal, waitReasonTextRes(WaitReason.DESKTOP_INTERNAL, null))
        // OUTDATED → one sentence per side (status card + pairing body).
        assertEquals(R.string.state_waiting_phone_outdated, outdatedTextRes(OutdatedSide.PHONE))
        assertEquals(R.string.state_waiting_desktop_outdated, outdatedTextRes(OutdatedSide.DESKTOP))
        assertEquals(R.string.state_waiting_phone_outdated, waitReasonTextRes(WaitReason.PHONE_OUTDATED, null))
        assertEquals(R.string.state_waiting_desktop_outdated, waitReasonTextRes(WaitReason.DESKTOP_OUTDATED, null))
        // Pairing: one detail line per cause, and an unknown reason gets the generic one — never blank.
        // 10-29 B5: the owner's "decline" is the only cause without a line (the title says it).
        val details = PairRefusal.entries.filter { it != PairRefusal.DENIED }.map(::pairRefusalDetailRes)
        assertTrue(details.all { it != null })
        assertEquals(details.size, details.toSet().size)
        assertNull(pairRefusalDetailRes(PairRefusal.DENIED))
        assertEquals(R.string.error_generic, pairRefusalDetailRes(pairRefusalOf(Reason.UNKNOWN)))
        assertEquals(R.string.pair_refused_detail_token_invalid, pairRefusalDetailRes(pairRefusalOf(Reason.PAIR_TOKEN_INVALID)))
        // 10-29 B13: only the generic line carries an error code, and it is the key without its prefix.
        assertEquals("generic", pairRefusalErrorCode(PairRefusal.OTHER))
        assertTrue(PairRefusal.entries.filter { it != PairRefusal.OTHER }.all { pairRefusalErrorCode(it) == null })
        // 10-29 C10: an expired QR code is its own page — title "QR code expired", body "valid for 10 minutes".
        // Disproof: QR_EXPIRED falls back to the lapsed title / old detail line → red.
        assertEquals(R.string.pair_qr_expired_title, pairRefusalTitleRes(PairRefusal.QR_EXPIRED))
        assertEquals(R.string.pair_qr_expired_body, pairRefusalDetailRes(PairRefusal.QR_EXPIRED))
        assertEquals(R.string.pair_refused_title, pairRefusalTitleRes(PairRefusal.DENIED))
        for (c in PairRefusal.entries.filter { it != PairRefusal.DENIED && it != PairRefusal.QR_EXPIRED }) {
            assertEquals("$c", R.string.pair_lapsed_title, pairRefusalTitleRes(c))
        }
    }

    @Test
    fun `the new wording exists in both languages`() {
        val names = listOf(
            "pair_refused_detail_token_invalid", "pair_refused_detail_expired",
            "pair_refused_detail_restarted", "error_generic", "error_code_line", "pair_qr_expired_title", "pair_qr_expired_body", "pair_needs_update_title",
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
        "not_paired", "pairing_mismatch" -> DeliveryOutcome.PairingLost
        "phone_outdated" -> DeliveryOutcome.NeedsUpdate(OutdatedSide.PHONE)
        "desktop_outdated", "unsupported_method" -> DeliveryOutcome.NeedsUpdate(OutdatedSide.DESKTOP)
        "storage_full" -> DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_FULL, reason)
        "library_unavailable" -> DeliveryOutcome.PeerFailure(PeerFailureKind.LIBRARY_UNAVAILABLE, reason)
        "storage_failed" -> DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_ERROR, reason)
        "internal" -> DeliveryOutcome.PeerFailure(PeerFailureKind.DESKTOP_INTERNAL, reason)
        "fetch_failed" -> DeliveryOutcome.PathFailure(reason)
        else -> DeliveryOutcome.ItemFailure("$channel:$reason")
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
    fun `what should not happen is one item failed - and nothing the desktop or the network did is`() {
        val counted = (registry() + "from_the_future").filter {
            rejected(it) is DeliveryOutcome.ItemFailure && classifyPushedFailure(it) is DeliveryOutcome.ItemFailure
        }
        assertEquals(
            listOf("role_forbidden", "pair_token_invalid", "pair_code_wrong", "bad_request", "not_found", "backup_failed", "grant_not_found", "grant_conflict", "cancelled", "from_the_future"),
            counted,
        )
    }

    @Test
    fun `a lost pairing is recorded from a push as well as from a rejection`() {
        val loss = FlowDeliveryPairingLoss()
        loss.record(PairingId("e1"), com.hawkeyexb.ppass.backup.flow.FlowPushedFailureException("pairing_mismatch"))
        assertTrue(loss.isLost(PairingId("e1")))
        val other = FlowDeliveryPairingLoss()
        other.record(PairingId("e1"), DesktopRejectedException("grant_conflict", "flow.offer"))
        other.record(PairingId("e1"), com.hawkeyexb.ppass.backup.flow.FlowPushedFailureException("grant_not_found"))
        other.record(PairingId("e1"), DesktopRejectedException("internal", "flow.offer"))
        assertFalse(other.isLost(PairingId("e1")))
    }

    private fun rejectingHello(reason: String) = object : FlowReceiptClient {
        override suspend fun currentPairingId(): String? = error("unused")
        override suspend fun probeHello(trace: (CallTrace) -> Unit): Hello = throw DesktopRejectedException(reason, "hello")
        override suspend fun offer(request: FlowFetchRequest) = FlowStatusReply(state = "active")
        override suspend fun status(tuple: FlowTupleRef) = FlowStatusReply(state = "active")
        override suspend fun suspendFetch(tuple: FlowTupleRef) = Unit
    }

    private val pairing = Pairing(daemonNodeId = "d", daemonAddrToken = "unused", storageDeviceName = "desk", pairingId = "e1")

    private suspend fun probe(reason: String, loss: FlowDeliveryPairingLoss = FlowDeliveryPairingLoss()) =
        DaemonDesktopProbe(pairing = { pairing }, desktopFor = { rejectingHello(reason) }, pairingLoss = loss).probe()

    @Test
    fun `hello probes - pairing lost for not_paired, unreachable otherwise`() = runTest {
        assertEquals(ProbeResult.PairingLost, probe("not_paired"))
        for (r in listOf("internal", "bad_request", "role_forbidden", "from_the_future")) {
            assertEquals(r, ProbeResult.Unreachable, probe(r))
        }
    }

    @Test
    fun `heartbeat - pairing lost for not_paired, reachable for other rejections`() {
        fun beat(reason: String): Pair<Int, Int> {
            var reachable = 0
            var lost = 0
            applyHeartbeatOutcome(null, Result.success(Resp(ok = false, error = RespError("X", reason))), onPairingLost = { lost++ }) { reachable++ }
            return reachable to lost
        }
        assertEquals(0 to 1, beat("not_paired"))
        assertEquals(1 to 0, beat("internal"))
        assertEquals(1 to 0, beat("from_the_future"))
        assertEquals("#1119: role_forbidden is a paired phone calling a forbidden method, not an unpairing", 1 to 0, beat("role_forbidden"))
        assertEquals(0 to 1, beat("pairing_mismatch"))
    }

    // ── version: decided at the handshake, before anything else ──

    @Test
    fun `an incompatible version is never pairing lost and never counted`() = runTest {
        val loss = FlowDeliveryPairingLoss()
        assertEquals(ProbeResult.NeedsUpdate(OutdatedSide.PHONE), probe("phone_outdated", loss))
        assertEquals(ProbeResult.NeedsUpdate(OutdatedSide.DESKTOP), probe("desktop_outdated", loss))
        assertFalse("版本不兼容不点亮配对失效红卡", loss.isLost(PairingId("e1")))
        assertEquals(DeliveryOutcome.NeedsUpdate(OutdatedSide.PHONE), rejected("phone_outdated"))
        assertEquals(DeliveryOutcome.NeedsUpdate(OutdatedSide.DESKTOP), rejected("desktop_outdated"))
        assertEquals(DeliveryOutcome.NeedsUpdate(OutdatedSide.DESKTOP), rejected("unsupported_method"))
        var reachable = 0
        var lost = 0
        applyHeartbeatOutcome(null, Result.success(Resp(ok = false, error = RespError("VERSION_MISMATCH", "desktop_outdated"))), onPairingLost = { lost++ }) { reachable++ }
        assertEquals("心跳遇到版本不兼容：既不算可达（不叫醒引擎），也不算配对失效", 0 to 0, reachable to lost)
    }
}
