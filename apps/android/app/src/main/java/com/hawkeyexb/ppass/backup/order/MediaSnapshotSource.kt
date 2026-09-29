// ARCH-12 (#416) / ARCH-13 (#417) → #413: MediaStore 快照读取——只读元数据、不读文件、不联系桌面。
package com.hawkeyexb.ppass.backup.order

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import com.hawkeyexb.ppass.backup.flow.sourceVersionOf

/** API < 29 没有卷名这一列，所有外部存储都算这一个卷。 */
const val LEGACY_VOLUME = MediaStore.VOLUME_EXTERNAL

/**
 * MediaStore 里的一张照片/视频。
 *
 * [generation] 只用来推进发现游标 G，**不是身份**（MOB-98）：API ≥ 30 是
 * `GENERATION_MODIFIED`，API < 30 退回 `DATE_MODIFIED`（秒）。
 */
data class MediaSnapshot(
    val mediaId: Long,
    val sourceVersion: String,
    val bucketId: Long,
    val generation: Long,
    val volumeName: String = LEGACY_VOLUME,
)

/** 传输一张照片需要的全部 MediaStore 事实。 */
data class MediaDetails(
    val snapshot: MediaSnapshot,
    val uri: String,
    val fileName: String,
    val mimeType: String,
    val sizeBytes: Long,
    /** DATE_TAKEN → DATE_MODIFIED → DATE_ADDED 依次回退（见 [captureAtMsOf]）。 */
    val captureAtMs: Long,
    /** MediaStore `_data`（真实路径，引用导入用）；API 29 或查不到时为 null，导入直接走复制（#413 契约 §4）。 */
    val dataPath: String? = null,
)

interface MediaSnapshotSource {
    /**
     * 对账扫描 / 精确计数：**范围内** `_id > [afterId]` 的图片与视频，按 `_id` 严格升序流式读出。流只在 [block] 内有效。
     */
    fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R

    /**
     * 发现：[volumeName] 卷上按 (generation, `_id`) 排在 ([afterGeneration], [afterMediaId]) 之后、**范围内**的照片，
     * 按 (generation, `_id`) 升序。G 以下的照片（新相册的历史照片、恢复的、重建后的）由对账扫描负责。
     */
    fun <R> readChangedSince(volumeName: String, afterGeneration: Long, afterMediaId: Long, block: (Sequence<MediaSnapshot>) -> R): R

    /** [volumeName] 卷上当前最大的 generation（0 = 空卷）。G 缺失 / MediaStore 重建时 G 从这里起步。 */
    fun maxGeneration(volumeName: String): Long

    /** generation 是否精确（API ≥ 30 的 `GENERATION_MODIFIED`）。退回 `DATE_MODIFIED`（秒）时发现可能漏同一秒的照片，对账要扫。 */
    val preciseGeneration: Boolean get() = true

    /** 当前挂着的外部卷（#416 裁决 7：G 按卷分开存）。 */
    fun volumeNames(): List<String>

    /** 每个外部卷当前的 `MediaStore.getVersion`；拿不到（API < 29）时为空表。 */
    fun volumeVersions(): Map<String, String>

    /** 这张照片现在的样子；MediaStore 里已经没有了返回 null。 */
    fun lookup(mediaId: Long): MediaDetails?

    /**
     * #459：[mediaIds] 里哪些此刻还在 MediaStore 里（图片 / 视频，**不看范围**——挪到别的相册也算在）。
     * 返回 null = 这次读不出来（查询返回 null 游标）：调用方必须当「不知道」，**不许**当「全都没了」。
     * 注意「不在」只在完整相册权限下才等于「被删了」（部分授权下看不见的也不在结果里），由调用方把关。
     */
    fun existingIds(mediaIds: Collection<Long>): Set<Long>?
}

/**
 * [MediaSnapshotSource] 的 ContentResolver 实现。
 *
 * 范围口径与旧 discovery 一致：`MEDIA_TYPE` 为图片或视频，`BUCKET_ID` 在 [selectedBuckets] 里；
 * [selectedBuckets] 返回 null 或空集 = 什么都不在范围内。
 *
 * 游标不分页：单个查询、一行一行 `moveToNext`，内存里只有当前一行。
 */
class ContentResolverMediaSnapshotSource(
    private val context: Context,
    private val selectedBuckets: () -> Set<Long>?,
    private val resolver: ContentResolver = context.contentResolver,
) : MediaSnapshotSource {

    private val external = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)

    /**
     * API ≥ 30 用 `GENERATION_MODIFIED`；API < 30 没有这一列，退回 `DATE_MODIFIED`。
     * 后者粒度是秒、而且会被改系统时间/拷入旧文件打乱——这时对账每次都扫（[preciseGeneration]）。
     */
    private val generationColumn: String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            MediaStore.MediaColumns.GENERATION_MODIFIED
        } else {
            MediaStore.MediaColumns.DATE_MODIFIED
        }

    private val volumeColumn: String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.MediaColumns.VOLUME_NAME else null

    private val projection = listOfNotNull(
        MediaStore.MediaColumns._ID,
        MediaStore.MediaColumns.DATE_MODIFIED,
        MediaStore.MediaColumns.SIZE,
        MediaStore.MediaColumns.BUCKET_ID,
        generationColumn,
        volumeColumn,
    ).distinct().toTypedArray()

    private val mediaTypeSelection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)"
    private val mediaTypeArgs = arrayOf(
        MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
        MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
    )

    override val preciseGeneration: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    override fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
        val buckets = selectedBuckets()
        if (buckets.isNullOrEmpty()) return block(emptySequence())
        val selection = "$mediaTypeSelection AND ${MediaStore.MediaColumns.BUCKET_ID} IN (${buckets.joinToString(",")}) AND ${MediaStore.MediaColumns._ID} > ?"
        return query(external, selection, mediaTypeArgs + afterId.toString(), "${MediaStore.MediaColumns._ID} ASC", LEGACY_VOLUME, block)
    }

    override fun maxGeneration(volumeName: String): Long {
        val cursor = resolver.query(
            collectionOf(volumeName),
            arrayOf(generationColumn),
            mediaTypeSelection,
            mediaTypeArgs,
            "$generationColumn DESC",
        ) ?: return 0L
        return cursor.use { if (it.moveToFirst()) it.getLong(0) else 0L }
    }

    override fun <R> readChangedSince(volumeName: String, afterGeneration: Long, afterMediaId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
        val buckets = selectedBuckets()
        if (buckets.isNullOrEmpty()) return block(emptySequence())
        // bucket id 是 Long，直接拼进 SQL 与旧 discovery 口径一致，且不占绑定变量名额。
        val id = MediaStore.MediaColumns._ID
        val selection = "$mediaTypeSelection AND ${MediaStore.MediaColumns.BUCKET_ID} IN (${buckets.joinToString(",")}) " +
            "AND ($generationColumn > ? OR ($generationColumn = ? AND $id > ?))"
        return query(
            collectionOf(volumeName),
            selection,
            mediaTypeArgs + arrayOf(afterGeneration.toString(), afterGeneration.toString(), afterMediaId.toString()),
            "$generationColumn ASC, ${MediaStore.MediaColumns._ID} ASC",
            volumeName,
            block,
        )
    }

    override fun volumeNames(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.getExternalVolumeNames(context).sorted()
        } else {
            listOf(LEGACY_VOLUME)
        }

    override fun volumeVersions(): Map<String, String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
            MediaStore.getExternalVolumeNames(context).associateWith { MediaStore.getVersion(context, it) }
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
            mapOf(MediaStore.VOLUME_EXTERNAL to MediaStore.getVersion(context))
        else -> emptyMap()
    }

    override fun lookup(mediaId: Long): MediaDetails? {
        val columns = lookupColumns(projection.toList())
        val cursor = resolver.query(
            external,
            columns,
            "${MediaStore.MediaColumns._ID} = ? AND $mediaTypeSelection",
            arrayOf(mediaId.toString()) + mediaTypeArgs,
            null,
        ) ?: return null
        return cursor.use { rows ->
            if (!rows.moveToFirst()) return null
            val snapshot = snapshotOf(rows, LEGACY_VOLUME)
            MediaDetails(
                snapshot = snapshot,
                uri = Uri.withAppendedPath(external, mediaId.toString()).toString(),
                fileName = rows.getString(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)).orEmpty(),
                mimeType = rows.getString(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)) ?: "application/octet-stream",
                sizeBytes = rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)),
                captureAtMs = captureAtMsOf(rows),
                // API 29 的分区存储下 `_data` 不可直读；拿不到就是 null，导入走复制。
                dataPath = if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
                    null
                } else {
                    @Suppress("DEPRECATION")
                    rows.getColumnIndex(MediaStore.MediaColumns.DATA).takeIf { it >= 0 }?.let { rows.getString(it) }?.takeIf { it.isNotBlank() }
                },
            )
        }
    }

    override fun existingIds(mediaIds: Collection<Long>): Set<Long>? {
        val out = HashSet<Long>()
        // id 是 Long，直接拼进 SQL（与 BUCKET_ID IN 同一做法），分批避免超长语句。
        for (chunk in mediaIds.distinct().chunked(EXISTING_IDS_CHUNK)) {
            val cursor = resolver.query(
                external,
                arrayOf(MediaStore.MediaColumns._ID),
                "$mediaTypeSelection AND ${MediaStore.MediaColumns._ID} IN (${chunk.joinToString(",")})",
                mediaTypeArgs,
                null,
            ) ?: return null
            cursor.use { rows -> while (rows.moveToNext()) out += rows.getLong(0) }
        }
        return out
    }

    private fun collectionOf(volumeName: String): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.Files.getContentUri(volumeName) else external

    private fun snapshotOf(rows: android.database.Cursor, fallbackVolume: String): MediaSnapshot {
        val volume = volumeColumn?.let { rows.getColumnIndex(it) }?.takeIf { it >= 0 }?.let { rows.getString(it) }
        return MediaSnapshot(
            mediaId = rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)),
            // MOB-98：版本只看内容有没有变，generation 不进来。
            sourceVersion = sourceVersionOf(
                rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)),
                rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)),
            ),
            bucketId = rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)),
            generation = rows.getLong(rows.getColumnIndexOrThrow(generationColumn)),
            volumeName = volume ?: fallbackVolume,
        )
    }

    private fun <R> query(
        collection: Uri,
        selection: String,
        args: Array<String>,
        sortOrder: String,
        fallbackVolume: String,
        block: (Sequence<MediaSnapshot>) -> R,
    ): R {
        val cursor = resolver.query(collection, projection, selection, args, sortOrder)
            ?: return block(emptySequence())
        return cursor.use { rows ->
            block(generateSequence { if (!rows.moveToNext()) null else snapshotOf(rows, fallbackVolume) })
        }
    }
}

private const val EXISTING_IDS_CHUNK = 500

/** 算 captureAt 要读的三列。[lookupColumns] 必须带上它们，否则 [captureAtMsOf] 取列直接抛错（MOB-99）。 */
internal val CAPTURE_AT_COLUMNS = listOf(
    MediaStore.MediaColumns.DATE_TAKEN,
    MediaStore.MediaColumns.DATE_MODIFIED,
    MediaStore.MediaColumns.DATE_ADDED,
)

/**
 * [ContentResolverMediaSnapshotSource.lookup] 的投影：[snapshotColumns]（快照本身要的列）加上传输要的列。
 * `DATE_MODIFIED` 虽然快照也要（算 sourceVersion），这里仍经 [CAPTURE_AT_COLUMNS] 显式带上，不靠巧合。
 */
internal fun lookupColumns(snapshotColumns: List<String>): Array<String> = (
    snapshotColumns + listOf(
        MediaStore.MediaColumns.DISPLAY_NAME,
        MediaStore.MediaColumns.MIME_TYPE,
        @Suppress("DEPRECATION") MediaStore.MediaColumns.DATA,
    ) + CAPTURE_AT_COLUMNS
    ).distinct().toTypedArray()

/** 从 [lookupColumns] 查出来的当前行读 captureAt；缺列抛 [IllegalArgumentException]，不静默当 0。 */
internal fun captureAtMsOf(rows: android.database.Cursor): Long = captureAtMsOf(
    dateTakenMs = rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)),
    dateModifiedSec = rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)),
    dateAddedSec = rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)),
)

/**
 * 回退链 `DATE_TAKEN → DATE_MODIFIED → DATE_ADDED`：
 * - `DATE_TAKEN`（毫秒）：多数相机 App 写的真实拍摄时间，优先。
 * - `DATE_MODIFIED`（秒）：文件 mtime。第三方 App（实测微信、飞书）存的图没有 DATE_TAKEN；再被移动/
 *   拷贝进相册时 mtime 保留原文件的时间（MOB-99 鸿蒙真机实测与文件名里的时间戳逐秒吻合）。
 * - `DATE_ADDED`（秒）：入 MediaStore 的时刻，对移进来的老照片就是移动那一刻，只作最后一级。
 *
 * 取舍：原地编辑过的图 mtime 是编辑时间，可能比 DATE_ADDED 还晚、离拍摄更远；但移动/拷入场景下
 * DATE_ADDED 必然是移动时刻，而这正是没有 DATE_TAKEN 的图最常见的来路，所以 DATE_MODIFIED 排在前面。
 * 三者都拿不到才是真的 0，交给 Desktop 端的 EXIF/mtime 兜底链继续处理（DESK-12）。
 */
internal fun captureAtMsOf(dateTakenMs: Long, dateModifiedSec: Long, dateAddedSec: Long): Long {
    if (dateTakenMs > 0) return dateTakenMs
    if (dateModifiedSec > 0) return dateModifiedSec * 1000
    return if (dateAddedSec > 0) dateAddedSec * 1000 else 0L
}
