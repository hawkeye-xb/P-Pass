// ARCH-07: remote reconciliation facts and recovery disposition contract.
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ARCH01RemoteReconciliationTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-reconcile-$case").toFile()

    @Test
    fun r01_remote_missing_with_phone_source_present_records_a_decision_without_requeueing() {
        val dir = tempDir("r01")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(
            listOf(DiscoveryCandidate("content://media/external/images/media/18", "generation-7", 42L)),
            DiscoveryCursor(7L, 18L),
        )
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(
                queueSequence = 1L,
                receiptId = "desktop-receipt-18",
                contentHash = "hash-18",
            ),
        )
        val before = store.load()

        RemoteReconciliation(store).recordRemoteMissing(
            contentHash = "hash-18",
            sourcePresence = SourcePresence.PRESENT,
        )

        val after = store.load()
        val item = after.items.single()
        assertEquals("hash-18", item.contentHash)
        assertEquals(RemotePresence.MISSING, item.remotePresence)
        assertEquals(SourcePresence.PRESENT, item.sourcePresence)
        assertEquals(RecoveryDisposition.NEEDS_DECISION, item.disposition)
        assertEquals(DeliveryState.CONFIRMED, item.deliveryState)
        assertEquals(before.uploadCursor, after.uploadCursor)
        assertEquals(before.fetchLease, after.fetchLease)
        assertEquals(before.nextQueueSequence, after.nextQueueSequence)
        assertEquals(0, item.attemptCount)
        dir.deleteRecursively()
    }

    @Test
    fun r02_remote_missing_with_phone_source_missing_records_unrecoverable_without_claiming_recovery() {
        val dir = tempDir("r02")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(
            listOf(DiscoveryCandidate("content://media/external/images/media/19", "generation-7", 42L)),
            DiscoveryCursor(7L, 19L),
        )
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(
                queueSequence = 1L,
                receiptId = "desktop-receipt-19",
                contentHash = "hash-19",
            ),
        )

        RemoteReconciliation(store).recordRemoteMissing(
            contentHash = "hash-19",
            sourcePresence = SourcePresence.MISSING,
        )

        val item = store.load().items.single()
        assertEquals(RemotePresence.MISSING, item.remotePresence)
        assertEquals(SourcePresence.MISSING, item.sourcePresence)
        assertEquals(RecoveryDisposition.UNRECOVERABLE, item.disposition)
        assertEquals(DeliveryState.CONFIRMED, item.deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun remote_present_records_only_remote_presence_without_a_source_probe_or_recovery_prompt() {
        val dir = tempDir("remote-present")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(
            listOf(DiscoveryCandidate("content://media/external/images/media/20", "generation-7", 42L)),
            DiscoveryCursor(7L, 20L),
        )
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(
                queueSequence = 1L,
                receiptId = "desktop-receipt-20",
                contentHash = "hash-20",
            ),
        )

        RemoteReconciliation(store).recordRemotePresent("hash-20")

        val item = store.load().items.single()
        assertEquals(RemotePresence.PRESENT, item.remotePresence)
        assertEquals(SourcePresence.UNKNOWN, item.sourcePresence)
        assertEquals(RecoveryDisposition.NONE, item.disposition)
        assertEquals(DeliveryState.CONFIRMED, item.deliveryState)
        dir.deleteRecursively()
    }
}
