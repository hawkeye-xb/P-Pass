// T-054: glue between the Home screen and the pipeline — scan real
// MediaStore photos, hash, run BackupRunner, advance the watermark.
package com.hawkeyexb.ppass.backup

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

    /** N=全量 count，M=确认缓存，K=N-M——随时可算（含断网/从未备份）。 */
    private suspend fun refreshTriplet() {
        val t = withContext(Dispatchers.IO) {
            val n = MediaScanner(context.contentResolver).countAll()
            tripletOf(n, confirmedStore.count().toLong(), confirmedStore.lastSuccessAt())
        }
        _triplet.value = t
    }

    fun backupNow() {
        if (_state.value is BackupUiState.Scanning ||
            _state.value is BackupUiState.Hashing ||
            _state.value is BackupUiState.Sending
        ) return
        scope.launch {
            try {
                runBackup()
            } catch (t: Throwable) {
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
