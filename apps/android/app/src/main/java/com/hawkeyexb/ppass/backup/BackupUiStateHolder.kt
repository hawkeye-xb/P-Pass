// REBUILD-04: Home status/actions are projected from the durable Flow ledger.
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.backup.flow.FlowCommand
import com.hawkeyexb.ppass.backup.flow.FlowUiState
import com.hawkeyexb.ppass.backup.flow.RoundProgress
import com.hawkeyexb.ppass.backup.flow.advanceRoundProgress
import com.hawkeyexb.ppass.backup.flow.backupUiStateOf
import com.hawkeyexb.ppass.backup.flow.cancelCurrentFlowRound
import com.hawkeyexb.ppass.backup.flow.continueFlow
import com.hawkeyexb.ppass.backup.flow.flowAggregateOf
import com.hawkeyexb.ppass.backup.flow.flowCancelledRoundNotice
import com.hawkeyexb.ppass.backup.flow.flowCommandOf
import com.hawkeyexb.ppass.backup.flow.flowIsAllDone
import com.hawkeyexb.ppass.backup.flow.flowLedgerSnapshot
import com.hawkeyexb.ppass.backup.flow.flowReuploadNoticeCount
import com.hawkeyexb.ppass.backup.flow.flowUiStateOf
import com.hawkeyexb.ppass.backup.flow.pauseFlow
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.flow.restoreAllCancelledFlowRounds
import com.hawkeyexb.ppass.backup.flow.retryFailedFlow
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.ui.BackupUiState
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject

class BackupUiStateHolder(
    private val context: Context,
    private val client: DaemonClient,
    @Suppress("UNUSED_PARAMETER") identity: IdentityStore,
    private val pairing: Pairing,
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
    // UI-10 item 1: guards the silent epoch-repair attempt so it fires at
    // most once per held instance — a repeated blank epoch after a failed
    // repair means the pairing is genuinely lost, not a transient race.
    private var epochRepairAttempted = false
    // 2026-09-07 真机反馈：暂停/取消/取消当前轮连点几下会各自往协程里排
    // 一个命令，但按钮从点击到下一次 500ms tick 刷新之间没有任何禁用/
    // 处理中反馈——用户看不出点击生效了没有，于是接着点，命令排队执行，
    // 表现为「按钮卡死」。这里加一个「命令处理中」标记，UI 据此禁用按钮
    // 并显示处理中文案，同一命令处理完才能再点下一次。
    private val _commandPending = mutableStateOf(false)
    val commandPending: State<Boolean> get() = _commandPending
    // MOB-59: X-05's restore entry — a permanent notice, not a dismissible
    // one (no Discard: real-device feedback was explicit that a discard
    // button with no way back is a dead end). Null = nothing cancelled and
    // still awaiting restore. Counts across ALL cancelled rounds, not just
    // the latest — repeated cancels must not orphan earlier batches.
    private val _cancelledRoundNotice = mutableStateOf<com.hawkeyexb.ppass.backup.flow.CancelledRoundNotice?>(null)
    val cancelledRoundNotice: State<com.hawkeyexb.ppass.backup.flow.CancelledRoundNotice?> get() = _cancelledRoundNotice
    // MOB-59: this round's own progress (0-based), separate from the
    // lifetime M/N triplet above the bar — real-device feedback: adding more
    // albums mid-round made the bar jump straight to "15/15"-ish territory
    // instead of showing the newly added work starting at 0. null previous
    // pending = round hasn't been observed yet (fresh holder instance).
    private var previousPending: Long? = null
    private var previousRoundDone: Long = 0L
    private val _roundProgress = mutableStateOf<RoundProgress?>(null)
    val roundProgress: State<RoundProgress?> get() = _roundProgress

    init {
        scope.launch {
            while (isActive) {
                repairEpochIfNeeded()
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
        if (_commandPending.value) return
        _commandPending.value = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    // MOB-51: route the click on the same durable facts the button
                    // label came from — a visible "Pause" always pauses, including
                    // in the between-files gap where the per-file state is Idle.
                    when (flowCommandOf(flowLedgerSnapshot(context))) {
                        FlowCommand.Pause -> pauseFlow(context)
                        FlowCommand.Continue -> continueFlow(context)
                        FlowCommand.Retry -> retryFailedFlow(context)
                        FlowCommand.Wake -> requestFlowWake(context)
                    }
                }
                refreshFlowState()
            } finally {
                _commandPending.value = false
            }
        }
    }

    /** Cancel is intentionally offered only from a durable user-paused state. */
    fun cancelCurrentRound() {
        if (_commandPending.value) return
        _commandPending.value = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    if (flowUiStateOf(flowLedgerSnapshot(context)) == FlowUiState.PausedByUser) {
                        cancelCurrentFlowRound(context)
                    }
                }
                refreshFlowState()
            } finally {
                _commandPending.value = false
            }
        }
    }

    /**
     * UI-10 item 1: `AndroidFlowRuntime.runtimeFor()` needs a non-blank
     * `pairingEpoch` to do anything — a blank one (legacy pairing, or a
     * pre-epoch app version) otherwise makes the home screen render Idle
     * forever with dead buttons. One silent `hello` attempt tries to recover
     * the current epoch from Desktop before ever showing the pairing-lost
     * red card; a real revoke still surfaces normally once the repair fails.
     */
    private suspend fun repairEpochIfNeeded() {
        if (epochRepairAttempted || !needsEpochRepair(pairing.pairingEpoch)) return
        epochRepairAttempted = true
        val outcome = runCatching {
            withContext(Dispatchers.IO) {
                withTimeout(5_000) {
                    val response = client.call(
                        parsePeerAddrToken(pairing.daemonAddrToken),
                        Methods.HELLO,
                        buildJsonObject {},
                    )
                    check(response.ok) { "hello: ${response.error?.msgKey}" }
                    ProtoJson.decodeFromJsonElement(Hello.serializer(), checkNotNull(response.result)).pairingEpoch
                }
            }
        }
        when (val result = applyEpochRepairOutcome(outcome)) {
            is EpochRepairResult.Repaired -> {
                val store = PairingStore(context.filesDir)
                store.load()?.let { store.save(it.copy(pairingEpoch = result.epoch)) }
            }
            EpochRepairResult.Lost -> _pairingLost.value = true
        }
    }

    private fun refreshFlowState() {
        // UI-09/MOB-51: the home screen state is the single shared production
        // mapping from the durable snapshot (backupUiStateOf). The aggregate
        // (K/M/last-success) is derived from the same facts by the slower
        // refreshTriplet loop.
        val snapshot = flowLedgerSnapshot(context)
        _state.value = backupUiStateOf(snapshot)
        // UI-10 item 2: ledger-derived reupload count replaces the dead
        // LEGACY ReuploadQueue read (see flowReuploadNoticeCount doc).
        _reuploadNoticeCount.value = flowReuploadNoticeCount(snapshot)
        // MOB-59: X-05's cancelled-round notice, read from the same tick.
        _cancelledRoundNotice.value = flowCancelledRoundNotice(snapshot)
        // MOB-59: this round's own progress, not the lifetime M/N triplet.
        val pending = flowAggregateOf(snapshot).pending
        val progress = advanceRoundProgress(previousPending, previousRoundDone, pending)
        previousPending = pending
        previousRoundDone = progress.done
        _roundProgress.value = progress
    }

    /** MOB-59: re-admit every cancelled round's items as QUEUED and wake the consumer. */
    fun restoreCancelledRounds() {
        if (_cancelledRoundNotice.value == null) return
        if (_commandPending.value) return
        _commandPending.value = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) { restoreAllCancelledFlowRounds(context) }
                refreshFlowState()
            } finally {
                _commandPending.value = false
            }
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

/**
 * UI-10 item 1: `AndroidFlowRuntime.runtimeFor()` returns null when a stored
 * pairing has a blank `pairingEpoch` (legacy pairing.json from before
 * ARCH-06, or one written by a pre-epoch app version). The home screen then
 * fell back to an empty Flow ledger snapshot — rendering plain `Idle` with a
 * fully clickable Pause/Continue/Cancel that silently did nothing, and no
 * explanation to the user (source-read finding, 2026-09-06: this is a
 * candidate root cause for "暂停/取消没有展示机会").
 *
 * The fix is a silent, one-shot repair attempt, not an immediate "重新扫码"
 * demand: a blank epoch is recoverable (the Desktop still knows this device
 * and answers `hello` with its current epoch) whenever the pairing itself
 * was never actually revoked — only escalate to the pairing-lost red card
 * when the repair attempt itself fails.
 */
internal fun needsEpochRepair(pairingEpoch: String): Boolean = pairingEpoch.isBlank()

/** The pure outcome mapping for a silent epoch-repair `hello` attempt. */
internal sealed class EpochRepairResult {
    data class Repaired(val epoch: String) : EpochRepairResult()
    data object Lost : EpochRepairResult()
}

/**
 * `outcome` is the result of asking Desktop for its current epoch (via the
 * same `hello` the Flow delivery preflight already uses — no new protocol).
 * A blank/null epoch in a successful response is treated the same as a
 * failure: Desktop itself has nothing to offer, so there is nothing to
 * repair to.
 */
internal fun applyEpochRepairOutcome(outcome: Result<String?>): EpochRepairResult {
    val epoch = outcome.getOrNull()
    return if (outcome.isSuccess && !epoch.isNullOrBlank()) {
        EpochRepairResult.Repaired(epoch)
    } else {
        EpochRepairResult.Lost
    }
}
