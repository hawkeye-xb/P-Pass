// REBUILD-04 → ARCH-13 (#417) → ARCH-14 (#418) → #413 W5: Home status/actions are projected from the engine view + order table.
//
// 所有裁决都在 FlowUiProjection.kt 的纯函数里（JVM 可测）；这里只负责取事实、把结果放进 Compose State。
// 两类事实分开刷新（#418 的节流教训）：
//  - 引擎视图 [EngineView]（状态 / 待办 / 当前这一张）每次变化都重投影，但只 `copy(view = …)`，不读库；
//  - 账目（m、FAILED、已跳过、源已删）只在 order 写入（revision）或 MediaStore 变化时重读。
// 用户操作（暂停 / 继续 / 取消剩余 / 恢复已跳过）全部经 [EngineGateway]，那是与 W1 引擎的唯一接线点。
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.backup.flow.AndroidFlowRuntime
import com.hawkeyexb.ppass.backup.flow.EngineView
import com.hawkeyexb.ppass.backup.flow.FlowCommand
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.FlowProjection
import com.hawkeyexb.ppass.backup.flow.GlobalState
import com.hawkeyexb.ppass.backup.flow.MissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.PairingEpoch
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.RemainingSnapshot
import com.hawkeyexb.ppass.backup.flow.acknowledgeFlowMissingSource
import com.hawkeyexb.ppass.backup.flow.backupUiStateOf
import com.hawkeyexb.ppass.backup.flow.cancelRemainingRowCount
import com.hawkeyexb.ppass.backup.flow.desktopLowSpaceWarning
import com.hawkeyexb.ppass.backup.flow.flowCommandOf
import com.hawkeyexb.ppass.backup.flow.flowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.flowMissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.supplementEngineView
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.flow.retryFailedFlow
import com.hawkeyexb.ppass.backup.flow.flowTripletOf
import com.hawkeyexb.ppass.backup.flow.runtimeFor
import com.hawkeyexb.ppass.backup.flow.skippedRowCount
import com.hawkeyexb.ppass.backup.flow.transferPermilleOf
import com.hawkeyexb.ppass.backup.flow.waitReasonTextRes
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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.stateIn
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

    /** #418：设置页「取消剩余 N 张」那一行的 N。null = 不渲染这一行（只在已暂停 / 等待中出现）。 */
    private val _cancelRemainingCount = mutableStateOf<Long?>(null)
    val cancelRemainingCount: State<Long?> get() = _cancelRemainingCount

    /** #418：设置卡「已跳过的照片 N 张」的 N（SKIPPED_BY_USER）。null = 不渲染这一行。 */
    private val _skippedCount = mutableStateOf<Long?>(null)
    val skippedCount: State<Long?> get() = _skippedCount

    /**
     * #413：确认框的快照（弹框那一刻的边界 + 张数）。确认时把**同一个**快照交回引擎；null = 没有确认框。
     */
    private var cancelSnapshot: RemainingSnapshot? = null
    private val _cancelConfirmCount = mutableStateOf<Int?>(null)
    val cancelConfirmCount: State<Int?> get() = _cancelConfirmCount

    /** 等待中的那句人话（每个等待原因一句，#413 §4）。null = 不在等 / 不在状态行说。 */
    private val _waitReasonNotice = mutableStateOf<Int?>(null)
    val waitReasonNotice: State<Int?> get() = _waitReasonNotice

    /** #413 §7：桌面剩余空间不足 5 GiB 的预警。 */
    private val _desktopLowSpace = mutableStateOf(false)
    val desktopLowSpace: State<Boolean> get() = _desktopLowSpace

    /** #418 交接：完整投影（引擎视图 + 账目）。 */
    private val _projection = mutableStateOf<FlowProjection?>(null)
    val projection: State<FlowProjection?> get() = _projection

    private val mediaObserver: ContentObserver
    private val refreshPending = AtomicBoolean(false)
    @Volatile private var inScopeTotal: Long? = null
    @Volatile private var gateway: EngineGateway? = null
    private var lastBucketIds: Set<Long>? = null

    init {
        scope.launch {
            repairEpochIfNeeded()
            refresh(recount = true)
        }
        // 订阅取代轮询（MOB-88 的思路保留）：引擎视图变化只换视图；order 写入（revision）才重读账目。
        scope.launch { subscribe() }
        mediaObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                gateway?.onMediaChanged()
                scheduleRefresh(recount = true)
            }
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
        val g = engineGatewayFor(runtime).also { gateway = it }
        refresh(recount = false)
        scope.launch { g.revision.debounce(UI_DEBOUNCE_MS).collect { refresh(recount = false) } }
        g.view.collect { view -> _projection.value?.let { publish(it.copy(view = view)) } }
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
        gateway?.close()
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
        val p = _projection.value
        when (p?.let(::flowCommandOf) ?: FlowCommand.Wake) {
            FlowCommand.Pause -> gateway?.pause()
            FlowCommand.Continue -> gateway?.resume()
            FlowCommand.Retry -> retryFailedFlow(context)
            FlowCommand.Wake -> requestFlowWake(context, TriggerReason.MANUAL)
        }
    }

    /**
     * 点「取消剩余 N 张」：向引擎要一份快照（边界 + 张数），N > 0 才弹确认框（框里写明 N）。
     * 算出来是 0（这期间都传完了）就只把那一行收起来。
     */
    fun requestCancelRemaining() {
        if (_commandPending.value) return
        val g = gateway ?: return
        _commandPending.value = true
        scope.launch {
            try {
                val snapshot = withContext(Dispatchers.IO) { runCatching { g.remainingSnapshot() }.getOrNull() } ?: return@launch
                cancelSnapshot = snapshot.takeIf { it.count > 0 }
                _cancelConfirmCount.value = cancelSnapshot?.count
            } finally {
                _commandPending.value = false
            }
        }
    }

    /** 「已跳过的照片 · 点击恢复」：从跳过名单移除，待办现算自然包含（#413 §5）。 */
    fun restoreSkipped() = command { gateway?.restoreSkipped() }

    fun dismissCancelRemaining() {
        cancelSnapshot = null
        _cancelConfirmCount.value = null
    }

    /**
     * 确认「取消剩余 N 张」：把弹框那一刻的快照原样交回引擎（边界之后新拍的照片不动），之后回到空闲（#413 §5）。
     */
    fun confirmCancelRemaining() {
        val snapshot = cancelSnapshot ?: return
        cancelSnapshot = null
        _cancelConfirmCount.value = null
        command { gateway?.cancelRemaining(snapshot) }
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

    /** 账目（读库）。引擎视图取最新值带上。 */
    private fun currentFacts(recount: Boolean): FlowProjection? {
        val g = gateway ?: return null
        val bucketIds = scopeStore.selectedBucketIds()
        if (recount || inScopeTotal == null) {
            inScopeTotal = try {
                bucketIds?.let { MediaScanner(context.contentResolver).countAll(it) }
            } catch (_: Throwable) {
                null
            }
        }
        return g.facts(bucketIds, inScopeTotal).copy(view = g.view.value)
    }

    private suspend fun refresh(recount: Boolean) {
        pairingLostState.syncFrom(flowDeliveryPairingLoss, PairingEpoch(pairing.pairingEpoch))
        val bucketIds = withContext(Dispatchers.IO) { scopeStore.selectedBucketIds() }
        val p = withContext(Dispatchers.IO) { runCatching { currentFacts(recount) }.getOrNull() } ?: return
        lastBucketIds = bucketIds
        publish(p)
    }

    /** 投影 → 各个 State。全部裁决在 FlowUiProjection.kt 的纯函数里。 */
    private fun publish(p: FlowProjection) {
        _projection.value = p
        _state.value = backupUiStateOf(p)
        _missingSourceNotice.value = flowMissingSourceNotice(p)
        _acknowledgedMissingSourceCount.value = p.missingSourceAcknowledged.toInt()
        _transferProgress.value = transferPermilleOf(p.current)?.let { it / 1000f }
        _waitReasonNotice.value = waitReasonTextRes(p)
        _desktopLowSpace.value = desktopLowSpaceWarning(p)
        _cancelRemainingCount.value = cancelRemainingRowCount(p, pairingLostState.value.value)
        _skippedCount.value = skippedRowCount(p)
        // UI-09 / UI-16：N 是范围内 MediaStore 实时计数，M 是同范围的已确认、原图还在的 order 数。
        _triplet.value = flowTripletOf(p, lastBucketIds)
    }

    private companion object {
        const val RUNTIME_RETRY_MS = 2_000L
        const val UI_DEBOUNCE_MS = 150L
    }
}

// ================================================================ W1 接线点：EngineGateway
//
// UI 与引擎之间只有这一层：视图读 [com.hawkeyexb.ppass.backup.flow.FlowEngine.view]，用户操作直接转发引擎的
// pause / resume / remainingSnapshot / cancelRemaining(snapshot) / restoreSkipped（契约 §3）。
// 唯一的补齐：W1-M1 的视图还没填待办与本轮已完成、检查阶段仍报 IDLE——见 [supplementEngineView]。

/** 首页读引擎、发用户操作的唯一接口。 */
internal interface EngineGateway {
    /** 引擎视图。null = 还不知道——首个待办计数出来之前不发 `pending = 0`，否则英雄区会先说「照片都存好了」。 */
    val view: StateFlow<EngineView?>

    /** order 写入计数：账目（m、FAILED、已跳过、源已删）据此重读。 */
    val revision: Flow<Long>

    /** 账目（读 order 表与 FlowControl），不含引擎视图。 */
    fun facts(bucketIds: Set<Long>?, inScopeTotal: Long?): FlowProjection

    /** 只在 RUNNING 有效。 */
    suspend fun pause()

    /** 只在 PAUSED 有效。 */
    suspend fun resume()

    /** 弹框那一刻的边界 + 张数。 */
    suspend fun remainingSnapshot(): RemainingSnapshot

    /** 在 PAUSED / WAITING 有效：快照里的待办全部跳过、清除暂停标志 → IDLE。 */
    suspend fun cancelRemaining(snapshot: RemainingSnapshot)

    suspend fun restoreSkipped()

    /** MediaStore 变了（待办可能变了）。 */
    fun onMediaChanged()

    fun close()
}

internal fun engineGatewayFor(runtime: AndroidFlowRuntime): EngineGateway = EngineViewGateway(runtime)

/**
 * 转发 W1 引擎。待办 = `remainingSnapshot().count`（全量扫描，所以每次算完歇 [RECOUNT_MIN_INTERVAL_MS]），
 * 在 order 写入与 MediaStore 变化时重算；「本轮已完成」按「备份中待办的减少量」近似，回到空闲清零。
 * W1 在视图里填好这两样之后，[view] 直接用 `engine.view`，[pending] / [round] 删掉。
 */
private class EngineViewGateway(private val runtime: AndroidFlowRuntime) : EngineGateway {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val engine get() = runtime.engine
    private val pending = MutableStateFlow<Int?>(null)
    private val recounts = Channel<Unit>(Channel.CONFLATED)
    private val round = RoundCounter()

    override val view: StateFlow<EngineView?> =
        combine(engine.view, engine.display, pending) { v, status, n ->
            n?.let {
                val filled = supplementEngineView(v, status.phase, it, doneThisRound = 0)
                filled.copy(doneThisRound = round.next(filled.state, it))
            }
        }.stateIn(scope, SharingStarted.Eagerly, null)

    override val revision: Flow<Long> = engine.revision

    init {
        scope.launch { engine.revision.collect { recounts.trySend(Unit) } }
        scope.launch {
            for (request in recounts) {
                runCatching { engine.remainingSnapshot().count }.getOrNull()?.let { pending.value = it }
                delay(RECOUNT_MIN_INTERVAL_MS)
            }
        }
    }

    override fun facts(bucketIds: Set<Long>?, inScopeTotal: Long?): FlowProjection =
        FlowProjection.facts(runtime.store, runtime.control, bucketIds, inScopeTotal, view = null)

    override suspend fun pause() {
        engine.pause().await()
    }

    override suspend fun resume() {
        engine.resume().await()
    }

    override suspend fun remainingSnapshot(): RemainingSnapshot = engine.remainingSnapshot()

    override suspend fun cancelRemaining(snapshot: RemainingSnapshot) {
        engine.cancelRemaining(snapshot).await()
        recounts.trySend(Unit)
    }

    override suspend fun restoreSkipped() {
        engine.restoreSkipped().await()
        recounts.trySend(Unit)
    }

    override fun onMediaChanged() {
        recounts.trySend(Unit)
    }

    override fun close() = scope.cancel()

    private companion object {
        const val RECOUNT_MIN_INTERVAL_MS = 2_000L
    }
}

/** 「本轮已完成」的近似（W1 填好视图后删）：备份中待办每减少 1 记 1；新增的待办不抵扣；回到空闲清零。 */
internal class RoundCounter {
    private var done = 0
    private var lastPending: Int? = null

    fun next(state: GlobalState, pending: Int): Int {
        when (state) {
            GlobalState.IDLE -> {
                done = 0
                lastPending = null
            }
            GlobalState.RUNNING -> {
                lastPending?.let { if (pending < it) done += it - pending }
                lastPending = pending
            }
            // 暂停 / 等待中仍是同一轮：只记下基线，不计完成。
            GlobalState.PAUSED, GlobalState.WAITING -> lastPending = pending
        }
        return done
    }
}
// ================================================================ W1 接线点结束

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
