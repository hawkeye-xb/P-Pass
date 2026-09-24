// REBUILD-04 → ARCH-13 (#417) → ARCH-14 (#418): Home status/actions are projected from the order table + loop status.
//
// 所有裁决都在 FlowUiProjection.kt 的纯函数里（JVM 可测）；这里只负责取事实、节流、把结果放进 Compose State。
// 取消轮与桌面缺失补传提示已删除（#413：桌面缺失自动补传、不打扰）。取消 = 「取消剩余 N 张」逐张写
// SKIPPED_BY_USER；恢复 = 「已跳过的照片 · 点击恢复」删掉这些行，交给慢路径重新规划。
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.backup.flow.FlowCommand
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.FlowProjection
import com.hawkeyexb.ppass.backup.flow.MissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.PairingEpoch
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.acknowledgeFlowMissingSource
import com.hawkeyexb.ppass.backup.flow.backupUiStateOf
import com.hawkeyexb.ppass.backup.flow.cancelRemainingFlow
import com.hawkeyexb.ppass.backup.flow.cancelRemainingRowCount
import com.hawkeyexb.ppass.backup.flow.continueFlow
import com.hawkeyexb.ppass.backup.flow.countRemainingFlow
import com.hawkeyexb.ppass.backup.flow.fgsBlockWaitNoticeRes
import com.hawkeyexb.ppass.backup.flow.flowCommandOf
import com.hawkeyexb.ppass.backup.flow.flowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.flowMissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.flowProjection
import com.hawkeyexb.ppass.backup.flow.pauseFlow
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.flow.restoreSkippedFlow
import com.hawkeyexb.ppass.backup.flow.retryFailedFlow
import com.hawkeyexb.ppass.backup.flow.flowTripletOf
import com.hawkeyexb.ppass.backup.flow.runtimeFor
import com.hawkeyexb.ppass.backup.flow.skippedRowCount
import com.hawkeyexb.ppass.backup.flow.transferPermilleOf
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
import kotlinx.coroutines.channels.Channel
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

    /** #418：正在传的这一张的字节进度（0..1）。null = 没在传 / 总字节未知。 */
    private val _transferProgress = mutableStateOf<Float?>(null)
    val transferProgress: State<Float?> get() = _transferProgress

    /** #418：设置页「取消剩余 N 张」那一行的 N。null = 不渲染这一行。 */
    private val _cancelRemainingCount = mutableStateOf<Long?>(null)
    val cancelRemainingCount: State<Long?> get() = _cancelRemainingCount

    /** #418：设置卡「已跳过的照片 N 张」的 N（SKIPPED_BY_USER）。null = 不渲染这一行。 */
    private val _skippedCount = mutableStateOf<Long?>(null)
    val skippedCount: State<Long?> get() = _skippedCount

    /** #418：确认框要写明的 N（点那一行时现算）。null = 没有确认框。 */
    private val _cancelConfirmCount = mutableStateOf<Int?>(null)
    val cancelConfirmCount: State<Int?> get() = _cancelConfirmCount

    /** FGS 受阻的人话（额度用完 / 被拒），只在循环此刻正因此等待时给出。null = 没有可解释的。 */
    private val _waitReasonNotice = mutableStateOf<Int?>(null)
    val waitReasonNotice: State<Int?> get() = _waitReasonNotice

    /** #418 交接：完整投影（已确认数、范围内总数、当前进度、等待原因、暂停、FAILED 数）。 */
    private val _projection = mutableStateOf<FlowProjection?>(null)
    val projection: State<FlowProjection?> get() = _projection

    private val mediaObserver: ContentObserver
    private val refreshPending = AtomicBoolean(false)
    @Volatile private var inScopeTotal: Long? = null

    /** 最近一次现算的「剩余张数」。全量读 MediaStore + order 表，所以节流（见 [remainingLoop]）。 */
    @Volatile private var remaining: Long? = null
    private val remainingRequests = Channel<Unit>(Channel.CONFLATED)
    private var lastBucketIds: Set<Long>? = null

    init {
        scope.launch {
            repairEpochIfNeeded()
            refresh(recount = true)
        }
        // 订阅取代轮询（MOB-88 的思路保留）：order 写入（revision）或循环运行态变化时重算投影。
        // 运行态读 engine.display（与 FGS 通知同一个出口）：值变了才发、字节进度每秒最多一次。
        scope.launch { subscribe() }
        scope.launch { remainingLoop() }
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
        combine(runtime.engine.revision, runtime.engine.display) { _, _ -> Unit }
            .debounce(UI_DEBOUNCE_MS)
            .collect { refresh(recount = false) }
    }

    /**
     * 「剩余张数」要把 MediaStore 与 order 表各读一遍，不能跟着每个进度回调算。每次投影刷新只是投一个
     * 请求（CONFLATED，合并），这里算完一次至少歇 [REMAINING_MIN_INTERVAL_MS]；算出来只重新发布上一次的
     * 投影，不再触发刷新（否则自己喂自己）。
     */
    private suspend fun remainingLoop() {
        for (request in remainingRequests) {
            val n = withContext(Dispatchers.IO) { runCatching { countRemainingFlow(context) }.getOrNull() }
            if (n != null) {
                remaining = n.toLong()
                _projection.value?.let { publish(it.copy(remaining = remaining)) }
            }
            delay(REMAINING_MIN_INTERVAL_MS)
        }
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
     * 点「取消剩余 N 张」：先按引擎同一个函数现算 N，N > 0 才弹确认框（框里写明 N）。
     * 算出来是 0（这期间都传完了）就只把那一行收起来。
     */
    fun requestCancelRemaining() {
        if (_commandPending.value) return
        _commandPending.value = true
        scope.launch {
            try {
                val n = withContext(Dispatchers.IO) { runCatching { countRemainingFlow(context) }.getOrNull() } ?: return@launch
                remaining = n.toLong()
                _projection.value?.let { publish(it.copy(remaining = remaining)) }
                _cancelConfirmCount.value = n.takeIf { it > 0 }
            } finally {
                _commandPending.value = false
            }
        }
    }

    /**
     * 「已跳过的照片 · 点击恢复」：删掉所有 SKIPPED_BY_USER 行（单事务），慢路径把它们重新规划进待传。
     */
    fun restoreSkipped() = command {
        restoreSkippedFlow(context)
        remaining = runCatching { countRemainingFlow(context) }.getOrNull()?.toLong() ?: remaining
    }

    fun dismissCancelRemaining() {
        _cancelConfirmCount.value = null
    }

    /**
     * 确认「取消剩余 N 张」：#415 裁决 4，不需要先暂停；当场停掉当前这张，剩余的逐张写成
     * SKIPPED_BY_USER（含 FAILED，裁决 7）。这次不提供恢复入口。
     */
    fun confirmCancelRemaining() {
        if (_cancelConfirmCount.value == null) return
        _cancelConfirmCount.value = null
        command {
            cancelRemainingFlow(context)
            remaining = runCatching { countRemainingFlow(context) }.getOrNull()?.toLong() ?: remaining
        }
    }

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
        return flowProjection(context, bucketIds, inScopeTotal, remaining)
    }

    private suspend fun refresh(recount: Boolean) {
        pairingLostState.syncFrom(flowDeliveryPairingLoss, PairingEpoch(pairing.pairingEpoch))
        val bucketIds = withContext(Dispatchers.IO) { scopeStore.selectedBucketIds() }
        val p = withContext(Dispatchers.IO) { runCatching { currentProjection(recount) }.getOrNull() } ?: return
        lastBucketIds = bucketIds
        publish(p)
        remainingRequests.trySend(Unit)
    }

    /** 投影 → 各个 State。全部裁决在 FlowUiProjection.kt 的纯函数里。 */
    private fun publish(p: FlowProjection) {
        _projection.value = p
        _state.value = backupUiStateOf(p)
        _missingSourceNotice.value = flowMissingSourceNotice(p)
        _acknowledgedMissingSourceCount.value = p.missingSourceAcknowledged.toInt()
        _transferProgress.value = transferPermilleOf(p.current)?.let { it / 1000f }
        _waitReasonNotice.value = fgsBlockWaitNoticeRes(p)
        _cancelRemainingCount.value = cancelRemainingRowCount(p, pairingLostState.value.value)
        _skippedCount.value = skippedRowCount(p)
        // UI-09 / UI-16：N 是范围内 MediaStore 实时计数，M 是同范围的已确认、原图还在的 order 数。
        _triplet.value = flowTripletOf(p, lastBucketIds)
    }

    private companion object {
        const val RUNTIME_RETRY_MS = 2_000L
        const val UI_DEBOUNCE_MS = 150L
        const val REMAINING_MIN_INTERVAL_MS = 2_000L
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
