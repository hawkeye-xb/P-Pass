package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import com.hawkeyexb.ppass.backup.flow.liveFlowRuntime
import com.hawkeyexb.ppass.backup.flow.sourceVersionOf
import com.hawkeyexb.ppass.backup.folder.FolderAccess
import com.hawkeyexb.ppass.backup.folder.SafFolderTree
import com.hawkeyexb.ppass.backup.folder.isFolderId
import com.hawkeyexb.ppass.backup.order.Order
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.proto.AssetMeta
import com.hawkeyexb.ppass.proto.ThumbSize
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal data class LocalOriginal(val mediaId: Long, val sourceVersion: String)

internal class LocalSourceIndex private constructor(private val byHash: Map<String, LocalOriginal>) {
    fun find(hash: String): LocalOriginal? = byHash[hash]

    val hasEntries: Boolean get() = byHash.isNotEmpty()

    companion object {
        val EMPTY = LocalSourceIndex(emptyMap())

        fun of(orders: Sequence<Order>): LocalSourceIndex {
            val out = HashMap<String, LocalOriginal>()
            for (order in orders) {
                val hash = order.contentHash?.takeIf { it.isNotBlank() } ?: continue
                if (order.state != OrderState.CONFIRMED || order.sourceMissing) continue
                val seen = out[hash]
                if (seen == null || order.mediaId > seen.mediaId) {
                    out[hash] = LocalOriginal(order.mediaId, order.sourceVersion)
                }
            }
            return if (out.isEmpty()) EMPTY else LocalSourceIndex(out)
        }
    }
}

internal fun localMediaUri(mediaType: String, mediaId: Long): String =
    if (mediaType.startsWith("video")) "content://media/external/video/media/$mediaId"
    else "content://media/external/images/media/$mediaId"

internal const val LOCAL_INDEX_EMPTY_RETRY_MS = 5_000L

internal const val LOCAL_INDEX_REFRESH_MS = 60_000L

internal fun localIndexReloadDue(nowMs: Long, loadedAtMs: Long?, hasEntries: Boolean): Boolean =
    loadedAtMs == null ||
        nowMs - loadedAtMs >= (if (hasEntries) LOCAL_INDEX_REFRESH_MS else LOCAL_INDEX_EMPTY_RETRY_MS)

internal interface OriginalReader<T> {
    suspend fun thumb(uri: String, sourceVersion: String, maxPx: Int): T?
    suspend fun copy(uri: String, sourceVersion: String, dest: File): Boolean
    suspend fun playableUri(uri: String, sourceVersion: String): String? = null
}

internal class LocalFirstOriginals<T>(
    private val reader: OriginalReader<T>,
    private val loadIndex: suspend () -> LocalSourceIndex,
    private val clock: () -> Long = System::currentTimeMillis,
    private val resolveUri: suspend (mediaType: String, mediaId: Long) -> String? = { mediaType, mediaId ->
        if (isFolderId(mediaId)) null else localMediaUri(mediaType, mediaId)
    },
) {
    private val mutex = Mutex()
    private var index: LocalSourceIndex = LocalSourceIndex.EMPTY
    private var loadedAtMs: Long? = null

    suspend fun currentIndex(): LocalSourceIndex = mutex.withLock {
        val now = clock()
        if (localIndexReloadDue(now, loadedAtMs, index.hasEntries)) {
            index = runCatching { loadIndex() }.getOrDefault(LocalSourceIndex.EMPTY)
            loadedAtMs = now
        }
        index
    }

    suspend fun thumb(asset: AssetMeta, maxPx: Int): T? =
        withLocal(asset) { uri, version -> reader.thumb(uri, version, maxPx) }

    suspend fun copy(asset: AssetMeta, dest: File): Boolean =
        withLocal(asset) { uri, version -> reader.copy(uri, version, dest) } ?: false

    suspend fun playableUri(asset: AssetMeta): String? =
        withLocal(asset) { uri, version -> reader.playableUri(uri, version) }

    private suspend fun <R : Any> withLocal(asset: AssetMeta, block: suspend (String, String) -> R?): R? {
        val hit = currentIndex().find(asset.hash) ?: return null
        val uri = runCatching { resolveUri(asset.mediaType, hit.mediaId) }.getOrNull() ?: return null
        return block(uri, hit.sourceVersion)
    }
}

internal class LocalFirstLoader<T>(
    private val local: LocalFirstOriginals<T>,
    private val remoteThumb: suspend (hash: String, size: ThumbSize) -> T?,
    private val remoteDownload: suspend (hash: String, dest: File) -> Unit,
) {
    suspend fun thumb(asset: AssetMeta, size: ThumbSize, isMine: Boolean): T? {
        if (isMine) runCatching { local.thumb(asset, size.px) }.getOrNull()?.let { return it }
        return remoteThumb(asset.hash, size)
    }

    suspend fun fetchOriginal(asset: AssetMeta, isMine: Boolean, dest: File): File {
        if (isMine && runCatching { local.copy(asset, dest) }.getOrDefault(false)) return dest
        remoteDownload(asset.hash, dest)
        return dest
    }

    suspend fun localVideoUri(asset: AssetMeta, isMine: Boolean): String? {
        if (!isMine) return null
        return runCatching { local.playableUri(asset) }.getOrNull()
    }
}

internal class AndroidOriginalReader(private val context: Context) : OriginalReader<Bitmap> {
    private val resolver: ContentResolver get() = context.contentResolver

    override suspend fun thumb(uri: String, sourceVersion: String, maxPx: Int): Bitmap? =
        withContext(Dispatchers.IO) {
            runCatching {
                val target = Uri.parse(uri)
                if (!versionMatches(target, sourceVersion)) return@runCatching null
                decodeDownscaled(target, maxPx)
            }.getOrNull()
        }

    override suspend fun copy(uri: String, sourceVersion: String, dest: File): Boolean =
        withContext(Dispatchers.IO) {
            val copied = runCatching {
                val target = Uri.parse(uri)
                if (!versionMatches(target, sourceVersion)) return@runCatching false
                resolver.openInputStream(target)?.use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                } ?: return@runCatching false
                true
            }.getOrDefault(false)
            if (!copied) runCatching { dest.delete() }
            copied
        }

    override suspend fun playableUri(uri: String, sourceVersion: String): String? =
        withContext(Dispatchers.IO) {
            runCatching {
                val target = Uri.parse(uri)
                if (!versionMatches(target, sourceVersion)) return@runCatching null
                resolver.openAssetFileDescriptor(target, "r")?.use { uri }
            }.getOrNull()
        }

    private fun versionMatches(uri: Uri, expected: String): Boolean = runCatching {
        if (DocumentsContract.isDocumentUri(context, uri)) {
            resolver.query(
                uri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_SIZE,
                ),
                null,
                null,
                null,
            )?.use { row ->
                row.moveToFirst() && sourceVersionOf(row.getLong(0) / 1000L, row.getLong(1)) == expected
            } ?: false
        } else {
            resolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.SIZE),
                null,
                null,
                null,
            )?.use { row ->
                row.moveToFirst() && sourceVersionOf(row.getLong(0), row.getLong(1)) == expected
            } ?: false
        }
    }.getOrDefault(false)

    private fun decodeDownscaled(uri: Uri, maxPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, maxPx)
        }
        return resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
    }
}

internal fun sampleSizeFor(width: Int, height: Int, maxPx: Int): Int {
    if (width <= 0 || height <= 0 || maxPx <= 0) return 1
    var sample = 1
    while (maxOf(width, height) / sample > maxPx) sample *= 2
    return sample
}

internal fun readLocalSourceIndex(): LocalSourceIndex =
    liveFlowRuntime()?.store?.readCurrentOrders { LocalSourceIndex.of(it) } ?: LocalSourceIndex.EMPTY

internal suspend fun resolveLocalMediaUri(context: Context, mediaType: String, mediaId: Long): String? {
    if (!isFolderId(mediaId)) return localMediaUri(mediaType, mediaId)
    return withContext(Dispatchers.IO) {
        runCatching {
            val registry = FolderAccess.registry(context)
            val sourceId = registry.sourceIdOfMedia(mediaId) ?: return@runCatching null
            val opaqueId = registry.opaqueIdOfMedia(mediaId) ?: return@runCatching null
            val relativePath = registry.relativePath(sourceId, opaqueId) ?: return@runCatching null
            val record = registry.record(sourceId) ?: return@runCatching null
            SafFolderTree(context, Uri.parse(record.treeUri)).uriOf(relativePath)
        }.getOrNull()
    }
}
