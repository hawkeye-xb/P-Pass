// #1762 组合层（ADR docs/decisions/2026-11-13-local-folder-media-source.md §2 CompositeMediaSource / CompositeImporter
// 的 Android 对位）：MediaStore 来源 × 目录来源拼进**同一个** [MediaSnapshotSource] / [MediaImporter]，
// 不新增流程阶段。Android 与 iOS 的差异：两端的导入最终都走同一个原生 provider 桥——Android 端 folder 的
// SAF 文档 URI 直接可被 [AndroidMediaImporter] 的 `openFileDescriptor` 读（lookup 给的 uri 就是文档 URI），
// 所以 import 侧不需要第二个导入器实现，只需要按来源分发 + 授权失效的异常口径转换。
package com.hawkeyexb.ppass.backup.folder

import com.hawkeyexb.ppass.backup.flow.MediaImporter
import com.hawkeyexb.ppass.backup.flow.SourceUnavailableException
import com.hawkeyexb.ppass.backup.order.MediaDetails
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import com.hawkeyexb.ppass.backup.order.MediaSnapshotSource

/**
 * MediaStore × 目录的组合快照源。约定（全部继承 [MediaSnapshotSource] 的契约）：
 * - [readInScope]：**先枚举 folder**（授权失效在这里抛，发生在向调用方产出任何一行之前），再读 MediaStore；
 *   输出按 mediaId 严格升序——folder 的 Long ID 全部带 bit 62，恒大于 MediaStore 的正 `_id`，
 *   两段各自升序拼接后整体仍严格升序（对账扫描按序归并依赖这一点）。
 * - [readChangedSince] / [maxGeneration] / [volumeNames] / [volumeVersions] / [preciseGeneration]：目录不参与
 *   G 游标与卷口径（ADR §4），全部来自 MediaStore 段。
 * - [lookup]：folder ID（bit 62）走目录，其余走 MediaStore。
 * - [existingIds]：目录授权失效 → **整体返回 null**（「不知道」），不得只丢掉 folder 部分、更不得把
 *   folder 撤权当成「folder 的照片全没了」（ADR §5 / 验收）。
 */
class CompositeMediaSnapshotSource(
    private val primary: MediaSnapshotSource,
    private val folder: MediaSnapshotSource,
) : MediaSnapshotSource {

    override fun <R> readInScope(afterId: Long, block: (Sequence<MediaSnapshot>) -> R): R {
        val folderRows = ArrayList<MediaSnapshot>()
        // 目录段没有游标：完整枚举只在「afterId 还没扫进目录命名空间」时做一次。对账扫描每 64 张
        // 调一次 [readInScope]，游标推进过目录段后再枚举是纯浪费（O(n²)），且 [needsNewOrder] 幂等。
        val folderMax = (folder as? FolderMediaSnapshotSource)?.maxMediaId() ?: Long.MAX_VALUE
        if (afterId < folderMax) {
            folder.readInScope(afterId) { rows -> folderRows += rows }
        }
        return primary.readInScope(afterId) { rows ->
            block(rows.asSequence() + folderRows.asSequence())
        }
    }

    override fun <R> readChangedSince(volumeName: String, afterGeneration: Long, afterMediaId: Long, block: (Sequence<MediaSnapshot>) -> R): R =
        primary.readChangedSince(volumeName, afterGeneration, afterMediaId, block)

    override fun maxGeneration(volumeName: String): Long = primary.maxGeneration(volumeName)

    override val preciseGeneration: Boolean get() = primary.preciseGeneration

    override fun volumeNames(): List<String> = primary.volumeNames()

    override fun volumeVersions(): Map<String, String> = primary.volumeVersions()

    override fun lookup(mediaId: Long): MediaDetails? =
        if (isFolderId(mediaId)) folder.lookup(mediaId) else primary.lookup(mediaId)

    override fun existingIds(mediaIds: Collection<Long>): Set<Long>? = try {
        // FolderMediaSnapshotSource 恒返回非 null（授权失效抛 SourceUnavailableException，被下面 catch 成
        // 整体「不知道」）；null 若真出现（未来实现违反契约）也按 ADR §4 整体「不知道」，不当空集。
        val folderPart = folder.existingIds(mediaIds) ?: return null
        val primaryPart = primary.existingIds(mediaIds.filter { !isFolderId(it) })
        if (primaryPart == null) null else primaryPart + folderPart
    } catch (failure: SourceUnavailableException) {
        // ADR §5：任何相关来源不可信 → 整体「不知道」。folder 侧授权失效只能这样表达。
        null
    }

    /**
     * #1762：目录段的独立对账入口（供 FlowEngine 在「带 reconcile 的轮」做全集差集——ADR §4
     * 「新素材在下一个 reconcile 轮被发现」的 Android 对应：Android 的对账扫描只走脏扫描，
     * 素材变化不置脏，所以引擎在 reconcile 轮显式问一次目录段）。语义与 [readInScope] 的 folder
     * 段完全一致（完整枚举 → registry.reconcile → 授权失效抛 [SourceUnavailableException]），
     * 只是**不含 MediaStore 段**——非脏轮不为对账扫全库相册。
     */
    internal fun readFolderInScope(afterId: Long = 0L): Sequence<MediaSnapshot> =
        folder.readInScope(afterId) { it }
}

/**
 * 组合导入器（ADR §2 CompositeImporter 的 Android 对位）：import 按来源分发；release/serve 委托。
 * Android 端两个来源共用同一个原生 provider 桥（folder 的 SAF 文档 URI 由 [com.hawkeyexb.ppass.backup.flow.AndroidMediaImporter]
 * 的 openFileDescriptor 直接读，lookup 给的 uri 就是文档 URI），所以只有**一个**子导入器实现——ADR 表里的
 * FolderImporter 在 Android 由这层分发 + 既有导入器承担；release 广播 = 单实现幂等清理（同一口径）。
 *
 * 唯一的来源级缝：folder 文档 URI 被撤销授权时 `openFileDescriptor` 抛 [SecurityException]——那是**整个来源**
 * 暂不可用（ADR §5），转成 [SourceUnavailableException] 让引擎进 WAITING，不许记成单张失败、更不许当源缺失。
 */
internal class CompositeMediaImporter(private val primary: MediaImporter) : MediaImporter by primary {
    override fun import(mediaId: Long, contentUri: String, dataPath: String?): com.hawkeyexb.ppass.backup.flow.ImportResult = try {
        primary.import(mediaId, contentUri, dataPath)
    } catch (failure: SecurityException) {
        if (isFolderId(mediaId)) {
            throw SourceUnavailableException("folder permission revoked (mediaId bit62): ${failure.javaClass.simpleName}", failure)
        } else {
            throw failure
        }
    }
}
