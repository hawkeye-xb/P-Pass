// ARCH-03: ARCH-01 P0 strict consumer contract.
// These cases define consumer behavior without WorkManager, UI, or native fetch.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH01StrictConsumerTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-consumer-$case").toFile()

    private fun page(): List<DiscoveryCandidate> =
        listOf(
            DiscoveryCandidate("content://media/external/images/media/18", "generation-7", 42L),
            DiscoveryCandidate("content://media/external/images/media/19", "generation-7", 42L),
        )

    private fun seededStore(dir: File): DiscoveryLedgerStore =
        DiscoveryLedgerStore(dir).also {
            it.commitDiscoveryPage(page(), DiscoveryCursor(lastGeneration = 7L, lastMediaId = 19L))
        }

    private class FakeDeliveryPort : DeliveryPort {
        val starts = mutableListOf<Long>()
        val stops = mutableListOf<Long>()

        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
            starts += item.queueSequence
        }

        override fun stop(queueSequence: Long): PartialDisposition {
            stops += queueSequence
            return PartialDisposition.RETAINED
        }
    }

    @Test
    fun c01_pause_stops_current_item_keeps_partial_and_never_starts_next_item() {
        val dir = tempDir("c01")
        val port = FakeDeliveryPort()
        val consumer = StrictConsumer(seededStore(dir), port)

        consumer.wake(constraintsSatisfied = true)
        consumer.pauseByUser()

        val snapshot = DiscoveryLedgerStore(dir).load()
        assertEquals(listOf(1L), port.starts)
        assertEquals(listOf(1L), port.stops)
        assertEquals(ConsumerGate.PAUSED_BY_USER, snapshot.consumerGate)
        assertEquals(UploadCursor(1L), snapshot.uploadCursor)
        assertTrue("C-01 keeps the current partial", snapshot.items.single { it.queueSequence == 1L }.partialRetained)
        assertEquals(DeliveryState.QUEUED, snapshot.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(DeliveryState.QUEUED, snapshot.items.single { it.queueSequence == 2L }.deliveryState)
        assertFalse("C-01 must never start #19", 2L in port.starts)
        dir.deleteRecursively()
    }

    @Test
    fun c02_pause_is_durable_across_restart_wakes_and_network_recovery() {
        val dir = tempDir("c02")
        val port = FakeDeliveryPort()
        StrictConsumer(seededStore(dir), port).apply {
            wake(constraintsSatisfied = true)
            pauseByUser()
        }

        val restarted = StrictConsumer(DiscoveryLedgerStore(dir), port)
        restarted.wake(constraintsSatisfied = true)
        restarted.wake(constraintsSatisfied = false)
        restarted.wake(constraintsSatisfied = true)

        assertEquals("C-02 only permits the initial start before Pause", listOf(1L), port.starts)
        assertEquals(ConsumerGate.PAUSED_BY_USER, DiscoveryLedgerStore(dir).load().consumerGate)
        dir.deleteRecursively()
    }

    @Test
    fun c03_user_continue_resumes_original_head_without_creating_another_pipeline() {
        val dir = tempDir("c03")
        val port = FakeDeliveryPort()
        StrictConsumer(seededStore(dir), port).apply {
            wake(constraintsSatisfied = true)
            pauseByUser()
        }

        StrictConsumer(DiscoveryLedgerStore(dir), port).continueByUser()

        val snapshot = DiscoveryLedgerStore(dir).load()
        assertEquals("C-03 resumes only #18", listOf(1L, 1L), port.starts)
        assertEquals(ConsumerGate.OPEN, snapshot.consumerGate)
        assertEquals(UploadCursor(1L), snapshot.uploadCursor)
        assertEquals(DeliveryState.TRANSFERRING, snapshot.items.single { it.queueSequence == 1L }.deliveryState)
        assertFalse("C-03 must not create a second pipeline for #19", 2L in port.starts)
        dir.deleteRecursively()
    }

    @Test
    fun c04_constraint_loss_waits_without_spending_failure_budget_and_auto_resumes_head() {
        val dir = tempDir("c04")
        val port = FakeDeliveryPort()
        val consumer = StrictConsumer(seededStore(dir), port)

        consumer.wake(constraintsSatisfied = true)
        consumer.wake(constraintsSatisfied = false)
        val waiting = DiscoveryLedgerStore(dir).load()
        assertEquals(ConsumerStatus.WAITING_FOR_CONSTRAINTS, waiting.consumerStatus)
        assertEquals(ConsumerGate.OPEN, waiting.consumerGate)
        assertEquals(0, waiting.items.single { it.queueSequence == 1L }.attemptCount)
        assertTrue(waiting.items.single { it.queueSequence == 1L }.partialRetained)

        StrictConsumer(DiscoveryLedgerStore(dir), port).wake(constraintsSatisfied = true)
        assertEquals("C-04 resumes the same head automatically", listOf(1L, 1L), port.starts)
        assertFalse("C-04 must not start #19", 2L in port.starts)
        dir.deleteRecursively()
    }

    @Test
    fun c05_only_terminal_permanent_failure_advances_strict_head_to_next_item() {
        val dir = tempDir("c05")
        val port = FakeDeliveryPort()
        val consumer = StrictConsumer(seededStore(dir), port)

        consumer.wake(constraintsSatisfied = true)
        consumer.recordPermanentFailure()
        assertEquals(UploadCursor(1L), DiscoveryLedgerStore(dir).load().uploadCursor)
        consumer.wake(constraintsSatisfied = true)
        consumer.recordPermanentFailure()
        assertEquals(UploadCursor(1L), DiscoveryLedgerStore(dir).load().uploadCursor)
        consumer.wake(constraintsSatisfied = true)
        consumer.recordPermanentFailure()

        val terminal = DiscoveryLedgerStore(dir).load()
        assertEquals(DeliveryState.FAILED_NEEDS_USER, terminal.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(3, terminal.items.single { it.queueSequence == 1L }.attemptCount)
        assertEquals("C-05 advances only after #18 reaches a terminal state", UploadCursor(2L), terminal.uploadCursor)

        StrictConsumer(DiscoveryLedgerStore(dir), port).wake(constraintsSatisfied = true)
        assertEquals("C-05 may start #19 only after #18 is terminal", listOf(1L, 1L, 1L, 2L), port.starts)
        dir.deleteRecursively()
    }
}
