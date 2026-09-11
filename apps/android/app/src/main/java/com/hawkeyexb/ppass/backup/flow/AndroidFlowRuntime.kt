// REBUILD-04: shared Android runtime for Flow wake, ledger commands, and UI reads.
package com.hawkeyexb.ppass.backup.flow

import android.content.Context
import android.net.Uri
import com.hawkeyexb.ppass.PPassApplication
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.backup.NotifyOnFailurePrefs
import com.hawkeyexb.ppass.backup.SystemFailureNotifier
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairingStore
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

/**
 * A scope save is an explicit foreground action, not just a future WorkManager
 * eligibility change.  Keep the durable backfill request and its first run in
 * one background critical section so an older KEEP work request cannot delay it.
 */
internal fun requestFlowScopeBackfillAndWake(context: Context, constraintsSatisfied: Boolean) {
    val app = context.applicationContext
    thread(name = "ppass-flow-scope-wake") {
        runtimeFor(app)?.let { runtime ->
            synchronized(flowTriggerLock) {
                runtime.runner.requestScopeBackfill()
                runtime.runner.run(constraintsSatisfied)
            }
        }
        flushAuditOutbox(app)
    }
}

internal fun runFlowWake(context: Context, constraintsSatisfied: Boolean = true) {
    runtimeFor(context.applicationContext)?.let { runtime ->
        synchronized(flowTriggerLock) {
            runtime.runner.requestDiscovery()
            runtime.runner.run(constraintsSatisfied)
        }
    }
    flushAuditOutbox(context)
}

internal fun pauseFlow(context: Context) {
    runtimeFor(context.applicationContext)?.let { synchronized(flowTriggerLock) { it.runner.pause() } }
    flushAuditOutbox(context)
}

internal fun continueFlow(context: Context, constraintsSatisfied: Boolean = true) {
    runtimeFor(context.applicationContext)?.let {
        synchronized(flowTriggerLock) { it.runner.continueFlow(constraintsSatisfied) }
    }
    flushAuditOutbox(context)
}

internal fun retryFailedFlow(context: Context) {
    runtimeFor(context.applicationContext)?.let {
        synchronized(flowTriggerLock) { it.runner.retryFailedDeliveries() }
    }
    flushAuditOutbox(context)
}

internal fun cancelCurrentFlowRound(context: Context) {
    runtimeFor(context.applicationContext)?.let {
        synchronized(flowTriggerLock) { it.runner.cancelCurrentRound(UUID.randomUUID().toString()) }
    }
    flushAuditOutbox(context)
}

/** MOB-59: the notice's only action — re-admit every cancelled round's items as QUEUED. */
internal fun restoreAllCancelledFlowRounds(context: Context) {
    runtimeFor(context.applicationContext)?.let {
        synchronized(flowTriggerLock) { it.runner.restoreAllCancelledRounds() }
    }
    flushAuditOutbox(context)
}

internal fun flowLedgerSnapshot(context: Context): DiscoveryLedgerSnapshot =
    runtimeFor(context.applicationContext)?.ledger?.load() ?: DiscoveryLedgerSnapshot()

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
)

/** AUDIT-01: best-effort drain of the ledger's durable audit outbox after
 *  every trigger. Every other Flow trigger already serializes state
 *  mutation through [flowTriggerLock] synchronously; the network hop to
 *  the daemon must not block that path, so this fires on its own
 *  coroutine and simply retries from the next trigger on any failure. */
private fun flushAuditOutbox(context: Context) {
    runtimeFor(context.applicationContext)?.let { runtime ->
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
        val ledger = DiscoveryLedgerStore(File(context.filesDir, "flow-state/$key"))
        PairingEpochController(ledger).ensureCurrentEpoch(epoch)
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
            // A deleted MediaStore URI is a terminal local fact, unlike a network
            // failure. It must skip exactly this head and advance, never reset a
            // retry budget or surface "try again" for a photo that no longer exists.
            onMissingSource = { synchronized(flowTriggerLock) { runner.skipMissingSource() }; flushAuditOutbox(context) },
            onPermanentFailure = { synchronized(flowTriggerLock) { runner.recordPermanentFailure() }; flushAuditOutbox(context) },
            onReceipt = { receipt -> synchronized(flowTriggerLock) { runner.acceptCompletionReceipt(receipt) }; flushAuditOutbox(context) },
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
            // MOB-67: re-connect the UX-02 failure notification that REBUILD-04
            // deleted with the legacy worker. Reads NotifyOnFailurePrefs live,
            // so the settings toggle takes effect from the next failure.
            failureNotifier = SystemFailureNotifier(
                context.applicationContext,
                NotifyOnFailurePrefs(context.filesDir),
            ),
        )
        val auditScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val auditDispatcher = AuditOutboxDispatcher(
            ledger = ledger,
            pairing = { PairingStore(context.filesDir).load() },
            identityKey = { IdentityStore(context.filesDir).secretKey() },
            client = app.daemonClient,
        )
        return AndroidFlowRuntime(epoch, ledger, runner, native, auditDispatcher, auditScope)
            .also { flowRuntimes[key] = it }
    }
}

private val flowTriggerLock = Any()
private val flowRuntimeLock = Any()
private val flowRuntimes = mutableMapOf<String, AndroidFlowRuntime>()
