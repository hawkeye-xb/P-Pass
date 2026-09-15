// NET-06: CancellationRoundController must tell the daemon about items
// that already made real contact with it, and must NOT waste a network
// call on items the daemon never heard from (卡片 review fix #2).
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NET06CancellationTupleNotifyTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-net06-cancel-tuple-$case").toFile()

    private fun candidates(from: Int, count: Int): List<DiscoveryCandidate> =
        (from until from + count).map { id ->
            DiscoveryCandidate("content://media/external/images/media/$id", "generation-7", 42L)
        }

    private class RecordingCanceller : FlowTupleCancelPort {
        val cancelled = mutableListOf<Long>()
        override fun cancel(item: TransferItem) {
            cancelled += item.queueSequence
        }
    }

    @Test
    fun a_plain_queued_item_that_was_never_offered_is_never_sent_a_cancel_call() {
        val dir = tempDir("plain-queued-skipped")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(candidates(1, 2), DiscoveryCursor(7L, 2L))
        store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        val canceller = RecordingCanceller()

        CancellationRoundController(store, canceller).startPausedRound("round-1")

        assertTrue(
            "neither item ever made contact with the daemon (attemptCount == 0, partialRetained == false)",
            canceller.cancelled.isEmpty(),
        )
        dir.deleteRecursively()
    }

    @Test
    fun a_permanently_failed_item_that_exhausted_its_retry_budget_is_sent_a_cancel_call() {
        val dir = tempDir("failed-needs-user-notified")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(candidates(1, 1), DiscoveryCursor(7L, 1L))
        store.update { snapshot ->
            snapshot.copy(
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                items = snapshot.items.map { it.copy(deliveryState = DeliveryState.FAILED_NEEDS_USER, attemptCount = 3) },
            )
        }
        val canceller = RecordingCanceller()

        CancellationRoundController(store, canceller).startPausedRound("round-1")

        assertEquals(
            "a FAILED_NEEDS_USER item genuinely made contact with the daemon (attemptCount > 0) and must be cancelled there too",
            listOf(1L),
            canceller.cancelled,
        )
        dir.deleteRecursively()
    }

    @Test
    fun a_queued_item_interrupted_mid_transfer_and_requeued_is_sent_a_cancel_call() {
        val dir = tempDir("requeued-with-partial")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(candidates(1, 1), DiscoveryCursor(7L, 1L))
        // Simulates StrictConsumer.pauseByUser()'s outcome for an item that
        // was actually delivery.start()-ed: back to QUEUED, but
        // partialRetained=true is left behind as the durable proof that a
        // real offer/fetch round trip happened for it.
        store.update { snapshot ->
            snapshot.copy(
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                items = snapshot.items.map { it.copy(deliveryState = DeliveryState.QUEUED, partialRetained = true) },
            )
        }
        val canceller = RecordingCanceller()

        CancellationRoundController(store, canceller).startPausedRound("round-1")

        assertEquals(
            "partialRetained is only ever set by delivery.stop() on an item that was actually started — must be cancelled",
            listOf(1L),
            canceller.cancelled,
        )
        dir.deleteRecursively()
    }

    // Counterexample: deleting the attemptCount/partialRetained guard and
    // always calling tupleCanceller for every cancelled item must make the
    // first test above fail.
    @Test
    fun counterexample_mixed_batch_only_notifies_for_the_one_real_grant() {
        val dir = tempDir("mixed-batch")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(candidates(1, 3), DiscoveryCursor(7L, 3L))
        store.update { snapshot ->
            snapshot.copy(
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                items = snapshot.items.map { item ->
                    when (item.queueSequence) {
                        // 1: plain QUEUED, never offered.
                        1L -> item
                        // 2: exhausted retries — real grant existed.
                        2L -> item.copy(deliveryState = DeliveryState.FAILED_NEEDS_USER, attemptCount = 3)
                        // 3: plain QUEUED, never offered.
                        else -> item
                    }
                },
            )
        }
        val canceller = RecordingCanceller()

        CancellationRoundController(store, canceller).startPausedRound("round-1")

        assertEquals(listOf(2L), canceller.cancelled)
        dir.deleteRecursively()
    }
}
