// REBUILD-04: shared Android runtime for Flow wake, ledger commands, and UI reads.
package com.hawkeyexb.ppass.backup.flow

import android.content.Context
import android.net.Uri
import com.hawkeyexb.ppass.PPassApplication
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.backup.BackupSettings
import com.hawkeyexb.ppass.backup.NotifyOnFailurePrefs
import com.hawkeyexb.ppass.backup.SystemFailureNotifier
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Reads one ordered MediaStore window; it never hashes or contacts Desktop. */
internal class AndroidFlowDiscoveryPort(
    private val resolver: android.content.ContentResolver,
    private val selectedBuckets: () -> Set<Long>?,
) : FlowDiscoveryPort {
    override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage {
        val generation = if (android.os.Build.VERSION.SDK_INT >= 30) {
            android.provider.MediaStore.MediaColumns.GENERATION_MODIFIED
        } else {
            android.provider.MediaStore.MediaColumns.DATE_MODIFIED
        }
        val collection = android.provider.MediaStore.Files.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL)
        val projection = arrayOf(
            android.provider.MediaStore.MediaColumns._ID,
            android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
            android.provider.MediaStore.MediaColumns.MIME_TYPE,
            android.provider.MediaStore.MediaColumns.SIZE,
            generation,
            android.provider.MediaStore.MediaColumns.DATE_MODIFIED,
            android.provider.MediaStore.MediaColumns.BUCKET_ID,
            // DESK-12: the phone's own capture-time fact — carried to
            // Desktop as a fallback for files with no EXIF (screenshots,
            // some video codecs), which otherwise landed under the
            // Flow-delivered file's export moment instead of its real date.
            android.provider.MediaStore.MediaColumns.DATE_TAKEN,
            // 2026-09-15 用户实测：飞书(Lark)等第三方 App 保存的图片既没有
            // EXIF DateTimeOriginal 也没有 DATE_TAKEN（两者都为 null/0）——
            // 手机自己的相册 App 遇到这批素材也拿不到"拍摄时间"，但
            // MediaStore 仍然记得 DATE_ADDED（这个 App 把文件写入相册库的
            // 那一刻，单位是秒不是毫秒）。这是手机上唯一还剩的、比 Desktop
            // 端"daemon 收到文件的时刻"更接近真相的时间信号，缺 DATE_TAKEN
            // 时必须退到它，否则这批素材会被扣上"落地时刻"这个跟内容本身
            // 毫无关系的时间戳（Google 相册等主流相册处理无 EXIF 素材就是
            // 这个优先级，不是我们发明的口径）。
            android.provider.MediaStore.MediaColumns.DATE_ADDED,
        )
        val buckets = selectedBuckets() ?: return DiscoveryPage(emptyList(), cursor)
        if (buckets.isEmpty()) return DiscoveryPage(emptyList(), cursor)
        val selection = buildString {
            append("${android.provider.MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)")
            append(" AND ($generation > ? OR ($generation = ? AND ${android.provider.MediaStore.MediaColumns._ID} > ?))")
            append(" AND ${android.provider.MediaStore.MediaColumns.BUCKET_ID} IN (${buckets.joinToString(",")})")
        }
        val args = arrayOf(
            android.provider.MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            android.provider.MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            cursor.lastGeneration.toString(),
            cursor.lastGeneration.toString(),
            cursor.lastMediaId.toString(),
        )
        val candidates = mutableListOf<DiscoveryCandidate>()
        var next = cursor
        resolver.query(collection, projection, selection, args, "$generation ASC, ${android.provider.MediaStore.MediaColumns._ID} ASC")?.use { rows ->
            val id = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns._ID)
            val name = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DISPLAY_NAME)
            val mime = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.MIME_TYPE)
            val size = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.SIZE)
            val gen = rows.getColumnIndexOrThrow(generation)
            val modified = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATE_MODIFIED)
            val bucket = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.BUCKET_ID)
            val taken = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATE_TAKEN)
            val added = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATE_ADDED)
            while (rows.moveToNext() && candidates.size < DISCOVERY_PAGE_SIZE) {
                val rowId = rows.getLong(id)
                val rowGeneration = rows.getLong(gen)
                candidates += DiscoveryCandidate(
                    sourceRef = Uri.withAppendedPath(collection, rowId.toString()).toString(),
                    sourceVersion = "$rowGeneration:${rows.getLong(modified)}:${rows.getLong(size)}",
                    bucketId = rows.getLong(bucket),
                    fileName = rows.getString(name).orEmpty(),
                    mediaType = rows.getString(mime) ?: "application/octet-stream",
                    captureAtMs = captureAtMsOrDateAdded(rows.getLong(taken), rows.getLong(added)),
                )
                next = DiscoveryCursor(rowGeneration, rowId)
            }
        }
        return DiscoveryPage(candidates, next)
    }

    override fun backfill(request: ScopeBackfillRequest): ScopeBackfillPage {
        if (request.boundary == DiscoveryCursor.INITIAL) {
            return ScopeBackfillPage(emptyList(), request.cursor, complete = true)
        }
        val generation = if (android.os.Build.VERSION.SDK_INT >= 30) {
            android.provider.MediaStore.MediaColumns.GENERATION_MODIFIED
        } else {
            android.provider.MediaStore.MediaColumns.DATE_MODIFIED
        }
        val collection = android.provider.MediaStore.Files.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL)
        val buckets = selectedBuckets() ?: return ScopeBackfillPage(emptyList(), request.cursor, complete = true)
        if (buckets.isEmpty()) return ScopeBackfillPage(emptyList(), request.cursor, complete = true)
        val projection = arrayOf(
            android.provider.MediaStore.MediaColumns._ID,
            android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
            android.provider.MediaStore.MediaColumns.MIME_TYPE,
            android.provider.MediaStore.MediaColumns.SIZE,
            generation,
            android.provider.MediaStore.MediaColumns.DATE_MODIFIED,
            android.provider.MediaStore.MediaColumns.BUCKET_ID,
            android.provider.MediaStore.MediaColumns.DATE_TAKEN,
            android.provider.MediaStore.MediaColumns.DATE_ADDED,
        )
        val selection = buildString {
            append("${android.provider.MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)")
            append(" AND ($generation > ? OR ($generation = ? AND ${android.provider.MediaStore.MediaColumns._ID} > ?))")
            append(" AND ($generation < ? OR ($generation = ? AND ${android.provider.MediaStore.MediaColumns._ID} <= ?))")
            append(" AND ${android.provider.MediaStore.MediaColumns.BUCKET_ID} IN (${buckets.joinToString(",")})")
        }
        val args = arrayOf(
            android.provider.MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            android.provider.MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            request.cursor.lastGeneration.toString(),
            request.cursor.lastGeneration.toString(),
            request.cursor.lastMediaId.toString(),
            request.boundary.lastGeneration.toString(),
            request.boundary.lastGeneration.toString(),
            request.boundary.lastMediaId.toString(),
        )
        val candidates = mutableListOf<DiscoveryCandidate>()
        var next = request.cursor
        var complete = true
        resolver.query(collection, projection, selection, args, "$generation ASC, ${android.provider.MediaStore.MediaColumns._ID} ASC")?.use { rows ->
            val id = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns._ID)
            val name = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DISPLAY_NAME)
            val mime = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.MIME_TYPE)
            val size = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.SIZE)
            val gen = rows.getColumnIndexOrThrow(generation)
            val modified = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATE_MODIFIED)
            val bucket = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.BUCKET_ID)
            val taken = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATE_TAKEN)
            val added = rows.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATE_ADDED)
            while (rows.moveToNext()) {
                if (candidates.size == DISCOVERY_PAGE_SIZE) {
                    complete = false
                    break
                }
                val rowId = rows.getLong(id)
                val rowGeneration = rows.getLong(gen)
                candidates += DiscoveryCandidate(
                    sourceRef = Uri.withAppendedPath(collection, rowId.toString()).toString(),
                    sourceVersion = "$rowGeneration:${rows.getLong(modified)}:${rows.getLong(size)}",
                    bucketId = rows.getLong(bucket),
                    fileName = rows.getString(name).orEmpty(),
                    mediaType = rows.getString(mime) ?: "application/octet-stream",
                    captureAtMs = captureAtMsOrDateAdded(rows.getLong(taken), rows.getLong(added)),
                )
                next = DiscoveryCursor(rowGeneration, rowId)
            }
        }
        return ScopeBackfillPage(candidates, next, complete)
    }

    private companion object { const val DISCOVERY_PAGE_SIZE = 500 }
}

/**
 * MediaStore `DATE_TAKEN` 优先（毫秒，多数相机 App 的真实拍摄时间）；
 * 为 0（列缺失/未知）时退到 `DATE_ADDED`（秒，第三方 App —— 实测飞书 —— 保存
 * 图片时唯一还留着的时间信号，见调用处注释）。两者都拿不到才是真的 0，
 * 交给 Desktop 端的 EXIF/mtime 兜底链继续处理。
 */
private fun captureAtMsOrDateAdded(dateTakenMs: Long, dateAddedSec: Long): Long {
    if (dateTakenMs > 0) return dateTakenMs
    return if (dateAddedSec > 0) dateAddedSec * 1000 else 0L
}

/**
 * MOB-76: the live delivery gate —「仅 Wi-Fi 时备份」× current network.
 * This answers 「往哪条网络发」 and is deliberately separate from the
 * WorkManager scheduling constraints in TriggerPolicy (「什么时候允许跑」):
 * even a MANUAL-tier worker that the scheduler let run on cellular must not
 * push a delivery onto a metered network while the switch is on (09-12 OPPO
 * real device, card: 任何触发路径都不例外).
 */
internal fun flowConstraintsSatisfied(context: Context): Boolean {
    val settings = BackupSettings(context.filesDir).load()
    return !settings.wifiOnly || isOnUnmetered(context)
}

/** 是否在不计流量网络（Wi-Fi）上——从 MainActivity 的私有实现上移共用。 */
internal fun isOnUnmetered(context: Context): Boolean {
    val cm = context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE)
        as? android.net.ConnectivityManager ?: return false
    val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
    return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
}

/** Framework wake path. The Worker invokes [runFlowWake] synchronously. */
internal fun requestFlowWake(
    context: Context,
    constraintsSatisfied: Boolean = flowConstraintsSatisfied(context),
) {
    val app = context.applicationContext
    thread(name = "ppass-flow-wake") { runFlowWake(app, constraintsSatisfied) }
}

/** Scope changes only record durable Flow work; the scheduled wake enforces runtime constraints. */
internal fun requestFlowScopeBackfill(context: Context) {
    runtimeFor(context.applicationContext)?.writer?.dispatch(FlowAction.ScopeBackfill)
}

/**
 * A scope save is an explicit foreground action, not just a future WorkManager
 * eligibility change.  Keep the durable backfill request and its first run in
 * one background critical section so an older KEEP work request cannot delay it.
 */
internal fun requestFlowScopeBackfillAndWake(context: Context, constraintsSatisfied: Boolean) {
    val app = context.applicationContext
    thread(name = "ppass-flow-scope-wake") {
        runtimeFor(app)?.writer?.dispatch(FlowAction.ScopeBackfillAndWake(constraintsSatisfied))
        flushAuditOutbox(app)
    }
}

internal fun runFlowWake(
    context: Context,
    constraintsSatisfied: Boolean = flowConstraintsSatisfied(context),
) {
    runtimeFor(context.applicationContext)?.writer?.dispatch(FlowAction.Wake(constraintsSatisfied))
    flushAuditOutbox(context)
}

internal fun pauseFlow(context: Context) {
    runtimeFor(context.applicationContext)?.writer?.dispatch(FlowAction.Pause)
    flushAuditOutbox(context)
}

internal fun continueFlow(
    context: Context,
    constraintsSatisfied: Boolean = flowConstraintsSatisfied(context),
) {
    runtimeFor(context.applicationContext)?.writer?.dispatch(FlowAction.Continue(constraintsSatisfied))
    flushAuditOutbox(context)
}

internal fun retryFailedFlow(context: Context) {
    runtimeFor(context.applicationContext)?.writer?.dispatch(FlowAction.RetryFailed)
    flushAuditOutbox(context)
}

internal fun cancelCurrentFlowRound(context: Context) {
    runtimeFor(context.applicationContext)?.writer?.dispatch(FlowAction.CancelCurrentRound(UUID.randomUUID().toString()))
    flushAuditOutbox(context)
}

/** MOB-59: the notice's only action — re-admit every cancelled round's items as QUEUED. */
internal fun restoreAllCancelledFlowRounds(context: Context) {
    runtimeFor(context.applicationContext)?.writer?.dispatch(FlowAction.RestoreAllCancelledRounds)
    flushAuditOutbox(context)
}

/**
 * MOB-88: 账本提交的订阅总线，取代 UI 每 500ms 重读整份 JSON 的轮询。
 *
 * 为什么是进程级而不是挂在运行时上：运行时会随配对/代号变化重建，而 UI
 * 的订阅只想订一次。运行时构造时把自己的提交回调接到这条总线上。
 *
 * 回调在**写者线程**上同步触发，所以实现方必须廉价、不得回头写账本
 * （写了会被写入门禁当场拦住）。
 */
private val flowLedgerListeners =
    java.util.concurrent.CopyOnWriteArrayList<(DiscoveryLedgerSnapshot) -> Unit>()

/** 返回取消订阅的句柄。 */
internal fun observeFlowLedger(listener: (DiscoveryLedgerSnapshot) -> Unit): () -> Unit {
    flowLedgerListeners += listener
    return { flowLedgerListeners -= listener }
}

internal fun flowLedgerSnapshot(context: Context): DiscoveryLedgerSnapshot {
    val pairing = PairingStore(context.filesDir).load() ?: return DiscoveryLedgerSnapshot()
    if (pairing.pairingEpoch.isBlank()) return DiscoveryLedgerSnapshot()
    val epoch = PairingEpoch(pairing.pairingEpoch)
    val key = pairing.daemonNodeId
    val liveLedger = synchronized(flowRuntimeLock) {
        flowRuntimes[key]?.takeIf { it.epoch == epoch }?.ledger
    }
    return liveLedger?.load()
        ?: DiscoveryLedgerStore(File(context.filesDir, "flow-state/$key")).load()
}

/**
 * Unpair/rejoin is a lifetime boundary: no old native provider, durable Flow
 * ledger, or in-memory runtime may survive and contaminate a new pairing.
 * This must run off the UI thread because native shutdown and filesystem
 * cleanup can block. */
internal fun clearFlowRuntime(context: Context, daemonNodeId: String) {
    synchronized(flowRuntimeLock) {
        flowRuntimes.remove(daemonNodeId)?.nativeProvider?.close()
    }
    File(context.filesDir, "flow-state/$daemonNodeId").deleteRecursively()
}

private data class AndroidFlowRuntime(
    val epoch: PairingEpoch,
    val ledger: DiscoveryLedgerStore,
    val runner: FlowRunner,
    val nativeProvider: AndroidNativeIrohBlobsProvider,
    val auditDispatcher: AuditOutboxDispatcher,
    val auditScope: CoroutineScope,
    // MOB-88: 这个 epoch 下账本的唯一写入者。
    val writer: FlowWriter,
    // 起飞（整文件哈希 + 原生注册 + offer）在这上面跑，不占写者线程。
    val effects: java.util.concurrent.ExecutorService,
) {
    fun shutdown() {
        writer.shutdown()
        effects.shutdownNow()
    }
}

/**
 * MOB-88 的 reducer：把一条已发生的事实变成新的账本状态。
 *
 * 只在写者线程上执行，所以这里面的每一步都不需要考虑并发——「读账本、
 * 判断、写回」这种读-改-写在这条线程上天然原子，这正是改造要换掉那把
 * 靠自觉去拿的锁所换来的东西。
 */
private fun AndroidFlowRuntime.reduce(context: Context, action: FlowAction) {
    when (action) {
        FlowAction.ReconcileProcessStart -> runner.reconcileProcessStart()
        FlowAction.MigrateCompletedAt -> ledger.migrateMissingCompletedAt()
        is FlowAction.EnsurePairingEpoch -> PairingEpochController(ledger).ensureCurrentEpoch(action.epoch)
        is FlowAction.Wake -> {
            runner.requestDiscovery()
            runner.run(action.constraintsSatisfied)
        }
        FlowAction.ScopeBackfill -> runner.requestScopeBackfill()
        is FlowAction.ScopeBackfillAndWake -> {
            runner.requestScopeBackfill()
            runner.run(action.constraintsSatisfied)
        }
        FlowAction.Pause -> runner.pause()
        is FlowAction.Continue -> runner.continueFlow(action.constraintsSatisfied)
        FlowAction.RetryFailed -> runner.retryFailedDeliveries()
        is FlowAction.CancelCurrentRound -> runner.cancelCurrentRound(action.roundId)
        FlowAction.RestoreAllCancelledRounds -> runner.restoreAllCancelledRounds()
        FlowAction.SkipMissingSource -> runner.skipMissingSource()
        FlowAction.RecordPermanentFailure -> runner.recordPermanentFailure()
        is FlowAction.AcceptReceipt -> runner.acceptCompletionReceipt(action.receipt)
        is FlowAction.RecordContentHash -> ledger.update { snapshot -> snapshot.withContentHash(action.item) }
        is FlowAction.AcknowledgeAuditEvents -> ledger.acknowledgeAuditEvents(action.eventIds)
    }
    // NET-12 的后置钩子原本挂在每个入口后面的 flushAuditOutbox 上；状态
    // 变更收口到这里之后，挂在这一处就没有任何调用点能忘。
    FlowTransferForeground.sync(context, ledger.load())
}

/** AUDIT-01: best-effort drain of the ledger's durable audit outbox after
 *  every trigger. Every other Flow trigger already serializes state
 *  mutation through [flowTriggerLock] synchronously; the network hop to
 *  the daemon must not block that path, so this fires on its own
 *  coroutine and simply retries from the next trigger on any failure.
 *
 *  NET-12: also the single postcondition hook for the transfer foreground
 *  service — every ledger-mutating trigger (wake/pause/continue/retry/
 *  cancel/restore/receipt/failure) already reaches this exact point, so
 *  syncing the service here means no call site can forget it. This part
 *  is synchronous and cheap (ContextCompat.startForegroundService /
 *  stopService are non-blocking Binder calls) — it must not wait on the
 *  audit network hop above. */
private fun flushAuditOutbox(context: Context) {
    runtimeFor(context.applicationContext)?.let { runtime ->
        FlowTransferForeground.sync(context, runtime.ledger.load())
        runtime.auditScope.launch { runtime.auditDispatcher.flush() }
    }
}

private fun runtimeFor(context: Context): AndroidFlowRuntime? {
    val app = context.applicationContext as PPassApplication
    val pairing = PairingStore(context.filesDir).load() ?: return null
    if (pairing.pairingEpoch.isBlank()) return null
    val epoch = PairingEpoch(pairing.pairingEpoch)
    val key = pairing.daemonNodeId
    synchronized(flowRuntimeLock) {
        flowRuntimes[key]?.takeIf { it.epoch == epoch }?.let { return it }
    }
    // MOB-88: 构造段做 single-flight。改造前这里没有互斥——两个线程同时
    // 为同一个 key 构造，会各建一套 FlowRunner、各跑一次
    // reconcileProcessStart()，写的是**同一份磁盘账本**（本卡的原始范围）。
    // 用独立的锁而不是 flowRuntimeLock：原生 open 要几秒，不能挡住读取
    // 运行时引用的人（MOB-62 的结论，此处保留）。
    synchronized(flowConstructionLock) {
        synchronized(flowRuntimeLock) {
            flowRuntimes[key]?.takeIf { it.epoch == epoch }?.let { return it }
        }
        return buildRuntime(context, app, epoch, key)
    }
}

private fun buildRuntime(
    context: Context,
    app: PPassApplication,
    epoch: PairingEpoch,
    key: String,
): AndroidFlowRuntime? {
    // 先起写者线程：账本的写入门禁要拿它的引用，而账本要先于 runner 构造。
    val writer = FlowWriter.start("ppass-flow-writer")
    val effects = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
        thread(start = false, name = "ppass-flow-effects", block = { runnable.run() })
    }
    val ledger = DiscoveryLedgerStore(
        repository = JsonFileFlowLedgerRepository(File(context.filesDir, "flow-state/$key")),
        writeGuard = SingleThreadLedgerWrites(writer.thread),
    )
    lateinit var runner: FlowRunner
    val native = AndroidNativeIrohBlobsProvider.open(context.filesDir)
    val bridge = IrohBlobsProviderBridge(native) { source ->
        try {
            context.contentResolver.openFileDescriptor(Uri.parse(source), "r")
                ?: throw SourceMissingException()
        } catch (failure: FileNotFoundException) {
            throw SourceMissingException(failure)
        }
    }
    val delivery = NativeFlowDeliveryPort(
        ledger = ledger,
        bridge = bridge,
        resolver = context.contentResolver,
        pairing = { PairingStore(context.filesDir).load() },
        identityKey = { IdentityStore(context.filesDir).secretKey() },
        client = app.daemonClient,
        // MOB-88: 这三个原生回调曾经是唯一绕过 flowTriggerLock 的入口
        // （#107：同一队头双发，2026-09-07 三星真机抓到两条 322ms 内不同
        // 线程的独立传输失败）。现在它们和别的入口一样只是投一条事实给
        // 写者——「记得加锁」这件事不存在了，因为没有锁。
        onMissingSource = { writer.dispatch(FlowAction.SkipMissingSource); flushAuditOutbox(context) },
        onPermanentFailure = { writer.dispatch(FlowAction.RecordPermanentFailure); flushAuditOutbox(context) },
        onReceipt = { receipt -> writer.dispatch(FlowAction.AcceptReceipt(receipt)); flushAuditOutbox(context) },
        onPairingEpochRefreshed = { refreshedEpoch ->
            // 桌面端换了身份：旧账全部作废。改造前这个回调整体没有任何
            // 同步，而它触发的是整份清空重置——四条锁外写入里写坏最狠的
            // 一条。pairing.json 是另一份文件、与账本无共享状态，仍在原
            // 线程上保存；账本的重置走 action。
            val pairings = PairingStore(context.filesDir)
            val current = pairings.load()
            if (current != null && current.pairingEpoch != refreshedEpoch.value) {
                pairings.save(current.copy(pairingEpoch = refreshedEpoch.value))
                writer.dispatch(FlowAction.EnsurePairingEpoch(refreshedEpoch))
                requestFlowWake(context.applicationContext)
            }
        },
        recordContentHash = { hashed ->
            // 起飞已经离开写者线程，这里必须投 action 回去，并等它落地：
            // 注册凭据与 offer 都要求哈希已经持久化。
            writer.dispatchAndAwait(FlowAction.RecordContentHash(hashed))
        },
    )
    val tupleCanceller = FlowTupleCancelPort { item ->
        // NET-06: best-effort — the local cancellation state change
        // already happened in the ledger before this fires (卡片原则1:
        // 意图先行，不等回声). A failure here just leaves a stale
        // "active" row in the daemon's ledger for that one tuple,
        // which is a separate cleanup concern (see NET-06 card), not a
        // reason to block or retry the phone's own state transition.
        val currentPairing = PairingStore(context.filesDir).load()
        if (currentPairing != null) {
            CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
                runCatching {
                    app.daemonClient.bind(IdentityStore(context.filesDir).secretKey())
                    app.daemonClient.flowCancelTuple(
                        parsePeerAddrToken(currentPairing.daemonAddrToken),
                        com.hawkeyexb.ppass.proto.FlowTupleRef(
                            queueSequence = item.queueSequence,
                            pairingEpoch = item.pairingEpoch.value,
                            leaseToken = "lease-${item.queueSequence}",
                        ),
                    )
                }
            }
        }
    }
    runner = FlowRunner(
        ledger = ledger,
        discovery = AndroidFlowDiscoveryPort(context.contentResolver) { BackupScopeStore(context).selectedBucketIds() },
        delivery = delivery,
        // MOB-67: re-connect the UX-02 failure notification that REBUILD-04
        // deleted with the legacy worker. Reads NotifyOnFailurePrefs live,
        // so the settings toggle takes effect from the next failure.
        failureNotifier = SystemFailureNotifier(
            context.applicationContext,
            NotifyOnFailurePrefs(context.filesDir),
        ),
        // MOB-76: every event-driven wake (receipt/requeue/retry/
        // cancel-restore) reads the live Wi-Fi gate through this port.
        constraintsProvider = { flowConstraintsSatisfied(context) },
        tupleCanceller = tupleCanceller,
        // MOB-88: 起飞里的整文件哈希（4GB 视频就是读完 4GB + BLAKE3）绝不
        // 能占着状态决策线程——改造前它占的是那把全局锁，见 #134。
        effects = FlowEffectSink { effect -> effects.execute(effect) },
    )
    val auditScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val auditDispatcher = AuditOutboxDispatcher(
        ledger = ledger,
        pairing = { PairingStore(context.filesDir).load() },
        identityKey = { IdentityStore(context.filesDir).secretKey() },
        client = app.daemonClient,
        // MOB-88: 审计确认后删事件——四条锁外写入里触发最频繁的一条。
        acknowledgeEvents = { ids -> writer.dispatch(FlowAction.AcknowledgeAuditEvents(ids)) },
    )
    val candidate = AndroidFlowRuntime(epoch, ledger, runner, native, auditDispatcher, auditScope, writer, effects)
    writer.bind { action -> candidate.reduce(context, action) }
    ledger.onCommit { snapshot -> flowLedgerListeners.forEach { it(snapshot) } }
    // 启动引导，全部走写者、按顺序落地后才对外发布这套运行时：
    //   ① 代号校正（旧代号的账要整份作废）
    //   ② MOB-53 的 completedAt 一次性迁移（改造前藏在 load() 里）
    //   ③ 上一条进程life遗留的租约降级回 QUEUED
    writer.dispatchAndAwait(FlowAction.EnsurePairingEpoch(epoch))
    writer.dispatchAndAwait(FlowAction.MigrateCompletedAt)
    writer.dispatchAndAwait(FlowAction.ReconcileProcessStart)
    return synchronized(flowRuntimeLock) {
        val current = PairingStore(context.filesDir).load()
        if (current?.daemonNodeId != key || current.pairingEpoch != epoch.value) {
            candidate.shutdown()
            native.close()
            null
        } else {
            flowRuntimes[key] = candidate
            candidate
        }
    }
}

private val flowRuntimeLock = Any()

// MOB-88: 构造段的 single-flight 锁，与 flowRuntimeLock 分开——原生 open
// 要几秒，不能挡住只是取一下运行时引用的调用方。
private val flowConstructionLock = Any()
private val flowRuntimes = mutableMapOf<String, AndroidFlowRuntime>()
