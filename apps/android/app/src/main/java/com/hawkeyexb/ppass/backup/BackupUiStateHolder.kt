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
        _state.value = BackupUiState.AllSafe(report.ingested, report.duplicates)
    }
}
