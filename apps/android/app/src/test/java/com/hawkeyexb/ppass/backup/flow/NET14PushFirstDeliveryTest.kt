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
 * built from — push-vs-tuple matching, and
 * the priority order (push > local signal > bounded status() fallback).
 * These are the JVM-testable seam; the coroutine wiring itself
 * (NativeFlowDeliveryPort.start's launch block) is exercised on real
 * devices, same split as NET06StatusPollDeliveryTest.
 */
class NET14PushFirstDeliveryTest {

    // ── parseFlowPushOutcome ─────────────────────────────────────

    private val tuple = FlowTupleRefFixture(queueSequence = 7L, pairingId = "pid-1", leaseToken = "lease-7")

    @Test
    fun delivered_push_matching_the_tuple_yields_delivered_with_receipt() {
        val receipt = FlowCompletionReceipt(
            queueSequence = 7L,
            receiptId = "desktop-1",
            pairingId = "pid-1",
            leaseToken = "lease-7",
            contentHash = "c".repeat(64),
        )
        val data = buildJsonObject {
            put("node_id", JsonPrimitive("phone-node"))
            put("queue_sequence", JsonPrimitive(7L))
            put("pairing_id", JsonPrimitive("pid-1"))
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
            put("pairing_id", JsonPrimitive("pid-1"))
            put("lease_token", JsonPrimitive("lease-7"))
            put("reason", JsonPrimitive("fetch_failed"))
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
            put("pairing_id", JsonPrimitive("pid-1"))
            put("lease_token", JsonPrimitive("lease-STALE"))
            put("reason", JsonPrimitive("fetch_failed"))
        }
        assertNull(parseFlowPushOutcome("flow.failed", data, tuple.toRef()))
    }

    @Test
    fun delivered_push_missing_a_receipt_is_ignored() {
        val data = buildJsonObject {
            put("queue_sequence", JsonPrimitive(7L))
            put("pairing_id", JsonPrimitive("pid-1"))
            put("lease_token", JsonPrimitive("lease-7"))
        }
        assertNull(parseFlowPushOutcome("flow.delivered", data, tuple.toRef()))
    }

    // flowWaitStep 的判据（#410 新参数：15s / 3min 字节停滞）由 ARCH13DeliveryPortTest 覆盖。

    private data class FlowTupleRefFixture(val queueSequence: Long, val pairingId: String, val leaseToken: String) {
        fun toRef() = com.hawkeyexb.ppass.proto.FlowTupleRef(
            queueSequence = queueSequence,
            pairingId = pairingId,
            leaseToken = leaseToken,
        )
    }
}
