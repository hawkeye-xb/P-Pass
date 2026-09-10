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
        reopenGate(auditAction = "continue")
        run(constraintsSatisfied)
    }

    /**
     * Reopen the consumer gate without a dedicated audit entry — used by
     * [cancelCurrentRound] and [restoreAllCancelledRounds], whose own cancel/
     * restore audit event already covers the user action; a second
     * `flow.round.controlled` "continue" entry right after would be a
     * duplicate description of the same click, not a second fact.
     */
    private fun reopenGate(auditAction: String?) {
        ledger.update { snapshot ->
            val reopened = snapshot.copy(consumerGate = ConsumerGate.OPEN, consumerStatus = ConsumerStatus.IDLE)
            if (auditAction != null) {
                reopened.appendAudit(AuditKinds.ROUND_CONTROLLED, roundId = snapshot.currentRoundId, payload = mapOf("action" to auditAction))
            } else {
                reopened
            }
        }
    }

    /**
     * Cancel is deliberately only available after pausing the current head —
     * the pre-cancel [pause] exists solely to bring the consumer to a safe,
     * quiescent point before the cancellation scan runs.
     *
     * MOB-60: once that scan finishes, there is no in-flight round left for
     * "Continue" to resume — every cancellable item in the window was just
     * marked [DeliveryState.CANCELLED_BY_USER_ROUND]. Leaving the gate on
     * [ConsumerGate.PAUSED_BY_USER] after that point is a leftover safety
     * artifact masquerading as a durable state: the home screen kept showing
     * Paused/Continue/Cancel for a round that no longer existed (real
     * device, 2026-09-07: "取消完了怎么还是暂停"). Reopening the gate the
     * same way [continueFlow]/[restoreAllCancelledRounds] already do lets
     * the existing snapshot -> UI projection do its job: with nothing left
     * QUEUED/TRANSFERRING it resolves to Idle on its own, no new UI state
     * needed. Any still-pending discovery request is free to admit the
     * *next* round's candidates immediately, exactly as it would after any
     * other terminal window.
     */
    fun cancelCurrentRound(roundId: String) {
        pause()
        val cancelledRoundId = ledger.load().currentRoundId
        cancellation.startPausedRound(roundId)
        // startPausedRound terminally marks every cancellable item in the
        // current durable window, so this production cancellation scan ends
        // atomically before future discovery admits the next round.
        cancellation.finishRound()
        ledger.update { snapshot ->
            snapshot.appendAudit(AuditKinds.ROUND_CONTROLLED, roundId = cancelledRoundId, payload = mapOf("action" to "cancel"))
        }
        reopenGate(auditAction = null)
        run(constraintsSatisfied = true)
    }

    fun acceptCompletionReceipt(receipt: CompletionReceipt) {
        completion.acceptCompletionReceipt(receipt)
        // Receipt persistence is the strict-head boundary: only after it is
        // durable may the next queued item acquire a new lease.
        consumer.wake(constraintsSatisfied = true)
    }

    /** A user retry reopens terminal delivery failures as a new strict round.
     *  AUDIT-04: retry does not write a canonical audit fact — card acceptance
     *  criterion #4 groups it with hello as routine, not a long-term audit
     *  event (unlike cancel/restore, which ARE decisions); the case matrix
     *  also has no "用户重试" case. The terminal failure itself is already
     *  durable object evidence via [AuditKinds.ITEM_ATTENTION]. */
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

    fun recordPermanentFailure() {
        consumer.recordPermanentFailure()
        // MOB-54: a transient (non-terminal) failure re-queues the head but
        // must not stall there — same rule as acceptCompletionReceipt: only
        // after the outcome is durable may the consumer look for its next
        // action (retry the same head if still QUEUED, or move on if this
        // attempt made it terminal).
        consumer.wake(constraintsSatisfied = true)
    }

    /** A deleted phone source is terminal; immediately advance past it. */
    fun skipMissingSource() {
        consumer.skipMissingSource()
        consumer.wake(constraintsSatisfied = true)
    }

    /**
     * MOB-59: X-05's explicit user action, finally wired to production, and
     * corrected to survive repeated cancels (2026-09-07 real device: cancelling
     * twice orphaned the first batch behind a notice that only knew the
     * latest round id). There is no Discard: the notice is meant to be a
     * permanent, always-there entry, not a dismissible one with a dead end —
     * so this restores every distinct cancelled round in one atomic action.
     * Restoring must also reopen the gate and wake the consumer — the same
     * gate `continueFlow` reopens — otherwise the re-admitted QUEUED items
     * sit inert behind the still-active user pause (MOB-49).
     */
    fun restoreAllCancelledRounds() {
        val roundIds = ledger.load().items
            .mapNotNull { if (it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND) it.cancellationRoundId else null }
            .distinct()
        if (roundIds.isEmpty()) return
        roundIds.forEach { cancellation.restoreRound(it) }
        ledger.update { snapshot ->
            snapshot.appendAudit(AuditKinds.ROUND_CONTROLLED, roundId = snapshot.currentRoundId, payload = mapOf("action" to "restore"))
        }
        reopenGate(auditAction = null)
        run(constraintsSatisfied = true)
    }

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
                item.deliveryState == DeliveryState.SKIPPED_SOURCE_MISSING ||
                item.deliveryState == DeliveryState.CANCELLED_BY_SCOPE ||
                item.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND
        }
}
