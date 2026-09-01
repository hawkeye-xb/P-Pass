// ARCH-06: pairing epoch isolation contract.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH01PairingEpochTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-pairing-$case").toFile()

    private fun candidate(id: Int) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    @Test
    fun p01_switching_desktop_preserves_scope_but_atomically_discards_old_epoch_runtime_state() {
        val dir = tempDir("p01")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(listOf(candidate(1)), DiscoveryCursor(7L, 1L))
        store.update { snapshot ->
            snapshot.copy(
                scopeRevision = ScopeRevision(4L),
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                consumerStatus = ConsumerStatus.WAITING_FOR_CONSTRAINTS,
                cancellationRound = CancellationRound("old-round"),
                uploadCursor = UploadCursor(1L),
                fetchLease = FetchLease(1L, "old-lease"),
                backfillRequests = listOf(ScopeBackfillRequest(ScopeRevision(4L))),
                items = snapshot.items.map {
                    it.copy(deliveryState = DeliveryState.TRANSFERRING, partialRetained = true)
                },
            )
        }

        PairingEpochController(store).replaceDesktop(PairingEpoch("new-desktop-epoch"))

        val switched = store.load()
        assertEquals(PairingEpoch("new-desktop-epoch"), switched.pairingEpoch)
        assertEquals("P-01 keeps the selected-scope revision", ScopeRevision(4L), switched.scopeRevision)
        assertEquals(DiscoveryCursor.INITIAL, switched.cursor)
        assertEquals(UploadCursor.INITIAL, switched.uploadCursor)
        assertEquals(ConsumerGate.OPEN, switched.consumerGate)
        assertEquals(ConsumerStatus.IDLE, switched.consumerStatus)
        assertNull(switched.cancellationRound)
        assertNull(switched.fetchLease)
        assertTrue(switched.backfillRequests.isEmpty())
        assertTrue("old queue and partial ownership must not enter the new epoch", switched.items.isEmpty())
        assertEquals(1L, switched.nextQueueSequence)
        dir.deleteRecursively()
    }

    @Test
    fun p02_late_receipt_from_old_desktop_cannot_confirm_the_new_epoch_item() {
        val dir = tempDir("p02")
        val store = DiscoveryLedgerStore(dir)
        PairingEpochController(store).replaceDesktop(PairingEpoch("new-desktop-epoch"))
        store.commitDiscoveryPage(listOf(candidate(2)), DiscoveryCursor(7L, 2L))
        CompletionAndScope(store).recordTransferStarted(1L)

        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(
                queueSequence = 1L,
                receiptId = "old-desktop-receipt",
                pairingEpoch = PairingEpoch("old-desktop-epoch"),
            ),
        )

        val item = store.load().items.single()
        assertEquals(DeliveryState.TRANSFERRING, item.deliveryState)
        assertNull(item.completionReceiptId)
        assertEquals(FetchLease(1L, "lease-1"), store.load().fetchLease)
        dir.deleteRecursively()
    }

    @Test
    fun p02_receipt_from_current_desktop_still_confirms_the_current_epoch_item() {
        val dir = tempDir("p02-current")
        val store = DiscoveryLedgerStore(dir)
        val epoch = PairingEpoch("current-desktop-epoch")
        PairingEpochController(store).replaceDesktop(epoch)
        store.commitDiscoveryPage(listOf(candidate(3)), DiscoveryCursor(7L, 3L))
        CompletionAndScope(store).recordTransferStarted(1L)

        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(queueSequence = 1L, receiptId = "current-desktop-receipt", pairingEpoch = epoch),
        )

        assertEquals(DeliveryState.CONFIRMED, store.load().items.single().deliveryState)
        assertEquals("current-desktop-receipt", store.load().items.single().completionReceiptId)
        dir.deleteRecursively()
    }
}
