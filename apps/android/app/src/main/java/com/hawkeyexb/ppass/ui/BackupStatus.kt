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

    /** FIX-T6: 一个相册都没选（空集 = 一个都不备）——「没有可备份的
     *  相册」。与 AllSafe 区分：空集不是「都存好了」，是「没东西可备」。 */
    data object NoAlbums : StatusLine()

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
    is BackupUiState.NoAlbums -> StatusLine.NoAlbums
    // UX-13: 被暂停在状态**文案**上与空闲同档（Pending/Ready 照旧说欠账），
    // 区别只在英雄区按钮——见 [heroActionOf]。
    is BackupUiState.Idle,
    is BackupUiState.Paused,
    is BackupUiState.AllSafe,
    -> when {
        pendingK > 0 -> StatusLine.Pending(pendingK)
        state is BackupUiState.AllSafe -> StatusLine.AllSafe
        else -> StatusLine.Ready
    }
}

/**
 * UX-13: 英雄区次级按钮的裁决——**同一个位置**在两种文案之间切换。
 *
 * `null` = 不显示（空闲、都存好了、没相册、出错了：出路在别处的卡上；
 * 配对失效时也收起，出路在红卡的「重新扫码」）。
 *
 * 两个分支的点击**走同一条路**（`onBackupNow` → `BackupUiStateHolder
 * .backupNow`）：进行中 = 暂停，被暂停 = 续传（重新 offer 全部候选，
 * dedup 收敛缺 0）。MOB-19 红线：不新增第二条管线，所以这里只裁决**文案**，
 * 不裁决动作。
 *
 * 为什么 [HeroAction.Resume] **不再加「待备份 K > 0」这道门**：`Paused`
 * 的构造前提已经是「有一轮跑到一半被打断，之后没有任何一轮跑完」——那本身
 * 就是「还有活没干完」。再拿三元组的 K 当门，会在三元组不可用（DOG-01d
 * 退化为 null → K 传 0）时恰好把按钮藏起来，也就是把本卡要修的缺陷原样
 * 放回去。K = 0 时点一下最坏是跑一轮零新增的空转，跑完 `Paused` 自动过期。
 */
enum class HeroAction { Pause, Resume }

fun heroActionOf(state: BackupUiState, pairingLost: Boolean): HeroAction? = when {
    pairingLost -> null
    isBackupRunning(state) -> HeroAction.Pause
    state is BackupUiState.Paused -> HeroAction.Resume
    else -> null
}

/**
 * 「这一刻有一轮备份在跑」——**点击的裁决也用它**：只有进行中那一下算
 * 暂停，其余（含被暂停态下的「继续」）一律落到 `triggerManualBackup`
 * 那一条管线（MOB-19 红线：不许有第二条）。
 *
 * `Paused` 刻意**不算**在跑：那正是「再点一次 = 续传」得以成立的判据。
 */
fun isBackupRunning(state: BackupUiState): Boolean =
    state is BackupUiState.Scanning ||
        state is BackupUiState.Hashing ||
        state is BackupUiState.Sending

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

// ── T-083 目标 3：失败红卡渲染闸门（设计红线「报错永远不出现代码，
// 先说『照片没丢』」）——纯函数、零 Android 依赖，JVM 直接可测。 ──

/** 红卡文案的两个去处：[main] = 人话正文（来自字符串资源，进红卡正文）；
 *  [detail] = 完整原始错误串（只进默认收起的「查看技术详情」折叠区，
 *  完整原文同时由 BackupUiStateHolder 走 Log.e 进 logcat 诊断导出路径）。 */
data class TroubleText(val main: String, val detail: String)

/**
 * 唯一允许把原始错误串（`IrohError { kind: ... }` / 异常 toString dump）
 * 变成可渲染文案的地方：原文只落 [TroubleText.detail]；[TroubleText.main]
 * 恒等于传入的人话正文——任何代码碎片都不经此进入主文案（有单测锁死）。
 */
fun troubleTextOf(rawError: String, humanBody: String): TroubleText =
    TroubleText(main = humanBody, detail = rawError.trim())

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
