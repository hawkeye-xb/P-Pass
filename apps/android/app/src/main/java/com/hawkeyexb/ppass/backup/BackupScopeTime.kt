// #1263 / #1778：备份范围 = 选中的来源 + 固定起点。时间档只有从今天起 / 全部，起点保存后不滑动。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.folder.isFolderId
import java.time.Instant
import java.time.ZoneId

/** 范围时间只有两级：拍摄时间（毫秒）优先，缺失才回退文件修改时间（秒）；不再使用 DATE_ADDED。 */
fun scopeTimeSecOf(dateTakenMs: Long, modifiedAtSec: Long): Long =
    if (dateTakenMs > 0L) dateTakenMs / 1000L else modifiedAtSec.coerceAtLeast(0L)

/**
 * 一张照片在不在范围里的判据本体（纯函数，JVM 单测直接跑）。
 * [sinceSec] 为 null = 全部；非 null = 拍摄／创建时间不早于它，缺失拍摄时间时才比较 mtime。
 */
data class BackupScope(val buckets: Set<Long>, val sinceSec: Long?) {
    fun contains(bucketId: Long, capturedOrModifiedSec: Long): Boolean =
        bucketId in buckets && (sinceSec == null || capturedOrModifiedSec >= sinceSec)
}

/**
 * 旧版目录来源读现状初始化：已有登记目录继续保持选中，直到用户保存过包含目录的新版统一范围。
 * 不写存值迁移，也不把新版里明确取消勾选的目录重新并回去。
 */
fun effectiveBackupScope(
    saved: BackupScope?,
    knownSourceIds: Set<Long>?,
    existingFolderBuckets: Set<Long>,
    sinceSec: Long?,
): BackupScope? {
    if (saved == null) {
        return if (existingFolderBuckets.isEmpty()) null else BackupScope(existingFolderBuckets, sinceSec)
    }
    val unifiedScopeSaved = knownSourceIds?.any(::isFolderId) == true
    val selectedNow = if (unifiedScopeSaved) {
        saved.buckets.filter { !isFolderId(it) || it in existingFolderBuckets }.toSet()
    } else {
        saved.buckets + existingFolderBuckets
    }
    return saved.copy(buckets = selectedNow)
}

/** 自动备份开关只在「从未保存且没有既有目录」时主动引导；保存过空集或读取失败都不是无值。 */
fun shouldGuideToScopeOnEnable(read: ScopeRead, existingFolderCount: Int): Boolean =
    read is ScopeRead.NeverSaved && existingFolderCount == 0

/** 选范围页上的两档。 */
enum class ScopeTime { SINCE_TODAY, ALL }

/** [nowMs] 所在那一天、手机本地时区的 0 点（epoch 秒）。「今天」从当天零点算，不从保存的那一刻算。 */
fun startOfLocalDaySec(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): Long =
    Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().atStartOfDay(zone).toEpochSecond()

/**
 * 保存时落盘的 since。
 * - 选「全部」→ null；
 * - 选「从今天起」，原来已经是「从某天起」→ 保留原来那天（不往后滑：几天后再打开保存，中间那几天的照片不能掉出去）；
 * - 选「从今天起」，原来是「全部」或从没存过 → 今天 0 点。
 */
fun sinceToSave(choice: ScopeTime, previousSinceSec: Long?, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): Long? =
    when (choice) {
        ScopeTime.ALL -> null
        ScopeTime.SINCE_TODAY -> previousSinceSec ?: startOfLocalDaySec(nowMs, zone)
    }

/**
 * 选范围页一进来选中哪一档：
 * - 存过范围 → 回显：没有开始时间（老用户、或选过「全部」）→ 全部，否则从今天起；
 * - 没存过、只给了部分照片 → 全部（10-30：只挑了几张就是想传它们，多半是以前的照片）；
 * - 没存过、全部权限 → 从今天起。
 */
fun initialScopeTime(saved: Boolean, sinceSec: Long?, partialAccess: Boolean = false): ScopeTime = when {
    saved -> if (sinceSec == null) ScopeTime.ALL else ScopeTime.SINCE_TODAY
    partialAccess -> ScopeTime.ALL
    else -> ScopeTime.SINCE_TODAY
}

/** 时间条件放宽了（「从某天起」→「全部」或更早）：按范围扩大处理，走补扫。 */
fun sinceWidened(previousSinceSec: Long?, newSinceSec: Long?): Boolean =
    previousSinceSec != null && (newSinceSec == null || newSinceSec < previousSinceSec)

/**
 * 选范围页一进来勾着哪些相册：这台电脑存过范围就是存下的那些；首次选（onboarding、这台电脑从没存过）默认勾上
 * 相机相册——有「从今天起」兜着，不会一次传很多；识别不到相机相册（个别机型路径不同）就不勾，退回原行为。
 * 从设置里进来、但从没存过范围的，也按原行为一个都不勾。
 */
fun initialSelection(saved: Set<Long>?, firstTime: Boolean, cameraBucketIds: Set<Long>): Set<Long> = when {
    saved != null -> saved
    firstTime -> cameraBucketIds
    else -> emptySet()
}

/**
 * 相机相册的识别：`RELATIVE_PATH` 为 `DCIM/Camera/`（API 29+），更早的系统看 `_data` 里有没有 `/DCIM/Camera/`。
 * 都不区分大小写。
 */
fun isCameraPath(relativePath: String?, dataPath: String?): Boolean {
    if (relativePath != null) return relativePath.trimEnd('/').equals("DCIM/Camera", ignoreCase = true)
    return dataPath?.contains("/DCIM/Camera/", ignoreCase = true) == true
}
