// DOG-02b: 契机式电池白名单提醒（decisions ④）——常驻引导卡保留，
// 新增「该跑没跑成才提醒」：近 2 天存在应触发的自动备份但均未成功执行
// 且当前未加白 → 通知一次「昨晚没备份成，可能是系统限制了后台」。
// 判定纯函数化（与 SENT-01 同套路，各自独立 store 不耦合）；加白后 /
// 成功一轮后状态清零；通知去重窗口 ≥72h。
// tmp+rename 崩溃安全，损坏当空。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 判定窗口：近 2 天内有失败尝试才可能提醒（卡面建议值，已定稿）。 */
const val WHITELIST_NUDGE_WINDOW_MS = 2L * 24 * 60 * 60 * 1000
/** 通知去重窗口：发过之后 72h 内不重复。 */
const val WHITELIST_NUDGE_COOLDOWN_MS = 72L * 60 * 60 * 1000

@Serializable
data class WhitelistNudgeState(
    /** 最近一次自动备份失败的时间戳（ms；0 = 无失败记录）。 */
    val lastFailedAt: Long = 0,
    /** 最近一次自动备份成功的时间戳（ms；0 = 从未成功过）。 */
    val lastSuccessAt: Long = 0,
    /** 最近一次白名单提醒通知的时间戳（ms；0 = 从未发过）。 */
    val lastNudgedAt: Long = 0,
)

/**
 * DOG-02b 判定纯函数（JVM 可测）：该不该发「昨晚没备份成」提醒。
 * 全部条件满足才发：
 *  1. 当前未加白名单（isIgnoringBatteryOptimizations == false）；
 *  2. 有失败记录（lastFailedAt > 0）；
 *  3. 最近一次失败距今 ≤ 2 天（近 N 天内确实跑过但没成）；
 *  4. 失败之后没有成功过（lastSuccessAt < lastFailedAt——当前处于
 *     「连续没跑成」状态，不是「失败后已恢复」）；
 *  5. 距上次提醒 > 72h（去重窗口）。
 */
fun shouldNudgeWhitelist(
    state: WhitelistNudgeState,
    now: Long = System.currentTimeMillis(),
    isWhitelisted: Boolean,
    windowMs: Long = WHITELIST_NUDGE_WINDOW_MS,
    cooldownMs: Long = WHITELIST_NUDGE_COOLDOWN_MS,
): Boolean {
    if (isWhitelisted) return false
    if (state.lastFailedAt <= 0) return false
    if (now - state.lastFailedAt > windowMs) return false
    if (state.lastSuccessAt >= state.lastFailedAt) return false
    return now - state.lastNudgedAt > cooldownMs
}

class WhitelistNudgeStore(private val dir: File) {
    private val file = File(dir, "whitelist-nudge.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): WhitelistNudgeState =
        if (file.isFile) {
            runCatching { json.decodeFromString<WhitelistNudgeState>(file.readText()) }
                .getOrDefault(WhitelistNudgeState())
        } else {
            WhitelistNudgeState()
        }

    private fun save(state: WhitelistNudgeState) {
        dir.mkdirs()
        val tmp = File(dir, "whitelist-nudge.json.tmp")
        tmp.writeText(json.encodeToString(WhitelistNudgeState.serializer(), state))
        check(tmp.renameTo(file)) { "cannot persist whitelist nudge state" }
    }

    /** 自动备份成功一轮：记成功时间戳（判定条件 4 的「已恢复」证据）。 */
    fun recordSuccess(now: Long = System.currentTimeMillis()) {
        save(load().copy(lastSuccessAt = now))
    }

    /** 自动备份失败一次：记失败时间戳。 */
    fun recordFailure(now: Long = System.currentTimeMillis()) {
        save(load().copy(lastFailedAt = now))
    }

    /** 提醒发出后记一笔（去重窗口从此算）。 */
    fun markNudged(now: Long = System.currentTimeMillis()) {
        save(load().copy(lastNudgedAt = now))
    }
}
