// SYNC-06: TimelineSubscriptionHolder 的协程级断言——用计数 fake 通道
// （不走网络），在 kotlinx-coroutines-test 的虚拟时间里验证：
//  ① tab 切换不重新订阅（UI 层零调用，连接保持）；
//  ② start() 幂等（即使 UI 误调也不会重连）；
//  ③ ON_STOP 关闭 / ON_RESUME 重建（预期行为，与心跳同边界）；
//  ④ 退避耗尽停止静默重试，手动重试重新发起。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.proto.AssetMeta
import com.hawkeyexb.ppass.proto.TimelinePage
import com.hawkeyexb.ppass.transport.Pairing
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

    /** #1883：第一次整页加载失败（留下 error），之后的加载成功；订阅一上来就连上。 */
    private class FlakyFirstLoadChannel : TimelineChannel {
        var pageCalls: Int = 0
            private set
        private val release = CompletableDeferred<Unit>()

        override val loader: TimelineLoader? get() = null

        override suspend fun loadPage(cursor: String?): TimelinePage {
            pageCalls++
            if (pageCalls == 1) throw IllegalStateException("first page load failed")
            return TimelinePage()
        }

        override suspend fun subscribe(
            onConnected: suspend () -> Unit,
            onInvalidated: suspend () -> Unit,
        ) {
            onConnected()
            release.await()
        }

        override fun onRefreshed(hashes: Set<String>) {}

        override fun onAppended(hashes: Set<String>) {}
    }

    /**
     * #1883：初始整页加载失败留下的 error，在订阅连上后不能自己赖着不走——那段里详情页已经说
     * 「已连接」，照片页却还整页说「无法连接电脑」（或者被遮成空白页，Bugbot 在 #1898 上抓过）。
     * 连上就补一次整页：成功即清 error。
     */
    @Test
    fun connectingRetriesThePageThatFailedBeforeTheConnection() = runTest {
        val ch = FlakyFirstLoadChannel()
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
        )
        holder.start()
        runCurrent()
        assertTrue("fake 订阅立即连上", holder.state.subscribeConnected)
        assertNull("连上后不得再留着「连不上」的旧 error", holder.error)
        assertEquals("连上时补一次整页", 2, ch.pageCalls)
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

    @Test
    fun pullToRefreshReloadsFirstPageAndClearsError() = runTest {
        var pageCalls = 0
        val release = CompletableDeferred<Unit>()
        val refreshGate = CompletableDeferred<Unit>()
        val ch = object : TimelineChannel {
            override val loader: TimelineLoader? get() = null
            override suspend fun loadPage(cursor: String?): TimelinePage {
                pageCalls++
                return if (pageCalls == 1) {
                    TimelinePage(items = listOf(AssetMeta(hash = "old", mediaType = "photo", bytes = 1)))
                } else {
                    refreshGate.await()
                    TimelinePage(items = listOf(AssetMeta(hash = "new", mediaType = "photo", bytes = 2)))
                }
            }
            override suspend fun subscribe(onConnected: suspend () -> Unit, onInvalidated: suspend () -> Unit) {
                onConnected()
                release.await()
            }
            override fun onRefreshed(hashes: Set<String>) {}
            override fun onAppended(hashes: Set<String>) {}
        }
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
        )
        holder.start()
        runCurrent()
        assertEquals(listOf("old"), holder.items.map { it.hash })
        assertFalse(holder.refreshing)

        holder.refresh()
        runCurrent()
        assertTrue("下拉刷新进行中 refreshing 必须为 true，保证刷新指示器可见", holder.refreshing)

        refreshGate.complete(Unit)
        runCurrent()
        assertEquals("下拉刷新应重拉首屏", 2, pageCalls)
        assertEquals(listOf("new"), holder.items.map { it.hash })
        assertFalse("刷新完成后 refreshing 必须回到 false", holder.refreshing)
        assertNull(holder.error)
    }

    @Test
    fun pullToRefreshWhenExhaustedAlsoRetriesSubscription() = runTest {
        val ch = FailingChannel()
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
        )
        holder.start()
        advanceTimeBy(61_000)
        runCurrent()
        assertTrue(holder.state.subscribeExhausted)
        val beforeCalls = ch.calls

        holder.refresh()
        runCurrent()
        assertFalse("下拉刷新在退避耗尽时应重新拉起订阅", holder.state.subscribeExhausted)
        assertTrue(ch.calls > beforeCalls)
        assertFalse(holder.refreshing)
    }

    @Test
    fun pullToRefreshAdvancesRefreshGenerationEvenWhenHashesUnchanged() = runTest {
        val release = CompletableDeferred<Unit>()
        val samePage = TimelinePage(items = listOf(AssetMeta(hash = "same", mediaType = "photo", bytes = 1)))
        val ch = object : TimelineChannel {
            override val loader: TimelineLoader? get() = null
            override suspend fun loadPage(cursor: String?): TimelinePage = samePage
            override suspend fun subscribe(onConnected: suspend () -> Unit, onInvalidated: suspend () -> Unit) {
                onConnected()
                release.await()
            }
            override fun onRefreshed(hashes: Set<String>) {}
            override fun onAppended(hashes: Set<String>) {}
        }
        val holder = TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
        )
        assertEquals(0, holder.refreshGeneration)

        holder.start()
        runCurrent()
        assertEquals(1, holder.refreshGeneration)

        holder.refresh()
        runCurrent()
        assertEquals(listOf("same"), holder.items.map { it.hash })
        assertEquals("即使时间线条目未变，下拉刷新也必须推进 refreshGeneration 供空白缩略图重拉", 2, holder.refreshGeneration)
    }
}
