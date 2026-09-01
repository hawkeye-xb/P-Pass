// ARCH-05: cancellation-round persistence contract.
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH01CancellationRoundTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-cancel-$case").toFile()

    private fun candidates(from: Int, count: Int): List<DiscoveryCandidate> =
        (from until from + count).map { id ->
            DiscoveryCandidate("content://media/external/images/media/$id", "generation-7", 42L)
        }

    @Test
    fun x01_starting_the_round_cancels_already_discovered_unconfirmed_items() {
        val dir = tempDir("x01-existing")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(candidates(1, 2), DiscoveryCursor(7L, 2L))
        store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }

        CancellationRoundController(store).startPausedRound("round-1")

        assertTrue(
            "X-01 must cancel the already discovered page before scanning later pages",
            store.load().items.all { it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND },
        )
        dir.deleteRecursively()
    }

    @Test
    fun x01_starting_the_round_cancels_every_unconfirmed_item_but_preserves_completion_evidence() {
        val dir = tempDir("x01-terminal-states")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(candidates(1, 2), DiscoveryCursor(7L, 2L))
        store.update { snapshot ->
            snapshot.copy(
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                items = snapshot.items.map { item ->
                    when (item.queueSequence) {
                        1L -> item.copy(
                            deliveryState = DeliveryState.CONFIRMED,
                            completionReceiptId = "desktop-receipt-1",
                        )
                        else -> item.copy(deliveryState = DeliveryState.FAILED_NEEDS_USER)
                    }
                },
            )
        }

        CancellationRoundController(store).startPausedRound("round-1")

        assertEquals(DeliveryState.CONFIRMED, store.load().items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(DeliveryState.CANCELLED_BY_USER_ROUND, store.load().items.single { it.queueSequence == 2L }.deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun x01_cancellation_sweeps_all_900_candidates_across_discovery_pages_without_delivery() {
        val dir = tempDir("x01")
        val store = DiscoveryLedgerStore(dir)
        val cancellation = CancellationRoundController(store)

        store.commitDiscoveryPage(candidates(1, 500), DiscoveryCursor(7L, 500L))
        store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        cancellation.startPausedRound("round-1")
        cancellation.admitPage(candidates(501, 400), DiscoveryCursor(7L, 900L))

        val snapshot = store.load()
        assertEquals(900, snapshot.items.size)
        assertTrue(snapshot.items.all { it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND })
        assertEquals(DiscoveryCursor(7L, 900L), snapshot.cursor)
        dir.deleteRecursively()
    }

    @Test
    fun x02_candidates_admitted_during_active_round_are_never_queued() {
        val dir = tempDir("x02")
        val store = DiscoveryLedgerStore(dir)
        val cancellation = CancellationRoundController(store)
        store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        cancellation.startPausedRound("round-1")

        cancellation.admitPage(candidates(1, 1), DiscoveryCursor(7L, 1L))

        assertEquals(DeliveryState.CANCELLED_BY_USER_ROUND, store.load().items.single().deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun x05_restore_requeues_only_items_cancelled_by_the_requested_round() {
        val dir = tempDir("x05-only-own-round")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(candidates(1, 2), DiscoveryCursor(7L, 2L))
        store.update { snapshot ->
            snapshot.copy(
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                items = snapshot.items.map { item ->
                    if (item.queueSequence == 1L) item.copy(deliveryState = DeliveryState.CANCELLED_BY_USER_ROUND) else item
                },
            )
        }
        val cancellation = CancellationRoundController(store)
        cancellation.startPausedRound("round-2")

        cancellation.restoreRound("round-2")

        assertEquals(DeliveryState.CANCELLED_BY_USER_ROUND, store.load().items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(DeliveryState.QUEUED, store.load().items.single { it.queueSequence == 2L }.deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun x03_restart_resumes_persisted_round_and_keeps_cancelling_remaining_pages() {
        val dir = tempDir("x03")
        val firstProcess = DiscoveryLedgerStore(dir)
        firstProcess.commitDiscoveryPage(candidates(1, 500), DiscoveryCursor(7L, 500L))
        firstProcess.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        CancellationRoundController(firstProcess).startPausedRound("round-1")

        CancellationRoundController(DiscoveryLedgerStore(dir)).admitPage(candidates(501, 400), DiscoveryCursor(7L, 900L))

        assertEquals(900, DiscoveryLedgerStore(dir).load().items.count { it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND })
        dir.deleteRecursively()
    }

    @Test
    fun x04_items_admitted_after_atomic_round_close_belong_to_next_round() {
        val dir = tempDir("x04")
        val store = DiscoveryLedgerStore(dir)
        val cancellation = CancellationRoundController(store)
        store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        cancellation.startPausedRound("round-1")
        cancellation.finishRound()

        cancellation.admitPage(candidates(1, 1), DiscoveryCursor(7L, 1L))

        assertEquals(DeliveryState.QUEUED, store.load().items.single().deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun x05_restore_is_available_after_the_round_has_closed() {
        val dir = tempDir("x05-closed-round")
        val store = DiscoveryLedgerStore(dir)
        val cancellation = CancellationRoundController(store)
        store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        cancellation.startPausedRound("round-1")
        cancellation.admitPage(candidates(1, 1), DiscoveryCursor(7L, 1L))
        cancellation.finishRound()

        val failure = runCatching { cancellation.restoreRound("round-1") }.exceptionOrNull()

        assertEquals("X-05 Restore must remain an explicit option after the scan closes", null, failure)
        assertEquals(DeliveryState.QUEUED, store.load().items.single().deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun x05_discard_after_close_keeps_items_cancelled_and_removes_restore_option() {
        val dir = tempDir("x05-discard")
        val store = DiscoveryLedgerStore(dir)
        val cancellation = CancellationRoundController(store)
        store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        cancellation.startPausedRound("round-1")
        cancellation.admitPage(candidates(1, 1), DiscoveryCursor(7L, 1L))
        cancellation.finishRound()

        val discardFailure = runCatching { cancellation.discardRound("round-1") }.exceptionOrNull()

        assertEquals("X-05 Discard must remain available after the scan closes", null, discardFailure)
        assertEquals(DeliveryState.CANCELLED_BY_USER_ROUND, store.load().items.single().deliveryState)
        assertTrue("X-05 discarded rounds must not be restored by ordinary triggers", runCatching {
            cancellation.restoreRound("round-1")
        }.isFailure)
        dir.deleteRecursively()
    }

    @Test
    fun x05_restore_requeues_only_cancelled_items_and_ends_the_active_round() {
        val dir = tempDir("x05")
        val store = DiscoveryLedgerStore(dir)
        val cancellation = CancellationRoundController(store)
        store.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        cancellation.startPausedRound("round-1")
        cancellation.admitPage(candidates(1, 2), DiscoveryCursor(7L, 2L))
        cancellation.restoreRound("round-1")

        assertTrue(store.load().items.all { it.deliveryState == DeliveryState.QUEUED })
        assertEquals(null, store.load().cancellationRound)
        dir.deleteRecursively()
    }
}
