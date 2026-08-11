// SENT-01: 手机盯电脑哨兵——判定纯函数边界 + 可达性存储读写。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SentinelStoreTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-sentinel-$tag").toFile()

    // ── 判定纯函数边界 ──────────────────────────────

    @Test
    fun fresh_reachable_never_notifies() {
        val now = 1_000_000_000L
        val s = SentinelState(lastReachableAt = now - 1_000, failedAttempts = 3)
        assertFalse(shouldNotifySentinel(s, now))
    }

    @Test
    fun stale_with_failed_attempts_notifies() {
        val now = 1_000_000_000L
        val s = SentinelState(
            lastReachableAt = now - SENTINEL_THRESHOLD_MS - 1,
            failedAttempts = 2,
        )
        assertTrue(shouldNotifySentinel(s, now))
    }

    @Test
    fun stale_but_zero_attempts_never_notifies() {
        // 「手机自己三天没触发」——期间无失败尝试 = 无结论，不误报。
        val now = 1_000_000_000L
        val s = SentinelState(lastReachableAt = now - SENTINEL_THRESHOLD_MS - 1, failedAttempts = 0)
        assertFalse(shouldNotifySentinel(s, now))
    }

    @Test
    fun never_reachable_is_inconclusive() {
        // 从未确认可达过 = 无结论（可能是配对后一直没跑过任务）。
        val now = 1_000_000_000L
        val s = SentinelState(lastReachableAt = 0, failedAttempts = 5)
        assertFalse(shouldNotifySentinel(s, now))
    }

    @Test
    fun notified_within_cooldown_does_not_repeat() {
        val now = 1_000_000_000L
        val s = SentinelState(
            lastReachableAt = now - SENTINEL_THRESHOLD_MS - 1,
            failedAttempts = 2,
            lastNotifiedAt = now - SENTINEL_COOLDOWN_MS + 1, // 刚发过
        )
        assertFalse(shouldNotifySentinel(s, now))
    }

    @Test
    fun notified_after_cooldown_notifies_again() {
        val now = 1_000_000_000L
        val s = SentinelState(
            lastReachableAt = now - SENTINEL_THRESHOLD_MS - 1,
            failedAttempts = 2,
            lastNotifiedAt = now - SENTINEL_COOLDOWN_MS - 1, // 已过窗口
        )
        assertTrue(shouldNotifySentinel(s, now))
    }

    @Test
    fun threshold_boundary_is_inclusive() {
        // 恰好 72h：不算超过（> 72h 才发）——边界不误发。
        val now = 1_000_000_000L
        val s = SentinelState(lastReachableAt = now - SENTINEL_THRESHOLD_MS, failedAttempts = 1)
        assertFalse(shouldNotifySentinel(s, now))
    }

    // ── Store 持久化 ────────────────────────────────

    @Test
    fun store_roundtrip_and_reset_on_reachable() {
        val dir = tempDir("roundtrip")
        val store = SentinelStore(dir)
        store.recordUnreachable()
        store.recordUnreachable()
        assertEquals(2, store.load().failedAttempts)
        assertEquals(0, store.load().lastReachableAt)

        val now = 5_000_000L
        store.recordReachable(now)
        val after = store.load()
        assertEquals(now, after.lastReachableAt)
        assertEquals(0, after.failedAttempts) // 恢复可达 = 清零
        dir.deleteRecursively()
    }

    @Test
    fun mark_notified_persists_and_keeps_reachability() {
        val dir = tempDir("notified")
        val store = SentinelStore(dir)
        store.recordReachable(1_000L)
        store.recordUnreachable()
        store.markNotified(2_000L)
        val s = store.load()
        assertEquals(1_000L, s.lastReachableAt)
        assertEquals(1, s.failedAttempts)
        assertEquals(2_000L, s.lastNotifiedAt)
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_file_reads_as_empty() {
        val dir = tempDir("corrupt")
        File(dir, "sentinel.json").apply {
            parentFile.mkdirs()
            writeText("{ not json !!!")
        }
        assertEquals(SentinelState(), SentinelStore(dir).load())
        dir.deleteRecursively()
    }
}
