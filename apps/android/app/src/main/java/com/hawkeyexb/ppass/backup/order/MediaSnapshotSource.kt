// ARCH-12 (#416): MediaStore 快照读取——只读、不算 hash、不联系桌面。
package com.hawkeyexb.ppass.backup.order

import android.content.ContentResolver
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import com.hawkeyexb.ppass.backup.flow.sourceVersionOf

/**
 * MediaStore 里范围内的一张照片/视频。
 *
 * [generation] 只用来推进快路径游标 G，**不是身份**（MOB-98）：API ≥ 30 是
 * `GENERATION_MODIFIED`，API < 30 退回 `DATE_MODIFIED`（秒）。
 */
data class MediaSnapshot(
    val mediaId: Long,
    val sourceVersion: String,
    val bucketId: Long,
    val generation: Long,
)

interface MediaSnapshotSource {
    /** 慢路径：范围内全部照片，按 `_id` 严格升序流式读出。流只在 [block] 内有效。 */
    fun <R> readAll(block: (Sequence<MediaSnapshot>) -> R): R

    /**
     * 快路径：`generation > [afterGeneration]` 的范围内照片，按 (generation, `_id`) 升序。
     * 结果只是加速提示——漏掉的照片由 [readAll] 那条慢路径补上。
     */
    fun <R> readChangedSince(afterGeneration: Long, block: (Sequence<MediaSnapshot>) -> R): R

    /** 每个外部卷当前的 `MediaStore.getVersion`；拿不到（API < 29）时为空表。 */
    fun volumeVersions(): Map<String, String>
}

/**
 * [MediaSnapshotSource] 的 ContentResolver 实现。
 *
 * 范围口径与 `AndroidFlowDiscoveryPort` 一致：`MEDIA_TYPE` 为图片或视频，且 `BUCKET_ID`
 * 在 [selectedBuckets] 里；[selectedBuckets] 返回 null 或空集 = 什么都不在范围内。
 *
 * 游标不分页：单个查询、一行一行 `moveToNext`，内存里只有当前一行。
 */
class ContentResolverMediaSnapshotSource(
    private val context: Context,
    private val selectedBuckets: () -> Set<Long>?,
    private val resolver: ContentResolver = context.contentResolver,
) : MediaSnapshotSource {

    private val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)

    /**
     * API ≥ 30 用 `GENERATION_MODIFIED`；API < 30 没有这一列，退回 `DATE_MODIFIED`。
     * 后者粒度是秒、而且会被改系统时间/拷入旧文件打乱——它**只是加速提示**，
     * 正确性由慢路径全量归并保证，不依赖它单调。
     */
    private val generationColumn: String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            MediaStore.MediaColumns.GENERATION_MODIFIED
        } else {
            MediaStore.MediaColumns.DATE_MODIFIED
        }

    private val projection = arrayOf(
        MediaStore.MediaColumns._ID,
        MediaStore.MediaColumns.DATE_MODIFIED,
        MediaStore.MediaColumns.SIZE,
        MediaStore.MediaColumns.BUCKET_ID,
        generationColumn,
    ).distinct().toTypedArray()

    override fun <R> readAll(block: (Sequence<MediaSnapshot>) -> R): R =
        query(extraSelection = null, extraArgs = emptyArray(), sortOrder = "${MediaStore.MediaColumns._ID} ASC", block = block)

    override fun <R> readChangedSince(afterGeneration: Long, block: (Sequence<MediaSnapshot>) -> R): R =
        query(
            extraSelection = "$generationColumn > ?",
            extraArgs = arrayOf(afterGeneration.toString()),
            sortOrder = "$generationColumn ASC, ${MediaStore.MediaColumns._ID} ASC",
            block = block,
        )

    override fun volumeVersions(): Map<String, String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
            MediaStore.getExternalVolumeNames(context).associateWith { MediaStore.getVersion(context, it) }
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
            mapOf(MediaStore.VOLUME_EXTERNAL to MediaStore.getVersion(context))
        else -> emptyMap()
    }

    private fun <R> query(
        extraSelection: String?,
        extraArgs: Array<String>,
        sortOrder: String,
        block: (Sequence<MediaSnapshot>) -> R,
    ): R {
        val buckets = selectedBuckets()
        if (buckets.isNullOrEmpty()) return block(emptySequence())
        val selection = buildString {
            append("${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)")
            // bucket id 是 Long，直接拼进 SQL 与现有 discovery 口径一致，且不占绑定变量名额。
            append(" AND ${MediaStore.MediaColumns.BUCKET_ID} IN (${buckets.joinToString(",")})")
            if (extraSelection != null) append(" AND $extraSelection")
        }
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
        ) + extraArgs
        val cursor = resolver.query(collection, projection, selection, args, sortOrder)
            ?: return block(emptySequence())
        return cursor.use { rows ->
            val id = rows.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val modified = rows.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val size = rows.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val bucket = rows.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
            val gen = rows.getColumnIndexOrThrow(generationColumn)
            block(
                generateSequence {
                    if (!rows.moveToNext()) {
                        null
                    } else {
                        MediaSnapshot(
                            mediaId = rows.getLong(id),
                            // MOB-98：版本只看内容有没有变，generation 不进来。
                            sourceVersion = sourceVersionOf(rows.getLong(modified), rows.getLong(size)),
                            bucketId = rows.getLong(bucket),
                            generation = rows.getLong(gen),
                        )
                    }
                },
            )
        }
    }
}
