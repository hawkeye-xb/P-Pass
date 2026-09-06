// REBUILD-04: minimal, durable UI projection. WorkManager state is intentionally absent.
package com.hawkeyexb.ppass.backup.flow

sealed interface FlowUiState {
    data object Idle : FlowUiState
    data object PausedByUser : FlowUiState
    data object WaitingForConstraints : FlowUiState
    data class Transferring(val queueSequence: Long, val fileName: String = "") : FlowUiState
    /** The strict head exhausted its delivery attempts and needs an explicit retry. */
    data object NeedsUserAttention : FlowUiState
    data object CancelledCurrentRound : FlowUiState
}

/**
 * Maps only persisted ledger facts to the small R3 status surface. A user pause
 * wins over constraints; an active cancellation round is distinct from both.
 */
fun flowUiStateOf(snapshot: DiscoveryLedgerSnapshot): FlowUiState = when {
    snapshot.cancellationRound != null -> FlowUiState.CancelledCurrentRound
    snapshot.consumerGate == ConsumerGate.PAUSED_BY_USER -> FlowUiState.PausedByUser
    snapshot.consumerStatus == ConsumerStatus.WAITING_FOR_CONSTRAINTS -> FlowUiState.WaitingForConstraints
    else -> snapshot.items.firstOrNull { it.deliveryState == DeliveryState.TRANSFERRING }
        ?.let { FlowUiState.Transferring(it.queueSequence, it.fileName) }
        ?: snapshot.items.firstOrNull { it.deliveryState == DeliveryState.FAILED_NEEDS_USER }
            ?.let { FlowUiState.NeedsUserAttention }
        ?: FlowUiState.Idle
}

/**
 * UI-09: the home status bar's aggregate (pending K / confirmed M /
 * last-success) derived purely from durable ledger facts. The LEGACY
 * ConfirmedStore is not consulted anywhere on this path — the Flow core was
 * the only writer after REBUILD-00 froze the batch pipeline, so the old read
 * path froze the numbers on real devices (verifier observation, 2026-09-06).
 */
data class FlowAggregate(val pending: Long, val confirmed: Long, val lastSuccessAt: Long)

fun flowAggregateOf(snapshot: DiscoveryLedgerSnapshot): FlowAggregate {
    var pending = 0L
    var confirmed = 0L
    var lastSuccessAt = 0L
    for (item in snapshot.items) {
        when (item.deliveryState) {
            // A user-cancelled round is a deliberate decision, not a debt;
            // scope-cancelled items left the selected scope entirely. Neither
            // counts as "待备份".
            DeliveryState.QUEUED, DeliveryState.TRANSFERRING, DeliveryState.FAILED_NEEDS_USER -> pending += 1
            DeliveryState.CONFIRMED -> {
                confirmed += 1
                if (item.completedAt > lastSuccessAt) lastSuccessAt = item.completedAt
            }
            DeliveryState.CANCELLED_BY_SCOPE, DeliveryState.CANCELLED_BY_USER_ROUND -> Unit
        }
    }
    return FlowAggregate(pending = pending, confirmed = confirmed, lastSuccessAt = lastSuccessAt)
}

/**
 * UI-09: "本轮全部安全" — every discovered item in the current durable window
 * carries a completion receipt and at least one item exists. An empty ledger
 * (nothing discovered yet) is deliberately NOT all-done; it renders Ready.
 */
fun flowIsAllDone(snapshot: DiscoveryLedgerSnapshot, aggregate: FlowAggregate): Boolean =
    snapshot.items.isNotEmpty() && aggregate.confirmed == snapshot.items.size.toLong()
