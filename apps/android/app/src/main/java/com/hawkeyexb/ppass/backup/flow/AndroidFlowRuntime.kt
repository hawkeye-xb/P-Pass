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
            // DESK-12: the phone's own capture-time fact — carried to
            // Desktop as a fallback for files with no EXIF (screenshots,
            // some video codecs), which otherwise landed under the
            // Flow-delivered file's export moment instead of its real date.
            android.provider.MediaStore.MediaColumns.DATE_TAKEN,
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
            while (rows.moveToNext() && candidates.size < DISCOVERY_PAGE_SIZE) {
                val rowId = rows.getLong(id)
                val rowGeneration = rows.getLong(gen)
                candidates += DiscoveryCandidate(
                    sourceRef = Uri.withAppendedPath(collection, rowId.toString()).toString(),
                    sourceVersion = "$rowGeneration:${rows.getLong(modified)}:${rows.getLong(size)}",
                    bucketId = rows.getLong(bucket),
                    fileName = rows.getString(name).orEmpty(),
                    mediaType = rows.getString(mime) ?: "application/octet-stream",
                    captureAtMs = rows.getLong(taken),
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
                    captureAtMs = rows.getLong(taken),
                )
                next = DiscoveryCursor(rowGeneration, rowId)
            }
        }
        return ScopeBackfillPage(candidates, next, complete)
    }

    private companion object { const val DISCOVERY_PAGE_SIZE = 500 }
}

/** Framework wake path. The Worker invokes [runFlowWake] synchronously. */
internal fun requestFlowWake(context: Context, constraintsSatisfied: Boolean = true) {
    val app = context.applicationContext
    thread(name = "ppass-flow-wake") { runFlowWake(app, constraintsSatisfied) }
}

/** Scope changes only record durable Flow work; the scheduled wake enforces runtime constraints. */
internal fun requestFlowScopeBackfill(context: Context) {
    runtimeFor(context.applicationContext)?.let {
        synchronized(flowTriggerLock) { it.runner.requestScopeBackfill() }
    }
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

internal fun retryFailedFlow(context: Context) {
    runtimeFor(context.applicationContext)?.let {
        synchronized(flowTriggerLock) { it.runner.retryFailedDeliveries() }
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
        PairingEpochController(ledger).ensureCurrentEpoch(epoch)
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
            // MOB-56: every other Flow trigger (pause/continue/wake/cancel/
            // retry) serializes through flowTriggerLock — these two native
            // delivery callbacks were the only entry points that called
            // straight into the runner. On an unstable connection, a failed
            // fetch's wake() could race a concurrent trigger's wake(), both
            // grabbing the strict head and starting two overlapping native
            // deliveries for the SAME item — a StrictConsumer (ARCH-03)
            // single-active-lease violation. Real device: two independent
            // delivery failures logged 322ms apart from different threads
            // (2026-09-07, Samsung SM-S9210, after MOB-54 made a failed
            // fetch's retry synchronous with the next wake).
            onPermanentFailure = { synchronized(flowTriggerLock) { runner.recordPermanentFailure() } },
            onReceipt = { receipt -> synchronized(flowTriggerLock) { runner.acceptCompletionReceipt(receipt) } },
            onPairingEpochRefreshed = { refreshedEpoch ->
                val pairings = PairingStore(context.filesDir)
                val current = pairings.load()
                if (current != null && current.pairingEpoch != refreshedEpoch.value) {
                    pairings.save(current.copy(pairingEpoch = refreshedEpoch.value))
                    PairingEpochController(ledger).ensureCurrentEpoch(refreshedEpoch)
                    requestFlowWake(context.applicationContext)
                }
            },
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
