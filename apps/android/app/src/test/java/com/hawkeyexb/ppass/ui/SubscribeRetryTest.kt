// SYNC-04：前台订阅断线重连的状态机——从 Compose LaunchedEffect 剥出来
// 的纯函数，验证触发次数、退避间隔递增、超限后停止并进入"需要手动
// 重试"状态。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SubscribeRetryTest {

    private val delays = longArrayOf(1_000, 2_000, 4_000)

    @Test
    fun firstFailureUsesTheFirstDelayAndAdvances() {
        val d = nextSubscribeRetry(currentAttempt = 0, wasLive = false, delays = delays)
        assertEquals(1_000L, d.delayMs)
        assertEquals(1, d.nextAttempt)
        assertFalse(d.exhausted)
    }

    @Test
    fun delaysIncreaseWithEachConsecutiveFailure() {
        var attempt = 0
        val seen = mutableListOf<Long?>()
        repeat(delays.size) {
            val d = nextSubscribeRetry(attempt, wasLive = false, delays = delays)
            seen.add(d.delayMs)
            attempt = d.nextAttempt
        }
        assertEquals(listOf(1_000L, 2_000L, 4_000L), seen)
    }

    @Test
    fun exhaustsAfterTheLastDelayAndStopsRetrying() {
        var attempt = 0
        repeat(delays.size) {
            attempt = nextSubscribeRetry(attempt, wasLive = false, delays = delays).nextAttempt
        }
        val d = nextSubscribeRetry(attempt, wasLive = false, delays = delays)
        assertTrue("用完所有退避档之后必须进入 exhausted", d.exhausted)
        assertNull("exhausted 时不该再给一个 delay 让调用方继续等", d.delayMs)
    }

    @Test
    fun wasLiveResetsTheBackoffEvenAfterPriorFailures() {
        // 模拟：连续失败到第 2 档之后，这次终于连上并撑住了一阵子才断。
        val afterFailures = nextSubscribeRetry(0, wasLive = false, delays = delays).nextAttempt
        val d = nextSubscribeRetry(afterFailures, wasLive = true, delays = delays)
        assertEquals(
            "曾经连上过——退避必须清零重来，不能带着上次失败的档位",
            delays[0],
            d.delayMs,
        )
        assertEquals(1, d.nextAttempt)
    }

    @Test
    fun manualRetryAfterExhaustionStartsFromZero() {
        var attempt = 0
        repeat(delays.size) {
            attempt = nextSubscribeRetry(attempt, wasLive = false, delays = delays).nextAttempt
        }
        check(nextSubscribeRetry(attempt, wasLive = false, delays = delays).exhausted)

        // 用户点了"重试"：调用方把 attempt 手动清零、exhausted 清掉,
        // 相当于从头开始一轮新的退避序列。
        val d = nextSubscribeRetry(currentAttempt = 0, wasLive = false, delays = delays)
        assertEquals(delays[0], d.delayMs)
        assertFalse(d.exhausted)
    }
}
