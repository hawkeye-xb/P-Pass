// #956 关闭裁决（2026-10-22）：主动断开时尽力通知电脑一次，收到就收到，没收到就算了；之后不再有任何动作
// （撤掉 #565 的发件箱）。通知仍带要结束的那次配对 id。#1239：不等通知——立刻清本地，通知在后台发。
package com.hawkeyexb.ppass.transport

import androidx.work.OneTimeWorkRequestBuilder
import com.hawkeyexb.ppass.proto.Resp
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class UnpairNoticeTest {

    /** 反证：在 sendUnpairNoticeOnce 里加回「失败就再试」→ 次数不是 1 → 红。 */
    @Test
    fun anUnreachableDesktopIsTriedExactlyOnce() = runTest {
        var sends = 0
        val reply = sendUnpairNoticeOnce {
            sends++
            throw IOException("unreachable")
        }
        assertNull(reply)
        assertEquals(1, sends)
    }

    /** 电脑接了连接却不回：最多等 5 秒，不卡住断开。 */
    @Test
    fun aSilentDesktopIsGivenUpAfterTheTimeout() = runTest {
        val reply = sendUnpairNoticeOnce { awaitCancellation() }
        assertNull(reply)
        assertEquals(UNPAIR_NOTICE_TIMEOUT_MS, testScheduler.currentTime)
    }

    @Test
    fun aRejectionIsReturnedAsIsAndNotRetried() = runTest {
        var sends = 0
        val reply = sendUnpairNoticeOnce {
            sends++
            Resp(ok = false)
        }
        assertFalse(reply!!.ok)
        assertEquals(1, sends)
    }

    /**
     * 反证：改回「先 await 通知再清本地」→ 通知挂住时清理永远不发生、断开函数不返回 → runTest 超时红。
     * 通知永不返回（对应 FFI 阻塞调用）：清理在通知完成前已发生，断开函数立即返回，通知已开始但未结束。
     */
    @Test
    fun localPairingIsClearedWhileTheNoticeIsStillHanging() = runTest {
        val events = mutableListOf<String>()
        val never = CompletableDeferred<Unit>()
        disconnectAndNotifyInBackground(
            notify = { events += "notify-start"; never.await(); events += "notify-end" },
            clearLocal = { events += "clear" },
            background = backgroundScope,
        )
        runCurrent()
        assertEquals(listOf("clear", "notify-start").sorted(), events.sorted())
        assertTrue("通知未完成时清理已发生", "clear" in events && "notify-end" !in events)
        assertTrue(never.isActive)
    }

    /** 通知只发一次；抛错不影响清理，也不连累后台作用域。 */
    @Test
    fun aFailingNoticeIsSentOnceAndDoesNotAffectCleanup() = runTest {
        var sends = 0
        var cleared = 0
        disconnectAndNotifyInBackground(
            notify = { sendUnpairNoticeOnce { sends++; throw IOException("unreachable") } },
            clearLocal = { cleared++ },
            background = backgroundScope,
        )
        runCurrent()
        assertEquals(1, sends)
        assertEquals(1, cleared)
        assertTrue("后台作用域仍然存活", backgroundScope.isActive)
    }

    /** 通知本身抛出（不经 sendUnpairNoticeOnce）也吞掉：清理照常，作用域不被取消。 */
    @Test
    fun aThrowingNotifyClosureIsSwallowed() = runTest {
        var cleared = 0
        disconnectAndNotifyInBackground(
            notify = { throw IllegalStateException("boom") },
            clearLocal = { cleared++ },
            background = backgroundScope,
        )
        runCurrent()
        assertEquals(1, cleared)
        assertTrue(backgroundScope.isActive)
    }

    /** 断开所在的协程被取消（Activity 销毁）：清理照样执行，通知因在应用级作用域里不受影响。反证：去掉 NonCancellable → 红。 */
    @Test
    fun cleanupAndNoticeSurviveTheDisconnectCallerBeingCancelled() = runTest {
        var cleared = 0
        var noticed = 0
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            disconnectAndNotifyInBackground(
                notify = { noticed++ },
                clearLocal = { kotlinx.coroutines.yield(); cleared++ },
                background = backgroundScope,
            )
        }
        job.cancel()
        job.join()
        runCurrent()
        assertEquals(1, cleared)
        assertEquals(1, noticed)
    }

    /** 反证：去掉配对 id 参数 → daemon 走无条件吊销，迟到的旧通知会吊销新配对——第一条红。 */
    @Test
    fun theNoticeNamesThePairingItEnds() {
        assertEquals(JsonPrimitive("pid-1"), unpairParams("pid-1")["pairing_id"])
        assertFalse("旧配对没有配对 id：不带参数，daemon 走旧语义", unpairParams("").containsKey("pairing_id"))
    }

    /** 老版本排下的任务按 Worker 类名 tag 撤：WorkManager 默认给每个请求加上 Worker 的全限定类名作 tag。 */
    @Test
    fun legacyNoticesAreCancelledByTheWorkerClassTag() {
        val legacy = OneTimeWorkRequestBuilder<UnpairNoticeWorker>().build()
        assertTrue(legacy.tags.toString(), LEGACY_UNPAIR_NOTICE_TAG in legacy.tags)
        val app = File("src/main/java/com/hawkeyexb/ppass/PPassApplication.kt").readText()
        assertTrue("进程启动时要撤掉老任务", app.contains("cancelLegacyUnpairNotices(this)"))
    }

    /**
     * 「之后回前台 / 网络恢复 / 重启都不再发」的结构门禁：生产代码里 device.unpair 只有一个发送点
     * （DaemonClient.unpair），它只有一个调用点（MainActivity 主动断开）；墓碑 Worker 不联网；不再有入队。
     * 反证：在 ON_RESUME / 网络回调 / Worker 里加一行 client.unpair(…) 或 WorkManager 入队 → 红。
     */
    @Test
    fun theOnlyUnpairSenderIsTheDisconnectAction() {
        val main = File("src/main/java")
        val sources = main.walkTopDown().filter { it.extension == "kt" }.associate { it.relativeTo(main).invariantSeparatorsPath to it.readText() }
        assertEquals(
            listOf("com/hawkeyexb/ppass/transport/DaemonClient.kt"),
            sources.filterValues { it.contains("\"device.unpair\"") }.keys.toList(),
        )
        assertEquals(
            listOf("com/hawkeyexb/ppass/MainActivity.kt"),
            sources.filterValues { Regex("""\.unpair\(""").containsMatchIn(it) }.keys.toList(),
        )
        val mainActivity = sources.getValue("com/hawkeyexb/ppass/MainActivity.kt")
        assertEquals("只有一处调用（notifyUnpairOnce）", 1, Regex("""\.unpair\(""").findAll(mainActivity).count())
        val notice = sources.getValue("com/hawkeyexb/ppass/transport/UnpairNotice.kt")
        assertFalse("不再入队任何断开通知任务", notice.contains("enqueue"))
        assertTrue("墓碑 Worker 直接结束", notice.contains("override suspend fun doWork(): Result = Result.failure()"))
    }

    /** 反证：通知闭包改回在清理后才取地址（就读不到了）、或去掉通知 / 换成界面作用域 → 红。 */
    @Test
    fun disconnectNotifiesOnceThenClearsLocalPairing() {
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val branch = main.substringAfter("onDisconnect = {").substringBefore("\n                        },")
        val notify = branch.indexOf("notifyUnpairOnce(client, s.pairing)")
        // #1039：断开经 clearLocalPairingLogged（清理写失败只记日志、照常离开）。
        val clear = branch.indexOf("clearLocalPairingLogged(context, s.pairing)")
        assertTrue("断开必须尽力通知一次: $branch", notify >= 0)
        assertTrue("通知所需的值在清理前取出（notifyUnpairOnce 在调用点求值，早于清理）", notify in 0 until clear)
        assertTrue("经 disconnectAndNotifyInBackground：清理不受通知结局与取消影响", branch.contains("disconnectAndNotifyInBackground("))
        assertTrue("通知跑在应用级作用域，不随界面销毁取消", branch.contains("background = app.noticeScope"))
        assertFalse("断开分支不得等通知（不得直接调用 notify 挂起）", Regex("""notify\s*=\s*\{\s*notifyUnpairOnce""").containsMatchIn(branch))
    }
}
