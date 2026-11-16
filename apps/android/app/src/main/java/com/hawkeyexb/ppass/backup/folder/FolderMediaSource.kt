// #1762 目录来源 → 现有 [MediaSnapshotSource] 的适配。ADR docs/decisions/2026-11-13-local-folder-media-source.md §2/§3/§4：
// - 递归枚举目录内照片/视频元数据，经 FolderRegistry 分配 Long mediaId/bucketId（bit 62 命名空间）进现有 order 流程；
// - readInScope = 对账扫描：完整枚举成功 → registry.reconcile（新项分配、缺席删除）；**授权失效抛
//   [SourceUnavailableException]**，不返回空列表冒充「没有文件」；
// - readChangedSince 恒空、maxGeneration 0、volumeNames 空：目录新项只在 reconcile 轮被发现（ADR §4），
//   Folder 不参与 G 游标与卷口径；
// - lookup 单文件：文件没了 → null（源缺失）；授权失效 → SourceUnavailableException（不许混）；
// - existingIds：只在「最近一次完整枚举成功后」的映射上回答（对账轮的顺序保证：reconcileSourcePresence
//   先 readInScope 再 existingIds）。
package com.hawkeyexb.ppass.backup.folder

import android.content.Context
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.net.Uri
import com.hawkeyexb.ppass.backup.BackupScope
import com.hawkeyexb.ppass.backup.flow.sourceVersionOf
import com.hawkeyexb.ppass.backup.order.MediaDetails
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import com.hawkeyexb.ppass.backup.order.MediaSnapshotSource
import com.hawkeyexb.ppass.backup.scopeTimeSecOf
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** folder 快照的 volumeName 占位（不进 volumeNames/volumeVersions，只进快照字段）。 */
const val FOLDER_VOLUME = "folder"

/** 只照片和视频：mimeType 前缀判（生产 SAF 直接给 MIME，测试侧 File 实现按扩展名给同口径 MIME）。 */
fun isMediaMime(mimeType: String): Boolean =
    mimeType.startsWith("image/") || mimeType.startsWith("video/")

/**
 * 目录来源。[treeFor] 把已登记来源映射到一个已授权的树访问（生产给 [SafFolderTree]，测试给 [FileFolderTree]）。
 * 线程模型：与引擎一致——对账/计数/lookup 全在引擎的 io 线程串行；registry 自带锁。
 */
class FolderMediaSnapshotSource(
    private val registry: FolderRegistry,
    private val scopeProvider: (() -> BackupScope?)? = null,
    private val captureAtMs: (FolderTree, FolderFile) -> Long? = { _, _ -> null },
    private val treeFor: (FolderRecord) -> FolderTree,
) : MediaSnapshotSource {

    /**
     * 对账扫描：每个现存来源完整枚举一次（授权失效抛 [SourceUnavailableException]，整轮等待）。
     * 枚举成功 → reconcile（新项分配 Long ID、缺席项删除并按源缺失走 existingIds 流程）。
     * 输出按 mediaId 严格升序（ID 全局分配不重复，直接排序）。
     */
    override fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
        val scope = scopeProvider?.invoke()
        val scans = registry.allRecords().mapNotNull { record ->
            if (scope != null && record.bucketId !in scope.buckets) return@mapNotNull null
            if (scopeProvider != null && scope == null) return@mapNotNull null
            val tree = treeFor(record)
            // 枚举与对账必须先完成：授权失效在交给 block 前抛出，不能因消费方不遍历而吞掉。
            val files = tree.enumerate().filter { isMediaMime(it.mimeType) }
            registry.reconcile(record.id, files.map { it.relativePath })
            val byPath = files.associateBy { it.relativePath }
            Triple(record, tree, byPath)
        }
        val snapshots = sequence {
            for ((record, tree, byPath) in scans) {
                val current = registry.record(record.id) ?: continue
                for (item in current.items.values.sortedBy { it.mediaId }) {
                    if (item.mediaId <= afterId) continue
                    val file = byPath[item.relativePath] ?: continue
                    val captured = captureAtMs(tree, file)
                    if (scope?.contains(record.bucketId, scopeTimeSecOf(captured ?: 0L, file.modifiedAtMs / 1000)) == false) continue
                    yield(folderSnapshot(item, record.bucketId, file, captured))
                }
            }
        }
        return block(snapshots)
    }

    /** ADR §4：changes 恒返回空批，目录新项不依赖 incremental changes，只在 reconcile（readInScope）轮出现。 */
    override fun <R> readChangedSince(volumeName: String, afterGeneration: Long, afterMediaId: Long, block: (Sequence<MediaSnapshot>) -> R): R =
        block(emptySequence())

    /** 目录来源不参与 G 游标。 */
    override fun maxGeneration(volumeName: String): Long = 0L

    override val preciseGeneration: Boolean get() = true

    /** 不报卷：FlowEngine 的「按卷推 G」只遍历 MediaStore 卷。 */
    override fun volumeNames(): List<String> = emptyList()

    /** 游标过滤用：afterId ≥ 当前最大 mediaId 时目录段不可能还有未扫项（见 [FolderRegistry.maxMediaId]）。 */
    internal fun maxMediaId(): Long = registry.maxMediaId()

    override fun volumeVersions(): Map<String, String> = emptyMap()

    /** 单文件现状：文件没了 → null；授权失效抛 [SourceUnavailableException]。目录外 ID 返回 null。 */
    override fun lookup(mediaId: Long): MediaDetails? {
        if (!isFolderId(mediaId)) return null
        val opaque = registry.opaqueIdOfMedia(mediaId) ?: return null
        val record = registry.record(registry.sourceIdOfMedia(mediaId) ?: return null) ?: return null
        val relativePath = registry.relativePath(record.id, opaque) ?: return null
        val tree = treeFor(record)
        val uri = tree.uriOf(relativePath) ?: return null // 文件没了：源缺失（调用方按单张处理）
        val file = tree.stat(relativePath) ?: return null // 元数据取不全：该项目按不可得处理（ADR §3）
        val captured = captureAtMs(tree, file)
        return MediaDetails(
            snapshot = MediaSnapshot(
                mediaId = mediaId,
                sourceVersion = sourceVersionOf(file.modifiedAtMs / 1000, file.sizeBytes),
                bucketId = record.bucketId,
                generation = 0L,
                volumeName = FOLDER_VOLUME,
                dateAddedSec = scopeTimeSecOf(captured ?: 0L, file.modifiedAtMs / 1000),
            ),
            uri = uri,
            fileName = relativePath.substringAfterLast('/'),
            mimeType = file.mimeType,
            sizeBytes = file.sizeBytes,
            captureAtMs = captured ?: file.modifiedAtMs,
            // 引用导入的 dataPath：externalstorage 的 documentId 可推导真实路径；推导不出为 null（回退复制）。
            // 原生侧校验路径与描述符不一致自动复制——传错只会慢，不会传错数据（#413 §3）。
            dataPath = tree.filePath(relativePath),
        )
    }

    /**
     * #459 presence 对账的 folder 一侧：这些 Long ID 里哪些还在已登记目录里。
     * 授权失效抛 [SourceUnavailableException]（Composite 捕获后整体返回 null =「不知道」，不许当「全没了」）。
     * 前提：本轮 reconcileSourcePresence 已先跑过 [readInScope]（registry.items 是最新可信扫描结果）。
     */
    override fun existingIds(mediaIds: Collection<Long>): Set<Long>? {
        val folderIds = mediaIds.filter { isFolderId(it) }
        if (folderIds.isEmpty()) return emptySet()
        val wanted = folderIds.toHashSet()
        // 涉及的来源先各做一次可用性确认（一次完整枚举；对账轮本来就要做）：
        // 授权失效 → 抛 → Composite 整体返回「不知道」。
        for (record in registry.allRecords()) {
            if (record.items.values.none { it.mediaId in wanted }) continue
            treeFor(record).enumerate()
        }
        val known = HashSet<Long>()
        for (record in registry.allRecords()) {
            for (item in record.items.values) known += item.mediaId
        }
        // 在映射里 = 还在；不在 = 最近一次可信扫描里缺席（含来源已移除清掉的映射）→ 按「不在」回答，
        // order 行经 mark 流程记源缺失（ADR §3「旧 ID 按可信扫描结果记源缺失」）。
        return folderIds.filterTo(HashSet()) { it in known }
    }
}

private fun folderSnapshot(item: FolderItem, bucketId: Long, file: FolderFile, capturedAtMs: Long?): MediaSnapshot = MediaSnapshot(
    mediaId = item.mediaId,
    sourceVersion = sourceVersionOf(file.modifiedAtMs / 1000, file.sizeBytes),
    bucketId = bucketId,
    generation = 0L,
    volumeName = FOLDER_VOLUME,
    dateAddedSec = scopeTimeSecOf(capturedAtMs ?: 0L, file.modifiedAtMs / 1000),
)

/** SAF 的媒体元数据读取：图片读 EXIF，视频读容器创建时间；失败只表示时间未知，不影响文件是否存在。 */
class SafFolderCaptureTimeReader(private val context: Context) {
    fun read(tree: FolderTree, file: FolderFile): Long? {
        val uri = tree.uriOf(file.relativePath)?.let(Uri::parse) ?: return null
        return runCatching {
            when {
                file.mimeType.startsWith("image/") -> readImageCapture(uri)
                file.mimeType.startsWith("video/") -> readVideoCapture(uri)
                else -> null
            }
        }.getOrNull()
    }

    private fun readImageCapture(uri: Uri): Long? {
        context.contentResolver.openInputStream(uri)?.use { input ->
            @Suppress("DEPRECATION")
            val exif = ExifInterface(input)
            for (tag in listOf("DateTimeOriginal", "DateTimeDigitized", "DateTime")) {
                val raw = exif.getAttribute(tag) ?: continue
                val offset = exif.getAttribute("OffsetTime${tag.removePrefix("DateTime")}")
                parseExifDateTime(raw, offset, TimeZone.getDefault())?.let { return it }
            }
        }
        return null
    }

    private fun readVideoCapture(uri: Uri): Long? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            val raw = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE) ?: return null
            parseDate(raw, "yyyyMMdd'T'HHmmss.SSS'Z'", utc = true)
                ?: parseDate(raw, "yyyyMMdd'T'HHmmss'Z'", utc = true)
        } finally {
            retriever.release()
        }
    }

    private fun parseDate(raw: String, pattern: String, utc: Boolean): Long? {
        val format = SimpleDateFormat(pattern, Locale.US)
        format.isLenient = false
        if (utc) format.timeZone = TimeZone.getTimeZone("UTC")
        val position = ParsePosition(0)
        val parsed: Date = format.parse(raw, position) ?: return null
        return if (position.index == raw.length) parsed.time else null
    }
}

internal fun parseExifDateTime(raw: String, offset: String?, defaultZone: TimeZone): Long? {
    val format = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US)
    format.isLenient = false
    format.timeZone = offset?.let { runCatching { java.time.ZoneId.of(it) }.getOrNull() }
        ?.let(TimeZone::getTimeZone) ?: defaultZone
    val position = ParsePosition(0)
    val parsed: Date = format.parse(raw, position) ?: return null
    return if (position.index == raw.length) parsed.time else null
}
