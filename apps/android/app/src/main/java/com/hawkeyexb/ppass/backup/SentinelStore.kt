// SENT-01: 手机盯电脑哨兵（decisions ⑤ 下半场）——备份静默失败必须被
// 发现。机制红线：**不是后台心跳**——搭现有后台任务便车：每次后台任务
// 执行顺记一笔 daemon 可达性结果；判定纯函数：最近一次确认可达距今
// > 72h 且期间有过 ≥1 次失败尝试 → 该发提醒（「手机自己三天没触发」
// 不误报；无尝试=无结论）。恢复可达后状态清零。
// tmp+rename 崩溃安全（WatermarkStore 同款），损坏当空。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 哨兵阈值：最近一次确认可达距今超过 72h 才可能提醒（decisions ⑤）。 */
const val SENTINEL_THRESHOLD_MS = 72L * 60 * 60 * 1000
/** 通知去重窗口：发过之后 72h 内不重复（避免每轮后台任务都响）。 */
const val SENTINEL_COOLDOWN_MS = 72L * 60 * 60 * 1000

@Serializable
data class SentinelState(
    /** 最近一次确认 daemon 可达的时间戳（ms；0 = 从未确认可达）。 */
    val lastReachableAt: Long = 0,
    /** 期间累计的失败尝试次数（recordReachable 时清零）。 */
    val failedAttempts: Int = 0,
    /** 最近一次哨兵通知的时间戳（ms；0 = 从未发过）。 */
    val lastNotifiedAt: Long = 0,
)

/**
 * SENT-01 判定纯函数（JVM 可测）：该不该发「3 天没连上电脑」提醒。
 * 三个条件全部满足才发：
 *  1. 确认可达过（lastReachableAt > 0）——从未连上 = 无结论，不误报；
 *  2. 最近一次可达距今 > 72h；
 *  3. 期间有过 ≥1 次失败尝试（否则可能只是「手机自己没触发」）。
 *  4. 去重窗口已过（距上次通知 > 72h）。
 */
fun shouldNotifySentinel(
    state: SentinelState,
    now: Long = System.currentTimeMillis(),
    thresholdMs: Long = SENTINEL_THRESHOLD_MS,
    cooldownMs: Long = SENTINEL_COOLDOWN_MS,
): Boolean {
    if (state.lastReachableAt <= 0) return false
    if (now - state.lastReachableAt <= thresholdMs) return false
    if (state.failedAttempts < 1) return false
    return now - state.lastNotifiedAt > cooldownMs
}

class SentinelStore(private val dir: File) {
    private val file = File(dir, "sentinel.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): SentinelState =
        if (file.isFile) {
            runCatching { json.decodeFromString<SentinelState>(file.readText()) }
                .getOrDefault(SentinelState())
        } else {
            SentinelState()
        }

    private fun save(state: SentinelState) {
        dir.mkdirs()
        val tmp = File(dir, "sentinel.json.tmp")
        tmp.writeText(json.encodeToString(SentinelState.serializer(), state))
        check(tmp.renameTo(file)) { "cannot persist sentinel state" }
    }

    /** 确认 daemon 可达：记时间戳 + 失败计数清零（恢复可达状态清零）。 */
    fun recordReachable(now: Long = System.currentTimeMillis()) {
        save(load().copy(lastReachableAt = now, failedAttempts = 0))
    }

    /** 一次失败尝试：失败计数 +1（可达时间戳不动）。 */
    fun recordUnreachable() {
        val cur = load()
        save(cur.copy(failedAttempts = cur.failedAttempts + 1))
    }

    /** 通知发出后记一笔（去重窗口从此算）。 */
    fun markNotified(now: Long = System.currentTimeMillis()) {
        save(load().copy(lastNotifiedAt = now))
    }
}
