// REBUILD-04: Home status/actions are projected from the durable Flow ledger.
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.backup.flow.FlowUiState
import com.hawkeyexb.ppass.backup.flow.cancelCurrentFlowRound
import com.hawkeyexb.ppass.backup.flow.continueFlow
import com.hawkeyexb.ppass.backup.flow.flowLedgerSnapshot
import com.hawkeyexb.ppass.backup.flow.flowUiStateOf
import com.hawkeyexb.ppass.backup.flow.pauseFlow
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.ui.BackupUiState
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class BackupUiStateHolder(
    private val context: Context,
    @Suppress("UNUSED_PARAMETER") client: DaemonClient,
    @Suppress("UNUSED_PARAMETER") identity: IdentityStore,
    pairing: Pairing,
    private val scopeStore: BackupScopeStore = BackupScopeStore(context),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val _state = mutableStateOf<BackupUiState>(BackupUiState.Idle)
    val state: State<BackupUiState> get() = _state

    // Existing aggregate presentation remains independent of the new per-item
    // status surface. R3 deliberately does not change reconciliation/triplet UI.
    private val confirmedStore = ConfirmedStore(
        File(context.filesDir, "backup-state/${pairing.daemonNodeId}"),
    )
    private val _triplet = mutableStateOf<BackupTriplet?>(null)
    val triplet: State<BackupTriplet?> get() = _triplet
    private val _reuploadNoticeCount = mutableStateOf(0)
    val reuploadNoticeCount: State<Int> get() = _reuploadNoticeCount
    private val _pairingLost = mutableStateOf(false)
    val pairingLost: State<Boolean> get() = _pairingLost

    init {
        scope.launch { refreshTriplet() }
        scope.launch {
            while (isActive) {
                refreshFlowState()
                delay(500)
            }
        }
    }

    fun acknowledgeReuploadNotice() = Unit

    /** Pause/Continue/trigger commands operate on the same persisted Flow ledger. */
    fun backupNow() {
        scope.launch {
            withContext(Dispatchers.IO) {
                when (flowUiStateOf(flowLedgerSnapshot(context))) {
                    is FlowUiState.Transferring -> pauseFlow(context)
                    FlowUiState.PausedByUser -> continueFlow(context)
                    else -> requestFlowWake(context)
                }
            }
            refreshFlowState()
        }
    }

    /** Cancel is intentionally offered only from a durable user-paused state. */
    fun cancelCurrentRound() {
        scope.launch {
            withContext(Dispatchers.IO) {
                if (flowUiStateOf(flowLedgerSnapshot(context)) == FlowUiState.PausedByUser) {
                    cancelCurrentFlowRound(context)
                }
            }
            refreshFlowState()
        }
    }

    private fun refreshFlowState() {
        _state.value = when (val state = flowUiStateOf(flowLedgerSnapshot(context))) {
            FlowUiState.Idle -> BackupUiState.Idle
            FlowUiState.PausedByUser -> BackupUiState.Paused
            FlowUiState.WaitingForConstraints -> BackupUiState.WaitingForConstraints
            is FlowUiState.Transferring -> BackupUiState.Sending(0, 0, state.fileName)
            FlowUiState.CancelledCurrentRound -> BackupUiState.CancelledCurrentRound
        }
    }

    private suspend fun refreshTriplet() {
        _triplet.value = withContext(Dispatchers.IO) {
            computeTripletSafe(context.contentResolver, confirmedStore, scopeStore.selectedBucketIds())
        }
    }
}

internal fun computeTripletSafe(
    resolver: ContentResolver?,
    store: ConfirmedStore,
    bucketIds: Set<Long>? = null,
): BackupTriplet? = try {
    if (bucketIds == null) null else {
        val scanner = MediaScanner(checkNotNull(resolver))
        tripletOf(scanner.countAll(bucketIds), store.countInScope(bucketIds).toLong(), store.lastSuccessAt())
    }
} catch (_: Throwable) {
    null
}

internal fun isPairingLostError(t: Throwable): Boolean =
    t.message?.let { it.contains("err.not_paired") || it.contains("err.not_authorized") } ?: false

internal fun isPairingLostText(text: String): Boolean =
    text.contains("err.not_paired") || text.contains("err.not_authorized")
