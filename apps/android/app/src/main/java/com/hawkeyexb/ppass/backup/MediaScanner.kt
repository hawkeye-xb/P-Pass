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
    /** MediaStore DATE_MODIFIED (seconds, all API levels). PERF-01:
     *  the hash-cache key falls back to this + size below API 30. */
    val dateModified: Long,
    /** MediaStore BUCKET_ID（所属相册）。FIX-T6: 三元组范围口径 +
     *  确认缓存按范围计数（记录备份时从 MediaItem 带过来）。 */
    val bucketId: Long?,
)

data class ScanResult(
    val items: List<MediaItem>,
    /** Watermark to persist AFTER these items are committed. */
    val nextWatermark: Long,
)

class MediaScanner(private val resolver: ContentResolver?) {
    // FIX-T6: resolver 可空——空集守卫路径（scanSince/countAll 的空集
    // 分支）在触碰 resolver 之前返回，JVM 单测用 null resolver 即可
    // 验证「不发查询」；任何真实查询路径先 checkNotNull（生产恒传
    // context.contentResolver，行为不变；null 抛 IllegalArgumentException
    // 与三星 provider 拒绝同型，MediaQueryFailureTest 既有的 Throwable
    // 兜底契约覆盖）。

    private fun requireResolver(): ContentResolver =
        checkNotNull(resolver) { "MediaScanner requires a ContentResolver" }

    /** A photo/video album (MediaStore bucket) with its item count. */
    data class Bucket(val id: Long, val name: String, val count: Int)

    /**
     * All albums, each with a total item count (photos+videos). T6:
     * the user picks which albums to back up — WeChat/QQ albums etc.
     * can be left out. Empty name buckets are grouped as 未命名.
     */
    fun listBuckets(): List<Bucket> {
        val byId = LinkedHashMap<Long, MutableList<String>>()
        for ((collection, _) in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI to false,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI to true,
        )) {
            val projection = arrayOf(
                MediaStore.MediaColumns.BUCKET_ID,
                MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            )
            requireResolver().query(collection, projection, null, null, null)?.use { cur ->
                val idIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
                val nameIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
                while (cur.moveToNext()) {
                    val id = cur.getLong(idIdx)
                    val name = cur.getString(nameIdx)?.takeIf { it.isNotBlank() } ?: "未命名"
                    byId.getOrPut(id) { mutableListOf() }.add(name)
                }
            }
        }
        return byId.map { (id, names) -> Bucket(id, names.first(), names.size) }
            .sortedBy { it.name.lowercase() }
    }

    /**
     * All photos+videos newer than [watermark] (or all of them when
     * [bucketIds] selects albums), oldest-first. T6: bucketIds limits the
     * scan to the user-selected albums; null = everything (legacy).
     */
    fun scanSince(watermark: Long, bucketIds: Set<Long>? = null): ScanResult {
        // FIX-T6: 空集 = 一个都不备（用户全取消）——直接返回空结果，
        // 不发查询（顺手消掉「空 IN ()」类 SQL 风险）；水位不推进
        // （nextWatermark = watermark，自动备份 no-op 不会越过范围）。
        if (bucketIds != null && bucketIds.isEmpty()) {
            return ScanResult(emptyList(), watermark)
        }
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
                MediaStore.MediaColumns.DATE_MODIFIED,
                MediaStore.MediaColumns.BUCKET_ID,
            )
            val where = buildString {
                append("$genCol > ?")
                if (!bucketIds.isNullOrEmpty()) {
                    append(" AND ${MediaStore.MediaColumns.BUCKET_ID} IN (")
                    append(bucketIds.joinToString(","))
                    append(")")
                }
            }
            requireResolver().query(
                collection, projection, where, arrayOf(watermark.toString()),
                "$genCol ASC",
            )?.use { cur ->
                val idIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val mimeIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val sizeIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val genIdx = cur.getColumnIndexOrThrow(genCol)
                val modifiedIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                val bucketIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
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
                            dateModified = cur.getLong(modifiedIdx),
                            bucketId = if (cur.isNull(bucketIdx)) null else cur.getLong(bucketIdx),
                        )
                    )
                }
            }
        }
        items.sortBy { it.generation }
        return ScanResult(items, maxGen)
    }

    /** 当前扫描范围的全量 count（无 generation 过滤）——DOG-01b 三元组
     * 的分母 N。MediaStore COUNT 查询，便宜，不需要重 hash。口径常量
     * 一处定义（范围选择是另一张卡，改范围只动这里）。
     *
     * DOG-01d: 合规写法——projection 只放 [_ID]，用 cursor.count 取数。
     * 三星真机实锤：scoped storage 的 provider 拒绝 projection 里的 SQL
     * 函数（"Invalid column count(*)"），启动必闪退。查询异常不在此处
     * 吞——由 computeTripletSafe（refreshTriplet 生产实现）Throwable 级
     * 兜底为「三元组不显示」，绝不崩 App。
     */
    fun countAll(bucketIds: Set<Long>? = null): Long {
        // FIX-T6: 空集 = 一个都不备 → 0（不发查询）。
        if (bucketIds != null && bucketIds.isEmpty()) return 0L
        var total = 0L
        for (collection in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
        )) {
            val where = if (!bucketIds.isNullOrEmpty()) {
                "${MediaStore.MediaColumns.BUCKET_ID} IN (${bucketIds.joinToString(",")})"
            } else null
            requireResolver().query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                where,
                null,
                null,
            )?.use { cur -> total += cur.count.toLong() }
        }
        return total
    }

    /** PERF-01: MediaStore 现存所有行（images+videos）的 content uri 集。
     *  只投影 _ID，便宜；供 hash-cache 孤儿清理（prune）对齐现存 _ID
     *  集合用——照片被删/相册被清后，缓存里的孤儿条目随下次校准清掉。 */
    fun allItemUris(): Set<String> {
        val uris = mutableSetOf<String>()
        for (collection in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
        )) {
            requireResolver().query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                null,
                null,
                null,
            )?.use { cur ->
                val idIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                while (cur.moveToNext()) {
                    uris.add(ContentUris.withAppendedId(collection, cur.getLong(idIdx)).toString())
                }
            }
        }
        return uris
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
