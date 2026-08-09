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
// backup-state/<remoteId>/）；备份 commit 成功后本次候选全部加入缓存。
// 漂移校准（电脑端库被删/换库）与备份运行解耦：单独对缓存 hash 集做
// 只查不传的 exist-check（manifest「给 hashes 回 missing」语义，
// 不 push 不 commit），missing → 从缓存移除。触发时机：App 打开或
// 备份前，daemon 可达才跑，不可达跳过（三元组显示缓存值）。
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

/** DOG-01c: 一次成功 commit 后，本次候选**全部**确认。
 *
 *  [BackupReport.missing] 是**上传前** manifest 应答的缺失集合——这些文件
 *  随后被上传且 commit 成功，duplicates 与刚 ingested 的都在 daemon 库中，
 *  因此减项 = ∅。
 *  （回归：DOG-01b 旧实现 confirmed = allHashes − missing，把刚上传成功
 *  的照片从缓存删掉——首次全量备份 100 张成功后 M=0 且永远为 0。）
 *  漂移校准（电脑端库被删/换库）由独立的 exist-check 负责
 *  （[ConfirmedStore.removeMissing]），不挂在备份运行上。
 */
fun confirmedAfterCommit(candidates: List<Candidate>, report: BackupReport): Set<String> =
    candidates.mapTo(mutableSetOf()) { it.hash }

/** UX-06b: 断开连接时清空该 remote 的确认缓存目录
 * （`filesDir/backup-state/<remoteId>/`）——重配对到同一台电脑后 M 从
 * 0 重新计数，绝不沿用旧缓存（电脑端删过库时 M 虚高，首屏是错的；
 * 漂移校准虽会修正但时机滞后）。只删该 remote 目录，不动别的 remote。
 * MainActivity 断开确认分支调用（与测试共用同一生产函数）。 */
fun clearConfirmedCacheForRemote(filesDir: File, daemonNodeId: String) {
    File(filesDir, "backup-state/$daemonNodeId").deleteRecursively()
}

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
 * 备份成功（commit 落地）后调用 [recordRun]：本次候选全部加入缓存
 * （duplicates 与刚 ingested 的都在 daemon 库）。
 * 漂移校准（电脑端库被删/换库）用 [removeMissing]：对缓存 hash 集做
 * 只查不传的 exist-check，问出 daemon 已无的 hash 并从缓存移除。
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

    /** T6: 该 hash 是否已确认到家（手动备份跳过重复 hash 的预过滤）。 */
    fun contains(hash: String): Boolean = hash in load().confirmed

    /** 最后成功备份时间（0 = 从未成功）。 */
    fun lastSuccessAt(): Long = load().lastSuccessAt

    /** 一次成功运行后同步缓存：本次候选全部确认。幂等：重复传入同一
     *  hash 集合无副作用。 */
    fun recordRun(confirmed: Set<String>, lastSuccessAt: Long) {
        val cur = load()
        persist(
            ConfirmedState(
                confirmed = cur.confirmed + confirmed,
                lastSuccessAt = lastSuccessAt,
            )
        )
    }

    /** DOG-01c: 漂移校准——exist-check 问出 daemon 已无此库的 hash
     *  （电脑端库被删/换库）从缓存移除；保留 lastSuccessAt 原值。 */
    fun removeMissing(missing: Set<String>) {
        if (missing.isEmpty()) return
        val cur = load()
        persist(
            ConfirmedState(
                confirmed = cur.confirmed - missing,
                lastSuccessAt = cur.lastSuccessAt,
            )
        )
    }

    private fun persist(next: ConfirmedState) {
        dir.mkdirs()
        val tmp = File(dir, "confirmed.json.tmp")
        tmp.writeText(json.encodeToString(ConfirmedState.serializer(), next))
        check(tmp.renameTo(file)) { "cannot persist confirmed state" }
    }
}
