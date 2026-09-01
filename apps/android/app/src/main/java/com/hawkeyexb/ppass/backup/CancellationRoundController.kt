package com.hawkeyexb.ppass.backup

class CancellationRoundController(private val ledger: DiscoveryLedgerStore) {
    fun startPausedRound(id: String) {
        ledger.update { snapshot ->
            require(snapshot.consumerGate == ConsumerGate.PAUSED_BY_USER) { "cancellation requires a user pause" }
            require(snapshot.fetchLease == null) { "cancellation requires the active fetch to stop first" }
            require(snapshot.cancellationRound == null) { "a cancellation round is already active" }
            snapshot.copy(
                cancellationRound = CancellationRound(id),
                items = snapshot.items.map { item ->
                    if (item.deliveryState == DeliveryState.QUEUED || item.deliveryState == DeliveryState.FAILED_NEEDS_USER) {
                        item.copy(
                            deliveryState = DeliveryState.CANCELLED_BY_USER_ROUND,
                            cancellationRoundId = id,
                        )
                    } else {
                        item
                    }
                },
            )
        }
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
