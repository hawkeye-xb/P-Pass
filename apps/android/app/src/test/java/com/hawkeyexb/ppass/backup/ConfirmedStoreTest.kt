// DOG-01b: 三元组口径回归测试。
// 回归：增量当全量——全量 100 备完后新拍 5 张，第二次运行后三元组必须
// 是 N=105 M=105（不是 N=5）。M 来自确认缓存（不依赖单次运行报告）。
package com.hawkeyexb.ppass.backup

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

    @Test
    fun two_runs_full_then_incremental_shows_full_totals() {
        // 本次 bug 的回归测试：模拟两次运行（全量 100 → 增量 5）。
        val dir = tempDir("regression")
        val store = ConfirmedStore(dir)

        // 运行 1：全量 100 张，daemon 全部确认。
        store.recordRun(confirmed = hashes(100), missing = emptySet(), lastSuccessAt = 1000)
        // MediaStore 全量 count = 100 → N=100 M=100 K=0。
        var t = tripletOf(n = 100, confirmedCount = store.count().toLong(), lastSuccessAt = store.lastSuccessAt())
        assertEquals(100L, t.n)
        assertEquals(100L, t.m)
        assertEquals(0L, t.k)

        // 运行 2：增量扫描只出 5 张新照片（100..104），全量 count = 105。
        val new5 = hashes(105).drop(100).toSet()
        store.recordRun(confirmed = new5, missing = emptySet(), lastSuccessAt = 2000)
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
    fun counterproof_cleared_cache_all_missing_means_k_equals_n() {
        // 反证：清空状态缓存表 + exist-check 全 missing → M=0，K 必须 = N。
        val dir = tempDir("counterproof")
        val store = ConfirmedStore(dir)

        store.recordRun(confirmed = hashes(50), missing = emptySet(), lastSuccessAt = 1)
        assertEquals(50, store.count())

        // 电脑端库被删 → 全 missing → 缓存清空。
        store.recordRun(confirmed = emptySet(), missing = hashes(50), lastSuccessAt = 2)
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
        ConfirmedStore(dir).recordRun(confirmed = hashes(7), missing = emptySet(), lastSuccessAt = 42_000)

        val reopened = ConfirmedStore(dir)
        assertEquals(7, reopened.count())
        assertEquals(42_000L, reopened.lastSuccessAt())
        dir.deleteRecursively()
    }

    @Test
    fun record_run_removes_missing_hashes_drift_calibration() {
        // 漂移校准：daemon 回 missing 的 hash 从缓存移除（电脑端库被删）。
        val dir = tempDir("drift")
        val store = ConfirmedStore(dir)
        store.recordRun(confirmed = hashes(5), missing = emptySet(), lastSuccessAt = 1)
        assertEquals(5, store.count())

        // 第二次运行：h1/h2 被 daemon 报 missing（电脑端删了），其余仍在。
        val confirmed = setOf("hash-00003", "hash-00004")
        val missing = setOf("hash-00000", "hash-00001", "hash-00002")
        store.recordRun(confirmed = confirmed, missing = missing, lastSuccessAt = 2)
        assertEquals("漂移后只剩 daemon 确认的", 2, store.count())
        assertEquals(2L, store.lastSuccessAt())
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
        store.recordRun(confirmed = setOf("a"), missing = emptySet(), lastSuccessAt = 7)
        assertEquals(1, store.count())
        dir.deleteRecursively()
    }

    @Test
    fun k_is_never_negative() {
        // M 超过 N（防御：确认缓存多过全量 count 的竞态）→ K clamp 0。
        val t = tripletOf(n = 3, confirmedCount = 5, lastSuccessAt = 1)
        assertEquals(3L, t.n)
        assertEquals(5L, t.m)
        assertTrue("K 不为负", t.k >= 0)
        assertEquals(0L, t.k)
    }
}
