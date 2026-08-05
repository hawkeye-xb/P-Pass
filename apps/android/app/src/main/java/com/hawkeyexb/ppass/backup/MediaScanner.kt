// T-053: MediaStore enumeration with an incremental watermark.
//
// Watermark semantics (design 详细设计 §5 / BackupCommit.generation):
// MediaStore stamps every row with a monotonically increasing per-volume
// GENERATION_ADDED / GENERATION_MODIFIED (API 30+). We scan rows with
// generation > watermark; after a committed backup the daemon persists
// the new watermark via BackupCommit.generation, so the next scan is
// incremental. Below API 30 we fall back to DATE_ADDED seconds — coarser
// (re-hashing is harmless: dedup drops re-offers).
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.ContentUris
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.File

data class MediaItem(
    val uri: Uri,
    val displayName: String,
    val mimeType: String,
    val bytes: Long,
    /** Volume generation (API 30+) or DATE_ADDED seconds (fallback). */
    val generation: Long,
)

data class ScanResult(
    val items: List<MediaItem>,
    /** Watermark to persist AFTER these items are committed. */
    val nextWatermark: Long,
)

class MediaScanner(private val resolver: ContentResolver) {

    /** All photos+videos newer than [watermark], oldest-first. */
    fun scanSince(watermark: Long): ScanResult {
        val items = mutableListOf<MediaItem>()
        var maxGen = watermark
        for ((collection, isVideo) in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI to false,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI to true,
        )) {
            val genCol = if (Build.VERSION.SDK_INT >= 30) {
                MediaStore.MediaColumns.GENERATION_MODIFIED
            } else {
                MediaStore.MediaColumns.DATE_ADDED
            }
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.MIME_TYPE,
                MediaStore.MediaColumns.SIZE,
                genCol,
            )
            resolver.query(
                collection, projection,
                "$genCol > ?", arrayOf(watermark.toString()),
                "$genCol ASC",
            )?.use { cur ->
                val idIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val mimeIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val sizeIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val genIdx = cur.getColumnIndexOrThrow(genCol)
                while (cur.moveToNext()) {
                    val gen = cur.getLong(genIdx)
                    if (gen > maxGen) maxGen = gen
                    items.add(
                        MediaItem(
                            uri = ContentUris.withAppendedId(collection, cur.getLong(idIdx)),
                            displayName = cur.getString(nameIdx) ?: "unnamed",
                            mimeType = cur.getString(mimeIdx)
                                ?: if (isVideo) "video/*" else "image/*",
                            bytes = cur.getLong(sizeIdx),
                            generation = gen,
                        )
                    )
                }
            }
        }
        items.sortBy { it.generation }
        return ScanResult(items, maxGen)
    }

    /**
     * 当前扫描范围的全量 count（无 generation 过滤）——DOG-01b 三元组
     * 的分母 N。MediaStore COUNT 查询，便宜，不需要重 hash。口径常量
     * 一处定义（范围选择是另一张卡，改范围只动这里）。
     *
     * DOG-01d: 合规写法——projection 只放 [_ID]，用 cursor.count 取数。
     * 三星真机实锤：scoped storage 的 provider 拒绝 projection 里的 SQL
     * 函数（"Invalid column count(*)"），启动必闪退。查询异常不在此处
     * 吞——由 computeTripletSafe（refreshTriplet 生产实现）Throwable 级
     * 兜底为「三元组不显示」，绝不崩 App。
     */
    fun countAll(): Long {
        var total = 0L
        for (collection in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
        )) {
            resolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                null,
                null,
                null,
            )?.use { cur -> total += cur.count.toLong() }
        }
        return total
    }
}

/** The committed watermark, one long, crash-safe on disk. */
class WatermarkStore(private val dir: File) {
    private val file = File(dir, "backup.watermark")

    fun load(): Long =
        if (file.isFile) file.readText().trim().toLongOrNull() ?: 0L else 0L

    fun save(value: Long) {
        dir.mkdirs()
        val tmp = File(dir, "backup.watermark.tmp")
        tmp.writeText(value.toString())
        check(tmp.renameTo(file)) { "cannot persist watermark" }
    }
}
