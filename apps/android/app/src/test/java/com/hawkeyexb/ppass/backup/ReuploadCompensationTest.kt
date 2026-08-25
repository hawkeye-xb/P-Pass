// MOB-34 验收：被删的老照片**真的**被传回来，且补偿是定向的（不是每轮全量重扫）。
//
// 真机现场（2026-08-25）：用户在库里删了 3 张 1 月的老照片，之后跑了 11 轮
// 备份（ingested=1/8/7/1/0/1/3/3/1…），传的全是新照片，那 3 张一次都没回来；
// 同时「待备份 K」永远归不了零（校准把这 3 个 hash 从 confirmed 剔除，而它们
// 永远不会被重新 offer）。根因是增量扫描按水位只看新照片，老照片远在水位之下。
//
// 反证（卡面第 2 条）：把 doWork 里的 `val items = plan.items` 退回
// `val items = scan.items`（即不合并补偿条目）→ 本文件
// [below_the_watermark_photo_comes_back_even_when_the_scan_is_empty] 与
// [doWork_feeds_the_merged_list_into_the_pipeline] 必须变红。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReuploadCompensationTest {

    /** 源码级断言的前处理：剥掉注释行（BadMediaRecordTest 同款）——
     *  正向 contains 会被「把那行注释掉」骗过，反向禁令会被注释里引用的
     *  旧写法误判。 */
    private fun codeOf(file: File): String =
        file.readText().lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    private fun src(rel: String): String =
        codeOf(File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/$rel"))

    private fun sliceAfter(s: String, marker: String): String {
        assertTrue("源码锚点已消失，断言失效：$marker", s.contains(marker))
        return s.substringAfter(marker)
    }

    private fun sliceBetween(s: String, from: String, to: String): String {
        val tail = sliceAfter(s, from)
        assertTrue("源码结束锚点已消失，断言失效：$to", tail.contains(to))
        return tail.substringBefore(to)
    }

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-reupload-$tag").toFile()

    /** 一条 MediaStore 条目的替身——JVM 单测碰不到 android.net.Uri，
     *  fileKey 用字符串（生产口径就是 `item.uri.toString()`）。 */
    private data class Item(val key: String, val bucketId: Long?)

    private fun plan(
        pending: Set<String>,
        found: List<Item>,
        scanned: List<Item> = emptyList(),
        bucketIds: Set<Long>? = null,
    ) = planReuploads(
        pending = pending,
        found = found,
        scanned = scanned,
        keyOf = { it.key },
        inScope = { bucketIds == null || it.bucketId == null || it.bucketId in bucketIds },
    )

    private val imagesPrefix = "content://media/external/images/media"
    private fun imgKey(id: Long) = "$imagesPrefix/$id"

    // ── 1. 反查：从「校准查出来缺的 hash」到「本地是哪几个条目」 ──

    @Test
    fun lost_hashes_resolve_to_their_local_file_keys() {
        val state = ConfirmedState(
            confirmed = setOf("h-old", "h-new"),
            files = mapOf(
                imgKey(11) to ConfirmedFile("h-old", 100L),
                imgKey(12) to ConfirmedFile("h-new", 100L),
            ),
        )
        assertEquals(setOf(imgKey(11)), reuploadTargetsOf(state, setOf("h-old")))
    }

    @Test
    fun same_hash_with_two_local_files_queues_both() {
        // MOB-13 的场景：同内容两个文件（相机 `xxx(0).jpg`、微信存过又收一次）。
        // 库里那一份被删 → 两条本地记录都该有机会把它补回去。
        val state = ConfirmedState(
            confirmed = setOf("dup"),
            files = mapOf(
                imgKey(21) to ConfirmedFile("dup", 100L),
                imgKey(22) to ConfirmedFile("dup", 100L),
            ),
        )
        assertEquals(setOf(imgKey(21), imgKey(22)), reuploadTargetsOf(state, setOf("dup")))
    }

    @Test
    fun legacy_entries_without_file_records_are_a_known_gap_not_a_full_rescan() {
        // MOB-13 之前备份的条目没有文件级记录 → 反查不到，定向补偿够不着。
        // **不许**为此退化成全量重扫（卡面第 3 条）：空集就是空集。
        val state = ConfirmedState(confirmed = setOf("legacy"), files = emptyMap())
        assertTrue(reuploadTargetsOf(state, setOf("legacy")).isEmpty())
    }

    // ── 2. 队列落盘 ──

    @Test
    fun queue_survives_a_process_restart_and_add_is_idempotent() {
        val dir = tempDir("persist")
        ReuploadQueue(dir).add(setOf(imgKey(1), imgKey(2)))
        ReuploadQueue(dir).add(setOf(imgKey(2)))
        assertEquals(setOf(imgKey(1), imgKey(2)), ReuploadQueue(dir).load())
        ReuploadQueue(dir).remove(setOf(imgKey(1)))
        assertEquals(setOf(imgKey(2)), ReuploadQueue(dir).load())
        dir.deleteRecursively()
    }

    @Test
    fun queue_lives_in_the_per_remote_state_dir_so_unpair_clears_it() {
        // 断开配对走 clearConfirmedCacheForRemote 的 deleteRecursively——
        // 队列与 confirmed.json 同目录，清理语义免费拿到（不需要第二处逻辑）。
        val filesDir = tempDir("unpair")
        val remote = "node-abc"
        val stateDir = File(filesDir, "backup-state/$remote")
        ReuploadQueue(stateDir).add(setOf(imgKey(9)))
        assertTrue(File(stateDir, "reupload-queue.json").isFile)
        clearConfirmedCacheForRemote(filesDir, remote)
        assertTrue(ReuploadQueue(stateDir).load().isEmpty())
        filesDir.deleteRecursively()
    }

    // ── 3. 卡面验收①：水位之下的老照片仍被 offer ──

    @Test
    fun below_the_watermark_photo_comes_back_even_when_the_scan_is_empty() {
        // 真机那一组数字的 JVM 复刻：增量扫描空（没有新照片），而队列里
        // 有一条 1 月的老照片 → 本轮候选必须包含它。
        val old = Item(imgKey(101), 100L)
        val p = plan(pending = setOf(old.key), found = listOf(old), scanned = emptyList())
        assertEquals("水位之下的老照片必须进本轮候选", listOf(old), p.items)
        assertTrue("查得到的条目不许被丢出队列", p.drop.isEmpty())
    }

    @Test
    fun compensation_rides_along_with_the_new_photos() {
        val fresh = Item(imgKey(200), 100L)
        val old = Item(imgKey(101), 100L)
        val p = plan(pending = setOf(old.key), found = listOf(old), scanned = listOf(fresh))
        assertEquals(listOf(fresh, old), p.items)
    }

    @Test
    fun an_item_already_in_the_scan_is_not_added_twice() {
        // 1:1 同序是下游 fileEntriesOf 的承重前提（长度对不上就整体降级成
        // 空 map，MOB-13 的 K 又归不了零）。重复项会破坏它。
        val both = Item(imgKey(300), 100L)
        val p = plan(pending = setOf(both.key), found = listOf(both), scanned = listOf(both))
        assertEquals(listOf(both), p.items)
    }

    // ── 4. 卡面验收③：定向，不是全量重扫 ──

    @Test
    fun an_empty_queue_looks_up_nothing_at_all() {
        // 绝大多数轮次队列是空的——这条路径必须零成本（一次查询都不发）。
        val fresh = Item(imgKey(200), 100L)
        val p = plan(pending = emptySet(), found = emptyList(), scanned = listOf(fresh))
        assertEquals(listOf(fresh), p.items)
        assertTrue(p.drop.isEmpty())
    }

    @Test
    fun the_lookup_only_ever_asks_for_the_queued_ids() {
        // 定向查询的实现点：itemsByKeys 只把队列里那几个 _ID 拼进 IN ()。
        // mediaIdsOf 是它的解析器——只认「前缀 + / + 全数字」，别的一律不认
        // （认错了就会去查一个不相干的 _ID，把无关照片重传上去）。
        val keys = setOf(
            imgKey(11),
            "content://media/external/video/media/12",
            "content://media/external/images/media/not-a-number",
            "file:///storage/emulated/0/DCIM/x.jpg",
        )
        assertEquals(setOf(11L), mediaIdsOf(keys, imagesPrefix))
        assertEquals(setOf(12L), mediaIdsOf(keys, "content://media/external/video/media"))
        assertTrue(mediaIdsOf(emptySet(), imagesPrefix).isEmpty())
    }

    @Test
    fun full_rescan_stays_a_manual_only_semantic() {
        // 回归锁：补偿这条路径**不许**通过「把 since 改成 0」实现。
        // 全量重扫在大库上是几分钟的活，只许留给手动触发（MOB-19 事件⑥）。
        val body = sliceBetween(
            src("backup/BackupWorker.kt"),
            "override suspend fun doWork()",
            "catch (t: CancellationException)",
        )
        assertEquals(
            "since 只许有一处、且只由 fullRescan 决定",
            1,
            Regex("val since = if \\(fullRescan\\) 0L else watermarks\\.load\\(\\)")
                .findAll(body).count(),
        )
        assertTrue("定向查询必须走 itemsByKeys(pending)", body.contains("scanner.itemsByKeys(pending)"))
        assertFalse(
            "补偿不许靠全量扫描实现",
            body.contains("scanSince(0"),
        )
    }

    // ── 5. 队列清理：没救的条目必须能丢（别和 MOB-09 打架） ──

    @Test
    fun a_row_that_no_longer_exists_is_dropped_instead_of_retried_forever()
    {
        // 用户把手机上的原图也删了（MOB-29 说的「正确删除姿势」）——
        // MediaStore 查不到这一行，队列条目必须丢掉，不是每轮再查一次。
        val p = plan(pending = setOf(imgKey(101)), found = emptyList())
        assertTrue(p.items.isEmpty())
        assertEquals(setOf(imgKey(101)), p.drop)
    }

    @Test
    fun an_out_of_scope_item_is_dropped_and_never_re_uploaded() {
        // 用户缩过备份范围：那些照片已经不是我们的事，既不补也不占队列。
        val out = Item(imgKey(400), bucketId = 999L)
        val p = plan(pending = setOf(out.key), found = listOf(out), bucketIds = setOf(100L))
        assertTrue(p.items.isEmpty())
        assertEquals(setOf(out.key), p.drop)
    }

    @Test
    fun an_item_with_unknown_bucket_is_kept_in_scope() {
        // 与 ConfirmedStore.countInScope 同口径：归属未知视为范围内
        // （无法判定时宁可多算也不谎报「未备份」）。
        val unknown = Item(imgKey(401), bucketId = null)
        val p = plan(pending = setOf(unknown.key), found = listOf(unknown), bucketIds = setOf(100L))
        assertEquals(listOf(unknown), p.items)
        assertTrue(p.drop.isEmpty())
    }

    @Test
    fun unreadable_rows_are_dropped_before_the_empty_candidates_early_return() {
        // 行还在、文件打不开（MOB-09 的坏记录）：它进得了 MediaStore 查询，
        // 死在 buildCandidates 的探针上。出队必须发生在
        // `if (candidates.isEmpty())` 早退**之前**——否则「整批都读不了」
        // 这条路径每轮都把同一条坏记录查回来、读失败、原样留着，正是
        // MOB-09 要防的「一条坏记录卡死整批」。
        val body = sliceBetween(
            src("backup/BackupWorker.kt"),
            "override suspend fun doWork()",
            "catch (t: CancellationException)",
        )
        val dropAt = body.indexOf("reuploads.remove(built.skipped")
        val earlyReturnAt = body.indexOf("if (candidates.isEmpty())")
        assertTrue("坏记录必须出队", dropAt >= 0)
        assertTrue("必须在整批读不了的早退之前出队", dropAt in 0 until earlyReturnAt)
    }

    @Test
    fun committed_items_leave_the_queue_but_a_failed_run_keeps_them() {
        // 出队点在 recordRun 之后：run 抛错就走不到那里，队列原样保留、
        // 下一轮再试——网络瞬断不许把该补的照片悄悄丢掉。
        val body = sliceBetween(
            src("backup/BackupWorker.kt"),
            "override suspend fun doWork()",
            "catch (t: CancellationException)",
        )
        val recordAt = body.indexOf("confirmedStore.recordRun(")
        val dropAt = body.indexOf("reuploads.remove(built.kept")
        assertTrue("传成功的补偿条目必须出队", dropAt >= 0)
        assertTrue("出队必须在 recordRun 之后（失败路径保留队列）", dropAt > recordAt)
    }

    // ── 6. 卡面验收④：K 归零 ──

    @Test
    fun K_returns_to_zero_after_the_compensation_lands() {
        // 完整链条：2 个文件已确认（K=0）→ 库里删掉 1 张 → 校准剔除（K=1）
        // → 定向补偿传回 → recordRun 写回 hash + 文件级记录 → K 归零。
        val dir = tempDir("k-zero")
        val store = ConfirmedStore(dir)
        val queue = ReuploadQueue(dir)
        val n = 2L
        store.recordRun(
            confirmed = setOf("h1", "h2"),
            lastSuccessAt = 1L,
            bucketOf = mapOf("h1" to 100L, "h2" to 100L),
            files = mapOf(
                imgKey(1) to ConfirmedFile("h1", 100L),
                imgKey(2) to ConfirmedFile("h2", 100L),
            ),
        )
        assertEquals(0L, tripletOf(n, store.countInScope(setOf(100L)).toLong(), 1L).k)

        // 库里删掉 h1 → 生产口径的校准（onLost 登记 + removeMissing）。
        val ok = runBlocking {
            calibrateConfirmed(
                store,
                existCheck = { setOf("h1") },
                onLost = { lost -> enqueueReuploads(store.load(), queue, lost) },
            )
        }
        assertTrue(ok)
        assertEquals("补偿目标必须被登记", setOf(imgKey(1)), queue.load())
        assertEquals("校准之后 K 变成 1（这就是真机上归不了零的那个 1）",
            1L, tripletOf(n, store.countInScope(setOf(100L)).toLong(), 1L).k)

        // 定向补偿：队列里那一条被查回来、进候选、传成功 → 写回。
        val found = listOf(Item(imgKey(1), 100L))
        val p = plan(pending = queue.load(), found = found, bucketIds = setOf(100L))
        assertEquals(listOf(found[0]), p.items)
        store.recordRun(
            confirmed = setOf("h1"),
            lastSuccessAt = 2L,
            bucketOf = mapOf("h1" to 100L),
            files = mapOf(imgKey(1) to ConfirmedFile("h1", 100L)),
        )
        queue.remove(setOf(imgKey(1)))
        assertEquals("补偿完成后 K 必须归零",
            0L, tripletOf(n, store.countInScope(setOf(100L)).toLong(), 1L).k)
        assertTrue("队列必须清空（否则每轮都白查一次）", queue.load().isEmpty())
        dir.deleteRecursively()
    }

    // ── 7. 接线：两条校准路径都必须登记 ──

    @Test
    fun doWork_feeds_the_merged_list_into_the_pipeline() {
        // 合并后的列表必须**全部**替掉 scan.items：候选构建、进度 total、
        // batchSize 漏一处，1:1 同序就断（fileEntriesOf 降级成空 map，
        // K 又归不了零——MOB-13 的坑）。
        val body = sliceBetween(
            src("backup/BackupWorker.kt"),
            "override suspend fun doWork()",
            "catch (t: CancellationException)",
        )
        assertTrue("必须先算补偿计划", body.contains("val plan = planReuploads("))
        assertTrue("合并结果必须落成本轮列表", body.contains("val items = plan.items"))
        assertTrue("候选必须从合并列表构建", body.contains("buildCandidates(items)"))
        assertTrue("批次数必须按合并列表算", body.contains("batchSize = items.size"))
        // scan.items 只许剩**一处**：喂给 planReuploads 的那个参数。
        // 别处（候选构建、进度 total、batchSize）漏改一处就断 1:1。
        assertEquals(
            "扫描结果不许再被直接喂进管线（漏一处就断 1:1）",
            1,
            Regex("scan\\.items").findAll(body).count(),
        )
        assertTrue(
            "那一处必须是 planReuploads 的 scanned 参数",
            sliceBetween(body, "val plan = planReuploads(", "val items = plan.items")
                .contains("scanned = scan.items"),
        )
    }

    @Test
    fun both_calibration_doors_enqueue_before_the_cache_is_pruned() {
        // 少接一处 = 那条门里的 hash 照样被剔除、永不补偿，bug 换个门重现。
        val worker = src("backup/BackupWorker.kt")
        val onLost = sliceBetween(worker, "onLost = { lost ->", "postReuploadNotification")
        assertTrue(
            "BackupWorker 的校准必须登记补偿",
            onLost.contains("enqueueReuploads(store.load(), reuploads, lost)"),
        )

        val holder = src("backup/BackupUiStateHolder.kt")
        val calib = sliceAfter(holder, "private suspend fun calibrateFromDaemon()")
        val enqueueAt = calib.indexOf("enqueueReuploads(")
        val removeAt = calib.indexOf("confirmedStore.removeMissing(missing)")
        assertTrue("App 打开时那次校准同样必须登记补偿", enqueueAt >= 0)
        assertTrue("登记必须在 removeMissing 之前（之后文件级记录就没了）",
            enqueueAt in 0 until removeAt)
    }

    @Test
    fun enqueue_reads_the_pre_calibration_snapshot() {
        // 顺序契约的直接判据：把登记挪到 removeMissing 之后，反查恒空。
        val dir = tempDir("order")
        val store = ConfirmedStore(dir)
        val queue = ReuploadQueue(dir)
        store.recordRun(
            confirmed = setOf("h1"),
            lastSuccessAt = 1L,
            files = mapOf(imgKey(1) to ConfirmedFile("h1", 100L)),
        )
        store.removeMissing(setOf("h1"))
        assertTrue(
            "removeMissing 之后再登记 = 什么都登记不到（所以顺序是承重的）",
            enqueueReuploads(store.load(), queue, setOf("h1")).isEmpty(),
        )
        dir.deleteRecursively()
    }
}
