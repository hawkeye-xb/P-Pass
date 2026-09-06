// REBUILD-04: Home status/actions are projected from the durable Flow ledger.
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.backup.flow.FlowUiState
import com.hawkeyexb.ppass.backup.flow.cancelCurrentFlowRound
import com.hawkeyexb.ppass.backup.flow.continueFlow
import com.hawkeyexb.ppass.backup.flow.flowAggregateOf
import com.hawkeyexb.ppass.backup.flow.flowIsAllDone
import com.hawkeyexb.ppass.backup.flow.flowLedgerSnapshot
import com.hawkeyexb.ppass.backup.flow.flowUiStateOf
import com.hawkeyexb.ppass.backup.flow.pauseFlow
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.flow.retryFailedFlow
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
    private val tripletScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val _state = mutableStateOf<BackupUiState>(BackupUiState.Idle)
    val state: State<BackupUiState> get() = _state

    // UI-09: K/M/last-success now derive from the durable Flow ledger. The
    // LEGACY ConfirmedStore had no production writer after REBUILD-00 froze
    // the batch pipeline — reading it froze the home screen while transfers
    // actually succeeded (verifier observation, 2026-09-06).
    private val _triplet = mutableStateOf<BackupTriplet?>(null)
    val triplet: State<BackupTriplet?> get() = _triplet
    private val _reuploadNoticeCount = mutableStateOf(0)
    val reuploadNoticeCount: State<Int> get() = _reuploadNoticeCount
    private val _pairingLost = mutableStateOf(false)
    val pairingLost: State<Boolean> get() = _pairingLost

    init {
        scope.launch {
            while (isActive) {
                refreshFlowState()
                delay(500)
            }
        }
        // The triplet's N is a MediaStore count — too heavy for the 500ms
        // status tick, so it refreshes on its own slower IO loop.
        tripletScope.launch {
            while (isActive) {
                withContext(Dispatchers.IO) { refreshTriplet() }
                delay(2_000)
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
                    FlowUiState.NeedsUserAttention -> retryFailedFlow(context)
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
        // UI-09: one ledger read for the six-state surface. The aggregate
        // (K/M/last-success) is derived from the same durable facts by the
        // slower refreshTriplet loop.
        val snapshot = flowLedgerSnapshot(context)
        val aggregate = flowAggregateOf(snapshot)
        _state.value = when (val state = flowUiStateOf(snapshot)) {
            FlowUiState.Idle -> if (flowIsAllDone(snapshot, aggregate)) {
                BackupUiState.AllSafe(ingested = aggregate.confirmed.toInt(), duplicates = 0)
            } else {
                BackupUiState.Idle
            }
            FlowUiState.PausedByUser -> BackupUiState.Paused
            FlowUiState.WaitingForConstraints -> BackupUiState.WaitingForConstraints
            is FlowUiState.Transferring -> BackupUiState.Sending(0, 0, state.fileName)
            FlowUiState.NeedsUserAttention -> BackupUiState.Trouble("Flow delivery exhausted its retry limit")
            FlowUiState.CancelledCurrentRound -> BackupUiState.CancelledCurrentRound
        }
    }

    /**
     * UI-09: the displayed triplet. N stays a live MediaStore count (the
     * selected-scope total); M and last-success come from the durable Flow
     * ledger. Runs on the IO dispatcher; the media query keeps the same
     * Throwable guard as before (a scoped provider failure must hide the
     * triplet, never crash — see MediaQueryFailureTest).
     */
    private fun refreshTriplet() {
        _triplet.value = try {
            val bucketIds = scopeStore.selectedBucketIds() ?: return
            val aggregate = flowAggregateOf(flowLedgerSnapshot(context))
            val n = MediaScanner(context.contentResolver).countAll(bucketIds)
            tripletOf(n, aggregate.confirmed, aggregate.lastSuccessAt)
        } catch (_: Throwable) {
            null
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
