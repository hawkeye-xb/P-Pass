package com.hawkeyexb.ppass.backup.flow

class CancellationRoundController(
    private val ledger: DiscoveryLedgerStore,
    // NET-06: best-effort daemon notification for items that already made
    // real contact (a `flow.offer` at some point) — default no-op keeps
    // every existing call site and test untouched. AndroidFlowRuntime
    // wires the real daemon-backed implementation.
    private val tupleCanceller: FlowTupleCancelPort = NoopFlowTupleCancelPort,
) {
    fun startPausedRound(id: String) {
        ledger.update { snapshot ->
            require(snapshot.consumerGate == ConsumerGate.PAUSED_BY_USER) { "cancellation requires a user pause" }
            require(snapshot.fetchLease == null) { "cancellation requires the active fetch to stop first" }
            require(snapshot.cancellationRound == null) { "a cancellation round is already active" }
            val items = snapshot.items.map { item ->
                if (item.deliveryState == DeliveryState.QUEUED || item.deliveryState == DeliveryState.FAILED_NEEDS_USER) {
                    item.copy(
                        deliveryState = DeliveryState.CANCELLED_BY_USER_ROUND,
                        cancellationRoundId = id,
                    )
                } else {
                    item
                }
            }
            snapshot.copy(
                cancellationRound = CancellationRound(id),
                uploadCursor = items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }
                    ?.let { UploadCursor(it.queueSequence) }
                    ?: UploadCursor.INITIAL,
                items = items,
            )
        }
        // NET-06 review fix #2: only items that could plausibly have a real
        // daemon grant get a network call. Under ARCH-03's strict single-head
        // rule, the daemon only ever heard from an item once it was actually
        // offered. Two durable facts each independently prove that happened:
        // `attemptCount > 0` (StrictConsumer.recordPermanentFailure ran at
        // least once — a genuine failed round trip) or `partialRetained`
        // (StrictConsumer.pauseByUser/waitForConstraints called
        // delivery.stop() on it — NativeFlowDeliveryPort.stop() always
        // returns PartialDisposition.RETAINED, so this is only ever true
        // for an item delivery.start() was actually called on). A plain
        // QUEUED item discovered but never offered has neither — the
        // daemon has no grant for it, and a cancel call would just be a
        // wasted round trip silently swallowed as GuardMismatch.
        ledger.load().items
            .filter { it.cancellationRoundId == id && (it.attemptCount > 0 || it.partialRetained) }
            .forEach(tupleCanceller::cancel)
    }

    fun admitPage(candidates: List<DiscoveryCandidate>, cursor: DiscoveryCursor) {
        ledger.commitDiscoveryPage(candidates, cursor)
    }

    fun finishRound() {
        ledger.update { it.copy(cancellationRound = null) }
    }

    fun restoreRound(id: String) {
        ledger.update { snapshot ->
            require(snapshot.cancellationRound == null || snapshot.cancellationRound.id == id) {
                "another cancellation round is active"
            }
            require(snapshot.items.any { it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND && it.cancellationRoundId == id }) {
                "no cancelled items remain for round $id"
            }
            snapshot.copy(
                cancellationRound = if (snapshot.cancellationRound?.id == id) null else snapshot.cancellationRound,
                items = snapshot.items.map { item ->
                    if (item.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND && item.cancellationRoundId == id) {
                        item.copy(deliveryState = DeliveryState.QUEUED, cancellationRoundId = null)
                    } else {
                        item
                    }
                },
            )
        }
    }

    fun discardRound(id: String) {
        ledger.update { snapshot ->
            require(snapshot.cancellationRound == null || snapshot.cancellationRound.id == id) {
                "another cancellation round is active"
            }
            require(snapshot.items.any { it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND && it.cancellationRoundId == id }) {
                "no cancelled items remain for round $id"
            }
            snapshot.copy(
                cancellationRound = if (snapshot.cancellationRound?.id == id) null else snapshot.cancellationRound,
                items = snapshot.items.map { item ->
                    if (item.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND && item.cancellationRoundId == id) {
                        item.copy(cancellationRoundId = null)
                    } else {
                        item
                    }
                },
            )
        }
    }
}
