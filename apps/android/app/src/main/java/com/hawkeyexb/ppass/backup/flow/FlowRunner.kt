// REBUILD-03: production coordinator for the durable ARCH-01 Flow boundary.
package com.hawkeyexb.ppass.backup.flow

/** One ordered, bounded discovery response. It carries no transport decision. */
data class DiscoveryPage(
    val candidates: List<DiscoveryCandidate>,
    val nextCursor: DiscoveryCursor,
)

/** One historical page for a scope expansion; it never advances the live cursor. */
data class ScopeBackfillPage(
    val candidates: List<DiscoveryCandidate>,
    val nextCursor: DiscoveryCursor,
    val complete: Boolean,
)

/** Android's MediaStore adapter implements this port; tests use a deterministic page. */
interface FlowDiscoveryPort {
    fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage

    /** Reads only the historical interval recorded by a durable scope-expansion request. */
    fun backfill(request: ScopeBackfillRequest): ScopeBackfillPage =
        ScopeBackfillPage(emptyList(), request.cursor, complete = true)
}

/**
 * The sole production entrypoint for Flow state changes. Triggers only write
 * [DiscoveryLedgerSnapshot.discoveryRequested]; they cannot scan, hash, fetch,
 * or advance the upload cursor on their own.
 */
class FlowRunner(
    private val ledger: DiscoveryLedgerStore,
    private val discovery: FlowDiscoveryPort,
    delivery: DeliveryPort,
) {
    private val consumer = StrictConsumer(ledger, delivery)
    private val completion = CompletionAndScope(ledger)
    private val cancellation = CancellationRoundController(ledger)

    fun requestDiscovery() {
        ledger.update { it.copy(discoveryRequested = true) }
    }

    /** Scope expansion is durable and coexists with the current strict window. */
    fun requestScopeBackfill() {
        val snapshot = ledger.load()
        completion.requestScopeBackfill(ScopeRevision(snapshot.scopeRevision.value + 1L))
    }

    /**
     * Consume at most one requested discovery page, then offer exactly the
     * durable strict head to the delivery port. Repeated triggers coalesce in
     * the ledger; active windows never receive another discovery page.
     */
    fun run(constraintsSatisfied: Boolean) {
        backfillIfAdmitted()
        discoverIfAdmitted()
        consumer.wake(constraintsSatisfied)
    }

    fun pause() = consumer.pauseByUser()

    /** User Continue reopens the durable gate; a false constraint remains waiting. */
    fun continueFlow(constraintsSatisfied: Boolean) {
        ledger.update { it.copy(consumerGate = ConsumerGate.OPEN, consumerStatus = ConsumerStatus.IDLE) }
        run(constraintsSatisfied)
    }

    /** Cancel is deliberately only available after pausing the current head. */
    fun cancelCurrentRound(roundId: String) {
        pause()
        cancellation.startPausedRound(roundId)
        // startPausedRound terminally marks every cancellable item in the
        // current durable window, so this production cancellation scan ends
        // atomically before future discovery admits the next round.
        cancellation.finishRound()
    }

    fun acceptCompletionReceipt(receipt: CompletionReceipt) {
        completion.acceptCompletionReceipt(receipt)
        // Receipt persistence is the strict-head boundary: only after it is
        // durable may the next queued item acquire a new lease.
        consumer.wake(constraintsSatisfied = true)
    }

    /** A user retry reopens terminal delivery failures as a new strict round. */
    fun retryFailedDeliveries() {
        ledger.update { snapshot ->
            val items = snapshot.items.map { item ->
                if (item.deliveryState == DeliveryState.FAILED_NEEDS_USER) {
                    item.copy(deliveryState = DeliveryState.QUEUED, attemptCount = 0)
                } else item
            }
            snapshot.copy(
                uploadCursor = UploadCursor(items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }?.queueSequence),
                consumerGate = ConsumerGate.OPEN,
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                items = items,
            )
        }
        consumer.wake(constraintsSatisfied = true)
    }

    fun recordPermanentFailure() = consumer.recordPermanentFailure()

    private fun backfillIfAdmitted() {
        val snapshot = ledger.load()
        if (snapshot.consumerGate != ConsumerGate.OPEN) return
        val request = snapshot.backfillRequests.firstOrNull() ?: return
        ledger.commitScopeBackfill(request, discovery.backfill(request))
    }

    private fun discoverIfAdmitted() {
        val snapshot = ledger.load()
        if (!snapshot.discoveryRequested || snapshot.consumerGate != ConsumerGate.OPEN) return
        if (!windowIsTerminal(snapshot)) return
        val page = discovery.discover(snapshot.cursor, snapshot.scopeRevision)
        ledger.commitDiscoveryPage(
            candidates = page.candidates,
            nextCursor = page.nextCursor,
            discoveryRequested = false,
        )
    }

    private fun windowIsTerminal(snapshot: DiscoveryLedgerSnapshot): Boolean =
        snapshot.items.all { item ->
            item.deliveryState == DeliveryState.CONFIRMED ||
                item.deliveryState == DeliveryState.FAILED_NEEDS_USER ||
                item.deliveryState == DeliveryState.CANCELLED_BY_SCOPE ||
                item.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND
        }
}
