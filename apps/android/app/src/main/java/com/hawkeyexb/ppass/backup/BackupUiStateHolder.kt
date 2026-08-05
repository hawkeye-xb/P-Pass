// T-054: glue between the Home screen and the pipeline — scan real
// MediaStore photos, hash, run BackupRunner, advance the watermark.
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.ui.BackupUiState
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class BackupUiStateHolder(
    private val context: Context,
    private val client: DaemonClient,
    private val identity: IdentityStore,
    private val pairing: Pairing,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val _state = mutableStateOf<BackupUiState>(BackupUiState.Idle)
    val state: State<BackupUiState> get() = _state
    // DOG-01b: 状态缓存表 key=(hash, remote_id)，落 per-remote 目录。
    // M = 该 remote 已确认条数；N = MediaStore 全量 count；K = N-M。
    // 杀 App 重开不归零；断网也走本地（MediaStore + 本地文件）→ 恒真。
    private val confirmedStore = ConfirmedStore(
        File(context.filesDir, "backup-state/${pairing.daemonNodeId}")
    )
    private val _triplet = mutableStateOf<BackupTriplet?>(null)
    val triplet: State<BackupTriplet?> get() = _triplet

    // 存储端移除/吊销本设备后，备份请求被配对门拒（err.not_paired /
    // err.not_authorized）——UI 借此感知「配对已失效」，给出重新扫码入口。
    private val _pairingLost = mutableStateOf(false)
    val pairingLost: State<Boolean> get() = _pairingLost

    init {
        // 启动即算一次（MediaStore COUNT 便宜；扫描在 IO 线程）。
        scope.launch { refreshTriplet() }
        // DOG-01c: App 打开即做一次漂移校准（daemon 可达才跑，不可达跳过）。
        scope.launch { calibrateFromDaemon() }
    }

    /** DOG-01c: 漂移校准——电脑端库被删/换库时，缓存里的旧 hash 已不在
     *  daemon。用只查不传的 exist-check 问出 missing 并从缓存移除。
     *  daemon 不可达/未配对 → 跳过（三元组显示缓存值，不归零不崩）。 */
    private suspend fun calibrateFromDaemon() {
        try {
            val cached = withContext(Dispatchers.IO) { confirmedStore.load().confirmed }
            if (cached.isEmpty()) return
            withContext(Dispatchers.IO) { client.bind(identity.secretKey()) }
            val daemon = parsePeerAddrToken(pairing.daemonAddrToken)
            val missing = withContext(Dispatchers.IO) {
                BackupRunner(client).existCheck(daemon, cached)
            }
            if (missing.isNotEmpty()) {
                withContext(Dispatchers.IO) { confirmedStore.removeMissing(missing) }
                refreshTriplet()
            }
        } catch (_: Throwable) {
            // 不可达/未配对/超时——保留缓存值，下次再校准。
        }
    }

    /** N=全量 count，M=确认缓存，K=N-M——随时可算（含断网/从未备份）。
     *  DOG-01d: 全链容错——媒体查询/缓存读取失败退化为「三元组不显示」
     *  （triplet=null），绝不崩 App（三星真机：countAll 启动即跑且异常
     *  未接住 → 启动必闪退）。 */
    private suspend fun refreshTriplet() {
        _triplet.value = withContext(Dispatchers.IO) {
            computeTripletSafe(context.contentResolver, confirmedStore)
        }
    }

    // UX-01: 备份运行句柄——进行中再点 = 暂停（取消当前批，幂等管线安全）。
    private var backupJob: Job? = null

    fun backupNow() {
        // UX-01: 备份进行中再点 = 暂停——中断当前批。幂等管线保证安全：
        // 中断不 commit、水位不推进，已到家的 blob 下次 run 去重；再点
        // 一次 = 续传（重新 offer 全部候选，dedup 收敛缺 0）。
        if (backupJob?.isActive == true) {
            backupJob?.cancel()
            backupJob = null
            _state.value = BackupUiState.Idle
            return
        }
        backupJob = scope.launch {
            try {
                runBackup()
            } catch (t: Throwable) {
                if (t is kotlinx.coroutines.CancellationException) throw t
                // 存储端已移除/吊销本设备 → 备份被配对门拒——UI 切「配对已
                // 失效」态，主按钮变重新扫码（rejoin 门：新 token 可重建）。
                _pairingLost.value = isPairingLostError(t)
                _state.value = BackupUiState.Trouble(
                    "Could not finish this run — photos already home are safe; " +
                        "try again and it picks up where it left off.\n" +
                        "这次没传完——已存回家的照片是安全的；再点一次会从断点继续。\n" +
                        "(${t.toString().take(140)})"
                )
            }
        }
    }

    private suspend fun runBackup() {
        // DOG-01c: 备份前先做一次漂移校准（只查不传；daemon 不可达则跳过）。
        calibrateFromDaemon()

        val watermarks = WatermarkStore(context.filesDir)
        val since = watermarks.load()

        _state.value = BackupUiState.Scanning(0)
        val scan = withContext(Dispatchers.IO) {
            MediaScanner(context.contentResolver).scanSince(since)
        }
        _state.value = BackupUiState.Scanning(scan.items.size)
        if (scan.items.isEmpty()) {
            _state.value = BackupUiState.AllSafe(0, 0)
            return
        }

        // Hash every candidate (streamed off the resolver).
        val candidates = withContext(Dispatchers.IO) {
            scan.items.mapIndexed { i, item ->
                withContext(Dispatchers.Main) {
                    _state.value = BackupUiState.Hashing(i + 1, scan.items.size)
                }
                val open = {
                    context.contentResolver.openInputStream(item.uri)
                        ?: error("cannot open ${item.displayName}")
                }
                Candidate(
                    hash = open().use { blake3Hex(it) },
                    fileName = item.displayName,
                    mediaType = item.mimeType,
                    bytes = item.bytes,
                    open = open,
                )
            }
        }

        _state.value = BackupUiState.Sending(0, candidates.size)
        withContext(Dispatchers.IO) { client.bind(identity.secretKey()) }
        val daemon = parsePeerAddrToken(pairing.daemonAddrToken)
        val report = BackupRunner(client).run(daemon, candidates, scan.nextWatermark)

        // Watermark only advances after a committed run (T-053 semantics).
        withContext(Dispatchers.IO) { watermarks.save(scan.nextWatermark) }
        // DOG-01c: commit 成功后本次候选**全部**确认——report.missing 是
        // 上传前 manifest 应答的缺失集合，commit 成功后这些文件已在库，
        // 不参与减项（回归：旧实现 confirmed = allHashes − missing 会把
        // 刚上传成功的照片从缓存删掉，首次全量备份后 M=0 且永远为 0）。
        // 漂移校准由独立的 exist-check（calibrateFromDaemon）负责。
        withContext(Dispatchers.IO) {
            confirmedStore.recordRun(
                confirmed = confirmedAfterCommit(candidates, report),
                lastSuccessAt = System.currentTimeMillis(),
            )
        }
        refreshTriplet()
        _state.value = BackupUiState.AllSafe(report.ingested, report.duplicates)
    }
}

/**
 * DOG-01d: 三元组计算全链容错（refreshTriplet 的生产实现，测试共用——
 * DOG-01c 教训：语义测试走生产调用链）。媒体查询或缓存读取抛任何异常
 * → 返回 null（UI 不显示三元组），绝不崩 App。三星真机实锤：COUNT(*)
 * 投影被 provider 拒绝（Invalid column count(*)），refreshTriplet 启动
 * 即跑、异常未接住 → 启动必闪退。
 *
 * @param resolver 生产恒传 context.contentResolver；null 仅测试注入
 *  （JVM 单测无法实例化 android.jar 的 ContentResolver——构造即 Stub!，
 *  checkNotNull 抛的 IllegalArgumentException 与三星 provider 拒绝同型）。
 */
internal fun computeTripletSafe(
    resolver: ContentResolver?,
    store: ConfirmedStore,
): BackupTriplet? = try {
    val n = MediaScanner(checkNotNull(resolver)).countAll()
    tripletOf(n, store.count().toLong(), store.lastSuccessAt())
} catch (_: Throwable) {
    null
}

/**
 * 配对失效判定（存储端移除/吊销本设备）：备份链路的 check 失败异常消息
 * 携带 daemon 的 msg_key——`err.not_paired`（设备行已删/从未配对）与
 * `err.not_authorized`（已吊销/角色不允）都意味着「配对关系已失效，
 * 需重新扫码」。其余错误（超时/磁盘满/网络）不算配对失效。
 *
 * 生产调用链：BackupUiStateHolder.backupNow 的 catch → 此函数。
 * 测试注入：直接构造含 msg_key 的异常消息。
 */
internal fun isPairingLostError(t: Throwable): Boolean {
    val msg = t.message ?: return false
    return msg.contains("err.not_paired") || msg.contains("err.not_authorized")
}
