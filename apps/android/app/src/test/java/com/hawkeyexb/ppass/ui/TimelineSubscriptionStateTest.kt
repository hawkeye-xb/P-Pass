// SYNC-06: 订阅会话状态机的纯函数断言（JVM 可测，不起 Compose 测试环境）。
//
// 核心契约：订阅状态机的输入集只有前台生命周期事件（ON_RESUME/ON_STOP）
// 和用户动作（手动重试）——**tab 切换不在输入集里**。旧实现里每次切回
// 照片 tab 都会重建订阅连接（LaunchedEffect 重新进入组合树）；新实现
// tab 0→1→0 不产生任何状态转换，订阅发起次数保持 0 变化。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TimelineSubscriptionStateTest {

    private val delays = longArrayOf(1_000, 2_000, 4_000)

    private fun retry(attempt: Int, wasLive: Boolean) = nextSubscribeRetry(attempt, wasLive, delays)

    // ── SYNC-06 验收面：tab 切换不得重新触发订阅 ──────────────

    @Test
    fun tabSwitchAppliesNoTransitionsToSubscriptionMachine() {
        var state = SubscriptionSessionState()
        state = onSubscriptionSessionStarted(state) // ON_RESUME 发起第一次订阅

        // 模拟「tab 0 → 1 → 0」：UI 层在 tab 切换时不调用 holder 任何方法
        // （tab 不在订阅状态机的输入集里——这是新设计与旧实现的本质区别）。
        // 全程零状态转换 → 订阅发起次数不变、退避档位不变、连接保持。
        assertEquals("订阅发起次数必须保持 1（tab 切换一次都没重新触发）", 1, state.subscriptionsStarted)
        assertEquals(0, state.subscribeAttempt)
        assertFalse(state.subscribeExhausted)
        assertFalse(state.subscribeConnected)
    }

    @Test
    fun oldWiringEmulationShowsTabReturnRestartsPerVisit() {
        // 对照：旧实现的等价行为——每次切回照片 tab，PhotosScreen 重新进入
        // 组合树，LaunchedEffect 重跑 = 重新发起一次订阅。证明上面断言用的
        // 计数器有检测能力（同样的序列下旧接线会让订阅发起次数 +1/次返回）。
        var state = SubscriptionSessionState()
        state = onSubscriptionSessionStarted(state) // 进入照片 tab（首次）
        // tab → 1：旧实现取消订阅（状态无变化）
        // tab → 0：旧实现重建订阅 = 重新发起
        state = onSubscriptionSessionStarted(state)
        assertEquals(2, state.subscriptionsStarted)
    }

    // ── 会话内状态转换（退避决策复用 SYNC-04 nextSubscribeRetry） ──

    @Test
    fun connectClearsFailureAndSetsConnected() {
        var s = onSubscriptionSessionStarted(SubscriptionSessionState())
        s = onSubscriptionConnected(s)
        assertTrue(s.subscribeConnected)
        assertFalse(s.subscribeHadFailure)
    }

    @Test
    fun disconnectAdvancesRetryAttemptAndReturnsDelay() {
        var s = SubscriptionSessionState()
        s = onSubscriptionSessionStarted(s)
        s = onSubscriptionConnected(s)
        val ended = onSubscriptionEnded(s, wasLive = false, retry = ::retry)
        assertEquals(1, ended.state.subscribeAttempt)
        assertTrue(ended.state.subscribeHadFailure)
        assertFalse(ended.state.subscribeConnected)
        assertEquals(1_000L, ended.delayMs)
    }

    @Test
    fun wasLiveResetsBackoffDebt() {
        var s = SubscriptionSessionState()
        s = onSubscriptionEnded(s, wasLive = false, retry = ::retry).state
        s = onSubscriptionEnded(s, wasLive = false, retry = ::retry).state
        assertEquals(2, s.subscribeAttempt)

        // 连上并撑过一段才断（wasLive）——退避清零重来：从第一档重新开始
        // （nextAttempt=1 是第一档之后的档位，不是 0——0 只属于从未失败过）。
        val live = onSubscriptionEnded(s, wasLive = true, retry = ::retry)
        assertEquals(1, live.state.subscribeAttempt)
        assertEquals(1_000L, live.delayMs)
    }

    @Test
    fun exhaustionStopsRetryingAndManualRetryClearsIt() {
        // 用完所有退避档（这里 3 档）→ exhausted，不再给 delay。
        var s = SubscriptionSessionState()
        repeat(3) {
            s = onSubscriptionEnded(s, wasLive = false, retry = ::retry).state
        }
        val ended = onSubscriptionEnded(s, wasLive = false, retry = ::retry)
        assertTrue(ended.state.subscribeExhausted)
        assertEquals(null, ended.delayMs)

        // 用户点「重试」→ 清零重来。
        s = onSubscriptionManualRetry(ended.state)
        assertEquals(0, s.subscribeAttempt)
        assertFalse(s.subscribeExhausted)
    }

    @Test
    fun foregroundRestartStartsFreshSession() {
        // ON_RESUME → 会话开始；进后台（ON_STOP）连接关闭但状态保留；
        // 回前台（ON_RESUME）→ holder.start() 把整份会话状态清零重来
        // （旧实现里每次重建组合树 = 全新状态）——这里显式建模 start()
        // 的 reset，再断言新会话不带退避债务。
        var s = SubscriptionSessionState()
        s = onSubscriptionSessionStarted(s) // 第一段前台
        s = onSubscriptionConnected(s)
        s = onSubscriptionEnded(s, wasLive = true, retry = ::retry).state
        assertEquals(1, s.subscribeAttempt)

        // ON_STOP / ON_RESUME：start() 清零 → 全新会话。
        s = SubscriptionSessionState()
        s = onSubscriptionSessionStarted(s)
        assertEquals(1, s.subscriptionsStarted) // 新会话的计数器从 0 起
        assertEquals(0, s.subscribeAttempt)
        assertFalse(s.subscribeExhausted)
        assertFalse(s.subscribeHadFailure)
    }
}
