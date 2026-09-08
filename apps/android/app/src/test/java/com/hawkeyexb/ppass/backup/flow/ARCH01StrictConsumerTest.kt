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

    // MOB-56 RED: StrictConsumer.wake() is read-check-write (load lease,
    // check null, persist a new lease) with no internal locking — by design,
    // ARCH-03 pushes serialization to the caller (every Android trigger site
    // wraps calls in `synchronized(flowTriggerLock)`; see AndroidFlowRuntime.kt).
    // This test proves why that external lock is load-bearing: without it,
    // two threads racing wake() (e.g. a delivery failure callback and a
    // concurrent receipt/pause/wake trigger) can both observe fetchLease ==
    // null before either persists, so both can start a delivery for the same
    // strict head, and/or their concurrent persist() calls corrupt each
    // other's atomic rename. Real device: two independent "Native Flow
    // delivery failed" log lines 322ms apart from different threads
    // (2026-09-07, Samsung SM-S9210) after MOB-54 added a second wake() call
    // path (recordPermanentFailure) alongside the pre-existing
    // acceptCompletionReceipt wake() — neither callback was synchronized
    // (fixed in AndroidFlowRuntime.kt by wrapping both in flowTriggerLock).
    // The exact symptom (double start vs. a corrupted-persist exception)
    // depends on OS thread scheduling, so this repeats the race across
    // several trials and accepts either as proof of the hazard.
    @Test
    fun concurrent_wake_without_external_synchronization_is_unsafe() {
        var sawDoubleStart = false
        var sawPersistCorruption = false
        repeat(20) { trial ->
            if (sawDoubleStart || sawPersistCorruption) return@repeat
            val dir = tempDir("mob56-race-$trial")
            val port = SlowFakeDeliveryPort()
            val consumer = StrictConsumer(seededStore(dir), port)
            val threadExceptions = java.util.Collections.synchronizedList(mutableListOf<Throwable>())

            val ready = java.util.concurrent.CyclicBarrier(2)
            val threads = (1..2).map {
                Thread {
                    ready.await()
                    try {
                        consumer.wake(constraintsSatisfied = true)
                    } catch (t: Throwable) {
                        threadExceptions += t
                    }
                }.apply {
                    setUncaughtExceptionHandler { _, t -> threadExceptions += t }
                }
            }
            threads.forEach { it.start() }
            threads.forEach { it.join(2_000) }

            if (port.starts.count { it == 1L } >= 2) sawDoubleStart = true
            if (threadExceptions.any { it.message?.contains("atomically persist") == true }) {
                sawPersistCorruption = true
            }
            dir.deleteRecursively()
        }
        assertTrue(
            "MOB-56: unsynchronized concurrent wake() must be unsafe (double-start the " +
                "same head, or corrupt the concurrent persist) across repeated trials — " +
                "this is the race the production flowTriggerLock closes",
            sawDoubleStart || sawPersistCorruption,
        )
    }

    /** Holds start() open briefly so two racing wake() calls can both observe no lease. */
    private class SlowFakeDeliveryPort : DeliveryPort {
        val starts = java.util.Collections.synchronizedList(mutableListOf<Long>())
        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
            Thread.sleep(20)
            starts += item.queueSequence
        }
        override fun stop(queueSequence: Long): PartialDisposition = PartialDisposition.RETAINED
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
    fun c06_deleted_source_is_terminal_unrecoverable_and_advances_without_retry() {
        val dir = tempDir("c06")
        val port = FakeDeliveryPort()
        val consumer = StrictConsumer(seededStore(dir), port)

        consumer.wake(constraintsSatisfied = true)
        consumer.skipMissingSource()

        val skipped = DiscoveryLedgerStore(dir).load()
        val missing = skipped.items.single { it.queueSequence == 1L }
        assertEquals(DeliveryState.SKIPPED_SOURCE_MISSING, missing.deliveryState)
        assertEquals(SourcePresence.MISSING, missing.sourcePresence)
        assertEquals(RecoveryDisposition.UNRECOVERABLE, missing.disposition)
        assertEquals(UploadCursor(2L), skipped.uploadCursor)
        assertEquals(null, skipped.fetchLease)

        StrictConsumer(DiscoveryLedgerStore(dir), port).wake(constraintsSatisfied = true)
        assertEquals("the next available source starts; the deleted source is never retried", listOf(1L, 2L), port.starts)
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
