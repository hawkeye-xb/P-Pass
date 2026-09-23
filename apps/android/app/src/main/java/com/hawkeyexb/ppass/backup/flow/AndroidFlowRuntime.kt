// REBUILD-04 → ARCH-13 (#417): Android 侧的逐张循环运行时——把 FlowEngine 接到 SQLite、MediaStore、
// iroh 原生 provider、前台服务与 WorkManager 上，并提供所有触发入口。
package com.hawkeyexb.ppass.backup.flow

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import com.hawkeyexb.ppass.PPassApplication
import com.hawkeyexb.ppass.backup.AutoBackupPrefs
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.backup.BackupSettings
import com.hawkeyexb.ppass.backup.WorkManagerWakeScheduler
import com.hawkeyexb.ppass.backup.order.OrderStore
import com.hawkeyexb.ppass.backup.order.ContentResolverMediaSnapshotSource
import com.hawkeyexb.ppass.backup.order.SqliteOrderStore
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import io.github.rctcwyvrn.blake3.Blake3
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

private const val TAG = "PPassFlow"
private val androidLog = FlowLogger { Log.i(TAG, it) }

/**
 * MOB-76: the live delivery gate —「仅 Wi-Fi 时备份」× current network. Separate from the WorkManager
 * scheduling constraints: even a MANUAL worker must not push onto a metered network while the switch is on.
 */
internal fun flowConstraintsSatisfied(context: Context): Boolean {
    val settings = BackupSettings(context.filesDir).load()
    return !settings.wifiOnly || isOnUnmetered(context)
}

/** 是否在不计流量网络（Wi-Fi）上。 */
internal fun isOnUnmetered(context: Context): Boolean {
    val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager ?: return false
    val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
    return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
}

/** 电量低（与 WorkManager `requiresBatteryNotLow` 同一口径：未充电且 ≤ 15%）。 */
internal fun isBatteryLow(context: Context): Boolean {
    val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return false
    val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
    val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
    val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
    if (level < 0 || scale <= 0 || plugged) return false
    return level * 100 / scale <= 15
}

// ------------------------------------------------------------------ 触发入口

/** 任何触发都走这里（先查暂停在 [FlowEngine.trigger] 里）。不阻塞调用方。 */
internal fun requestFlowWake(context: Context, reason: TriggerReason) {
    val app = context.applicationContext
    thread(name = "ppass-flow-wake") {
        runCatching { runtimeFor(app)?.engine?.trigger(reason) }
            .onFailure { Log.e(TAG, "wake $reason failed", it) }
    }
}

/** worker 用：触发并等检查阶段结束（传输跑在进程级 scope + FGS 下，不占 worker 的执行时长）。 */
internal suspend fun runFlowWake(context: Context, reason: TriggerReason) {
    val runtime = runtimeFor(context.applicationContext) ?: return
    withTimeoutOrNull(WORKER_CHECK_BUDGET_MS) { runtime.engine.triggerAndAwaitChecks(reason) }
        ?: Log.w(TAG, "wake $reason: checks did not finish within ${WORKER_CHECK_BUDGET_MS}ms; the cycle continues on its own")
}

/** 新增相册：立刻跑一次慢路径（#415 裁决 5）。减少相册不需要调用任何东西。 */
@Suppress("UNUSED_PARAMETER")
internal fun requestFlowScopeBackfillAndWake(context: Context, constraintsSatisfied: Boolean) =
    requestFlowWake(context, TriggerReason.SCOPE_ADDED)

/** MOB-87：重新配对成功——唤醒 + 一次慢路径（含问桌面「还在吗」）。 */
internal fun requestFlowWakeAfterRepair(context: Context) = requestFlowWake(context, TriggerReason.PAIRING_REPAIRED)

internal fun pauseFlow(context: Context) {
    runtimeFor(context.applicationContext)?.engine?.pause()
}

internal fun continueFlow(context: Context) {
    runtimeFor(context.applicationContext)?.engine?.continueFlow()
}

/** FAILED 立即重试一次（走慢路径第 3 步）。 */
internal fun retryFailedFlow(context: Context) = requestFlowWake(context, TriggerReason.RETRY_FAILED)

/** 「取消剩余 N 张」，返回 N。 */
internal suspend fun cancelRemainingFlow(context: Context): Int =
    runtimeFor(context.applicationContext)?.engine?.cancelRemaining()?.await() ?: 0

internal fun acknowledgeFlowMissingSource(context: Context) {
    runtimeFor(context.applicationContext)?.engine?.acknowledgeMissingSource()
}

/** App 进入前台：清 FGS 受阻事实并触发一次（含慢路径）。 */
internal fun onFlowAppForeground(context: Context) {
    val app = context.applicationContext
    thread(name = "ppass-flow-foreground") {
        runCatching { runtimeFor(app)?.engine?.onAppForeground() }.onFailure { Log.e(TAG, "foreground trigger failed", it) }
    }
}

/** ConnectivityManager 网络变化回调：先让 iroh 立刻重探路径，再交给引擎。 */
internal fun onFlowNetworkChanged(context: Context) {
    val app = context.applicationContext
    thread(name = "ppass-flow-network") {
        runCatching {
            val runtime = runtimeFor(app) ?: return@runCatching
            runCatching { runtime.bridge.networkChange() }.onFailure { Log.w(TAG, "network_change failed", it) }
            runtime.engine.onNetworkChanged()
        }.onFailure { Log.e(TAG, "network trigger failed", it) }
    }
}

// ------------------------------------------------------------------ UI 读取

/** 当前运行时（不触发构造）；UI 投影用。 */
internal fun liveFlowRuntime(): AndroidFlowRuntime? = synchronized(runtimeLock) { runtime }

internal fun flowProjection(context: Context, bucketIds: Set<Long>?, inScopeTotal: Long?): FlowProjection? {
    val live = runtimeFor(context.applicationContext) ?: return null
    return FlowProjection.of(live.store, live.engine.status.value, live.control, bucketIds, inScopeTotal)
}

// ------------------------------------------------------------------ 生命周期

internal class AndroidFlowRuntime(
    val ownerKey: String,
    val engine: FlowEngine,
    val store: OrderStore,
    val control: FlowControl,
    val bridge: IrohBlobsProviderBridge,
    private val writer: FlowWriter,
    private val scope: CoroutineScope,
    private val sqlite: SqliteOrderStore,
) {
    fun shutdown() {
        scope.cancel()
        writer.shutdown()
        runCatching { sqlite.close() }
    }
}

/**
 * 解除配对：停掉运行时（在飞的传输随 scope 取消而停；原生仓库不关，MOB-91）。order 表不删——
 * 连回**同一台**桌面时 CONFIRMED 仍然有效；换一台桌面时由 [OrderStore.claimOwner] 清空（#415 裁决 6）。
 */
internal fun clearFlowRuntime(context: Context, daemonNodeId: String) {
    val stale = synchronized(runtimeLock) {
        runtime?.takeIf { it.ownerKey == daemonNodeId }?.also { runtime = null }
    }
    stale?.shutdown()
    runCatching { sharedNativeProvider?.revoke("") }.onFailure { Log.w(TAG, "clearFlowRuntime: revoke failed; ignoring", it) }
}

/**
 * 取运行时，必要时构造。构造（原生 open 数秒 + SQLite）在专门的线程上跑，调用方**有界等待**
 * [INIT_TIMEOUT_MS]：之前 `flowConstructionLock` 里原生 open 永久阻塞时，所有入口跟着永久阻塞（MOB-91 / #414）。
 * 超时只打日志返回 null；构造继续跑，下一个调用方等同一个 future。
 */
internal fun runtimeFor(context: Context): AndroidFlowRuntime? {
    val app = context.applicationContext
    val pairing = PairingStore(app.filesDir).load() ?: return null.also { Log.i(TAG, "runtimeFor: not paired") }
    if (pairing.pairingEpoch.isBlank()) return null.also { Log.w(TAG, "runtimeFor: blank pairing epoch; refusing to build") }
    val key = pairing.daemonNodeId
    val task = synchronized(runtimeLock) {
        runtime?.let { live ->
            if (live.ownerKey == key) return live
            runtime = null
            live.shutdown()
        }
        building?.takeIf { it.first == key }?.second ?: FutureTask { buildRuntime(app, key) }.also { future ->
            building = key to future
            thread(name = "ppass-flow-init") { future.run() }
        }
    }
    val started = SystemClock.elapsedRealtime()
    return try {
        task.get(INIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
    } catch (_: TimeoutException) {
        Log.e(TAG, "runtimeFor: initialization still running after ${INIT_TIMEOUT_MS}ms; giving up this call")
        null
    } catch (failure: Exception) {
        Log.e(TAG, "runtimeFor: initialization failed", failure)
        synchronized(runtimeLock) { if (building?.second === task) building = null }
        null
    }.also { Log.i(TAG, "runtimeFor: ready=${it != null} in ${SystemClock.elapsedRealtime() - started}ms") }
}

private fun buildRuntime(app: Context, key: String): AndroidFlowRuntime {
    Log.i(TAG, "buildRuntime: start")
    migrateLegacyFlowState(app.filesDir)
    val application = app as PPassApplication
    val writer = FlowWriter.start("ppass-flow-writer")
    val sqlite = SqliteOrderStore.open(app)
    val store = WriterGuardedOrderStore(sqlite, SingleThreadWrites(writer.thread))
    val cleared = runBlocking(writer.dispatcher) { store.claimOwner(key, idFloor = System.currentTimeMillis()) }
    Log.i(TAG, "buildRuntime: order store ready (cleared for a different desktop=$cleared)")
    val native = sharedNativeProvider(app)
    Log.i(TAG, "buildRuntime: native blobs provider ready")
    val bridge = IrohBlobsProviderBridge(native) { source ->
        try {
            app.contentResolver.openFileDescriptor(Uri.parse(source), "r") ?: throw SourceMissingException()
        } catch (failure: FileNotFoundException) {
            throw SourceMissingException(failure)
        }
    }
    val pairing: () -> Pairing? = { PairingStore(app.filesDir).load() }
    val client = application.daemonClient
    val desktopFor: suspend (Pairing) -> FlowReceiptClient = { p ->
        client.bind(IdentityStore(app.filesDir).secretKey())
        DaemonFlowReceiptClient(client, parsePeerAddrToken(p.daemonAddrToken))
    }
    val delivery = NativeFlowDeliveryPort(
        bridge = bridge,
        pairing = pairing,
        desktopFor = desktopFor,
        subscribe = { p, onEvent ->
            client.subscribeTimeline(parsePeerAddrToken(p.daemonAddrToken), onFlowEvent = { kind, data -> onEvent(kind, data) }, onInvalidated = {})
        },
        cancelTuple = { p, tuple ->
            client.bind(IdentityStore(app.filesDir).secretKey())
            client.flowCancelTuple(parsePeerAddrToken(p.daemonAddrToken), tuple)
        },
        log = androidLog,
        clock = SystemClock::elapsedRealtime,
    )
    val scopeStore = BackupScopeStore(app)
    val control = FlowControlStore(app.filesDir)
    val scope = CoroutineScope(SupervisorJob() + writer.dispatcher)
    val auditScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    lateinit var engine: FlowEngine
    val dispatcher = AuditOutboxDispatcher(
        store = store,
        pairing = pairing,
        transportFor = { p ->
            client.bind(IdentityStore(app.filesDir).secretKey())
            DaemonFlowAuditTransport(client, parsePeerAddrToken(p.daemonAddrToken))
        },
        acknowledgeEvents = { ids -> engine.acknowledgeAudit(ids) },
    )
    engine = FlowEngine(
        store = store,
        media = ContentResolverMediaSnapshotSource(app, { scopeStore.selectedBucketIds() }),
        hasher = ContentResolverHasher(app),
        delivery = delivery,
        probe = DaemonDesktopProbe(pairing, desktopFor),
        presence = RemotePresence { hashes ->
            val p = pairing() ?: error("not paired")
            client.bind(IdentityStore(app.filesDir).secretKey())
            RemotePresenceProbe(client).missing(parsePeerAddrToken(p.daemonAddrToken), hashes)
        },
        foreground = AndroidForegroundLease(app, control),
        scheduler = WorkManagerWakeScheduler(app),
        control = control,
        conditions = {
            val settings = BackupSettings(app.filesDir).load()
            Conditions(
                paired = pairing() != null,
                autoBackupEnabled = AutoBackupPrefs(app.filesDir).enabled(),
                wifiOnly = settings.wifiOnly,
                onUnmetered = isOnUnmetered(app),
                batteryLow = isBatteryLow(app),
                fgsBlocked = control.fgsBlock() != null,
            )
        },
        inScope = { bucket -> scopeStore.selectedBucketIds()?.contains(bucket) == true },
        pairingEpoch = { pairing()?.pairingEpoch?.takeIf { it.isNotBlank() }?.let(::PairingEpoch) },
        scope = scope,
        io = Dispatchers.IO,
        log = androidLog,
        afterCycle = { auditScope.launch { dispatcher.flush() } },
        onEpochAdvertised = { advertised ->
            // 同一台桌面换了配对代号：order 表保留（内容寻址，CONFIRMED 跨代号成立），只更新凭证。
            val pairings = PairingStore(app.filesDir)
            pairings.load()?.let { current -> if (current.pairingEpoch != advertised) pairings.save(current.copy(pairingEpoch = advertised)) }
        },
    )
    FlowForegroundHandoff.control = control
    FlowForegroundHandoff.onLost = { reason -> engine.onForegroundLost(reason) }
    engine.start()
    val built = AndroidFlowRuntime(key, engine, store, control, bridge, writer, scope, sqlite)
    synchronized(runtimeLock) {
        val current = PairingStore(app.filesDir).load()
        if (current?.daemonNodeId != key) {
            Log.w(TAG, "buildRuntime: pairing moved during construction; discarding")
            built.shutdown()
            building = null
            error("pairing moved during construction")
        }
        runtime = built
        building = null
    }
    Log.i(TAG, "buildRuntime: published")
    return built
}

/**
 * #413「迁移」：没有正式用户，旧账本（`flow-state/`）与旧的前台保护状态文件直接删，不做数据迁移。
 * 第一次全量慢路径重建 order 表；桌面按内容去重，不会重复传输。只做一次（marker 文件）。
 */
internal fun migrateLegacyFlowState(filesDir: File) {
    val marker = File(filesDir, "flow-migrated-arch13")
    if (marker.exists()) return
    File(filesDir, "flow-state").deleteRecursively()
    File(filesDir, "flow-transfer-protection.json").delete()
    filesDir.listFiles { f -> f.name.startsWith("flow-transfer-protection.json.") }?.forEach { it.delete() }
    runCatching { marker.writeText("1") }
}

/** 整文件 BLAKE3（按 media_id 在外部卷上打开）。 */
private class ContentResolverHasher(private val context: Context) : ContentHasher {
    override fun hash(mediaId: Long): String {
        val uri = Uri.withAppendedPath(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), mediaId.toString())
        val hasher = Blake3.newInstance()
        try {
            context.contentResolver.openInputStream(uri).use { input ->
                val present = input ?: throw SourceMissingException()
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    val count = present.read(buffer)
                    if (count < 0) break
                    hasher.update(if (count == buffer.size) buffer else buffer.copyOf(count))
                }
            }
        } catch (failure: FileNotFoundException) {
            throw SourceMissingException(failure)
        }
        return hasher.hexdigest()
    }
}

/**
 * MOB-91：原生内容仓库是**进程内单例，开一次，永不关**——同一进程内第二次 nativeOpen 会永久阻塞。
 * 断开只 revoke（停掉在飞的传输、放掉 temp tag），仓库本身不动。
 */
private val nativeProviderLock = Any()

@Volatile
private var sharedNativeProvider: AndroidNativeIrohBlobsProvider? = null

private fun sharedNativeProvider(context: Context): AndroidNativeIrohBlobsProvider =
    sharedNativeProvider ?: synchronized(nativeProviderLock) {
        sharedNativeProvider ?: run {
            Log.i(TAG, "native blobs provider: opening (once per process)")
            AndroidNativeIrohBlobsProvider.open(context.filesDir).also { sharedNativeProvider = it }
        }
    }

private val runtimeLock = Any()
private var runtime: AndroidFlowRuntime? = null
private var building: Pair<String, FutureTask<AndroidFlowRuntime>>? = null

/** 运行时初始化的有界等待。 */
private const val INIT_TIMEOUT_MS = 20_000L

/** worker 只等检查阶段（WorkManager 的单次执行上限约 10 分钟）。 */
private const val WORKER_CHECK_BUDGET_MS = 8 * 60 * 1000L
