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

    /** A photo/video album (MediaStore bucket) with its item count.
     *  UX-10: [coverUri] = 相册内最新一项（按 DATE_ADDED 比较，跨
     *  图片/视频两个 collection 取全局最新）——BucketScreen 拿它解码
     *  封面缩略图，模拟系统相册选择器的交互；取不到（老数据/异常）
     *  时为 null，UI 退化为空白封面，不阻塞选择流程。 */
    data class Bucket(val id: Long, val name: String, val count: Int, val coverUri: Uri? = null)

    /**
     * All albums, each with a total item count (photos+videos). T6:
     * the user picks which albums to back up — WeChat/QQ albums etc.
     * can be left out. Empty name buckets are grouped as 未命名.
     */
    fun listBuckets(): List<Bucket> {
        val byId = LinkedHashMap<Long, MutableList<String>>()
        val coverUri = mutableMapOf<Long, Uri>()
        val coverDate = mutableMapOf<Long, Long>()
        for ((collection, _) in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI to false,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI to true,
        )) {
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.BUCKET_ID,
                MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
                MediaStore.MediaColumns.DATE_ADDED,
            )
            requireResolver().query(collection, projection, null, null, null)?.use { cur ->
                val idIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val bucketIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
                val nameIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
                val dateIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
                while (cur.moveToNext()) {
                    val id = cur.getLong(bucketIdx)
                    val name = cur.getString(nameIdx)?.takeIf { it.isNotBlank() } ?: "未命名"
                    byId.getOrPut(id) { mutableListOf() }.add(name)
                    val date = cur.getLong(dateIdx)
                    if (date > (coverDate[id] ?: -1L)) {
                        coverDate[id] = date
                        coverUri[id] = ContentUris.withAppendedId(collection, cur.getLong(idIdx))
                    }
                }
            }
        }
        return byId.map { (id, names) -> Bucket(id, names.first(), names.size, coverUri[id]) }
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

    /**
     * MOB-36: 已选相册里、水位**之下**的行——增量扫描 (`scanSince`) 的补集。
     *
     * 在相册之间移动一张照片不改 `_ID` / `date_added` / `date_modified`，只改
     * `bucket_id`；于是「移进已选相册的老照片」的水位值远在当前水位之下，增量
     * 扫描永远看不见它。这一查把范围内的水位下行捞回来，由
     * [planScopeBackfill] 靠 `files` / 哈希缓存两张现成的表筛出真的没备过的
     * 那些（**返回集不许全量哈希**——那是本方案成立的全部前提）。
     *
     * 只投影元数据（哈希缓存 key 需要 generation / dateModified / size），
     * **一个 collection 一次查询**，不按条发查询；范围由
     * `BUCKET_ID IN (…)` 约束——移**出**已选相册的照片天然不在结果里，
     * 一行也不会被补（卡面验收⑤）。
     *
     * 两条零成本早退：范围为 null（从未选过 = 全量模式，没有「范围边界」
     * 可跨，本卡的 bug 不存在）或空集；水位为 0（没有「之下」，且手动全量
     * 重扫 `since=0` 时增量扫描已覆盖全部）——都一次查询都不发。
     *
     * **不返回 nextWatermark**：补齐条目在水位之下，不参与水位推进
     * （`MOB-09` 的坏记录跳过语义原样保留）。返回类型就把这条钉死。
     */
    fun scanScopeBelow(watermark: Long, bucketIds: Set<Long>?): List<MediaItem> {
        if (bucketIds.isNullOrEmpty() || watermark <= 0L) return emptyList()
        val items = mutableListOf<MediaItem>()
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
            // bucketIds 是我们自己解析出来的 Long（BackupScopeStore 只认
            // toLongOrNull），拼进 IN () 没有注入面。
            val where = "$genCol <= ? AND " +
                "${MediaStore.MediaColumns.BUCKET_ID} IN (${bucketIds.joinToString(",")})"
            requireResolver().query(
                collection, projection, where, arrayOf(watermark.toString()), "$genCol ASC",
            )?.use { cur ->
                val idIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val mimeIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val sizeIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val genIdx = cur.getColumnIndexOrThrow(genCol)
                val modifiedIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                val bucketIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
                while (cur.moveToNext()) {
                    items.add(
                        MediaItem(
                            uri = ContentUris.withAppendedId(collection, cur.getLong(idIdx)),
                            displayName = cur.getString(nameIdx) ?: "unnamed",
                            mimeType = cur.getString(mimeIdx)
                                ?: if (isVideo) "video/*" else "image/*",
                            bytes = cur.getLong(sizeIdx),
                            generation = cur.getLong(genIdx),
                            dateModified = cur.getLong(modifiedIdx),
                            bucketId = if (cur.isNull(bucketIdx)) null else cur.getLong(bucketIdx),
                        )
                    )
                }
            }
        }
        return items
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

    /**
     * MOB-34: **定向**取回这几条 MediaStore 记录（不是全量重扫）。
     *
     * [keys] 是 fileKey（`content://media/external/{images,video}/media/<_ID>`，
     * 与 [ConfirmedState.files] 同 key）。按 collection 前缀分组、只查这几个
     * `_ID`——查询代价与队列长度成正比，与相册规模无关。这是卡面第 3 条
     * 「补偿只针对校准查出来缺的那些 hash，不退化成每轮全量重扫」的实现点。
     *
     * 重建出来的 uri 必须与原 fileKey **字符串全等**才算配上：_ID 撞车
     * （images 与 video 各有自己的 _ID 序列）或 uri 格式漂移时，宁可当「查
     * 无此行」丢掉队列条目，也绝不把一张不相干的照片传上去。
     *
     * 查不到的行不在返回值里——调用方据此把队列条目丢掉（[planReuploads]）。
     */
    fun itemsByKeys(keys: Set<String>): List<MediaItem> {
        if (keys.isEmpty()) return emptyList()
        val items = mutableListOf<MediaItem>()
        for ((collection, isVideo) in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI to false,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI to true,
        )) {
            val ids = mediaIdsOf(keys, collection.toString())
            if (ids.isEmpty()) continue
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
            // _ID 是我们自己从 uri 里解析出来的**纯数字**（mediaIdsOf 只认
            // 全数字），拼进 IN () 没有注入面。
            val where = "${MediaStore.MediaColumns._ID} IN (${ids.joinToString(",")})"
            requireResolver().query(collection, projection, where, null, null)?.use { cur ->
                val idIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val mimeIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val sizeIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val genIdx = cur.getColumnIndexOrThrow(genCol)
                val modifiedIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                val bucketIdx = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
                while (cur.moveToNext()) {
                    val uri = ContentUris.withAppendedId(collection, cur.getLong(idIdx))
                    if (uri.toString() !in keys) continue
                    items.add(
                        MediaItem(
                            uri = uri,
                            displayName = cur.getString(nameIdx) ?: "unnamed",
                            mimeType = cur.getString(mimeIdx)
                                ?: if (isVideo) "video/*" else "image/*",
                            bytes = cur.getLong(sizeIdx),
                            generation = cur.getLong(genIdx),
                            dateModified = cur.getLong(modifiedIdx),
                            bucketId = if (cur.isNull(bucketIdx)) null else cur.getLong(bucketIdx),
                        )
                    )
                }
            }
        }
        return items
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
