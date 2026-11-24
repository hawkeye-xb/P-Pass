package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.flow.AndroidFlowRuntime
import com.hawkeyexb.ppass.backup.flow.EngineView
import com.hawkeyexb.ppass.backup.flow.FlowCommand
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.FlowProjection
import com.hawkeyexb.ppass.backup.flow.MissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.PairingId
import com.hawkeyexb.ppass.backup.flow.RemainingSnapshot
import com.hawkeyexb.ppass.backup.flow.TransferMark
import com.hawkeyexb.ppass.backup.flow.TransferRow
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.acknowledgeFlowMissingSource
import com.hawkeyexb.ppass.backup.flow.advanceTransferMark
import com.hawkeyexb.ppass.backup.flow.backupUiStateOf
import com.hawkeyexb.ppass.backup.flow.cancelRemainingRowCount
import com.hawkeyexb.ppass.backup.flow.desktopLowSpaceWarning
import com.hawkeyexb.ppass.backup.flow.flowCommandOf
import com.hawkeyexb.ppass.backup.flow.flowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.flowMissingSourceNotice
import com.hawkeyexb.ppass.backup.flow.flowTripletOf
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.flow.runtimeFor
import com.hawkeyexb.ppass.backup.flow.skippedRowCount
import com.hawkeyexb.ppass.backup.flow.transferPermilleOf
import com.hawkeyexb.ppass.backup.flow.transferRowOf
import com.hawkeyexb.ppass.backup.flow.visibleEngineView
import com.hawkeyexb.ppass.backup.flow.waitReasonTextRes
import com.hawkeyexb.ppass.backup.folder.FolderAccess
import com.hawkeyexb.ppass.backup.folder.isFolderId
import com.hawkeyexb.ppass.isAppVisible
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.ConnectionState
import com.hawkeyexb.ppass.ui.TimelineSubscriptionHolder
import com.hawkeyexb.ppass.ui.selectedExistingCount
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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

    private val _commandPending = mutableStateOf(false)
    val commandPending: State<Boolean> get() = _commandPending

    private val _transferProgress = mutableStateOf<Float?>(null)
    val transferProgress: State<Float?> get() = _transferProgress

    private val _transferRow = mutableStateOf<TransferRow?>(null)
    val transferRow: State<TransferRow?> get() = _transferRow
    private var transferMark: TransferMark? = null
    private var transferTicker: Job? = null

    private val _cancelRemainingCount = mutableStateOf<Long?>(null)
    val cancelRemainingCount: State<Long?> get() = _cancelRemainingCount

    private val _skippedCount = mutableStateOf<Long?>(null)
    val skippedCount: State<Long?> get() = _skippedCount

    private var cancelSnapshot: RemainingSnapshot? = null
    private val _cancelConfirmCount = mutableStateOf<Int?>(null)
    val cancelConfirmCount: State<Int?> get() = _cancelConfirmCount

    private val _waitReasonNotice = mutableStateOf<Int?>(null)
    val waitReasonNotice: State<Int?> get() = _waitReasonNotice

    private val _desktopLowSpace = mutableStateOf(false)
    val desktopLowSpace: State<Boolean> get() = _desktopLowSpace

    private val _countsReadable = mutableStateOf(true)
    val countsReadable: State<Boolean> get() = _countsReadable
    private val _scopeSaved = mutableStateOf(true)
    val scopeSaved: State<Boolean> get() = _scopeSaved

    private val _noSources = mutableStateOf(false)
    val noSources: State<Boolean> get() = _noSources

    private val _notices = MutableSharedFlow<Int>(extraBufferCapacity = 4)
    val notices: SharedFlow<Int> get() = _notices

    private val _projection = mutableStateOf<FlowProjection?>(null)
    val projection: State<FlowProjection?> get() = _projection

    private val mediaObserver: ContentObserver
    private val refreshPending = AtomicBoolean(false)
    @Volatile private var inScopeTotal: Long? = null
    @Volatile private var existingBuckets: Set<Long>? = null
    @Volatile private var folderBuckets: Set<Long> = emptySet()
    @Volatile private var gateway: EngineGateway? = null
    private var lastBucketIds: Set<Long>? = null
    private var lastNoAlbums = false
    private var countsUnreadableLogged = false
    private val accessGate = MediaAccessRecountGate()

    init {
        scope.launch {
            refresh(recount = true)
        }
        scope.launch { subscribe() }
        scope.launch {
            flowDeliveryPairingLoss.changes.collect {
                pairingLostState.syncFrom(flowDeliveryPairingLoss, PairingId(pairing.pairingId))
            }
        }
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

    internal fun connectionState(
        timeline: TimelineSubscriptionHolder,
        daysUnreachable: Int? = null,
    ): ConnectionState = timeline.connectionState(
        pairingLost = pairingLostState.value.value,
        daysUnreachable = daysUnreachable,
    )

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
        g.view.collect { view ->
            pairingLostState.syncFrom(flowDeliveryPairingLoss, PairingId(pairing.pairingId))
            accessGate.onEngineView()
            _projection.value?.let { publish(it.copy(view = view)) }
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

    // Android 授权变更不会触发 MediaStore ContentObserver，必须显式清空计数缓存并重算
    fun onMediaAccess(access: MediaAccess) {
        if (!accessGate.onAccess(access)) return
        inScopeTotal = null
        gateway?.onMediaChanged()
        scope.launch { refresh(recount = true) }
    }

    fun onResume() = scheduleRefresh(recount = false)

    fun dispose() {
        runCatching { context.contentResolver.unregisterContentObserver(mediaObserver) }
        gateway?.close()
        scope.cancel()
    }

    fun acknowledgeMissingSourceNotice() {
        if (_missingSourceNotice.value == null) return
        command("acknowledge-missing-source") { acknowledgeFlowMissingSource(context) }
    }

    private fun command(what: String, block: suspend () -> Unit) {
        if (_commandPending.value) return
        _commandPending.value = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) { attemptUserCommand(what) { block() } }
                    .onFailure { _notices.tryEmit(R.string.command_failed) }
            } finally {
                _commandPending.value = false
                refresh(recount = false)
            }
        }
    }

    fun backupNow() {
        val c = _projection.value?.let(::flowCommandOf) ?: FlowCommand.Wake
        command(c.name.lowercase()) {
            dispatchFlowCommand(c, gateway) { requestFlowWake(context, TriggerReason.MANUAL) }
        }
    }

    fun requestCancelRemaining() {
        if (_commandPending.value) return
        val g = gateway ?: return
        _commandPending.value = true
        scope.launch {
            try {
                val snapshot = withContext(Dispatchers.IO) { attemptUserCommand("remaining-snapshot") { g.remainingSnapshot() } }
                    .getOrElse {
                        _notices.tryEmit(R.string.command_failed)
                        return@launch
                    }
                cancelSnapshot = snapshot.takeIf { it.count > 0 }
                _cancelConfirmCount.value = cancelSnapshot?.count
            } finally {
                _commandPending.value = false
            }
        }
    }

    fun restoreSkipped() = command("restore-skipped") { gateway?.restoreSkipped() }

    fun dismissCancelRemaining() {
        cancelSnapshot = null
        _cancelConfirmCount.value = null
    }

    fun confirmCancelRemaining() {
        val snapshot = cancelSnapshot ?: return
        cancelSnapshot = null
        _cancelConfirmCount.value = null
        command("cancel-remaining") { gateway?.cancelRemaining(snapshot) }
    }

    private fun currentFacts(recount: Boolean, bucketIds: Set<Long>?, sinceSec: Long?): FlowProjection? {
        val g = gateway ?: return null
        folderBuckets = try {
            FolderAccess.registry(context).allRecords().mapTo(HashSet()) { it.bucketId }
        } catch (_: Throwable) {
            emptySet()
        }
        if (recount || inScopeTotal == null) {
            inScopeTotal = try {
                bucketIds?.let { MediaScanner(context.contentResolver).countAll(it, sinceSec) }
            } catch (_: Throwable) {
                null
            }
            existingBuckets = try {
                MediaScanner(context.contentResolver).listBuckets().map { it.id }.toSet()
            } catch (_: Throwable) {
                null
            }
        }
        val view = accessGate.visible(g.view.value)
        val total = inScopeTotal
        val p = factsOrUnreadable(
            total, view,
            onUnreadable = { e -> if (!countsUnreadableLogged) PLog.w(TAG, "home-facts: order counts unreadable", e) },
        ) { g.facts(bucketIds, total, sinceSec) }
        countsUnreadableLogged = !p.countsReadable
        return p
    }

    private suspend fun refresh(recount: Boolean) {
        pairingLostState.syncFrom(flowDeliveryPairingLoss, PairingId(pairing.pairingId))
        val (bucketIds, knownSources) = withContext(Dispatchers.IO) {
            (scopeStore.readScope() as? ScopeRead.Saved)?.ids to scopeStore.knownBucketIds()
        }
        val sinceSec = withContext(Dispatchers.IO) { scopeStore.sinceSec() }
        val p = withContext(Dispatchers.IO) { currentFacts(recount, bucketIds, sinceSec) } ?: return
        lastBucketIds = bucketIds
        lastNoAlbums = noAlbumsOf(bucketIds, existingBuckets, folderBuckets, knownSources)
        publish(p)
    }

    private fun publish(p: FlowProjection) {
        _projection.value = p
        _state.value = backupUiStateOf(p, noAlbums = lastNoAlbums)
        _countsReadable.value = p.countsReadable
        _scopeSaved.value = heroScopeSavedOf(lastNoAlbums)
        _noSources.value = lastNoAlbums
        _missingSourceNotice.value = flowMissingSourceNotice(p)
        _acknowledgedMissingSourceCount.value = p.missingSourceAcknowledged.toInt()
        _transferProgress.value = transferPermilleOf(p.current)?.let { it / 1000f }
        publishTransferRow(p)
        _waitReasonNotice.value = waitReasonTextRes(p)
        _desktopLowSpace.value = desktopLowSpaceWarning(p)
        _cancelRemainingCount.value = cancelRemainingRowCount(p, pairingLostState.value.value)
        _skippedCount.value = skippedRowCount(p)
        _triplet.value = flowTripletOf(p, lastBucketIds)
    }

    private fun publishTransferRow(p: FlowProjection?) {
        val current = p?.current
        val now = monotonicNowMs()
        transferMark = advanceTransferMark(transferMark, current, now)
        _transferRow.value = transferRowOf(current, transferMark, now)
        if (current == null) {
            transferTicker?.cancel()
            transferTicker = null
        } else if (transferTicker?.isActive != true) {
            transferTicker = scope.launch {
                while (true) {
                    delay(TRANSFER_TICK_MS)
                    publishTransferRow(_projection.value)
                }
            }
        }
    }

    private companion object {
        const val TAG = "PPassHome"
        const val RUNTIME_RETRY_MS = 2_000L
        const val TRANSFER_TICK_MS = 1_000L

        fun monotonicNowMs(): Long = System.nanoTime() / 1_000_000
        const val UI_DEBOUNCE_MS = 150L
    }
}

internal class MediaAccessRecountGate {
    private var last: MediaAccess? = null
    @Volatile private var holdView = false

    fun onAccess(now: MediaAccess): Boolean {
        val changed = last != null && last != now
        last = now
        if (changed) holdView = true
        return changed
    }

    fun onEngineView() {
        holdView = false
    }

    fun <V> visible(view: V?): V? = if (holdView) null else view
}

internal interface EngineGateway {
    val view: StateFlow<EngineView?>
    val revision: Flow<Long>

    fun facts(bucketIds: Set<Long>?, inScopeTotal: Long?, sinceSec: Long?): FlowProjection

    suspend fun pause()
    suspend fun resume()
    suspend fun remainingSnapshot(): RemainingSnapshot
    suspend fun cancelRemaining(snapshot: RemainingSnapshot)
    suspend fun restoreSkipped()
    suspend fun retryFailed()
    fun onMediaChanged()
    fun close()
}

internal suspend fun dispatchFlowCommand(
    command: FlowCommand,
    gateway: EngineGateway?,
    onWake: suspend () -> Unit,
) {
    when (command) {
        FlowCommand.Pause -> gateway?.pause()
        FlowCommand.Continue -> gateway?.resume()
        FlowCommand.Retry -> gateway?.retryFailed()
        FlowCommand.Wake -> onWake()
    }
}

internal fun engineGatewayFor(runtime: AndroidFlowRuntime): EngineGateway = EngineViewGateway(runtime)

private class EngineViewGateway(private val runtime: AndroidFlowRuntime) : EngineGateway {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val engine get() = runtime.engine

    override val view: StateFlow<EngineView?> =
        combine(engine.view, engine.pendingKnown, ::visibleEngineView)
            .stateIn(scope, SharingStarted.Eagerly, null)

    override val revision: Flow<Long> = engine.revision

    override fun facts(bucketIds: Set<Long>?, inScopeTotal: Long?, sinceSec: Long?): FlowProjection =
        FlowProjection.facts(runtime.store, runtime.control, bucketIds, inScopeTotal, view = null, sinceSec = sinceSec, scopeTimeOf = runtime.scopeTimeOf)

    override suspend fun pause() {
        engine.pause().await()
    }

    override suspend fun resume() {
        engine.resume().await()
    }

    override suspend fun remainingSnapshot(): RemainingSnapshot = engine.remainingSnapshot()

    override suspend fun cancelRemaining(snapshot: RemainingSnapshot) {
        engine.cancelRemaining(snapshot).await()
    }

    override suspend fun restoreSkipped() {
        engine.restoreSkipped().await()
    }

    override suspend fun retryFailed() {
        engine.retryFailed().await()
    }

    override fun onMediaChanged() {
        if (isAppVisible()) engine.trigger(TriggerReason.FOREGROUND_MEDIA_CHANGE)
    }

    override fun close() = scope.cancel()
}

internal fun factsOrUnreadable(
    inScopeTotal: Long?,
    view: EngineView?,
    onUnreadable: (Exception) -> Unit,
    read: () -> FlowProjection,
): FlowProjection =
    try {
        read().copy(view = view)
    } catch (e: Exception) {
        onUnreadable(e)
        FlowProjection.unreadable(inScopeTotal, view)
    }

internal fun noAlbumsOf(
    bucketIds: Set<Long>?,
    existing: Set<Long>?,
    folderBuckets: Set<Long> = emptySet(),
    knownBucketIds: Set<Long>? = null,
): Boolean {
    val effective = effectiveBackupScope(
        saved = bucketIds?.let { BackupScope(it, sinceSec = null) },
        knownSourceIds = knownBucketIds,
        existingFolderBuckets = folderBuckets,
        sinceSec = null,
    )?.buckets.orEmpty()
    val albums = selectedExistingCount(effective.filterNot(::isFolderId).toSet(), existing) ?: 0
    val folders = effective.count { isFolderId(it) && it in folderBuckets }
    return albums == 0 && folders == 0
}

internal fun heroScopeSavedOf(noSources: Boolean): Boolean = !noSources

internal suspend fun <T> attemptUserCommand(what: String, op: suspend () -> T): Result<T> =
    try {
        Result.success(op()).also { PLog.i(USER_COMMAND_TAG, "command $what ok") }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        PLog.w(USER_COMMAND_TAG, "command failed ($what)", e)
        Result.failure(e)
    }

private const val USER_COMMAND_TAG = "PPassHome"

internal class HolderPairingLostState {
    private val _value = mutableStateOf(false)
    val value: State<Boolean> get() = _value

    fun markLost() {
        _value.value = true
    }

    fun syncFrom(deliveryLoss: FlowDeliveryPairingLoss, pid: PairingId) {
        if (deliveryLoss.isLost(pid)) markLost()
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
