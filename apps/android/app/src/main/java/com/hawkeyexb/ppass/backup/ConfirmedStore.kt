// LEGACY BATCH STATE — frozen by REBUILD-00; Flow confirmation lives in backup.flow.
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
//
// MOB-13 口径修复（K 永远归不了零）：M 曾是 confirmed（内容 hash 集合）
// 的 size，而 N 是 MediaStore 的文件 COUNT。相册里只要有内容重复的照片
// （相机 `xxx(0).jpg`、微信保存过又收到一次），hash 集合记一条、文件数
// 记两条 → K = N − M 恒 > 0，哪怕每一张都已备份成功（用户 116 个文件
// 全部到家，UI 仍说有未同步）。修法：确认缓存**增记文件级记录**
// （fileKey=MediaStore uri → hash + bucketId），M 改成「已确认**文件**
// 数」，与 N 同单位。confirmed 仍在（去重预过滤、exist-check 漂移校准、
// 照片页归属过滤都按内容 hash 走），只是不再当 M 用。
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
 *
 *  FIX-T6 验收③：**UI 三元组永不出现 M > N**——m 在这里 clamp 到 n
 *  （确认缓存漂移/口径过渡期 m 可能超 n，显示层必须收敛，否则 UI 出
 *  「手机 10 张 · 已备份 51」类假话）。k 由 clamp 后的 m 计算，恒 ≥0。
 */
fun tripletOf(n: Long, confirmedCount: Long, lastSuccessAt: Long): BackupTriplet =
    BackupTriplet(
        n = n,
        m = confirmedCount.coerceAtMost(n),
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

/** MOB-13: 一条**文件级**确认记录（key 是文件标识，不是内容 hash）。
 *  @param hash 该文件的内容 hash（与 [ConfirmedState.confirmed] 同一口径，
 *   漂移校准移除该 hash 后这条记录随之失效——见 [ConfirmedStore.countInScope]）
 *  @param bucketId 所属相册（范围口径；null = 未知，视为范围内） */
@Serializable
data class ConfirmedFile(val hash: String, val bucketId: Long? = null)

/** MOB-13: 把「本次扫描到的文件（fileKey, bucketId）」与**同序**候选配成
 *  文件级确认记录。fileKey 生产口径 = `MediaItem.uri.toString()`
 *  （content://media/external/images/media/<_ID>，MediaStore 里唯一）。
 *
 *  两个列表必须 1:1 同序（`scan.items.map { … }` 建候选的天然性质）。
 *  **一旦候选构建改成 filter/flatMap 之类破坏 1:1 的写法**，这里长度对不上
 *  → 返回空 map → 退回「按 hash 计数」的旧口径（会重新出现 K 归不了零，
 *  但绝不会写错文件↔hash 的对应关系）。ConfirmedStoreTest
 *  `file_entries_size_mismatch_degrades_to_empty` 钉住这个降级语义。
 */
fun fileEntriesOf(
    files: List<Pair<String, Long?>>,
    candidates: List<Candidate>,
): Map<String, ConfirmedFile> =
    if (files.size != candidates.size) {
        emptyMap()
    } else {
        files.indices.associate { i ->
            files[i].first to ConfirmedFile(candidates[i].hash, files[i].second)
        }
    }

/** 一个 remote 的确认状态（崩溃安全持久化，tmp + rename）。 */
@Serializable
data class ConfirmedState(
    /** 已被该 remote 确认存在的本地资产 hash 集合。 */
    val confirmed: Set<String> = emptySet(),
    /** FIX-T6: 确认条目的所属相册（hash → bucketId）。记录备份时从
     *  MediaItem 带过来；**存量旧条目无 bucketId = 视为范围内**（口径
     *  注释见 [ConfirmedStore.countInScope]），随下次备份/exist-check
     *  校准逐步补齐。 */
    val bucketOf: Map<String, Long> = emptyMap(),
    /** MOB-13: **文件级**确认记录（fileKey → [ConfirmedFile]）。
     *  存在的理由：[confirmed] 是内容 hash 的集合，同内容的两个文件只占
     *  一条，而 N 是 MediaStore 的文件 COUNT——两个口径一混，相册里只要
     *  有一张内容重复的照片（相机的 `xxx(0).jpg`、微信保存过又收到一次），
     *  K = N − M 就恒 > 0，哪怕每一张都已备份成功。
     *  **存量旧数据没有这张表**——迁移口径见 [ConfirmedStore.countInScope]。 */
    val files: Map<String, ConfirmedFile> = emptyMap(),
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

    /** 该 remote 已确认条数 M（全量口径——调用方按范围过滤，
     *  见 [countInScope]）。MOB-13 起同为**文件**数口径。 */
    fun count(): Int = countInScope(null)

    /** FIX-T6: 当前备份范围口径下的已确认条数。范围外的确认数不进 M
     *  （DOG-01 钉死的「分母=当前扫描范围、口径一处定义」——T6 改了
     *  分母（N 按范围算）就必须同步改分子）。
     *
     *  MOB-13: 分子还必须与分母**同单位**。N 是 MediaStore 的文件 COUNT，
     *  所以 M 数的是**文件**，不是内容 hash：
     *  - 有文件级记录的（[ConfirmedState.files]）：一条文件记一个，只要
     *    它的 hash 仍在 [ConfirmedState.confirmed] 里（漂移校准移除该
     *    hash → 这些文件同时失效）；
     *  - 没有任何文件级记录的 hash（**存量旧条目**，0.3.4 之前备份的）：
     *    按老口径一条算一个——无法判定它对应几个文件时宁可少算也不虚报
     *    「已备份」，随下次手动备份（since=0 全量扫描）补齐文件级记录。
     *
     *  范围口径：
     *  - [bucketIds] == null（从未选范围）= 全量；
     *  - 空集 = 一个都不备 → 0；
     *  - 非空：只数 bucketId ∈ 范围的条目；**bucketId 未知的视为范围内**
     *    ——无法判定归属时宁可多算也不谎报「未备份」。
     */
    fun countInScope(bucketIds: Set<Long>?): Int {
        if (bucketIds != null && bucketIds.isEmpty()) return 0
        val s = load()
        fun inScope(bucketId: Long?): Boolean =
            bucketIds == null || bucketId == null || bucketId in bucketIds

        // 仍然有效的文件级记录（hash 还在确认集里）。covered 必须跨**全部**
        // 范围统计：某 hash 的文件都落在范围外时，它已经"有文件级记录"了，
        // 不能再按存量旧条目补记一条（那是范围外的照片，不该进 M）。
        val liveFiles = s.files.values.filter { it.hash in s.confirmed }
        val fileCount = liveFiles.count { inScope(it.bucketId) }
        val covered = liveFiles.mapTo(mutableSetOf()) { it.hash }
        val legacyCount = s.confirmed.count { h ->
            h !in covered && inScope(s.bucketOf[h])
        }
        return fileCount + legacyCount
    }

    /** T6: 该 hash 是否已确认到家（手动备份跳过重复 hash 的预过滤）。 */
    fun contains(hash: String): Boolean = hash in load().confirmed

    /** 最后成功备份时间（0 = 从未成功）。 */
    fun lastSuccessAt(): Long = load().lastSuccessAt

    /** 一次成功运行后同步缓存：本次候选全部确认。幂等：重复传入同一
     *  hash 集合无副作用。FIX-T6: 同时记录每个 hash 的所属相册
     *  [bucketOf]（备份记录时从 MediaItem 带过来；无 bucketId 的条目
     *  不写——保持「旧条目」语义由 [countInScope] 视为范围内）。
     *
     *  MOB-13: [files] = 本次扫描到的**文件级**确认记录（[fileEntriesOf]
     *  由 scan.items + 同序候选生成）。同 fileKey 重复记录直接覆盖（文件
     *  被改写 → 新 hash）；不传 = 只写 hash 口径（旧行为）。 */
    fun recordRun(
        confirmed: Set<String>,
        lastSuccessAt: Long,
        bucketOf: Map<String, Long> = emptyMap(),
        files: Map<String, ConfirmedFile> = emptyMap(),
    ) {
        val cur = load()
        persist(
            ConfirmedState(
                confirmed = cur.confirmed + confirmed,
                bucketOf = cur.bucketOf + bucketOf,
                files = cur.files + files,
                lastSuccessAt = lastSuccessAt,
            )
        )
    }

    /** DOG-01c: 漂移校准——exist-check 问出 daemon 已无此库的 hash
     *  （电脑端库被删/换库）从缓存移除；保留 lastSuccessAt 原值。
     *
     *  MOB-13: 同时清掉指向这些 hash 的文件级记录（[ConfirmedState.files]）
     *  与 [ConfirmedState.bucketOf] 条目，三张表不留悬挂项。
     *  顺带修掉旧实现丢 bucketOf 的问题：原来重建 ConfirmedState 时没带
     *  bucketOf，一次漂移校准就把所有相册归属抹平（残留条目全部退化成
     *  「视为范围内」，缩过范围的 M 虚高）——顺手保留，见卡面「顺带修正」。 */
    fun removeMissing(missing: Set<String>) {
        if (missing.isEmpty()) return
        val cur = load()
        persist(
            ConfirmedState(
                confirmed = cur.confirmed - missing,
                bucketOf = cur.bucketOf.filterKeys { it !in missing },
                files = cur.files.filterValues { it.hash !in missing },
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
