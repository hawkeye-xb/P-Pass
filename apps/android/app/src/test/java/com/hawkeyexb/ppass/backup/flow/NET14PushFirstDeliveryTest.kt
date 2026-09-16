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
            TransferStatus.InProgress(connected = true, idleForMs = 1500L),
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

    // ── flowWaitStep ─────────────────────────────────────────────

    @Test
    fun a_delivered_push_resolves_immediately_regardless_of_local_status() {
        val receipt = FlowCompletionReceipt(queueSequence = 7L)
        val step = flowWaitStep(
            pushed = FlowPushOutcome.Delivered(receipt),
            localStatus = TransferStatus.InProgress(connected = false, idleForMs = 99_999L),
            idleStallThresholdMs = 30_000L,
            attemptElapsedMs = 0L,
        )
        assertEquals(
            FlowWaitStep.Resolved(FlowStatusPollOutcome.Completed(receipt)),
            step,
        )
    }

    @Test
    fun a_failed_push_throws_a_pushed_failure_exception() {
        try {
            flowWaitStep(
                pushed = FlowPushOutcome.Failed("fetch_failed"),
                localStatus = TransferStatus.InProgress(connected = true, idleForMs = 0L),
                idleStallThresholdMs = 30_000L,
                attemptElapsedMs = 0L,
            )
            throw AssertionError("expected FlowPushedFailureException")
        } catch (failure: FlowPushedFailureException) {
            assertEquals("fetch_failed", failure.code)
        }
    }

    @Test
    fun connected_local_status_keeps_waiting_for_push_no_matter_how_long_idle_is_zero() {
        // The core NET-14 property: an actively-connected transfer is NEVER
        // treated as stalled, regardless of a fixed clock — only "nobody
        // connected" plus an idle threshold can trigger the fallback.
        val step = flowWaitStep(
            pushed = null,
            localStatus = TransferStatus.InProgress(connected = true, idleForMs = 999_999L),
            idleStallThresholdMs = 30_000L,
            attemptElapsedMs = 999_999L,
        )
        assertEquals(FlowWaitStep.KeepWaitingForPush, step)
    }

    @Test
    fun disconnected_and_under_the_stall_threshold_keeps_waiting() {
        val step = flowWaitStep(
            pushed = null,
            localStatus = TransferStatus.InProgress(connected = false, idleForMs = 10_000L),
            idleStallThresholdMs = 30_000L,
            attemptElapsedMs = 10_000L,
        )
        assertEquals(FlowWaitStep.KeepWaitingForPush, step)
    }

    @Test
    fun disconnected_and_past_the_stall_threshold_falls_back_to_status_check() {
        val step = flowWaitStep(
            pushed = null,
            localStatus = TransferStatus.InProgress(connected = false, idleForMs = 30_001L),
            idleStallThresholdMs = 30_000L,
            attemptElapsedMs = 30_001L,
        )
        assertEquals(FlowWaitStep.CheckStatusNow, step)
    }

    @Test
    fun disconnected_with_no_activity_ever_but_still_under_the_stall_threshold_keeps_waiting() {
        // A brand-new transfer starts exactly here: connected=false,
        // idleForMs=null (no iroh-blobs event has fired yet because the
        // daemon has not connected yet). Must NOT be treated as stalled
        // just because idleForMs is null — only the attempt's own elapsed
        // time may promote this to a status check.
        val step = flowWaitStep(
            pushed = null,
            localStatus = TransferStatus.InProgress(connected = false, idleForMs = null),
            idleStallThresholdMs = 30_000L,
            attemptElapsedMs = 5_000L,
        )
        assertEquals(FlowWaitStep.KeepWaitingForPush, step)
    }

    @Test
    fun disconnected_with_no_activity_ever_past_the_stall_threshold_falls_back_to_status_check() {
        // NET: a grant the daemon completed without ever touching the data
        // plane (content-already-exists dedup, or a rebind of an
        // already-completed tuple) never fires a single iroh-blobs event on
        // this phone's sender side — idleForMs stays null forever, not just
        // at the start. Without this branch the attempt hangs forever
        // whenever the flow.delivered push is also missed (real device,
        // 2026-09-16).
        val step = flowWaitStep(
            pushed = null,
            localStatus = TransferStatus.InProgress(connected = false, idleForMs = null),
            idleStallThresholdMs = 30_000L,
            attemptElapsedMs = 30_001L,
        )
        assertEquals(FlowWaitStep.CheckStatusNow, step)
    }

    @Test
    fun no_lease_locally_falls_back_to_status_check() {
        // No local registration at all is itself an inconsistency this
        // attempt should resolve via the daemon, not sit on indefinitely.
        val step = flowWaitStep(
            pushed = null,
            localStatus = TransferStatus.NoLease,
            idleStallThresholdMs = 30_000L,
            attemptElapsedMs = 0L,
        )
        assertEquals(FlowWaitStep.CheckStatusNow, step)
    }

    @Test
    fun local_completed_status_falls_back_to_status_check_to_confirm_with_a_durable_receipt() {
        // The phone's own sender-side "completed" event is not itself a
        // receipt — it must still be confirmed against the daemon's
        // durable state before this attempt accepts it.
        val step = flowWaitStep(
            pushed = null,
            localStatus = TransferStatus.Completed("d".repeat(64)),
            idleStallThresholdMs = 30_000L,
            attemptElapsedMs = 0L,
        )
        assertEquals(FlowWaitStep.CheckStatusNow, step)
    }

    private data class FlowTupleRefFixture(val queueSequence: Long, val pairingEpoch: String, val leaseToken: String) {
        fun toRef() = com.hawkeyexb.ppass.proto.FlowTupleRef(
            queueSequence = queueSequence,
            pairingEpoch = pairingEpoch,
            leaseToken = leaseToken,
        )
    }
}
