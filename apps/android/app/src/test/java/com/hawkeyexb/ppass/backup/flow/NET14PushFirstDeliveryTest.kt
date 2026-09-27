package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * NET-14: pure decision functions the phone's push-first wait loop is
 * built from — transfer_status() JSON decode, push-vs-tuple matching, and
 * the priority order (push > local signal > bounded status() fallback).
 * These are the JVM-testable seam; the coroutine wiring itself
 * (NativeFlowDeliveryPort.start's launch block) is exercised on real
 * devices, same split as NET06StatusPollDeliveryTest.
 */
class NET14PushFirstDeliveryTest {

    // ── parseTransferStatus ──────────────────────────────────────

    @Test
    fun no_lease_json_decodes_to_no_lease() {
        assertEquals(TransferStatus.NoLease, parseTransferStatus("""{"state":"no_lease"}"""))
    }

    @Test
    fun completed_json_decodes_with_hash() {
        val hash = "a".repeat(64)
        assertEquals(
            TransferStatus.Completed(hash),
            parseTransferStatus("""{"state":"completed","hash":"$hash"}"""),
        )
    }

    @Test
    fun aborted_json_decodes_with_hash() {
        val hash = "b".repeat(64)
        assertEquals(
            TransferStatus.Aborted(hash),
            parseTransferStatus("""{"state":"aborted","hash":"$hash"}"""),
        )
    }

    @Test
    fun in_progress_json_decodes_connected_and_idle() {
        assertEquals(
            TransferStatus.InProgress(connected = true, idleForMs = 1500L, bytesSent = null, byteIdleForMs = null),
            parseTransferStatus("""{"state":"in_progress","connected":true,"idle_for_ms":1500}"""),
        )
    }

    @Test
    fun in_progress_json_with_null_idle_decodes_null() {
        assertEquals(
            TransferStatus.InProgress(connected = false, idleForMs = null),
            parseTransferStatus("""{"state":"in_progress","connected":false}"""),
        )
    }

    @Test
    fun unrecognized_state_degrades_to_no_lease_not_a_throw() {
        // Counterexample: a future native build's new state must not crash
        // an older phone build — this is a local convenience signal, not a
        // durable wire contract the phone must reject unknown values from.
        assertEquals(TransferStatus.NoLease, parseTransferStatus("""{"state":"something_new"}"""))
    }

    // ── parseFlowPushOutcome ─────────────────────────────────────

    private val tuple = FlowTupleRefFixture(queueSequence = 7L, pairingEpoch = "epoch-1", leaseToken = "lease-7")

    @Test
    fun delivered_push_matching_the_tuple_yields_delivered_with_receipt() {
        val receipt = FlowCompletionReceipt(
            queueSequence = 7L,
            receiptId = "desktop-1",
            pairingEpoch = "epoch-1",
            leaseToken = "lease-7",
            contentHash = "c".repeat(64),
        )
        val data = buildJsonObject {
            put("node_id", JsonPrimitive("phone-node"))
            put("queue_sequence", JsonPrimitive(7L))
            put("pairing_epoch", JsonPrimitive("epoch-1"))
            put("lease_token", JsonPrimitive("lease-7"))
            put(
                "receipt",
                com.hawkeyexb.ppass.proto.ProtoJson.encodeToJsonElement(
                    FlowCompletionReceipt.serializer(),
                    receipt,
                ),
            )
        }
        val outcome = parseFlowPushOutcome("flow.delivered", data, tuple.toRef())
        assertEquals(FlowPushOutcome.Delivered(receipt), outcome)
    }

    @Test
    fun failed_push_matching_the_tuple_yields_failed_with_code() {
        val data = buildJsonObject {
            put("node_id", JsonPrimitive("phone-node"))
            put("queue_sequence", JsonPrimitive(7L))
            put("pairing_epoch", JsonPrimitive("epoch-1"))
            put("lease_token", JsonPrimitive("lease-7"))
            put("code", JsonPrimitive("fetch_failed"))
        }
        val outcome = parseFlowPushOutcome("flow.failed", data, tuple.toRef())
        assertEquals(FlowPushOutcome.Failed("fetch_failed"), outcome)
    }

    @Test
    fun push_for_a_different_tuple_is_ignored() {
        // Counterexample: a stale push for a PREVIOUS attempt (superseded
        // offer, old lease) must not resolve THIS attempt's wait — the
        // exact tuple identity is the only thing that may match.
        val data = buildJsonObject {
            put("queue_sequence", JsonPrimitive(7L))
            put("pairing_epoch", JsonPrimitive("epoch-1"))
            put("lease_token", JsonPrimitive("lease-STALE"))
            put("code", JsonPrimitive("fetch_failed"))
        }
        assertNull(parseFlowPushOutcome("flow.failed", data, tuple.toRef()))
    }

    @Test
    fun delivered_push_missing_a_receipt_is_ignored() {
        val data = buildJsonObject {
            put("queue_sequence", JsonPrimitive(7L))
            put("pairing_epoch", JsonPrimitive("epoch-1"))
            put("lease_token", JsonPrimitive("lease-7"))
        }
        assertNull(parseFlowPushOutcome("flow.delivered", data, tuple.toRef()))
    }

    // flowWaitStep 的判据（#410 新参数：15s / 3min 字节停滞）由 ARCH13DeliveryPortTest 覆盖。

    private data class FlowTupleRefFixture(val queueSequence: Long, val pairingEpoch: String, val leaseToken: String) {
        fun toRef() = com.hawkeyexb.ppass.proto.FlowTupleRef(
            queueSequence = queueSequence,
            pairingEpoch = pairingEpoch,
            leaseToken = leaseToken,
        )
    }
}
