package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB63PauseCompletionRaceTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob63-$case").toFile()

    private fun seededStore(dir: File, itemCount: Int): DiscoveryLedgerStore =
        DiscoveryLedgerStore(dir).also { store ->
            store.commitDiscoveryPage(
                (1..itemCount).map { index ->
                    DiscoveryCandidate(
                        sourceRef = "content://media/external/images/media/$index",
                        sourceVersion = "generation-7",
                        bucketId = 42L,
                    )
                },
                DiscoveryCursor(lastGeneration = 7L, lastMediaId = itemCount.toLong()),
            )
        }

    private class FakeDeliveryPort : DeliveryPort {
        val starts = mutableListOf<Long>()

        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
            starts += item.queueSequence
        }

        override fun stop(queueSequence: Long): PartialDisposition = PartialDisposition.RETAINED
    }

    @Test
    fun pause_then_last_receipt_converges_to_idle_and_all_safe() {
        val dir = tempDir("pause-then-receipt")
        val store = seededStore(dir, itemCount = 1)
        val consumer = StrictConsumer(store, FakeDeliveryPort())

        consumer.wake(constraintsSatisfied = true)
        val issuedLease = checkNotNull(store.load().fetchLease)
        consumer.pauseByUser()
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(1L, "desktop-1", leaseToken = issuedLease.leaseToken),
        )

        assertIdleAllSafe(store.load())
        dir.deleteRecursively()
    }

    @Test
    fun last_receipt_then_pause_converges_to_idle_and_all_safe() {
        val dir = tempDir("receipt-then-pause")
        val store = seededStore(dir, itemCount = 1)
        val consumer = StrictConsumer(store, FakeDeliveryPort())

        consumer.wake(constraintsSatisfied = true)
        val issuedLease = checkNotNull(store.load().fetchLease)
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(1L, "desktop-1", leaseToken = issuedLease.leaseToken),
        )
        consumer.pauseByUser()

        assertIdleAllSafe(store.load())
        dir.deleteRecursively()
    }

    @Test
    fun counterexample_pause_with_queued_work_remains_paused_and_resumable() {
        // Counterexample: deleting the "no QUEUED/TRANSFERRING item" guard and
        // always settling Pause to Idle must make this case fail.
        val dir = tempDir("queued-work-remains-paused")
        val store = seededStore(dir, itemCount = 2)
        val port = FakeDeliveryPort()
        val consumer = StrictConsumer(store, port)

        consumer.wake(constraintsSatisfied = true)
        val issuedLease = checkNotNull(store.load().fetchLease)
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(1L, "desktop-1", leaseToken = issuedLease.leaseToken),
        )
        consumer.pauseByUser()

        val snapshot = store.load()
        assertEquals(ConsumerGate.PAUSED_BY_USER, snapshot.consumerGate)
        assertEquals(ConsumerStatus.IDLE, snapshot.consumerStatus)
        assertNull(snapshot.fetchLease)
        assertEquals(DeliveryState.CONFIRMED, snapshot.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(DeliveryState.QUEUED, snapshot.items.single { it.queueSequence == 2L }.deliveryState)
        assertEquals(FlowUiState.PausedByUser, flowUiStateOf(snapshot))
        assertEquals(FlowCommand.Continue, flowCommandOf(snapshot))
        assertEquals(listOf(1L), port.starts)
        dir.deleteRecursively()
    }

    private fun assertIdleAllSafe(snapshot: DiscoveryLedgerSnapshot) {
        assertEquals(ConsumerGate.OPEN, snapshot.consumerGate)
        assertEquals(ConsumerStatus.IDLE, snapshot.consumerStatus)
        assertNull(snapshot.fetchLease)
        assertEquals(DeliveryState.CONFIRMED, snapshot.items.single().deliveryState)
        assertEquals(FlowUiState.Idle, flowUiStateOf(snapshot))
        assertTrue(backupUiStateOf(snapshot) is com.hawkeyexb.ppass.ui.BackupUiState.AllSafe)
    }
}
