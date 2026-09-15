package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import com.hawkeyexb.ppass.proto.FlowStatusReply
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * NET-06: pure decision functions extracted from NativeFlowDeliveryPort's
 * offer->poll-status loop. NativeFlowDeliveryPort itself constructs a real
 * android.content.ContentResolver-backed IrohBlobsProviderBridge and is
 * exercised at the daemon integration level and on real devices; these
 * tests lock in the JVM-testable decision seam (flowStatusPollOutcome,
 * nextStatusPollDelayMs) that the loop is built from, so the branching
 * logic itself has a fast, deterministic RED->GREEN gate.
 */
class NET06StatusPollDeliveryTest {

    @Test
    fun completed_status_with_a_receipt_yields_the_receipt() {
        val receipt = FlowCompletionReceipt(
            queueSequence = 7L,
            receiptId = "desktop-1",
            pairingEpoch = "epoch-1",
            leaseToken = "lease-7",
            contentHash = "a".repeat(64),
        )
        val outcome = flowStatusPollOutcome(
            FlowStatusReply(state = "completed", receipt = receipt, taskRunning = false),
        )
        assertEquals(FlowStatusPollOutcome.Completed(receipt), outcome)
    }

    @Test
    fun completed_status_with_no_receipt_is_a_bug_and_must_throw() {
        // Counterexample: the daemon reporting "completed" without a
        // receipt is an internal contract violation, not a state this
        // loop should silently treat as still-in-flight.
        try {
            flowStatusPollOutcome(FlowStatusReply(state = "completed", receipt = null))
            throw AssertionError("expected an exception for a receipt-less completed reply")
        } catch (failure: IllegalStateException) {
            assertTrue(failure.message.orEmpty().contains("completed with no receipt"))
        }
    }

    @Test
    fun cancelled_status_yields_cancelled() {
        val outcome = flowStatusPollOutcome(FlowStatusReply(state = "cancelled"))
        assertEquals(FlowStatusPollOutcome.Cancelled, outcome)
    }

    @Test
    fun active_status_yields_keep_polling() {
        val outcome = flowStatusPollOutcome(FlowStatusReply(state = "active", taskRunning = true))
        assertEquals(FlowStatusPollOutcome.KeepPolling, outcome)
    }

    @Test
    fun not_found_status_is_a_genuine_inconsistency_and_must_throw() {
        // A phone that already sent a successful offer() for this exact
        // tuple must never see "not_found" from status() — that would mean
        // the daemon's ledger disagrees with its own recent acceptance.
        // This must never be silently read as "still in flight".
        try {
            flowStatusPollOutcome(FlowStatusReply(state = "not_found"))
            throw AssertionError("expected an exception for not_found")
        } catch (failure: IllegalStateException) {
            assertTrue(failure.message.orEmpty().contains("no record of our own grant"))
        }
    }

    @Test
    fun poll_delay_starts_fast_and_settles_at_a_ceiling_without_growing_unbounded() {
        val delays = (0..10).map { nextStatusPollDelayMs(it) }
        // Strictly non-decreasing (never gets faster as it backs off)...
        for (i in 1 until delays.size) {
            assertTrue(
                "poll delay must never shrink between attempts (index ${i - 1}=${delays[i - 1]} -> $i=${delays[i]})",
                delays[i] >= delays[i - 1],
            )
        }
        // ...but bounded: a large index must not run away to an
        // effectively-abandoned wait — the card wants a large relay
        // transfer still checked on periodically, not left for hours.
        assertTrue(
            "poll delay must settle at a ceiling, not grow unbounded (got ${delays.last()}ms)",
            delays.last() <= 10_000L,
        )
        // The very first poll must be fast — small items regularly finish
        // inside the first status check, and this must not be punished
        // with the same wait a stalled multi-minute transfer gets.
        assertTrue("first poll delay must be fast", nextStatusPollDelayMs(0) <= 2_000L)
    }

    @Test
    fun poll_delay_index_beyond_the_table_reuses_the_last_entry_forever() {
        // Counterexample: an off-by-one or unguarded array index here
        // would throw ArrayIndexOutOfBoundsException on a very long-lived
        // transfer (e.g. hours over a slow relay path) instead of
        // continuing to poll at the settled ceiling.
        val ceiling = nextStatusPollDelayMs(4)
        assertEquals(ceiling, nextStatusPollDelayMs(100))
        assertEquals(ceiling, nextStatusPollDelayMs(10_000))
    }
}
