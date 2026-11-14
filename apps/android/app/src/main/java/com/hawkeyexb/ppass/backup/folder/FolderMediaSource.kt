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

import com.hawkeyexb.ppass.backup.flow.sourceVersionOf
import com.hawkeyexb.ppass.backup.order.MediaDetails
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import com.hawkeyexb.ppass.backup.order.MediaSnapshotSource

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
    private val treeFor: (FolderRecord) -> FolderTree,
) : MediaSnapshotSource {

    /**
     * 对账扫描：每个现存来源完整枚举一次（授权失效抛 [SourceUnavailableException]，整轮等待）。
     * 枚举成功 → reconcile（新项分配 Long ID、缺席项删除并按源缺失走 existingIds 流程）。
     * 输出按 mediaId 严格升序（ID 全局分配不重复，直接排序）。
     */
    override fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
        val snapshots = ArrayList<MediaSnapshot>()
        for (record in registry.allRecords()) {
            val tree = treeFor(record)
            // 完整枚举（失败抛 → 本轮无可信结果）；只收照片/视频（其他类型忽略，不计失败——ADR 异常口径）。
            val files = tree.enumerate().filter { isMediaMime(it.mimeType) }
            // 完整枚举成功才对账：新项分配 ID，缺席项删除（旧 ID 由 existingIds 流程记源缺失）。
            registry.reconcile(record.id, files.map { it.relativePath })
            val current = registry.record(record.id) ?: continue
            val byPath = files.associateBy { it.relativePath }
            for ((_, item) in current.items) {
                val file = byPath[item.relativePath] ?: continue
                if (item.mediaId > afterId) {
                    snapshots += folderSnapshot(item, record.bucketId, file)
                }
            }
        }
        snapshots.sortBy { it.mediaId }
        return block(snapshots.asSequence())
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
        return MediaDetails(
            snapshot = MediaSnapshot(
                mediaId = mediaId,
                // 与 MediaStore 同口径：modifiedAt(秒):size（MOB-98：版本只看内容有没有变）。
                sourceVersion = sourceVersionOf(file.modifiedAtMs / 1000, file.sizeBytes),
                bucketId = record.bucketId,
                generation = 0L,
                volumeName = FOLDER_VOLUME,
                dateAddedSec = file.modifiedAtMs / 1000,
            ),
            uri = uri,
            fileName = relativePath.substringAfterLast('/'),
            mimeType = file.mimeType,
            sizeBytes = file.sizeBytes,
            captureAtMs = file.modifiedAtMs,
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

private fun folderSnapshot(item: FolderItem, bucketId: Long, file: FolderFile): MediaSnapshot = MediaSnapshot(
    mediaId = item.mediaId,
    sourceVersion = sourceVersionOf(file.modifiedAtMs / 1000, file.sizeBytes),
    bucketId = bucketId,
    generation = 0L,
    volumeName = FOLDER_VOLUME,
    dateAddedSec = file.modifiedAtMs / 1000,
)
