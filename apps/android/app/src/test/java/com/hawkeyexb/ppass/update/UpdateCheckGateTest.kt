// UPD-02: ON_RESUME 自动检查 6h 节流门的边界锁。
// 这道门是 GitHub 匿名限流（60/h/IP）下的硬约束：每次切回前台都打更新源，
// 家人设备很快整段被限流打瞎（REL-07 的教训）；但门太死又会让常驻进程的
// 用户永远收不到更新。边界全部钉死。
package com.hawkeyexb.ppass.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateCheckGateTest {

    @Test
    fun intervalIsSixHours() {
        assertEquals(6L * 60 * 60 * 1000, AUTO_CHECK_INTERVAL_MS)
    }

    @Test
    fun neverCheckedMustCheck() {
        assertTrue(shouldAutoCheck(lastCheckAt = 0L, now = 1000L))
        // 异常负值（落盘损坏）同样视作「没查过」。
        assertTrue(shouldAutoCheck(lastCheckAt = -5L, now = 1000L))
    }

    @Test
    fun justUnderIntervalDoesNotCheck() {
        val last = 1_000_000L
        assertFalse(shouldAutoCheck(last, last + AUTO_CHECK_INTERVAL_MS - 1))
    }

    @Test
    fun exactlyAtIntervalChecks() {
        val last = 1_000_000L
        assertTrue(shouldAutoCheck(last, last + AUTO_CHECK_INTERVAL_MS))
    }

    @Test
    fun overIntervalChecks() {
        val last = 1_000_000L
        assertTrue(shouldAutoCheck(last, last + AUTO_CHECK_INTERVAL_MS + 60_000))
    }

    @Test
    fun clockBackwardsDoesNotCheck() {
        // 时钟回拨：差值为负，天然落在门槛内——不许因此狂查。
        val last = 1_000_000L
        assertFalse(shouldAutoCheck(last, last - 60_000))
    }
}
