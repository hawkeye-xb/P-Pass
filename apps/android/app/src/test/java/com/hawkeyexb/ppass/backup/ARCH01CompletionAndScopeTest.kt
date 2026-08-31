// ARCH-04: completion evidence and ScopeRevision contract.
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH01CompletionAndScopeTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-completion-$case").toFile()

    private fun seededStore(dir: File): DiscoveryLedgerStore =
        DiscoveryLedgerStore(dir).also {
            it.commitDiscoveryPage(
                listOf(
                    DiscoveryCandidate("content://media/external/images/media/18", "generation-7", 42L),
                    DiscoveryCandidate("content://media/external/images/media/19", "generation-7", 42L),
                ),
                DiscoveryCursor(7L, 19L),
            )
        }

    private fun complete(store: DiscoveryLedgerStore, sequence: Long = 1L) {
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(queueSequence = sequence, receiptId = "desktop-receipt-$sequence"),
        )
    }

    @Test
    fun e01_only_durable_completion_receipt_confirms_item_and_advances_cursor() {
        val dir = tempDir("e01")
        val store = seededStore(dir)

        CompletionAndScope(store).recordTransferStarted(queueSequence = 1L)
        assertEquals(DeliveryState.TRANSFERRING, store.load().items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(UploadCursor(1L), store.load().uploadCursor)

        complete(store)
        val snapshot = store.load()
        assertEquals(DeliveryState.CONFIRMED, snapshot.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(UploadCursor(2L), snapshot.uploadCursor)
        dir.deleteRecursively()
    }

    @Test
    fun e02_valid_late_receipt_preserves_confirmed_fact_after_scope_reduction() {
        val dir = tempDir("e02")
        val store = seededStore(dir)
        complete(store)

        CompletionAndScope(store).reduceScopeTo(ScopeRevision(2L))
        CompletionAndScope(store).acceptCompletionReceipt(CompletionReceipt(1L, "late-duplicate-receipt"))

        val snapshot = store.load()
        assertEquals(ScopeRevision(2L), snapshot.scopeRevision)
        assertEquals(DeliveryState.CONFIRMED, snapshot.items.single { it.queueSequence == 1L }.deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun e03_scope_reduction_cancels_unreceipted_partial_and_rejects_late_finalization() {
        val dir = tempDir("e03")
        val store = seededStore(dir)
        CompletionAndScope(store).recordTransferStarted(queueSequence = 1L)

        CompletionAndScope(store).reduceScopeTo(ScopeRevision(2L))
        CompletionAndScope(store).acceptCompletionReceipt(CompletionReceipt(1L, "late-receipt"))

        val item = store.load().items.single { it.queueSequence == 1L }
        assertEquals(DeliveryState.CANCELLED_BY_SCOPE, item.deliveryState)
        assertEquals(null, store.load().fetchLease)
        dir.deleteRecursively()
    }

    @Test
    fun e04_cancel_current_round_does_not_overwrite_confirmed_fact() {
        val dir = tempDir("e04")
        val store = seededStore(dir)
        complete(store)

        CompletionAndScope(store).cancelCurrentRound()

        assertEquals(DeliveryState.CONFIRMED, store.load().items.single { it.queueSequence == 1L }.deliveryState)
        assertTrue(store.load().cancellationRound != null)
        dir.deleteRecursively()
    }

    @Test
    fun scope_increase_records_a_separate_backfill_request_without_reusing_discovery_cursor() {
        val dir = tempDir("scope-increase")
        val store = seededStore(dir)

        CompletionAndScope(store).requestScopeBackfill(ScopeRevision(2L))

        assertEquals(listOf(ScopeBackfillRequest(ScopeRevision(2L))), store.load().backfillRequests)
        assertEquals(DiscoveryCursor(7L, 19L), store.load().cursor)
        dir.deleteRecursively()
    }
}
