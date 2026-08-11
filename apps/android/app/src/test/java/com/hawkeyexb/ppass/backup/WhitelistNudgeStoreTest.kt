// DOG-02b: 契机式白名单提醒——判定纯函数边界 + 存储读写。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WhitelistNudgeStoreTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-nudge-$tag").toFile()

    private val now = 1_000_000_000L

    // ── 判定纯函数边界 ──────────────────────────────

    @Test
    fun not_whitelisted_with_recent_failure_nudges() {
        val s = WhitelistNudgeState(
            lastFailedAt = now - 1_000,
            lastSuccessAt = now - 1_000_000,
        )
        assertTrue(shouldNudgeWhitelist(s, now, isWhitelisted = false))
    }

    @Test
    fun whitelisted_never_nudges() {
        // 已加白 = 问题已解决，不骚扰（反证条件：去掉此条件则已加白用户
        // 被骚扰——测试红即证明条件必要）。
        val s = WhitelistNudgeState(lastFailedAt = now - 1_000)
        assertFalse(shouldNudgeWhitelist(s, now, isWhitelisted = true))
    }

    @Test
    fun no_failure_record_is_inconclusive() {
        // 无失败记录 = 无结论（可能只是没触发过自动备份）。
        val s = WhitelistNudgeState(lastSuccessAt = now - 1_000)
        assertFalse(shouldNudgeWhitelist(s, now, isWhitelisted = false))
    }

    @Test
    fun failure_older_than_window_does_not_nudge() {
        // 失败太旧（>2 天）——早已过去，不提醒。
        val s = WhitelistNudgeState(lastFailedAt = now - WHITELIST_NUDGE_WINDOW_MS - 1)
        assertFalse(shouldNudgeWhitelist(s, now, isWhitelisted = false))
    }

    @Test
    fun failure_boundary_is_inclusive() {
        // 恰好 2 天：仍在窗口内（近 N 天内）——发。
        val s = WhitelistNudgeState(lastFailedAt = now - WHITELIST_NUDGE_WINDOW_MS)
        assertTrue(shouldNudgeWhitelist(s, now, isWhitelisted = false))
    }

    @Test
    fun success_after_failure_means_recovered() {
        // 失败后成功过 = 已恢复，不提醒（「该跑没跑成」已成过去）。
        val s = WhitelistNudgeState(
            lastFailedAt = now - 1_000,
            lastSuccessAt = now - 500,
        )
        assertFalse(shouldNudgeWhitelist(s, now, isWhitelisted = false))
    }

    @Test
    fun nudged_within_cooldown_does_not_repeat() {
        val s = WhitelistNudgeState(
            lastFailedAt = now - 1_000,
            lastNudgedAt = now - WHITELIST_NUDGE_COOLDOWN_MS + 1,
        )
        assertFalse(shouldNudgeWhitelist(s, now, isWhitelisted = false))
    }

    @Test
    fun nudged_after_cooldown_nudges_again() {
        val s = WhitelistNudgeState(
            lastFailedAt = now - 1_000,
            lastNudgedAt = now - WHITELIST_NUDGE_COOLDOWN_MS - 1,
        )
        assertTrue(shouldNudgeWhitelist(s, now, isWhitelisted = false))
    }

    // ── Store 持久化 ────────────────────────────────

    @Test
    fun store_roundtrip_success_and_failure() {
        val dir = tempDir("roundtrip")
        val store = WhitelistNudgeStore(dir)
        store.recordFailure(100L)
        store.recordSuccess(200L)
        val s = store.load()
        assertEquals(100L, s.lastFailedAt)
        assertEquals(200L, s.lastSuccessAt)
        dir.deleteRecursively()
    }

    @Test
    fun mark_nudged_persists() {
        val dir = tempDir("nudged")
        val store = WhitelistNudgeStore(dir)
        store.recordFailure(100L)
        store.markNudged(300L)
        assertEquals(300L, store.load().lastNudgedAt)
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_file_reads_as_empty() {
        val dir = tempDir("corrupt")
        File(dir, "whitelist-nudge.json").apply {
            parentFile.mkdirs()
            writeText("{ broken")
        }
        assertEquals(WhitelistNudgeState(), WhitelistNudgeStore(dir).load())
        dir.deleteRecursively()
    }
}
