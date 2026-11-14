// #1762 本地授权目录来源：目录树访问抽象（ADR §2 FolderMediaSource / §5 授权生命周期）。
// 生产用 SAF（DocumentFile + ContentResolver），JVM 单测用 java.io.File——枚举、类型过滤、
// sourceVersion 这些判据不依赖 Android API，直接可跑。
package com.hawkeyexb.ppass.backup.folder

import java.io.InputStream

/** 目录里一个文件项的元数据（不读完整文件）。 */
data class FolderFile(
    /** 规范化相对路径（`/` 分隔、不含 `.` / `..` 段）。 */
    val relativePath: String,
    val mimeType: String,
    val sizeBytes: Long,
    val modifiedAtMs: Long,
)

/**
 * 一个已授权目录树的只读访问。授权失效（树 URI 被撤销 / 根不可达）时抛 [SourceUnavailableException]，
 * 不得返回空列表或 null 冒充「没有文件」。
 */
interface FolderTree {
    /** 递归枚举根目录里的全部文件（含子目录）。授权失效抛 [SourceUnavailableException]。 */
    fun enumerate(): List<FolderFile>

    /**
     * 文件的 content URI（进 [com.hawkeyexb.ppass.backup.order.MediaDetails.uri]，导入时打开）。
     * **文件已不在 → 返回 null**（「这一个没了」是源缺失，不是授权失效）；授权失效 / 根不可达抛
     * [SourceUnavailableException]——两者语义不同，不许混（#1762 ADR §5）。
     */
    fun uriOf(relativePath: String): String?

    /**
     * 单文件元数据（不枚举整棵树——lookup 每张一次，成本必须是 O(路径深度) 而不是 O(树)）。
     * 文件不在 → null；授权失效抛 [SourceUnavailableException]（与 [uriOf] 同口径）。
     */
    fun stat(relativePath: String): FolderFile?

    /**
     * 文件的真实路径（引用导入的 dataPath）。SAF 文档没有「官方」路径；[SafFolderTree] 按
     * externalstorage provider 的 documentId 约定（`primary:relative` → `/storage/emulated/0/relative`）
     * 推导——推导错时原生侧校验路径与描述符不一致自动回退复制（传错只会慢，不会传错数据，#413 §3）。
     * null = 推导不出（该来源交给复制导入）。
     */
    fun filePath(relativePath: String): String?
}
