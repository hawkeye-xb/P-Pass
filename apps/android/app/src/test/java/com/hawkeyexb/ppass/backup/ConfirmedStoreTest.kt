// DOG-01b/DOG-01c: 三元组口径回归测试。
// 回归①（DOG-01b）：增量当全量——全量 100 备完后新拍 5 张，第二次运行后
//   三元组必须是 N=105 M=105（不是 N=5）。M 来自确认缓存（不依赖单次运行
//   报告）。
// 回归②（DOG-01c）：missing 时序错位——BackupReport.missing 是**上传前**
//   manifest 应答的缺失集合，commit 成功后这些文件全在库；生产调用链
//   （candidates + report → confirmedAfterCommit → recordRun）必须把本次
//   候选全部确认。旧实现 confirmed = allHashes − missing 会把刚上传成功的
//   照片从缓存删掉（首次全量备份 100 张成功后 M=0 且永远为 0）。
package com.hawkeyexb.ppass.backup

import java.io.ByteArrayInputStream
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmedStoreTest {

    /** 造 n 个不同 hash 的候选集合。 */
    private fun hashes(n: Int): Set<String> =
        (0 until n).map { "hash-%05d".format(it) }.toSet()

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-confirmed-$tag").toFile()

    /** 造一个可被 BackupRunner 报告消费的候选（测试用，不真读内容）。 */
    private fun candidate(i: Int, hash: String = "hash-%05d".format(i)): Candidate = Candidate(
        hash = hash,
        fileName = "photo-$i.jpg",
        mediaType = "image/jpeg",
        bytes = 1024,
        open = { ByteArrayInputStream(ByteArray(0)) },
    )

    /** MOB-13: 生产口径的 fileKey（BackupWorker/BackupUiStateHolder 传的是
     *  `MediaItem.uri.toString()`；JVM 单测起不了 android.net.Uri，用同形
     *  字符串——fileEntriesOf 只当它是不透明 key）。 */
    private fun fileKey(id: Int): String = "content://media/external/images/media/$id"

    /** MOB-13: 源码级断言的公共前处理——**剥掉注释行**再判断。
     *  （TriggerPolicyTest 同款：直接 contains 会被「把那行代码注释掉」
     *  骗过去，反证跑不红。） */
    private fun codeOf(file: File): String =
        file.readText().lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    @Test
    fun first_run_all_missing_pre_upload_then_all_success_m_equals_100() {
        // DOG-01c 回归测试（卡面验收①）：首次备份 100 张，manifest 上传前
        // 回 100 条 missing，随后全部上传且 commit 成功 → M 必须 = 100。
        // 走生产调用链：candidates + report → confirmedAfterCommit →
        // recordRun（与 BackupUiStateHolder.runBackup / BackupWorker 同款）。
        val dir = tempDir("dog01c-regression")
        val store = ConfirmedStore(dir)
        val candidates = (0 until 100).map { candidate(it) }
        val report = BackupReport(
            offered = 100, pushed = 100, ingested = 100, duplicates = 0,
            missing = candidates.map { it.hash }.toSet(),
        )
        store.recordRun(
            confirmed = confirmedAfterCommit(candidates, report),
            lastSuccessAt = 1000,
        )
        assertEquals("首次全量 100 张全部成功 → M 必须 = 100", 100, store.count())
        assertEquals(1000L, store.lastSuccessAt())
        dir.deleteRecursively()
    }

    @Test
    fun two_runs_full_then_incremental_shows_full_totals() {
        // 卡面验收②：两次运行 100→5 ⇒ N=105 M=105（增量当全量回归）。
        val dir = tempDir("regression")
        val store = ConfirmedStore(dir)

        // 运行 1：全量 100 张，daemon 全部确认。
        store.recordRun(confirmed = hashes(100), lastSuccessAt = 1000)
        // MediaStore 全量 count = 100 → N=100 M=100 K=0。
        var t = tripletOf(n = 100, confirmedCount = store.count().toLong(), lastSuccessAt = store.lastSuccessAt())
        assertEquals(100L, t.n)
        assertEquals(100L, t.m)
        assertEquals(0L, t.k)

        // 运行 2：增量扫描只出 5 张新照片（100..104），全量 count = 105。
        val new5 = hashes(105).drop(100).toSet()
        store.recordRun(confirmed = new5, lastSuccessAt = 2000)
        t = tripletOf(n = 105, confirmedCount = store.count().toLong(), lastSuccessAt = store.lastSuccessAt())
        assertEquals(
            "N 必须是全量 105，不是增量 offered 5",
            105L, t.n,
        )
        assertEquals("M 必须是累计确认 105", 105L, t.m)
        assertEquals(0L, t.k)
        dir.deleteRecursively()
    }

    @Test
    fun drift_exist_check_removes_30_of_100() {
        // 卡面验收③：缓存 100 条、exist-check 回 30 条 missing → M=70。
        // 漂移校准与备份运行解耦（DOG-01c）：removeMissing 只删 exist-check
        // 问出 daemon 已无的 hash，保留 lastSuccessAt 原值。
        val dir = tempDir("dog01c-drift")
        val store = ConfirmedStore(dir)
        store.recordRun(confirmed = hashes(100), lastSuccessAt = 42_000)
        assertEquals(100, store.count())

        // exist-check 回 30 条 missing（电脑端库被删/换库）。
        store.removeMissing(hashes(100).take(30).toSet())
        assertEquals("漂移后 M 必须 = 70", 70, store.count())
        assertEquals("lastSuccessAt 不被漂移校准改写", 42_000L, store.lastSuccessAt())

        val t = tripletOf(n = 100, confirmedCount = store.count().toLong(), lastSuccessAt = store.lastSuccessAt())
        assertEquals(70L, t.m)
        assertEquals("K 必须 = 30", 30L, t.k)
        dir.deleteRecursively()
    }

    @Test
    fun counterproof_exist_check_all_missing_means_k_equals_n() {
        // 反证（DOG-01 原卡）：exist-check 响应全 missing（电脑端库整个没了）
        // → 缓存清空，M=0，K 必须 = N。
        val dir = tempDir("counterproof")
        val store = ConfirmedStore(dir)

        store.recordRun(confirmed = hashes(50), lastSuccessAt = 1)
        assertEquals(50, store.count())

        store.removeMissing(hashes(50))
        assertEquals("全 missing 后缓存必须清零", 0, store.count())

        val t = tripletOf(n = 50, confirmedCount = store.count().toLong(), lastSuccessAt = store.lastSuccessAt())
        assertEquals(0L, t.m)
        assertEquals("K 必须 = N", 50L, t.k)
        dir.deleteRecursively()
    }

    @Test
    fun store_survives_reopen_like_app_kill() {
        // 杀 App 重开不归零：新 ConfirmedStore 实例读到同一缓存。
        val dir = tempDir("reopen")
        ConfirmedStore(dir).recordRun(confirmed = hashes(7), lastSuccessAt = 42_000)

        val reopened = ConfirmedStore(dir)
        assertEquals(7, reopened.count())
        assertEquals(42_000L, reopened.lastSuccessAt())
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_cache_reads_as_empty_not_crash() {
        val dir = tempDir("corrupt")
        File(dir, "confirmed.json").apply {
            parentFile.mkdirs()
            writeText("{not json")
        }
        val store = ConfirmedStore(dir)
        assertEquals(0, store.count())
        assertEquals(0L, store.lastSuccessAt())
        // 恢复写入也不崩。
        store.recordRun(confirmed = setOf("a"), lastSuccessAt = 7)
        assertEquals(1, store.count())
        dir.deleteRecursively()
    }

    @Test
    fun k_is_never_negative() {
        // M 超过 N（防御：确认缓存多过全量 count 的竞态）→ FIX-T6 验收③：
        // m clamp 到 n（UI 永不显示「手机 3 张 · 已备份 5」），k 恒 0。
        val t = tripletOf(n = 3, confirmedCount = 5, lastSuccessAt = 1)
        assertEquals(3L, t.n)
        assertEquals("M 必须 clamp 到 N", 3L, t.m)
        assertTrue("K 不为负", t.k >= 0)
        assertEquals(0L, t.k)
    }

    @Test
    fun disconnect_clears_confirmed_cache_for_that_remote_only() {
        // UX-06b 验收：写入缓存 → 模拟断开清理（生产函数
        // clearConfirmedCacheForRemote，MainActivity 断开分支同款）→
        // 该 remote ConfirmedStore.count()==0；别的 remote 目录不动。
        val root = tempDir("ux06b-disconnect")
        val remoteA = File(root, "backup-state/aaaa")
        val remoteB = File(root, "backup-state/bbbb")
        ConfirmedStore(remoteA).recordRun(confirmed = hashes(10), lastSuccessAt = 100)
        ConfirmedStore(remoteB).recordRun(confirmed = hashes(3), lastSuccessAt = 200)
        assertEquals(10, ConfirmedStore(remoteA).count())
        assertEquals(3, ConfirmedStore(remoteB).count())

        // 断开 remote A（生产调用链：filesDir + daemonNodeId）。
        clearConfirmedCacheForRemote(root, "aaaa")

        assertEquals("断开的 remote 确认缓存必须清零", 0, ConfirmedStore(remoteA).count())
        assertEquals(
            "别的 remote 确认缓存必须原样保留",
            3, ConfirmedStore(remoteB).count(),
        )
        root.deleteRecursively()
    }

    @Test
    fun counterproof_disconnect_without_delete_keeps_count_above_zero() {
        // UX-06b 反证：注释掉删除行（模拟回归）→ 断开后 count() 仍 > 0。
        // 正演 = 调生产函数后 count()==0（上一测试）；反演 = 只写缓存不删，
        // 缓存必须还在（证明测试真在测"删除"这个行为，而非恒真断言）。
        val root = tempDir("ux06b-counterproof")
        val remote = File(root, "backup-state/cccc")
        ConfirmedStore(remote).recordRun(confirmed = hashes(5), lastSuccessAt = 1)
        // 不调 clearConfirmedCacheForRemote（模拟删除行被注释）。
        assertEquals(
            "删除行缺失时断开不清缓存 → count() 仍 > 0",
            5, ConfirmedStore(remote).count(),
        )
        root.deleteRecursively()
    }

    // ── FIX-T6：范围口径（验收②）──

    @Test
    fun count_in_scope_counts_only_selected_albums() {
        // 验收②：范围 {相册A}，confirmed 含 A 的 3 条 + B 的 5 条 → M=3。
        val dir = tempDir("t6-scope")
        val store = ConfirmedStore(dir)
        // 记录时带 bucketId（备份记录从 MediaItem 带过来的生产语义）。
        val confirmed = hashes(8)
        val bucketOf = buildMap {
            confirmed.take(3).forEach { put(it, 1001L) } // A
            confirmed.drop(3).forEach { put(it, 2002L) } // B
        }
        store.recordRun(confirmed = confirmed, lastSuccessAt = 42, bucketOf = bucketOf)

        assertEquals("范围内 {A} → M 必须 = 3", 3, store.countInScope(setOf(1001L)))
        assertEquals("范围内 {B} → M 必须 = 5", 5, store.countInScope(setOf(2002L)))
        assertEquals("范围内 {A,B} → M = 8", 8, store.countInScope(setOf(1001L, 2002L)))
        assertEquals("null（从未选范围）→ 全量 8", 8, store.countInScope(null))
        assertEquals("空集（一个都不备）→ 0", 0, store.countInScope(emptySet()))
        dir.deleteRecursively()
    }

    @Test
    fun count_in_scope_legacy_entries_without_bucket_are_in_scope() {
        // 存量旧条目（0.3.1 之前备份，无 bucketId）→ 视为范围内（无法
        // 判定归属时宁可多算也不谎报「未备份」）。bucketOf 为空时全部
        // 旧条目都算进 M。
        val dir = tempDir("t6-legacy")
        val store = ConfirmedStore(dir)
        store.recordRun(confirmed = hashes(7), lastSuccessAt = 1) // 无 bucketOf

        assertEquals("旧条目无 bucketId → 范围内 M=7", 7, store.countInScope(setOf(1001L)))
        assertEquals("空集仍 = 0（一个都不备优先）", 0, store.countInScope(emptySet()))
        dir.deleteRecursively()
    }

    @Test
    fun triplet_m_never_exceeds_n() {
        // 验收③：任意组合下 UI 三元组永不出现 M > N——tripletOf clamp。
        for (n in listOf(0L, 1L, 10L, 1000L)) {
            for (m in listOf(0L, 1L, 10L, 1000L, 99999L)) {
                val t = tripletOf(n = n, confirmedCount = m, lastSuccessAt = 1)
                assertTrue("M 永不超 N (n=$n m=$m)", t.m <= t.n)
                assertTrue("K 恒 ≥0", t.k >= 0)
            }
        }
    }

    // ── MOB-13：K 永远归不了零（M 按 hash 计数、N 按文件计数）──

    @Test
    fun duplicate_content_all_backed_up_gives_k_zero() {
        // 卡面验收①：相册 5 个文件，其中 2 个**内容相同**（相机
        // `xxx(0).jpg` / 微信保存过又收到一次），全部备份成功 → K 必须 = 0。
        // 旧口径 M = confirmed.size = 4 个唯一 hash，N = MediaStore 文件
        // COUNT = 5 → K = 1 永远消不掉（用户报告的现象）。
        // 走生产调用链：fileEntriesOf + confirmedAfterCommit + recordRun +
        // tripletOf（与 BackupUiStateHolder.runBackup / BackupWorker 同款）。
        val dir = tempDir("mob13-dup")
        val store = ConfirmedStore(dir)

        // 文件 3 与文件 4 内容一致 → 同一个 hash（MediaStore 仍是两行）。
        val candidates = listOf(
            candidate(0), candidate(1), candidate(2),
            candidate(3, hash = "hash-dup"), candidate(4, hash = "hash-dup"),
        )
        val scanned = (0..4).map { fileKey(it) to 1001L as Long? }
        val report = BackupReport(
            offered = 5, pushed = 4, ingested = 4, duplicates = 1,
            missing = candidates.map { it.hash }.toSet(),
        )
        store.recordRun(
            confirmed = confirmedAfterCommit(candidates, report),
            lastSuccessAt = 1000,
            bucketOf = candidates.associate { it.hash to 1001L },
            files = fileEntriesOf(scanned, candidates),
        )

        assertEquals("内容 hash 只有 4 个（去重后）", 4, store.load().confirmed.size)
        assertEquals("M 必须按文件数 = 5", 5, store.count())

        val t = tripletOf(n = 5, confirmedCount = store.count().toLong(), lastSuccessAt = store.lastSuccessAt())
        assertEquals(5L, t.n)
        assertEquals(5L, t.m)
        assertEquals("5 张全部备份成功 → K 必须 = 0（不能被内容重复卡住）", 0L, t.k)

        // 范围口径同样按文件数（相册 1001 全选中）。
        assertEquals("范围内 M 也必须 = 5", 5, store.countInScope(setOf(1001L)))
        assertEquals("范围外 → 0", 0, store.countInScope(setOf(2002L)))
        dir.deleteRecursively()
    }

    @Test
    fun duplicate_content_with_one_unsynced_file_still_reports_k_one() {
        // 反向：不能靠"把 K 压成 0"作弊——5 个文件里 2 个内容相同已备份、
        // 另有 1 个真的没备份 → K 必须 = 1（真有没同步的必须报出来）。
        val dir = tempDir("mob13-partial")
        val store = ConfirmedStore(dir)
        val done = listOf(
            candidate(0), candidate(1),
            candidate(3, hash = "hash-dup"), candidate(4, hash = "hash-dup"),
        )
        val scanned = listOf(0, 1, 3, 4).map { fileKey(it) to null as Long? }
        store.recordRun(
            confirmed = done.mapTo(mutableSetOf()) { it.hash },
            lastSuccessAt = 1,
            files = fileEntriesOf(scanned, done),
        )
        val t = tripletOf(n = 5, confirmedCount = store.count().toLong(), lastSuccessAt = 1)
        assertEquals("已确认文件 4 个", 4L, t.m)
        assertEquals("剩 1 个没备份 → K = 1", 1L, t.k)
        dir.deleteRecursively()
    }

    @Test
    fun file_entries_size_mismatch_degrades_to_empty() {
        // fileEntriesOf 靠「scan.items 与 candidates 1:1 同序」配对。长度
        // 对不上（候选构建被改成 filter 之类）时必须**整体降级为空**，
        // 退回按 hash 计数的旧口径——绝不能错位写出 文件↔hash 的假对应。
        val candidates = listOf(candidate(0), candidate(1), candidate(2))
        assertEquals(
            "长度不等 → 空 map（降级，不错位）",
            emptyMap<String, ConfirmedFile>(),
            fileEntriesOf(listOf(fileKey(0) to 1L, fileKey(1) to 1L), candidates),
        )
        val ok = fileEntriesOf((0..2).map { fileKey(it) to 7L as Long? }, candidates)
        assertEquals(3, ok.size)
        assertEquals(ConfirmedFile("hash-00001", 7L), ok[fileKey(1)])
    }

    @Test
    fun legacy_hash_entries_without_file_records_still_count() {
        // 迁移兼容：存量 confirmed.json 没有文件级记录（0.3.4 之前备份的），
        // 这些 hash 仍按老口径一条算一个——升级后 M 不许突然掉下去。
        val dir = tempDir("mob13-legacy")
        val store = ConfirmedStore(dir)
        store.recordRun(confirmed = hashes(10), lastSuccessAt = 1) // 旧版写法
        assertEquals("升级后存量条目照旧计数", 10, store.count())

        // 之后一次带文件级记录的运行：3 个存量 hash 补上了文件记录（其中
        // 一个 hash 对应两个文件）→ 这 3 个不再按存量条目补记，改按文件数。
        val old = hashes(10).sorted()
        val migrated = listOf(
            candidate(0, hash = old[0]), candidate(1, hash = old[1]),
            candidate(2, hash = old[2]), candidate(3, hash = old[2]),
        )
        store.recordRun(
            confirmed = migrated.mapTo(mutableSetOf()) { it.hash },
            lastSuccessAt = 2,
            files = fileEntriesOf((0..3).map { fileKey(it) to null as Long? }, migrated),
        )
        assertEquals(
            "4 个已记录文件 + 7 个仍无文件记录的存量 hash",
            11, store.count(),
        )
        dir.deleteRecursively()
    }

    @Test
    fun out_of_scope_file_records_do_not_fall_back_to_legacy_counting() {
        // 覆盖判定必须跨全部范围：某 hash 的文件全在范围外时，它已经"有
        // 文件级记录"了，不能再当存量条目补记一条（那是别的相册的照片，
        // 不该进 M）——否则缩范围后 M 又虚高。
        val dir = tempDir("mob13-scope")
        val store = ConfirmedStore(dir)
        val inA = listOf(candidate(0, hash = "h-a"), candidate(1, hash = "h-a"))
        val inB = listOf(candidate(2, hash = "h-b"))
        store.recordRun(
            confirmed = setOf("h-a", "h-b"),
            lastSuccessAt = 1,
            files = fileEntriesOf(listOf(fileKey(0) to 1001L, fileKey(1) to 1001L), inA) +
                fileEntriesOf(listOf(fileKey(2) to 2002L), inB),
        )
        assertEquals("全量 = 3 个文件", 3, store.count())
        assertEquals("只选相册 A → 2 个文件（B 的不补记）", 2, store.countInScope(setOf(1001L)))
        assertEquals("只选相册 B → 1 个文件", 1, store.countInScope(setOf(2002L)))
        dir.deleteRecursively()
    }

    @Test
    fun drift_removes_file_records_of_missing_hashes() {
        // 漂移校准（电脑端库被删/换库）：exist-check 回 missing hash →
        // 指向它的文件级记录同时失效，M 必须跟着掉（内容重复的两个文件
        // 一起掉）。lastSuccessAt 与别的相册归属不受影响。
        val dir = tempDir("mob13-drift")
        val store = ConfirmedStore(dir)
        val cands = listOf(
            candidate(0, hash = "keep"), candidate(1, hash = "gone"),
            candidate(2, hash = "gone"),
        )
        store.recordRun(
            confirmed = setOf("keep", "gone"),
            lastSuccessAt = 42_000,
            bucketOf = mapOf("keep" to 1001L, "gone" to 1001L),
            files = fileEntriesOf((0..2).map { fileKey(it) to 1001L as Long? }, cands),
        )
        assertEquals(3, store.count())

        store.removeMissing(setOf("gone"))
        assertEquals("gone 的两个文件记录一起失效 → M = 1", 1, store.count())
        assertEquals("范围口径同样 = 1", 1, store.countInScope(setOf(1001L)))
        assertEquals("lastSuccessAt 不被漂移校准改写", 42_000L, store.lastSuccessAt())
        assertEquals(
            "MOB-13 顺带修正：漂移校准不再抹掉 bucketOf（原实现重建 state 时丢了）",
            mapOf("keep" to 1001L), store.load().bucketOf,
        )
        dir.deleteRecursively()
    }

    @Test
    fun production_call_sites_record_file_level_entries() {
        // 源码级断言（**先剥注释行**，见 codeOf）：两条生产写入链路都必须
        // 把文件级记录传给 recordRun。只改 ConfirmedStore 不改调用处 =
        // files 表永远是空的，K 照样归不了零，单测却全绿。
        val holder = codeOf(
            File(
                repoRoot(),
                "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt",
            )
        )
        val worker = codeOf(
            File(
                repoRoot(),
                "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt",
            )
        )
        assertTrue("手动备份必须记文件级确认", holder.contains("files = fileEntriesOf("))
        assertTrue("自动备份必须记文件级确认", worker.contains("files = fileEntriesOf("))
        // fileKey 口径 = MediaItem.uri.toString()（两端一致，否则同一文件
        // 在自动/手动两条链路会各记一条，M 虚高）。喂的列表两端不同名
        // （手动 scan.items / 自动 MOB-09 的 built.kept——跳过坏记录后
        // 只有 kept 与候选 1:1），只钉住取值口径。
        val key = ".map { it.uri.toString() to it.bucketId }"
        assertTrue("手动备份 fileKey 口径", holder.contains(key))
        assertTrue("自动备份 fileKey 口径", worker.contains(key))
        // 迁移路径：全已确认早退分支也要补齐文件级记录，否则存量用户
        // （每张都已备份）按几次备份都修不好 K。
        assertEquals(
            "runBackup 必须有两处 recordRun（正常提交 + 全已确认早退补齐）",
            2, Regex("confirmedStore\\.recordRun\\(").findAll(holder).count(),
        )
    }

    @Test
    fun record_run_with_bucket_updates_bucket_of() {
        // recordRun 带 bucketOf → 后续 countInScope 按新记录数；重复
        // 记录同 hash（幂等）不重复计数。
        val dir = tempDir("t6-record")
        val store = ConfirmedStore(dir)
        store.recordRun(confirmed = setOf("h1"), lastSuccessAt = 1, bucketOf = mapOf("h1" to 1001L))
        store.recordRun(confirmed = setOf("h1"), lastSuccessAt = 2, bucketOf = mapOf("h1" to 1001L))
        assertEquals(1, store.count())
        assertEquals(1, store.countInScope(setOf(1001L)))
        assertEquals("B 范围不包含 h1 → 0", 0, store.countInScope(setOf(2002L)))
        dir.deleteRecursively()
    }
}
