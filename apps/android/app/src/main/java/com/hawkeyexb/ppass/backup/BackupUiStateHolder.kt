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
    // DOG-01: 持久三元组（重开不归零）；空 = 还没成功备份过
    private val tripletStore = TripletStore(context.filesDir)
    private val _triplet = mutableStateOf<BackupTriplet?>(tripletStore.load())
    val triplet: State<BackupTriplet?> get() = _triplet

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
        // DOG-01: 持久化三元组（N=扫描范围，M=daemon 确认已在家，K=N-M）
        val t = tripletOf(
            offered = report.offered,
            ingested = report.ingested,
            duplicates = report.duplicates,
            lastSuccessAt = System.currentTimeMillis(),
        )
        withContext(Dispatchers.IO) { tripletStore.save(t) }
        _triplet.value = t
        _state.value = BackupUiState.AllSafe(report.ingested, report.duplicates)
    }
}
