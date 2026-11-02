// SENT-01 遗留：只剩「上次确认电脑可达的时间」——前台心跳写，首页/照片页
// 「失联 N 天」读。原先的「3 天没连上电脑」提醒判定从未接进生产代码，
// #1028 删除；旧文件里的多余字段由 ignoreUnknownKeys 忽略。
// tmp+rename 崩溃安全（WatermarkStore 同款），损坏当空。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.io.atomicReplace
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class SentinelState(
    /** 最近一次确认 daemon 可达的时间戳（ms；0 = 从未确认可达）。 */
    val lastReachableAt: Long = 0,
)

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
        check(atomicReplace(tmp, file)) { "cannot persist sentinel state" }
    }

    /** 确认 daemon 可达：记时间戳。 */
    fun recordReachable(now: Long = System.currentTimeMillis()) {
        save(load().copy(lastReachableAt = now))
    }
}
