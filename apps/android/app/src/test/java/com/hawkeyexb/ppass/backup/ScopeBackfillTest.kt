// MOB-36 验收：**移进**已选相册的老照片真的被备份，且这件事不许靠每轮全量重扫。
//
// 真机现场（2026-08-26，验收人原话）：「必须拍照才行？我通过相册移动，它后台
// 没触发？」——相册之间移动照片不改 `_ID` / `date_added` / `date_modified`，
// 只改 `bucket_id`，于是这张老照片的水位值远在当前水位之下，增量扫描永远看不见
// 它：MediaStore 通知照发、看门 job 照起、派活正常，**但什么也没传**。
//
// 反证（卡面第 2 条，两条都真跑过，输出摘录在卡里）：
//  1. `doWork` 里 `val items = plan.items + backfill` 退回 `val items = plan.items`
//     （算出来了却不喂进管线）→ [the_backfill_is_merged_into_this_rounds_list] 变红。
//  2. [planScopeBackfill] 退回 `return emptyList()`（不补齐）→
//     [a_photo_moved_into_a_selected_album_enters_this_round] 等 3 条变红。
//  3. 去掉「已确认的跳过」这一条（返回 below 全部）→
//     [a_photo_already_backed_up_is_not_uploaded_again_when_it_moves] 变红。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScopeBackfillTest {

    /** 源码级断言的前处理：剥掉注释行（BadMediaRecordTest 同款）——正向
     *  contains 会被「把那行注释掉」骗过，反向禁令会被注释里引用的旧写法误判。 */
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
        java.nio.file.Files.createTempDirectory("ppass-backfill-$tag").toFile()

    private val imagesPrefix = "content://media/external/images/media"
    private fun imgKey(id: Long) = "$imagesPrefix/$id"

    /** 一条 MediaStore 条目的替身（JVM 单测碰不到 android.net.Uri）。
     *  [hash] = 「两张现成的表能不能查到它的 hash」的替身：null = 未知
     *  （从来没在范围内被哈希过 = 刚被移进来的那种）。 */
    private data class Item(val key: String, val hash: String?)

    /** 生产调用点的形状：knownHashOf 走两张表，isConfirmed 查确认集。
     *  [hashed] 统计「hash 未知、因此下游必须开流哈希」的条目数——这是本卡
     *  真正要压住的成本（卡面第 3 条）。 */
    private fun backfill(
        below: List<Item>,
        already: List<Item> = emptyList(),
        confirmed: Set<String> = emptySet(),
    ): Pair<List<Item>, Int> {
        val out = planScopeBackfill(
            below = below,
            already = already,
            keyOf = { it.key },
            knownHashOf = { it.hash },
            isConfirmed = { it in confirmed },
        )
        return out to out.count { it.hash == null }
    }

    // ── 卡面验收①：水位之下、范围之内、未确认 → 进本轮候选 ──

    @Test
    fun a_photo_moved_into_a_selected_album_enters_this_round() {
        // 1 月的老照片被移进已选相册：_ID 与水位值都没变（增量扫描恒空），
        // 它从没在范围内被哈希过 → 两张表都查不到 → 必须进本轮候选。
        val moved = Item(imgKey(101), hash = null)
        val (items, hashed) = backfill(below = listOf(moved))
        assertEquals("移进来的老照片必须进本轮候选", listOf(moved), items)
        assertEquals("它是唯一需要哈希的那一条", 1, hashed)
    }

    @Test
    fun a_hash_that_calibration_pruned_comes_back() {
        // hash 已知（缓存里有）但已不在 confirmed 里（电脑端库被删/换库，
        // 校准剔除过）→ 仍要补。与 MOB-34 的定向补偿同一族语义，这里是
        // 靠范围查询兜住的第二道网。
        val pruned = Item(imgKey(102), hash = "h-pruned")
        val (items, hashed) = backfill(below = listOf(pruned), confirmed = setOf("h-other"))
        assertEquals(listOf(pruned), items)
        assertEquals("hash 已知 → 下游命中缓存，不用重新读流", 0, hashed)
    }

    // ── 卡面验收④：已经备份过的照片被移动 → 不重复上传 ──

    @Test
    fun a_photo_already_backed_up_is_not_uploaded_again_when_it_moves() {
        // 在客户端就挡住，**不靠存储端 duplicate 兜底**——那等于每次移动都
        // 白跑一趟传输。判据两条：不进候选，且一次哈希都不做。
        val done = Item(imgKey(201), hash = "h-done")
        val (items, hashed) = backfill(below = listOf(done), confirmed = setOf("h-done"))
        assertTrue("已确认的照片被移动不许重新上传", items.isEmpty())
        assertEquals("已确认的照片一次都不许被哈希", 0, hashed)
    }

    @Test
    fun the_known_hash_comes_from_two_ready_made_tables_and_never_from_a_re_hash() {
        // 生产的 knownHashOfFile：先文件级确认记录（per-remote 权威口径），
        // 再 PERF-01 的哈希缓存（全局兜底，覆盖存量条目/换过配对的机器）。
        val cache = HashCache(File(tempDir("known"), "hash-cache.json"))
        cache.put("${imgKey(302)}|g7", "from-cache")
        cache.put("${imgKey(303)}|m1700000000|s4096", "from-cache-old-api")
        val state = ConfirmedState(
            confirmed = setOf("from-files"),
            files = mapOf(imgKey(301) to ConfirmedFile("from-files", 100L)),
        )
        assertEquals(
            "第一路：文件级确认记录",
            "from-files",
            knownHashOfFile(state, cache, imgKey(301), "${imgKey(301)}|g1"),
        )
        assertEquals(
            "第二路：哈希缓存（存量条目只有这一路）",
            "from-cache",
            knownHashOfFile(state, cache, imgKey(302), "${imgKey(302)}|g7"),
        )
        assertEquals(
            "API<30 的 key 形状也必须认，否则老设备上第二路失效",
            "from-cache-old-api",
            knownHashOfFile(state, cache, imgKey(303), "${imgKey(303)}|m1700000000|s4096"),
        )
        assertNull(
            "文件改过（缓存 key 带修改信号）→ 必然 miss，当未知重新哈希，" +
                "绝不拿旧内容的 hash 冒充",
            knownHashOfFile(state, cache, imgKey(302), "${imgKey(302)}|g8"),
        )
        assertNull(
            "两张表都不知道 = 从没在范围内处理过",
            knownHashOfFile(state, cache, imgKey(999), "${imgKey(999)}|g1"),
        )
    }

    // ── 1:1 同序：不许重复追加 ──

    @Test
    fun an_item_already_in_this_round_is_not_added_twice() {
        // 下游 fileEntriesOf 靠「文件列表与候选列表 1:1 同序」配 fileKey↔hash，
        // 重复项会让长度对不上而整体降级成空 map（MOB-13 的 K 又归不了零）。
        val both = Item(imgKey(401), hash = null)
        val (items, _) = backfill(below = listOf(both), already = listOf(both))
        assertTrue("已在本轮列表里的不许重复追加", items.isEmpty())
    }

    @Test
    fun duplicate_rows_inside_the_query_result_are_collapsed() {
        val dup = Item(imgKey(402), hash = null)
        val (items, _) = backfill(below = listOf(dup, dup))
        assertEquals(listOf(dup), items)
    }

    // ── 卡面验收③：成本有上界，不随库大小线性增长 ──

    @Test
    fun a_quiet_round_costs_nothing_no_matter_how_big_the_library_is() {
        // 稳态：已选相册里每一张都已确认。返回集必须为空、哈希次数必须为 0，
        // **与库大小无关**——这是「按范围定向查」这条路成立的全部前提
        // （返回集 ≈ 已选相册总张数，绝不能每轮对它们全部哈希）。
        for (n in listOf(10, 10_000)) {
            val library = (1L..n).map { Item(imgKey(it), hash = "h$it") }
            val (items, hashed) = backfill(
                below = library,
                confirmed = library.mapTo(mutableSetOf()) { it.hash!! },
            )
            assertTrue("库有 $n 张时稳态一轮必须零候选", items.isEmpty())
            assertEquals("库有 $n 张时稳态一轮必须零哈希", 0, hashed)
        }
    }

    @Test
    fun the_output_is_proportional_to_the_change_not_to_the_library() {
        // 同一个变化量（移进来 1 张）放在 10 张和 10000 张的库里，返回集与
        // 哈希次数都必须恒为 1。库大小进不了这两个数字。
        for (n in listOf(10, 10_000)) {
            val library = (1L..n).map { Item(imgKey(it), hash = "h$it") }
            val moved = Item(imgKey(1_000_000), hash = null)
            val (items, hashed) = backfill(
                below = library + moved,
                confirmed = library.mapTo(mutableSetOf()) { it.hash!! },
            )
            assertEquals("库有 $n 张时也只补那 1 张", listOf(moved), items)
            assertEquals("库有 $n 张时也只哈希那 1 张", 1, hashed)
        }
    }

    // ── 卡面验收⑤ + 第 3 条的查询形状（纯函数看不见范围外的行，
    //    只靠它断言是恒真的——必须钉查询本身） ──

    @Test
    fun moving_a_photo_out_of_scope_can_never_trigger_an_upload() {
        // 范围外的不是我们的事。这由查询本身保证：WHERE 带
        // `BUCKET_ID IN (已选)`，移出去的行根本不在结果集里。
        val fn = sliceBetween(src("backup/MediaScanner.kt"), "fun scanScopeBelow(", "fun countAll(")
        assertTrue(
            "补齐查询必须按已选相册约束范围",
            fn.contains("${'$'}{MediaStore.MediaColumns.BUCKET_ID} IN ("),
        )
        assertTrue(
            "范围为 null（全量模式，没有范围边界可跨）或空集时一次查询都不发",
            fn.contains("if (bucketIds.isNullOrEmpty() || watermark <= 0L) return emptyList()"),
        )
    }

    @Test
    fun the_backfill_query_is_one_query_per_collection_and_stays_below_the_watermark() {
        val fn = sliceBetween(src("backup/MediaScanner.kt"), "fun scanScopeBelow(", "fun countAll(")
        assertEquals(
            "一个 collection 一次查询——绝不许按条发查询",
            1,
            Regex("requireResolver\\(\\)\\.query\\(").findAll(fn).count(),
        )
        assertTrue("只取水位之下（水位之上是增量扫描的活）", fn.contains("<= ?"))
        assertFalse(
            "补齐不许推进水位（MOB-09 的坏记录跳过语义原样保留）",
            fn.contains("nextWatermark"),
        )
    }

    // ── 接线：算出来了必须喂进管线（反证锚点） ──

    @Test
    fun the_backfill_is_merged_into_this_rounds_list() {
        val body = sliceBetween(
            src("backup/BackupWorker.kt"),
            "override suspend fun doWork()",
            "catch (t: CancellationException)",
        )
        assertTrue("必须算范围补齐", body.contains("val backfill = planScopeBackfill("))
        assertTrue(
            "补齐条目必须真的落进本轮列表（漏这一步 = 算了不用，正是本卡的断点）",
            body.contains("val items = plan.items + backfill"),
        )
        val args = sliceBetween(body, "val backfill = planScopeBackfill(", "val items =")
        assertTrue(
            "查询必须走范围 + 水位定向，不是全量重扫",
            args.contains("scanner.scanScopeBelow(since, bucketIds)"),
        )
        assertTrue(
            "去重基准必须是本轮已有的合并列表（否则 MOB-34 的补偿条目会被重复追加）",
            args.contains("already = plan.items"),
        )
        assertFalse("补齐不许靠全量扫描实现", body.contains("scanSince(0"))
    }

    @Test
    fun the_backfill_lands_before_the_pipeline_reads_the_list() {
        // 进度分母 / batchSize / 候选构建全部按合并后的列表算——顺序错了
        // 就是「补齐算完但这一轮已经早退了」。
        val body = sliceBetween(
            src("backup/BackupWorker.kt"),
            "override suspend fun doWork()",
            "catch (t: CancellationException)",
        )
        val mergeAt = body.indexOf("val items = plan.items + backfill")
        val progressAt = body.indexOf("reportProgress(PHASE_SCANNING")
        val emptyExitAt = body.indexOf("if (items.isEmpty())")
        assertTrue("合并必须在进度上报之前", mergeAt in 0 until progressAt)
        assertTrue("合并必须在空早退之前", mergeAt < emptyExitAt)
    }
}
