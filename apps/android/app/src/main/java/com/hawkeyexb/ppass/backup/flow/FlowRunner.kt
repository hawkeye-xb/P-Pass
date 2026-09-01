// REBUILD-03: production coordinator for the durable ARCH-01 Flow boundary.
package com.hawkeyexb.ppass.backup.flow

/** One ordered, bounded discovery response. It carries no transport decision. */
data class DiscoveryPage(
    val candidates: List<DiscoveryCandidate>,
    val nextCursor: DiscoveryCursor,
)

/** Android's MediaStore adapter implements this port; tests use a deterministic page. */
interface FlowDiscoveryPort {
    fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage
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

    /**
     * Consume at most one requested discovery page, then offer exactly the
     * durable strict head to the delivery port. Repeated triggers coalesce in
     * the ledger; active windows never receive another discovery page.
     */
    fun run(constraintsSatisfied: Boolean) {
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
    }

    fun acceptCompletionReceipt(receipt: CompletionReceipt) = completion.acceptCompletionReceipt(receipt)

    fun recordPermanentFailure() = consumer.recordPermanentFailure()

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
