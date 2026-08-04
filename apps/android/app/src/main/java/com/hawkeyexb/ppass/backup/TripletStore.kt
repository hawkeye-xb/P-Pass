// DOG-01: 备份恒真三元组「手机 N 张 · 已备份 M · 待备份 K + 最后成功时间」。
//
// 持久化最后一次成功运行的口径（杀 App 重开不归零；断网时显示缓存值）。
// 分母 = 当前扫描范围（卡架构预留：范围选择是另一张卡，口径在此常量定义）。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 三元组快照。K = n - m（待备份），由 UI 计算。 */
@Serializable
data class BackupTriplet(
    val n: Long,             // 手机 N 张（本次扫描范围）
    val m: Long,             // 已备份 M（ingested + duplicates，daemon 确认）
    val lastSuccessAt: Long, // 最后成功时间（unix ms）
) {
    /** 待备份 K = N - M（防御：不为负——UI 显示不允许负数）。 */
    val k: Long get() = (n - m).coerceAtLeast(0)
}

/** 由备份报告计算三元组；单独提纯便于测试（反证：missing 全量 → K = N）。 */
fun tripletOf(offered: Int, ingested: Int, duplicates: Int, lastSuccessAt: Long): BackupTriplet =
    BackupTriplet(
        n = offered.toLong(),
        m = (ingested + duplicates).toLong(),
        lastSuccessAt = lastSuccessAt,
    )

/** 崩溃安全的文件持久化（WatermarkStore 同款：tmp + rename）。 */
class TripletStore(private val dir: File) {
    private val file = File(dir, "backup.triplet.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): BackupTriplet? =
        if (file.isFile) {
            try {
                json.decodeFromString(BackupTriplet.serializer(), file.readText())
            } catch (_: Exception) {
                null // 损坏则当无缓存（不崩）
            }
        } else null

    fun save(t: BackupTriplet) {
        dir.mkdirs()
        val tmp = File(dir, "backup.triplet.json.tmp")
        tmp.writeText(json.encodeToString(BackupTriplet.serializer(), t))
        check(tmp.renameTo(file)) { "cannot persist triplet" }
    }
}
