package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class REBUILD03FlowRunnerTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-rebuild03-$case").toFile()

    @Test
    fun trigger_discovers_atomically_then_starts_only_the_strict_head_and_confirms_from_receipt() {
        val dir = tempDir("trigger-receipt")
        val ledger = DiscoveryLedgerStore(dir)
        val discovery = RecordingDiscovery(
            DiscoveryPage(
                candidates = listOf(candidate(18), candidate(19)),
                nextCursor = DiscoveryCursor(7L, 19L),
            ),
        )
        val delivery = RecordingDelivery()
        val runner = FlowRunner(ledger, discovery, delivery)

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)

        val transferring = ledger.load()
        assertEquals(listOf(DiscoveryCursor.INITIAL), discovery.cursors)
        assertEquals(DiscoveryCursor(7L, 19L), transferring.cursor)
        assertFalse("a committed discovery request is consumed", transferring.discoveryRequested)
        assertEquals(listOf(1L), delivery.starts)
        assertEquals(DeliveryState.TRANSFERRING, transferring.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(DeliveryState.QUEUED, transferring.items.single { it.queueSequence == 2L }.deliveryState)

        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = 1L, receiptId = "desktop-1"))

        val completed = ledger.load()
        assertEquals(DeliveryState.CONFIRMED, completed.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(UploadCursor(2L), completed.uploadCursor)
        assertEquals("a receipt advances the strict consumer to the next durable head", listOf(1L, 2L), delivery.starts)
        assertEquals(DeliveryState.TRANSFERRING, completed.items.single { it.queueSequence == 2L }.deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun pause_continue_constraints_and_cancel_route_through_the_same_ledger_consumer() {
        val dir = tempDir("routing")
        val ledger = DiscoveryLedgerStore(dir)
        val delivery = RecordingDelivery()
        val runner = FlowRunner(
            ledger,
            RecordingDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))),
            delivery,
        )
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)

        runner.pause()
        assertEquals(ConsumerGate.PAUSED_BY_USER, ledger.load().consumerGate)
        assertEquals(listOf(1L), delivery.stops)
        runner.run(constraintsSatisfied = true)
        assertEquals("Pause blocks ordinary trigger runs", listOf(1L), delivery.starts)

        runner.continueFlow(constraintsSatisfied = false)
        assertEquals(ConsumerStatus.WAITING_FOR_CONSTRAINTS, ledger.load().consumerStatus)
        assertEquals(ConsumerGate.OPEN, ledger.load().consumerGate)
        runner.run(constraintsSatisfied = true)
        assertEquals(listOf(1L, 1L), delivery.starts)

        runner.cancelCurrentRound("round-1")
        val cancelled = ledger.load()
        assertEquals(ConsumerGate.PAUSED_BY_USER, cancelled.consumerGate)
        assertEquals(DeliveryState.CANCELLED_BY_USER_ROUND, cancelled.items.single().deliveryState)
        assertEquals("round-1", cancelled.cancellationRound?.id)
        dir.deleteRecursively()
    }

    @Test
    fun receipt_with_stale_lease_or_wrong_hash_never_confirms_the_current_head() {
        val dir = tempDir("receipt-guards")
        val ledger = DiscoveryLedgerStore(dir)
        val runner = FlowRunner(
            ledger,
            RecordingDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))),
            RecordingDelivery(),
        )
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        ledger.update { snapshot ->
            snapshot.copy(items = snapshot.items.map { it.copy(contentHash = "a".repeat(64)) })
        }

        runner.acceptCompletionReceipt(
            CompletionReceipt(1L, "wrong-lease", leaseToken = "stale", contentHash = "a".repeat(64)),
        )
        runner.acceptCompletionReceipt(
            CompletionReceipt(1L, "wrong-hash", leaseToken = "lease-1", contentHash = "b".repeat(64)),
        )

        assertEquals(DeliveryState.TRANSFERRING, ledger.load().items.single().deliveryState)
        assertEquals("a".repeat(64), ledger.load().items.single().contentHash)
        dir.deleteRecursively()
    }

    @Test
    fun native_completion_is_relayed_back_to_the_flow_runner() {
        val request = FlowFetchRequest(
            queueSequence = 2L,
            pairingEpoch = "epoch-1",
            leaseToken = "lease-2",
            contentHash = "a".repeat(64),
            fileName = "photo.jpg",
            mediaType = "image/jpeg",
            provider = "ticket",
        )
        val receipt = FlowCompletionReceipt(
            queueSequence = 2L,
            receiptId = "desktop-2",
            pairingEpoch = "epoch-1",
            leaseToken = "lease-2",
            contentHash = "a".repeat(64),
        )
        var relayed: CompletionReceipt? = null

        relayFlowCompletion(receipt, request) { relayed = it }

        assertEquals(CompletionReceipt(2L, "desktop-2", PairingEpoch("epoch-1"), "a".repeat(64), "lease-2"), relayed)
    }

    @Test
    fun explicit_retry_reopens_failed_heads_without_reusing_their_attempt_budget() {
        val dir = tempDir("retry-failed")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(listOf(candidate(18), candidate(19)), DiscoveryCursor(7L, 19L))
        ledger.update { snapshot ->
            snapshot.copy(
                uploadCursor = UploadCursor.INITIAL,
                items = snapshot.items.map { it.copy(deliveryState = DeliveryState.FAILED_NEEDS_USER, attemptCount = 3) },
            )
        }
        val delivery = RecordingDelivery()
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(emptyList(), DiscoveryCursor.INITIAL)), delivery)

        runner.retryFailedDeliveries()

        val retried = ledger.load()
        assertEquals(listOf(1L), delivery.starts)
        assertEquals(DeliveryState.TRANSFERRING, retried.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(0, retried.items.single { it.queueSequence == 1L }.attemptCount)
        assertEquals(DeliveryState.QUEUED, retried.items.single { it.queueSequence == 2L }.deliveryState)
        assertEquals(0, retried.items.single { it.queueSequence == 2L }.attemptCount)
        dir.deleteRecursively()
    }

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    private class RecordingDiscovery(private val page: DiscoveryPage) : FlowDiscoveryPort {
        val cursors = mutableListOf<DiscoveryCursor>()
        override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage {
            cursors += cursor
            return page
        }
    }

    private class RecordingDelivery : DeliveryPort {
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
}
