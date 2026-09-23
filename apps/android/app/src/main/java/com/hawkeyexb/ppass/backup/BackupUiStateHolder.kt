// REBUILD-04 → ARCH-13 (#417): Home status/actions are projected from the order table + loop status.
//
// #417 只做「能编译、能运行」的最小改动：公开成员（state / triplet / 各提示 / 命令）一个不少，
// 背后换成 [FlowProjection]。UI 的行为改动（取消剩余 N 张的文案、恢复入口去留、等待原因的人话）属于 #418。
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.backup.flow.CancelledRoundNotice
import com.hawkeyexb.ppass.backup.flow.FlowCommand
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.FlowProjection
import com.hawkeyexb.ppass.backup.flow.MissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.PairingEpoch
import com.hawkeyexb.ppass.backup.flow.RoundProgress
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.acknowledgeFlowMissingSource
import com.hawkeyexb.ppass.backup.flow.backupUiStateOf
import com.hawkeyexb.ppass.backup.flow.cancelRemainingFlow
import com.hawkeyexb.ppass.backup.flow.continueFlow
import com.hawkeyexb.ppass.backup.flow.fgsBlockNoticeRes
import com.hawkeyexb.ppass.backup.flow.flowCommandOf
import com.hawkeyexb.ppass.backup.flow.flowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.flowMissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.flowProjection
import com.hawkeyexb.ppass.backup.flow.pauseFlow
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.flow.retryFailedFlow
import com.hawkeyexb.ppass.backup.flow.roundProgressOf
import com.hawkeyexb.ppass.backup.flow.runtimeFor
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.ui.BackupUiState
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
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
    private val _state = mutableStateOf<BackupUiState>(BackupUiState.Idle)
    val state: State<BackupUiState> get() = _state

    private val _triplet = mutableStateOf<BackupTriplet?>(null)
    val triplet: State<BackupTriplet?> get() = _triplet

    /** #417：桌面缺失的照片现在自动补传、不打扰（#413），这条提示没有数据源了——恒 0，去留由 #418 定。 */
    private val _reuploadNoticeCount = mutableStateOf(0)
    val reuploadNoticeCount: State<Int> get() = _reuploadNoticeCount
    private val _missingSourceNotice = mutableStateOf<MissingSourceNotice?>(null)
    val missingSourceNotice: State<MissingSourceNotice?> get() = _missingSourceNotice
    private val _acknowledgedMissingSourceCount = mutableStateOf(0)
    val acknowledgedMissingSourceCount: State<Int> get() = _acknowledgedMissingSourceCount
    private val pairingLostState = HolderPairingLostState()
    val pairingLost: State<Boolean> get() = pairingLostState.value
    private var epochRepairAttempted = false

    // 2026-09-07 真机反馈：命令处理中禁用按钮，同一命令处理完才能再点下一次。
    private val _commandPending = mutableStateOf(false)
    val commandPending: State<Boolean> get() = _commandPending

    /** #415 裁决 4：SKIPPED_BY_USER 这次不提供恢复入口——恒 null（HomeScreen 的入口因此不渲染）。 */
    private val _cancelledRoundNotice = mutableStateOf<CancelledRoundNotice?>(null)
    val cancelledRoundNotice: State<CancelledRoundNotice?> get() = _cancelledRoundNotice

    /** #413：「已确认的 order 数 / 范围内的照片总数」。 */
    private val _roundProgress = mutableStateOf<RoundProgress?>(null)
    val roundProgress: State<RoundProgress?> get() = _roundProgress

    /** FGS 受阻的人话（额度用完 / 被拒）。null = 没有可解释的。 */
    private val _pauseReason = mutableStateOf<Int?>(null)
    val pauseReason: State<Int?> get() = _pauseReason

    /** #418 交接：完整投影（已确认数、范围内总数、当前进度、等待原因、暂停、FAILED 数）。 */
    private val _projection = mutableStateOf<FlowProjection?>(null)
    val projection: State<FlowProjection?> get() = _projection

    private val mediaObserver: ContentObserver
    private val refreshPending = AtomicBoolean(false)
    @Volatile private var inScopeTotal: Long? = null

    init {
        scope.launch {
            repairEpochIfNeeded()
            refresh(recount = true)
        }
        // 订阅取代轮询（MOB-88 的思路保留）：order 写入（revision）或循环运行态变化时重算投影。
        scope.launch { subscribe() }
        mediaObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) = scheduleRefresh(recount = true)
        }
        runCatching {
            context.contentResolver.registerContentObserver(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), true, mediaObserver)
        }
    }

    @OptIn(FlowPreview::class)
    private suspend fun subscribe() {
        var runtime = withContext(Dispatchers.IO) { runtimeFor(context) }
        while (runtime == null) {
            delay(RUNTIME_RETRY_MS)
            runtime = withContext(Dispatchers.IO) { runtimeFor(context) }
        }
        combine(runtime.engine.revision, runtime.engine.status) { _, _ -> Unit }
            .debounce(UI_DEBOUNCE_MS)
            .collect { refresh(recount = false) }
    }

    private fun scheduleRefresh(recount: Boolean) {
        if (!refreshPending.compareAndSet(false, true)) return
        scope.launch {
            try {
                refresh(recount)
            } finally {
                refreshPending.set(false)
            }
        }
    }

    fun dispose() {
        runCatching { context.contentResolver.unregisterContentObserver(mediaObserver) }
        scope.cancel()
    }

    /** #417：桌面缺失自动补传、没有提示了——保留入口给 #418，no-op。 */
    fun acknowledgeReuploadNotice() = Unit

    /** MOB-100（B4）：「已跳过 N 张…不会再重传」的确认路径（水位 = 确认时刻）。 */
    fun acknowledgeMissingSourceNotice() {
        if (_missingSourceNotice.value == null) return
        command { acknowledgeFlowMissingSource(context) }
    }

    private fun command(block: suspend () -> Unit) {
        if (_commandPending.value) return
        _commandPending.value = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) { block() }
                refresh(recount = false)
            } finally {
                _commandPending.value = false
            }
        }
    }

    /** Pause/Continue/Retry/Wake，按与按钮文案同一个投影路由（MOB-51）。 */
    fun backupNow() = command {
        val p = _projection.value ?: currentProjection(recount = false)
        when (p?.let(::flowCommandOf) ?: FlowCommand.Wake) {
            FlowCommand.Pause -> pauseFlow(context)
            FlowCommand.Continue -> continueFlow(context)
            FlowCommand.Retry -> retryFailedFlow(context)
            FlowCommand.Wake -> requestFlowWake(context, TriggerReason.MANUAL)
        }
    }

    /**
     * 「取消剩余 N 张」。#415 裁决 4：不需要先暂停。UI 的确认文案（带 N）属于 #418；
     * 这里保留原入口名，行为已是新语义。
     */
    fun cancelCurrentRound() = command { cancelRemainingFlow(context) }

    /** #415 裁决 4：没有恢复入口。保留方法签名给 HomeScreen，no-op。 */
    fun restoreCancelledRounds() = Unit

    private suspend fun repairEpochIfNeeded() {
        if (epochRepairAttempted || !needsEpochRepair(pairing.pairingEpoch)) return
        epochRepairAttempted = true
        val outcome = runCatching {
            withContext(Dispatchers.IO) {
                withTimeout(5_000) {
                    val response = client.call(parsePeerAddrToken(pairing.daemonAddrToken), Methods.HELLO, buildJsonObject {})
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
            EpochRepairResult.Lost -> pairingLostState.markLost()
        }
    }

    private fun currentProjection(recount: Boolean): FlowProjection? {
        val bucketIds = scopeStore.selectedBucketIds()
        if (recount || inScopeTotal == null) {
            inScopeTotal = try {
                bucketIds?.let { MediaScanner(context.contentResolver).countAll(it) }
            } catch (_: Throwable) {
                null
            }
        }
        return flowProjection(context, bucketIds, inScopeTotal)
    }

    private suspend fun refresh(recount: Boolean) {
        pairingLostState.syncFrom(flowDeliveryPairingLoss, PairingEpoch(pairing.pairingEpoch))
        val bucketIds = withContext(Dispatchers.IO) { scopeStore.selectedBucketIds() }
        val p = withContext(Dispatchers.IO) { runCatching { currentProjection(recount) }.getOrNull() } ?: return
        _projection.value = p
        _state.value = backupUiStateOf(p)
        _missingSourceNotice.value = flowMissingSourceNotice(p)
        _acknowledgedMissingSourceCount.value = p.missingSourceAcknowledged.toInt()
        _roundProgress.value = roundProgressOf(p)
        _pauseReason.value = fgsBlockNoticeRes(p.fgsBlock)
        // UI-09 / UI-16：N 是范围内 MediaStore 实时计数，M 是同范围的已确认 order 数。
        _triplet.value = if (bucketIds == null) {
            null
        } else {
            p.inScopeTotal?.let { n ->
                tripletOf(n, p.confirmed, p.lastSuccessAt, hasFailedNeedsUser = p.failed > 0L, pausedByUser = p.paused)
            }
        }
    }

    private companion object {
        const val RUNTIME_RETRY_MS = 2_000L
        const val UI_DEBOUNCE_MS = 150L
    }
}

/** The holder's existing pairing-lost UI state, factored for Flow error projection. */
internal class HolderPairingLostState {
    private val _value = mutableStateOf(false)
    val value: State<Boolean> get() = _value

    fun markLost() {
        _value.value = true
    }

    fun syncFrom(deliveryLoss: FlowDeliveryPairingLoss, epoch: PairingEpoch) {
        if (deliveryLoss.isLost(epoch)) markLost()
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
