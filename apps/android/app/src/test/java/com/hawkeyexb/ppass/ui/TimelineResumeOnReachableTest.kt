// #474（MOB-118）：照片 tab 的实时订阅退避 6 次用完进入 exhausted 后，只有手点「重试」
// 才会重连——桌面回来了也不自己接上。前台心跳 hello 成功（onReachable）已经知道桌面可达，
// 这里钉住两件事：
//  ① holder 层（虚拟时间 + fake 通道）：耗尽 + 可达 → 重启一次；连上/退避中 + 可达 → 不动；
//     心跳每 30s 重复调用也只重启一次（幂等）。
//  ② 接线层（源文本门禁）：MainActivity 里心跳的 onReachable 同时叫醒 Flow（#449）和时间线。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.proto.TimelinePage
import com.hawkeyexb.ppass.transport.Pairing
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TimelineResumeOnReachableTest {

    private val pairing = Pairing(
        daemonNodeId = "a".repeat(64),
        daemonAddrToken = "tok",
        storageDeviceName = "Test",
    )

    /** 桌面停服 → 恢复：`desktopUp=false` 时订阅立即失败，翻成 true 后连上并保持长连接。 */
    private class ToggleChannel : TimelineChannel {
        var desktopUp = false
        var calls = 0
            private set
        private val hold = CompletableDeferred<Unit>()

        override val loader: TimelineLoader? get() = null
        override suspend fun loadPage(cursor: String?): TimelinePage = TimelinePage()
        override suspend fun subscribe(
            onConnected: suspend () -> Unit,
            onInvalidated: suspend () -> Unit,
        ) {
            calls++
            if (!desktopUp) throw IllegalStateException("conn refused")
            onConnected()
            hold.await()
        }
        override fun onRefreshed(hashes: Set<String>) {}
        override fun onAppended(hashes: Set<String>) {}
    }

    private fun TestScope.holder(ch: TimelineChannel, logs: MutableList<String>) =
        TimelineSubscriptionHolder(
            scope = backgroundScope,
            currentPairing = { pairing },
            channelFor = { ch },
            log = { logs += it },
        )

    @Test
    fun exhaustedThenDesktopReachableReconnectsWithoutTap() = runTest {
        val ch = ToggleChannel()
        val logs = mutableListOf<String>()
        val h = holder(ch, logs)
        h.start()
        advanceTimeBy(61_000) // 6 档退避用完（1+2+4+8+15+30）
        runCurrent()
        assertTrue(h.state.subscribeExhausted)
        assertEquals(7, ch.calls)

        ch.desktopUp = true // 桌面恢复——没人点「重试」
        h.onDesktopReachable() // 心跳 hello 成功
        runCurrent()
        assertEquals("耗尽 + 可达必须自己重启一次订阅", 8, ch.calls)
        assertFalse(h.state.subscribeExhausted)
        assertTrue("重启后应真的连上", h.state.subscribeConnected)

        // 心跳每 30s 又成功一次：已连上，不得重复起会话。
        repeat(3) {
            advanceTimeBy(30_000)
            h.onDesktopReachable()
            runCurrent()
        }
        assertEquals("连上后心跳可达必须幂等", 8, ch.calls)

        // 日志：断开 / 放弃 / 自动恢复 / 建立各有，且量有界（7 次失败 + 1 放弃 + 1 恢复 + 1 连上）。
        assertEquals(7, logs.count { it.startsWith("subscribe: ended") })
        assertEquals(1, logs.count { it.startsWith("subscribe: exhausted") })
        assertEquals(1, logs.count { it.startsWith("subscribe: auto-resume") })
        assertEquals(1, logs.count { it == "subscribe: connected" })
        assertEquals(10, logs.size)
    }

    @Test
    fun backToBackReachableAfterExhaustionStartsOnlyOneSession() = runTest {
        val ch = ToggleChannel()
        val h = holder(ch, mutableListOf())
        h.start()
        advanceTimeBy(61_000)
        runCurrent()
        assertTrue(h.state.subscribeExhausted)
        ch.desktopUp = true
        h.onDesktopReachable()
        h.onDesktopReachable() // 同一瞬间第二次（两拍挤在一起）
        runCurrent()
        assertEquals(8, ch.calls)
        assertEquals(8, h.state.subscriptionsStarted)
    }

    @Test
    fun reachableWhileBackingOffDoesNotInterfere() = runTest {
        val ch = ToggleChannel()
        val h = holder(ch, mutableListOf())
        h.start()
        advanceTimeBy(3_500) // 已失败几次，正在退避中，还没耗尽
        runCurrent()
        assertFalse(h.state.subscribeExhausted)
        val callsBefore = ch.calls
        val attemptBefore = h.state.subscribeAttempt
        val startedBefore = h.state.subscriptionsStarted
        assertTrue(attemptBefore > 0)

        h.onDesktopReachable()
        runCurrent()
        assertEquals("退避中心跳可达：不得额外起会话", callsBefore, ch.calls)
        assertEquals("退避中心跳可达：档位不得被清零", attemptBefore, h.state.subscribeAttempt)
        assertEquals(startedBefore, h.state.subscriptionsStarted)
    }

    @Test
    fun reachableWhileConnectedDoesNotInterfere() = runTest {
        val ch = ToggleChannel().apply { desktopUp = true }
        val h = holder(ch, mutableListOf())
        h.start()
        runCurrent()
        assertTrue(h.state.subscribeConnected)
        h.onDesktopReachable()
        runCurrent()
        assertEquals(1, ch.calls)
        assertEquals(1, h.state.subscriptionsStarted)
        assertTrue(h.state.subscribeConnected)
    }

    @Test
    fun reachableAfterStopDoesNothing() = runTest {
        val ch = ToggleChannel()
        val h = holder(ch, mutableListOf())
        h.start()
        advanceTimeBy(61_000)
        runCurrent()
        h.stop() // 退后台
        h.onDesktopReachable()
        runCurrent()
        assertEquals("后台不得因可达信号起会话（PRES-01）", 7, ch.calls)
    }

    // ── 接线门禁（源文本）：Compose 里的一行调用，JVM 跑不起 Activity，失效方式是「重构时弄丢那一行」。

    /** 剥注释行：正向 contains 会被「把那行注释掉」骗过。同 RepairWakesFlowTest 的惯例。 */
    private fun code(relative: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/$relative").readText().lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")
    }

    @Test
    fun heartbeatOnReachableNotifiesBothFlowAndTimeline() {
        val src = code("app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt")
        val from = "onReachable = {"
        assertTrue("源码锚点已消失，断言失效：$from", src.contains(from))
        val lambda = src.substringAfter(from).substringBefore("},")
        assertTrue("#449 的 Flow 唤醒不能丢", lambda.contains("onFlowDesktopReachable(context)"))
        assertTrue("#474：心跳可达必须通知照片 tab 的订阅", lambda.contains("timeline.onDesktopReachable()"))
    }
}
