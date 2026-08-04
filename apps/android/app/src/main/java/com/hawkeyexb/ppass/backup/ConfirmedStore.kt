// DOG-01/DOG-01b: 备份恒真三元组「手机 N 张 · 已备份 M · 待备份 K + 最后
// 成功时间」。
//
// DOG-01b 口径修复（增量当全量的回归）：旧实现把单次运行的 offered/
// ingested 当 N/M——全量 100 张备完后新拍 5 张，第二次备份后 UI 显示
// 「手机 5 张 · 已备份 5」，恒真三元组变假话。
//
// 新口径（按原卡架构预留实现）：
//   N = 当前扫描范围全量 count（MediaScanner.countAll，MediaStore COUNT
//       查询，便宜，不需要重 hash）；
//   M = 状态缓存表里该 remote 已确认条数（ConfirmedStore，备份成功即
//       写入，不依赖单次运行报告）；
//   K = N - M clamp ≥ 0。
// 状态缓存 key=(hash, remote_id)，落 per-remote 目录（filesDir/
// backup-state/<remoteId>/）；备份运行时用 manifest「给 hashes 回
// missing」语义（只查不传）校准：missing → 从缓存移除（处理电脑端库被
// 删/换库的漂移），其余候选（daemon 已确认存在）→ 加入缓存。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 三元组快照。K = n - m（待备份），由 UI 计算。 */
@Serializable
data class BackupTriplet(
    val n: Long,             // 手机 N 张（扫描范围全量 count）
    val m: Long,             // 已备份 M（该 remote 已确认条数）
    val lastSuccessAt: Long, // 最后成功时间（unix ms；0 = 从未成功）
) {
    /** 待备份 K = N - M（防御：不为负——UI 显示不允许负数）。 */
    val k: Long get() = (n - m).coerceAtLeast(0)
}

/** DOG-01b: 由「全量 N + 确认缓存 M」算三元组；单独提纯便于测试。
 *  @param n 扫描范围全量 count（MediaStore COUNT，非增量 offered）
 *  @param confirmedCount 该 remote 已确认缓存条数
 */
fun tripletOf(n: Long, confirmedCount: Long, lastSuccessAt: Long): BackupTriplet =
    BackupTriplet(
        n = n,
        m = confirmedCount,
        lastSuccessAt = lastSuccessAt,
    )

/** 一个 remote 的确认状态（崩溃安全持久化，tmp + rename）。 */
@Serializable
data class ConfirmedState(
    /** 已被该 remote 确认存在的本地资产 hash 集合。 */
    val confirmed: Set<String> = emptySet(),
    /** 最后成功备份时间（unix ms）。 */
    val lastSuccessAt: Long = 0L,
)

/**
 * 状态缓存表 key=(hash, remote_id)——每 remote 一个目录：
 * `filesDir/backup-state/<remoteId>/confirmed.json`。
 * 备份成功后调用 [recordRun]：missing 从缓存移除（电脑端库被删/换库的
 * 漂移），其余候选（daemon 已确认存在，含 duplicates）加入缓存。
 */
class ConfirmedStore(private val dir: File) {
    private val file = File(dir, "confirmed.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): ConfirmedState =
        if (file.isFile) {
            try {
                json.decodeFromString(ConfirmedState.serializer(), file.readText())
            } catch (_: Exception) {
                ConfirmedState() // 损坏则当空缓存（不崩）
            }
        } else ConfirmedState()

    /** 该 remote 已确认条数 M。 */
    fun count(): Int = load().confirmed.size

    /** 最后成功备份时间（0 = 从未成功）。 */
    fun lastSuccessAt(): Long = load().lastSuccessAt

    /** 一次成功运行后同步缓存。幂等：重复传入同一 hash 集合无副作用。 */
    fun recordRun(confirmed: Set<String>, missing: Set<String>, lastSuccessAt: Long) {
        val cur = load()
        val next = ConfirmedState(
            confirmed = (cur.confirmed + confirmed) - missing,
            lastSuccessAt = lastSuccessAt,
        )
        dir.mkdirs()
        val tmp = File(dir, "confirmed.json.tmp")
        tmp.writeText(json.encodeToString(ConfirmedState.serializer(), next))
        check(tmp.renameTo(file)) { "cannot persist confirmed state" }
    }
}
