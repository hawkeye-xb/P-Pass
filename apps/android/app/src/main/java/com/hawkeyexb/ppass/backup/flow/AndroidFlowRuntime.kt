// REBUILD-04: shared Android runtime for Flow wake, ledger commands, and UI reads.
package com.hawkeyexb.ppass.backup.flow

import android.content.Context
import android.net.Uri
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairingStore
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread

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
            while (rows.moveToNext() && candidates.size < DISCOVERY_PAGE_SIZE) {
                val rowId = rows.getLong(id)
                val rowGeneration = rows.getLong(gen)
                candidates += DiscoveryCandidate(
                    sourceRef = Uri.withAppendedPath(collection, rowId.toString()).toString(),
                    sourceVersion = "$rowGeneration:${rows.getLong(modified)}:${rows.getLong(size)}",
                    bucketId = rows.getLong(bucket),
                    fileName = rows.getString(name).orEmpty(),
                    mediaType = rows.getString(mime) ?: "application/octet-stream",
                )
                next = DiscoveryCursor(rowGeneration, rowId)
            }
        }
        return DiscoveryPage(candidates, next)
    }

    private companion object { const val DISCOVERY_PAGE_SIZE = 500 }
}

/** Framework wake path. The Worker invokes [runFlowWake] synchronously. */
internal fun requestFlowWake(context: Context, constraintsSatisfied: Boolean = true) {
    val app = context.applicationContext
    thread(name = "ppass-flow-wake") { runFlowWake(app, constraintsSatisfied) }
}

internal fun runFlowWake(context: Context, constraintsSatisfied: Boolean = true) {
    runtimeFor(context.applicationContext)?.let { runtime ->
        synchronized(flowTriggerLock) {
            runtime.runner.requestDiscovery()
            runtime.runner.run(constraintsSatisfied)
        }
    }
}

internal fun pauseFlow(context: Context) {
    runtimeFor(context.applicationContext)?.let { synchronized(flowTriggerLock) { it.runner.pause() } }
}

internal fun continueFlow(context: Context, constraintsSatisfied: Boolean = true) {
    runtimeFor(context.applicationContext)?.let {
        synchronized(flowTriggerLock) { it.runner.continueFlow(constraintsSatisfied) }
    }
}

internal fun cancelCurrentFlowRound(context: Context) {
    runtimeFor(context.applicationContext)?.let {
        synchronized(flowTriggerLock) { it.runner.cancelCurrentRound(UUID.randomUUID().toString()) }
    }
}

internal fun flowLedgerSnapshot(context: Context): DiscoveryLedgerSnapshot =
    runtimeFor(context.applicationContext)?.ledger?.load() ?: DiscoveryLedgerSnapshot()

private data class AndroidFlowRuntime(
    val epoch: PairingEpoch,
    val ledger: DiscoveryLedgerStore,
    val runner: FlowRunner,
)

private fun runtimeFor(context: Context): AndroidFlowRuntime? {
    val pairing = PairingStore(context.filesDir).load() ?: return null
    if (pairing.pairingEpoch.isBlank()) return null
    val epoch = PairingEpoch(pairing.pairingEpoch)
    val key = pairing.daemonNodeId
    synchronized(flowRuntimeLock) {
        flowRuntimes[key]?.takeIf { it.epoch == epoch }?.let { return it }
        val ledger = DiscoveryLedgerStore(File(context.filesDir, "flow-state/$key"))
        if (ledger.load().pairingEpoch != epoch) PairingEpochController(ledger).replaceDesktop(epoch)
        lateinit var runner: FlowRunner
        val native = AndroidNativeIrohBlobsProvider.open(context.filesDir)
        val bridge = IrohBlobsProviderBridge(native) { source ->
            requireNotNull(context.contentResolver.openFileDescriptor(Uri.parse(source), "r"))
        }
        val delivery = NativeFlowDeliveryPort(
            ledger = ledger,
            bridge = bridge,
            resolver = context.contentResolver,
            pairing = { PairingStore(context.filesDir).load() },
            identityKey = { IdentityStore(context.filesDir).secretKey() },
            onPermanentFailure = { runner.recordPermanentFailure() },
        )
        runner = FlowRunner(
            ledger = ledger,
            discovery = AndroidFlowDiscoveryPort(context.contentResolver) { BackupScopeStore(context).selectedBucketIds() },
            delivery = delivery,
        )
        return AndroidFlowRuntime(epoch, ledger, runner).also { flowRuntimes[key] = it }
    }
}

private val flowTriggerLock = Any()
private val flowRuntimeLock = Any()
private val flowRuntimes = mutableMapOf<String, AndroidFlowRuntime>()
