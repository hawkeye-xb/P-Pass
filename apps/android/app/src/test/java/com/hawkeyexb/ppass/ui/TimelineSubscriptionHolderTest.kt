// SYNC-06: TimelineSubscriptionHolder 的协程级断言——用计数 fake 通道
// （不走网络），在 kotlinx-coroutines-test 的虚拟时间里验证：
//  ① tab 切换不重新订阅（UI 层零调用，连接保持）；
//  ② start() 幂等（即使 UI 误调也不会重连）；
//  ③ ON_STOP 关闭 / ON_RESUME 重建（预期行为，与心跳同边界）；
//  ④ 退避耗尽停止静默重试，手动重试重新发起。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.proto.TimelinePage
import com.hawkeyexb.ppass.transport.Pairing
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TimelineSubscriptionHolderTest {

    private val pairing = Pairing(
        daemonNodeId = "a".repeat(64),
        daemonAddrToken = "tok",
        storageDeviceName = "Test",
    )

    /** 正常通道 fake：订阅挂起直到被外部释放/取消（模拟长连接）。 */
    private class FakeChannel(
        val subscribeCalls: Int = 0,
    ) : TimelineChannel {
        var calls: Int = subscribeCalls
            private set
        private val release = CompletableDeferred<Unit>()

        fun releaseConnection() {
            release.complete(Unit)
        }

        override val loader: TimelineLoader? get() = null

        override suspend fun loadPage(cursor: String?): TimelinePage = TimelinePage()

        override suspend fun subscribe(
            onConnected: suspend () -> Unit,
            onInvalidated: suspend () -> Unit,
        ) {
            calls++
            onConnected()
            release.await() // 长连接：挂起直到被释放/取消
        }

        override fun onRefreshed(hashes: Set<String>) {}

        override fun onAppended(hashes: Set<String>) {}
    }

    /** 断连通道 fake：每次订阅立即失败（模拟 daemon 不可达）。 */
    private class FailingChannel : TimelineChannel {
        var calls: Int = 0
            private set

        override val loader: TimelineLoader? get() = null
        override suspend fun loadPage(cursor: String?): TimelinePage = TimelinePage()

        override suspend fun subscribe(
            onConnected: suspend () -> Unit,
            onInvalidated: suspend () -> Unit,
        ) {
            calls++
            throw IllegalStateException("conn refused")
        }

        override fun onRefreshed(hashes: Set<String>) {}

        override fun onAppended(hashes: Set<String>) {}
    }

    @Test
    fun tabSwitchDoesNotRestartSubscription() = runTest {
        val ch = FakeChannel()
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
        )
        holder.start()
        runCurrent()
        assertEquals("ON_RESUME 应发起一次订阅", 1, ch.calls)
        assertTrue(holder.state.subscribeConnected) // fake 立即 onConnected

        // tab 0→1→0：UI 层不调用 holder 任何方法（tab 不在订阅状态机输入集）。
        // 订阅连接保持——发起次数不变、退避档位不变、不进入重连。
        assertEquals("切 tab 不得重新订阅", 1, ch.calls)
        assertEquals(1, holder.state.subscriptionsStarted)
        assertEquals(0, holder.state.subscribeAttempt)
        assertFalse(holder.state.subscribeExhausted)
    }

    @Test
    fun repeatedStartIsIdempotent() = runTest {
        // 即使 UI 误调 start()（比如在 tab 切换事件里顺手调了）——幂等守卫
        // 挡住，不会重建连接（跟 ForegroundHeartbeat.start() 同款守卫）。
        val ch = FakeChannel()
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
        )
        holder.start()
        runCurrent()
        holder.start()
        runCurrent()
        holder.start()
        runCurrent()
        assertEquals(1, ch.calls)
    }

    @Test
    fun stopClosesAndResumeRestarts() = runTest {
        // ON_STOP（退后台）关闭订阅；ON_RESUME（回前台）重建——这是预期
        // 行为（跟心跳同一个 ON_RESUME~ON_STOP 边界），重建后整页刷新
        // 补齐后台期间错过的变化（SYNC-04 挂账剧本③的判定边界从"tab 切走"
        // 变成"Activity 真正 onStop"）。
        val ch = FakeChannel()
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
        )
        holder.start()
        runCurrent()
        assertEquals(1, ch.calls)

        holder.stop()
        runCurrent()
        assertFalse(holder.state.subscribeConnected)

        holder.start()
        runCurrent()
        assertEquals("回前台应重新建立订阅", 2, ch.calls)
    }

    @Test
    fun exhaustionStopsAndManualRetryRelaunches() = runTest {
        val ch = FailingChannel()
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
        )
        holder.start()
        // 6 档退避（1+2+4+8+15+30 = 60s），第 7 次订阅尝试失败后耗尽。
        advanceTimeBy(61_000)
        runCurrent()
        assertTrue("退避耗尽后必须停止静默重试", holder.state.subscribeExhausted)
        assertEquals(7, ch.calls)

        holder.retry()
        runCurrent()
        assertFalse(holder.state.subscribeExhausted)
        assertEquals(8, ch.calls)
    }

    @Test
    fun unpairedStaysIdleAndPairingAppearsStartsSession() = runTest {
        // 未配对（Welcome 阶段）保持空闲；配对落盘后自动开始订阅——
        // 不需要用户重开 App（monitor 前台期间轮询配对存储）。
        var current: Pairing? = null
        val ch = FakeChannel()
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { current },
            channelFor = { ch },
        )
        holder.start()
        runCurrent()
        assertEquals(0, ch.calls)
        assertFalse(holder.loading)

        current = pairing // 配对成功落盘
        advanceTimeBy(SUBSCRIBE_MONITOR_POLL_MS + 100)
        runCurrent()
        assertEquals(1, ch.calls)
        assertTrue(holder.state.subscribeConnected)
    }
}
