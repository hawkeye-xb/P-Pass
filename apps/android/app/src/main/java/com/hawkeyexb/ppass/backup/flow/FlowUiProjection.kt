package com.hawkeyexb.ppass.backup.flow

/** Minimal, durable UI projection. WorkManager state is intentionally absent. */
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
