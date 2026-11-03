package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1317：test.4 的 P0。自动备份规则开关的读取节流把「还没读过」的哨兵（Long.MIN_VALUE）
 * 直接拿去做减法，溢出成负数，条件永远不成立，开关停在初值 false，自动备份整支一张不取。
 */
class RuleCacheDueTest {
    @Test
    fun `first read is due even though now minus Long MIN_VALUE overflows`() {
        // 生产里 elapsedRealtime 是开机毫秒，是个大正数；直接减 MIN_VALUE 会回绕成负数。
        assertTrue(ruleCacheDue(5_000_000_000L, RULE_CACHE_NEVER_MS))
        assertTrue(ruleCacheDue(0L, RULE_CACHE_NEVER_MS))
    }

    @Test
    fun `reads are throttled to once per second`() {
        val at = 5_000_000_000L
        assertFalse(ruleCacheDue(at, at))
        assertFalse(ruleCacheDue(at + 999L, at))
        assertTrue(ruleCacheDue(at + 1_001L, at))
    }
}
