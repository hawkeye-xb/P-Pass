// #1263：备份范围 = 选中的相册 + 开始时间。时间只有两档：从今天起（默认）/ 全部，不做自选日期。
// 范围仍然只是查询条件（#413 裁定 8）：这里只多一个 `DATE_ADDED >= since` 的条件，扩大 / 缩小沿用原有规则。
package com.hawkeyexb.ppass.backup

import java.time.Instant
import java.time.ZoneId

/**
 * 一张照片在不在范围里的判据本体（纯函数，JVM 单测直接跑）。
 *
 * [sinceSec] 为 null = 全部；非 null = 进入手机相册（MediaStore `DATE_ADDED`，秒）不早于它的才算。
 * Android 按 `DATE_ADDED` 算「新」：今天才存进手机的老照片也算今天的（iOS 只有拍摄时间，是登记过的偏离）。
 */
data class BackupScope(val buckets: Set<Long>, val sinceSec: Long?) {
    fun contains(bucketId: Long, dateAddedSec: Long): Boolean =
        bucketId in buckets && (sinceSec == null || dateAddedSec >= sinceSec)
}

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

/** 选范围页一进来选中哪一档：存过范围且没有开始时间（老用户、或选过「全部」）→ 全部；其余（含首次）→ 从今天起。 */
fun initialScopeTime(saved: Boolean, sinceSec: Long?): ScopeTime =
    if (saved && sinceSec == null) ScopeTime.ALL else ScopeTime.SINCE_TODAY

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
