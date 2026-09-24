package com.hawkeyexb.ppass.backup.flow

// #413 最终设计的共享类型：W1（核心）/ W3（导入）/ W5（UI）按此协作，已有签名不改。
// 设计见 docs/design/2026-08-29-arch01-backup-core/，分工见同目录的契约文档。

/** 全局状态。暂停是全局的，不是 order 的状态。 */
enum class GlobalState {
    IDLE,
    RUNNING,
    /** 只有用户能解除。 */
    PAUSED,
    /** 条件不满足 / 桌面不可达或不健康，由我们自动恢复；原因见 [EngineView.waitReason]。 */
    WAITING,
}

/** 探测时桌面带回的健康状况。旧版桌面不报时为 null（视为健康）。 */
data class DesktopHealth(
    val freeBytes: Long?,
    val libraryWritable: Boolean = true,
    val indexOk: Boolean = true,
) {
    val lowSpace: Boolean get() = freeBytes != null && freeBytes < LOW_SPACE_BYTES

    companion object {
        const val LOW_SPACE_BYTES: Long = 5L * 1024 * 1024 * 1024
    }
}

/** 对端失败的具体原因：桌面自身的问题，不计入这张照片的失败次数。 */
enum class PeerFailureKind { STORAGE_FULL, LIBRARY_UNAVAILABLE, STORAGE_ERROR }

/** UI 与 FGS 通知读的唯一视图。[pending] 是现算的待办张数。 */
data class EngineView(
    val state: GlobalState = GlobalState.IDLE,
    /** 仅 [GlobalState.WAITING] 时非空。 */
    val waitReason: WaitReason? = null,
    val pending: Int = 0,
    val doneThisRound: Int = 0,
    val current: CurrentItem? = null,
    val desktopHealth: DesktopHealth? = null,
)

/** 导入结果：流式读一次原图，得到 BLAKE3。 */
internal sealed interface ImportResult {
    data class Imported(val contentHash: String, val sizeBytes: Long, val byReference: Boolean) : ImportResult
    data object SourceMissing : ImportResult
}

/**
 * 原图 → 手机侧 iroh store。引用优先（不复制内容），条件不满足回退复制。
 * 导入与供数分两步：先拿 hash 建 order，再用这张 order 的 lease [serve]。
 */
internal interface MediaImporter {
    fun import(mediaId: Long, contentUri: String, dataPath: String?): ImportResult

    /** 让 provider 以这张 order 的 lease 对外供数，返回 ticket。 */
    fun serve(lease: ProviderLease): String

    /** 这份内容不再需要（桌面已有、放弃这一张）。不许抛。 */
    fun release(contentHash: String)
}
