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
        assertEquals(
            "the completed cancellation scan must release the production cancellation marker",
            null,
            cancelled.cancellationRound,
        )
        assertEquals(
            "after cancellation completes, the user-controlled pause remains in force",
            FlowUiState.PausedByUser,
            flowUiStateOf(cancelled),
        )
        dir.deleteRecursively()
    }

    @Test
    fun cancelled_round_releases_cursor_so_next_discovered_candidate_wakes() {
        val dir = tempDir("cancel-then-discover")
        val ledger = DiscoveryLedgerStore(dir)
        val delivery = RecordingDelivery()
        val runner = FlowRunner(
            ledger,
            RecordingDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))),
            delivery,
        )

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        runner.cancelCurrentRound("round-1")
        ledger.commitDiscoveryPage(listOf(candidate(19)), DiscoveryCursor(7L, 19L))

        runner.continueFlow(constraintsSatisfied = true)

        val resumed = ledger.load()
        assertEquals(
            "a new candidate admitted after cancellation must become the strict head",
            listOf(1L, 2L),
            delivery.starts,
        )
        assertEquals(UploadCursor(2L), resumed.uploadCursor)
        assertEquals(DeliveryState.TRANSFERRING, resumed.items.single { it.queueSequence == 2L }.deliveryState)
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

    @Test
    fun scope_expansion_backfills_cursor_predecessors_after_the_current_strict_head() {
        val dir = tempDir("scope-backfill")
        val ledger = DiscoveryLedgerStore(dir)
        val discovery = RecordingDiscovery(
            page = DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L)),
            backfill = listOf(candidate(17)),
        )
        val delivery = RecordingDelivery()
        val runner = FlowRunner(ledger, discovery, delivery)

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        runner.requestScopeBackfill()
        runner.run(constraintsSatisfied = true)

        val expanded = ledger.load()
        assertEquals(DiscoveryCursor(7L, 18L), expanded.cursor)
        assertEquals(ScopeRevision(2L), expanded.scopeRevision)
        assertEquals(emptyList<ScopeBackfillRequest>(), expanded.backfillRequests)
        assertEquals(listOf(1L), delivery.starts)
        assertEquals(DeliveryState.TRANSFERRING, expanded.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(DeliveryState.QUEUED, expanded.items.single { it.queueSequence == 2L }.deliveryState)
        assertEquals(ScopeRevision(2L), expanded.items.single { it.queueSequence == 2L }.scopeRevision)
        assertEquals(listOf(DiscoveryCursor(7L, 18L)), discovery.backfillCursors)
        assertEquals(listOf(ScopeRevision(2L)), discovery.backfillScopes)

        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = 1L, receiptId = "desktop-1"))
        assertEquals(listOf(1L, 2L), delivery.starts)
        dir.deleteRecursively()
    }

    // MOB-54 RED: recordPermanentFailure() re-queues a non-terminal item
    // (attemptCount < 3) but never wakes the strict consumer again — unlike
    // acceptCompletionReceipt(), which explicitly calls consumer.wake() after
    // a success. A transient failure (network blip, one retryable error)
    // leaves the head QUEUED with an open gate and no lease, and nothing
    // will pick it up again except an external trigger (album reselect, app
    // restart, the 5h periodic WorkManager fallback). Real device: last
    // queue item stuck QUEUED/attemptCount=1 indefinitely (2026-09-07,
    // Samsung SM-S9210, 12/13 confirmed, 1 stuck).
    @Test
    fun transient_failure_retries_automatically_without_an_external_trigger() {
        val dir = tempDir("mob54-retry-wake")
        val ledger = DiscoveryLedgerStore(dir)
        val discovery = RecordingDiscovery(
            DiscoveryPage(candidates = listOf(candidate(18)), nextCursor = DiscoveryCursor(7L, 18L)),
        )
        val delivery = RecordingDelivery()
        val runner = FlowRunner(ledger, discovery, delivery)

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        assertEquals(listOf(1L), delivery.starts)

        // One transient failure — attemptCount goes to 1, still short of the
        // 3-attempt terminal threshold, so the item is re-queued and (after
        // the fix) immediately re-leased for another attempt in the same
        // call — TRANSFERRING again, not stuck at QUEUED.
        runner.recordPermanentFailure()
        val afterFailure = ledger.load()
        assertEquals(DeliveryState.TRANSFERRING, afterFailure.items.single().deliveryState)
        assertEquals(1, afterFailure.items.single().attemptCount)

        // RED: without any external trigger, the strict consumer must retry
        // the still-open head on its own — the delivery port must see a
        // second start for queueSequence 1.
        assertEquals(
            "a non-terminal failure must retry automatically, not stall until an external trigger",
            listOf(1L, 1L),
            delivery.starts,
        )
        dir.deleteRecursively()
    }

    // MOB-58: X-05's Restore/Discard, decided in ARCH-01 but never wired past
    // CancellationRoundController's own JVM tests. Real device: "取消当前轮
    // 没有反应"、"这些照片也没有个重新传输的入口" (2026-09-07). FlowRunner
    // must expose the same restore/discard the controller already offers,
    // and restoring must also wake the consumer — nothing else notices new
    // QUEUED work materialized outside the normal discovery path.
    @Test
    fun restoring_a_cancelled_round_re_queues_its_items_and_wakes_the_consumer() {
        val dir = tempDir("mob58-restore")
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
        runner.cancelCurrentRound("round-1")
        assertEquals(DeliveryState.CANCELLED_BY_USER_ROUND, ledger.load().items.single().deliveryState)

        runner.restoreCancelledRound("round-1")

        val restored = ledger.load()
        assertEquals(
            "restoring must re-admit the item and let the consumer pick it up again",
            DeliveryState.TRANSFERRING,
            restored.items.single().deliveryState,
        )
        assertEquals(listOf(1L, 1L), delivery.starts)
        dir.deleteRecursively()
    }

    @Test
    fun discarding_a_cancelled_round_leaves_items_cancelled_and_does_not_wake() {
        val dir = tempDir("mob58-discard")
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
        runner.cancelCurrentRound("round-1")

        runner.discardCancelledRound("round-1")

        assertEquals(
            "discard must not resurrect the cancelled item",
            DeliveryState.CANCELLED_BY_USER_ROUND,
            ledger.load().items.single().deliveryState,
        )
        assertEquals("discard must not start any delivery", listOf(1L), delivery.starts)
        dir.deleteRecursively()
    }

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    private class RecordingDiscovery(
        private val page: DiscoveryPage,
        private val backfill: List<DiscoveryCandidate> = emptyList(),
    ) : FlowDiscoveryPort {
        val cursors = mutableListOf<DiscoveryCursor>()
        val backfillCursors = mutableListOf<DiscoveryCursor>()
        val backfillScopes = mutableListOf<ScopeRevision>()
        override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage {
            cursors += cursor
            return page
        }

        override fun backfill(request: ScopeBackfillRequest): ScopeBackfillPage {
            backfillCursors += request.boundary
            backfillScopes += request.scopeRevision
            return ScopeBackfillPage(backfill, request.boundary, complete = true)
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
