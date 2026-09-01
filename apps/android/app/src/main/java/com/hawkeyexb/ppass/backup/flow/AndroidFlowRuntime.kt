// REBUILD-03: Android MediaStore discovery adapter and production trigger bridge.
package com.hawkeyexb.ppass.backup.flow

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairingStore
import java.io.File
import kotlin.concurrent.thread

/** Reads one ordered MediaStore window; it never hashes or contacts Desktop. */
internal class AndroidFlowDiscoveryPort(
    private val resolver: ContentResolver,
    private val selectedBuckets: () -> Set<Long>?,
) : FlowDiscoveryPort {
    override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage {
        val generation = if (Build.VERSION.SDK_INT >= 30) {
            MediaStore.MediaColumns.GENERATION_MODIFIED
        } else {
            MediaStore.MediaColumns.DATE_MODIFIED
        }
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE,
            generation,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.BUCKET_ID,
        )
        val buckets = selectedBuckets() ?: return DiscoveryPage(emptyList(), cursor)
        if (buckets.isEmpty()) return DiscoveryPage(emptyList(), cursor)
        val selection = buildString {
            append("${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)")
            append(" AND ($generation > ? OR ($generation = ? AND ${MediaStore.MediaColumns._ID} > ?))")
            append(" AND ${MediaStore.MediaColumns.BUCKET_ID} IN (${buckets.joinToString(",")})")
        }
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            cursor.lastGeneration.toString(),
            cursor.lastGeneration.toString(),
            cursor.lastMediaId.toString(),
        )
        val candidates = mutableListOf<DiscoveryCandidate>()
        var next = cursor
        resolver.query(collection, projection, selection, args, "$generation ASC, ${MediaStore.MediaColumns._ID} ASC")?.use { rows ->
            val id = rows.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val name = rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val mime = rows.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val size = rows.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val gen = rows.getColumnIndexOrThrow(generation)
            val modified = rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val bucket = rows.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
            while (rows.moveToNext() && candidates.size < DISCOVERY_PAGE_SIZE) {
                val rowId = rows.getLong(id)
                val rowGeneration = rows.getLong(gen)
                val source = Uri.withAppendedPath(collection, rowId.toString()).toString()
                candidates += DiscoveryCandidate(
                    sourceRef = source,
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

    private companion object {
        const val DISCOVERY_PAGE_SIZE = 500
    }
}

/**
 * Minimal R3 trigger bridge. It starts only the Flow discovery request and
 * runner; old Worker scheduling/UI remains untouched for REBUILD-04.
 */
internal fun requestFlowDiscovery(context: Context, constraintsSatisfied: Boolean = true) {
    val app = context.applicationContext
    val pairing = PairingStore(app.filesDir).load() ?: return
    if (pairing.pairingEpoch.isBlank()) return
    if (BackupScopeStore(app).selectedBucketIds().isNullOrEmpty()) return
    thread(name = "ppass-flow-trigger") {
        synchronized(flowTriggerLock) {
            val ledger = DiscoveryLedgerStore(File(app.filesDir, "flow-state/${pairing.daemonNodeId}"))
            val epoch = PairingEpoch(pairing.pairingEpoch)
            if (ledger.load().pairingEpoch != epoch) PairingEpochController(ledger).replaceDesktop(epoch)
            lateinit var runner: FlowRunner
            val native = AndroidNativeIrohBlobsProvider.open(app.filesDir)
            val bridge = IrohBlobsProviderBridge(native) { source ->
                requireNotNull(app.contentResolver.openFileDescriptor(Uri.parse(source), "r"))
            }
            val delivery = NativeFlowDeliveryPort(
                ledger = ledger,
                bridge = bridge,
                resolver = app.contentResolver,
                pairing = { PairingStore(app.filesDir).load() },
                identityKey = { IdentityStore(app.filesDir).secretKey() },
                onPermanentFailure = { runner.recordPermanentFailure() },
            )
            runner = FlowRunner(
                ledger,
                AndroidFlowDiscoveryPort(app.contentResolver) { BackupScopeStore(app).selectedBucketIds() },
                delivery,
            )
            runner.requestDiscovery()
            runner.run(constraintsSatisfied)
        }
    }
}

private val flowTriggerLock = Any()
