// T-080: 备份页状态条的裁决逻辑——纯函数、零 Android 依赖，JVM 直接可测。
// 两条铁律（真机确认过的缺陷，各自有单测锁死）：
//   (a) 待备份 K > 0 时，永不允许「照片都存好了」类文案；
//   (b) 从未成功备份（时间戳 <= 0）时，永不把 epoch 0 交给日期格式化
//       （真机曾渲染出「01-01 08:00」假话），必须走「还没有成功备份过」。
package com.hawkeyexb.ppass.ui

/** 状态条只可能是这五种裁决之一；UI 只负责把裁决映射到字符串资源。 */
sealed class StatusLine {
    /** 没有在跑、也没有欠账、也没有可报告的成功——「随时可以备份」。 */
    data object Ready : StatusLine()

    /** 备份进行中（找照片 / 读取 / 传输）——把原始态透传给 UI 显示进度。 */
    data class Working(val state: BackupUiState) : StatusLine()

    /** 缺陷 (a) 的出口：还有 K 张待备份——即使刚跑完一轮成功，也说欠账。 */
    data class Pending(val k: Long) : StatusLine()

    /** 只有欠账为 0 且确有成功运行时，才允许「照片都存好了」。 */
    data object AllSafe : StatusLine()

    /** 失败才说话。 */
    data object Trouble : StatusLine()
}

/**
 * 状态条裁决。[pendingK] = 恒真三元组的 K（待备份张数；三元组不可用时
 * 传 0，退化为按运行态判定）。
 *
 * 优先级：失败 > 进行中 > 欠账 > 成功 > 就绪。
 * 缺陷 (a)：`pendingK > 0` 拦在 AllSafe 之前——一轮成功运行（增量扫完）
 * 不代表账清了，三元组说了算。
 */
fun statusLineOf(state: BackupUiState, pendingK: Long): StatusLine = when (state) {
    is BackupUiState.Trouble -> StatusLine.Trouble
    is BackupUiState.Scanning,
    is BackupUiState.Hashing,
    is BackupUiState.Sending,
    -> StatusLine.Working(state)
    is BackupUiState.Idle,
    is BackupUiState.AllSafe,
    -> when {
        pendingK > 0 -> StatusLine.Pending(pendingK)
        state is BackupUiState.AllSafe -> StatusLine.AllSafe
        else -> StatusLine.Ready
    }
}

/** 「最后成功时间」的裁决；UI 把每个分支映射到字符串资源。 */
sealed class LastSuccess {
    /** 缺陷 (b) 的出口：从未成功备份过——绝不渲染日期。 */
    data object Never : LastSuccess()
    data object JustNow : LastSuccess()
    data class MinutesAgo(val mins: Long) : LastSuccess()
    data class HoursAgo(val hours: Long) : LastSuccess()
    /** 超过一天——渲染日期。此分支的 ts 保证 > 0。 */
    data class At(val ts: Long) : LastSuccess()
}

/**
 * 缺陷 (b)：`ts <= 0`（ConfirmedStore 约定 0 = 从未成功）必须返回
 * [LastSuccess.Never]，日期格式化分支永远拿不到 epoch 0。
 */
fun lastSuccessOf(ts: Long, now: Long): LastSuccess {
    if (ts <= 0L) return LastSuccess.Never
    val mins = (now - ts) / 60_000
    return when {
        mins < 1 -> LastSuccess.JustNow
        mins < 60 -> LastSuccess.MinutesAgo(mins)
        mins < 60 * 24 -> LastSuccess.HoursAgo(mins / 60)
        else -> LastSuccess.At(ts)
    }
}

/** 照片页轻过滤器（设计稿：全部 / 仅本机 / 家人的）。
 *  proto 无 owner 字段（本卡不准动 proto），用「这台手机已确认备份的
 *  hash 集合」近似归属：在集合内 = 本机备份的；不在 = 家人设备的。 */
enum class TimelineFilter { All, LocalOnly, Family }

/** 纯过滤函数——[mine] = 本机确认缓存的 hash 集合。 */
fun <T> filterTimeline(
    items: List<T>,
    filter: TimelineFilter,
    mine: Set<String>,
    hashOf: (T) -> String,
): List<T> = when (filter) {
    TimelineFilter.All -> items
    TimelineFilter.LocalOnly -> items.filter { hashOf(it) in mine }
    TimelineFilter.Family -> items.filter { hashOf(it) !in mine }
}
