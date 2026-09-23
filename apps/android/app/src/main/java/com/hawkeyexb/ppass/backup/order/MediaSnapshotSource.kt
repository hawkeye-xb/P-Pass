// ARCH-12 (#416) / ARCH-13 (#417): MediaStore 快照读取——只读、不算 hash、不联系桌面。
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
 * MediaStore 里的一张照片/视频（不论是否在备份范围内——#416 裁决 1）。
 *
 * [generation] 只用来推进快路径游标 G，**不是身份**（MOB-98）：API ≥ 30 是
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
    /** DATE_TAKEN 优先，缺失时退到 DATE_ADDED（见 [captureAtMsOrDateAdded]）。 */
    val captureAtMs: Long,
)

interface MediaSnapshotSource {
    /**
     * 慢路径：MediaStore 里**全部**图片与视频（#416 裁决 1：不按相册过滤，带上 `bucket_id`），
     * 按 `_id` 严格升序流式读出。流只在 [block] 内有效。
     *
     * 为什么不过滤：照片还在、只是相册移出了范围（→ CANCELLED_BY_SCOPE），与照片真的没了
     * （→ Gone），只有看全量才分得开。
     */
    fun <R> readAll(block: (Sequence<MediaSnapshot>) -> R): R

    /**
     * 快路径：[volumeName] 卷上 `generation > [afterGeneration]`、**范围内**的照片，
     * 按 (generation, `_id`) 升序。结果只是加速提示——漏掉的照片由 [readAll] 那条慢路径补上。
     */
    fun <R> readChangedSince(volumeName: String, afterGeneration: Long, block: (Sequence<MediaSnapshot>) -> R): R

    /** 当前挂着的外部卷（#416 裁决 7：G 按卷分开存）。 */
    fun volumeNames(): List<String>

    /** 每个外部卷当前的 `MediaStore.getVersion`；拿不到（API < 29）时为空表。 */
    fun volumeVersions(): Map<String, String>

    /** 这张照片现在的样子；MediaStore 里已经没有了返回 null。 */
    fun lookup(mediaId: Long): MediaDetails?
}

/**
 * [MediaSnapshotSource] 的 ContentResolver 实现。
 *
 * 范围口径与旧 discovery 一致：`MEDIA_TYPE` 为图片或视频，快路径另加 `BUCKET_ID` 在
 * [selectedBuckets] 里；[selectedBuckets] 返回 null 或空集 = 什么都不在范围内。
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
     * 后者粒度是秒、而且会被改系统时间/拷入旧文件打乱——它**只是加速提示**
     * （#415 裁决 1），正确性由慢路径全量归并保证，不依赖它单调。
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

    override fun <R> readAll(block: (Sequence<MediaSnapshot>) -> R): R =
        query(external, mediaTypeSelection, mediaTypeArgs, "${MediaStore.MediaColumns._ID} ASC", LEGACY_VOLUME, block)

    override fun <R> readChangedSince(volumeName: String, afterGeneration: Long, block: (Sequence<MediaSnapshot>) -> R): R {
        val buckets = selectedBuckets()
        if (buckets.isNullOrEmpty()) return block(emptySequence())
        // bucket id 是 Long，直接拼进 SQL 与旧 discovery 口径一致，且不占绑定变量名额。
        val selection = "$mediaTypeSelection AND ${MediaStore.MediaColumns.BUCKET_ID} IN (${buckets.joinToString(",")}) AND $generationColumn > ?"
        return query(
            collectionOf(volumeName),
            selection,
            mediaTypeArgs + afterGeneration.toString(),
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
        val columns = (
            projection.toList() + listOf(
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.MIME_TYPE,
                MediaStore.MediaColumns.DATE_TAKEN,
                MediaStore.MediaColumns.DATE_ADDED,
            )
            ).distinct().toTypedArray()
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
                captureAtMs = captureAtMsOrDateAdded(
                    rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)),
                    rows.getLong(rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)),
                ),
            )
        }
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

/**
 * MediaStore `DATE_TAKEN` 优先（毫秒，多数相机 App 的真实拍摄时间）；
 * 为 0（列缺失/未知）时退到 `DATE_ADDED`（秒，第三方 App —— 实测飞书 —— 保存
 * 图片时唯一还留着的时间信号）。两者都拿不到才是真的 0，交给 Desktop 端的
 * EXIF/mtime 兜底链继续处理（DESK-12）。
 */
internal fun captureAtMsOrDateAdded(dateTakenMs: Long, dateAddedSec: Long): Long {
    if (dateTakenMs > 0) return dateTakenMs
    return if (dateAddedSec > 0) dateAddedSec * 1000 else 0L
}
