// MOB-37: 重传告知的落盘（通知丢了也要留下痕迹）。
//
// 反证怎么做（验收标准第 2 条）：把 [noteReuploadNotice] 改成只发通知、
// 不落盘（`if (lost.isEmpty()) return; runCatching { notify() }`），则
// [state_survives_a_notification_that_throws]、
// [in_app_notice_reads_the_disk_not_the_notification]、
// [acknowledge_hides_it_and_a_new_batch_shows_again]、
// [calibration_prunes_the_cache_even_when_the_notification_throws]
// 必须全部变红。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReuploadNoticeTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-notice-$tag").toFile()

    // ── 关键判据：通知抛异常，状态仍在盘上 ─────────────────

    @Test
    fun state_survives_a_notification_that_throws() {
        val dir = tempDir("throws")
        val prefs = ReuploadNoticePrefs(dir)
        var attempted = false

        noteReuploadNotice(prefs, setOf("a", "b", "c"), now = 111L) {
            attempted = true
            // 权限没授 / 渠道被关 / 系统抛——真机上这条路是常态，不是边角。
            throw SecurityException("no POST_NOTIFICATIONS permission")
        }

        assertTrue("通知确实被尝试过", attempted)
        // 落盘先于通知，且通知的异常被吞掉——所以状态在盘上。
        val onDisk = ReuploadNoticePrefs(dir).load()
        assertEquals(setOf("a", "b", "c"), onDisk.lost)
        assertEquals(3, reuploadNoticeCountOf(onDisk))
        assertEquals(111L, onDisk.detectedAt)
        assertTrue("状态必须真的落到文件上", File(dir, "reupload_notice.json").isFile)
    }

    @Test
    fun in_app_notice_reads_the_disk_not_the_notification() {
        // 呈现的唯一输入是落盘状态——本测试压根没有「通知」这个概念。
        val dir = tempDir("disk")
        assertEquals("干净状态不显示", 0, reuploadNoticeCountOf(ReuploadNoticePrefs(dir).load()))
        ReuploadNoticePrefs(dir).record(setOf("h1", "h2"), now = 1L)
        // 换一个实例读（跨进程/跨组件的等价物）。
        assertEquals(2, reuploadNoticeCountOf(ReuploadNoticePrefs(dir).load()))
    }

    // ── acknowledge：看过就消，新一批重新显示 ───────────────

    @Test
    fun acknowledge_hides_it_and_a_new_batch_shows_again() {
        val dir = tempDir("ack")
        val prefs = ReuploadNoticePrefs(dir)
        noteReuploadNotice(prefs, setOf("a"), now = 1L) {}
        assertEquals(1, reuploadNoticeCountOf(prefs.load()))

        prefs.acknowledge()
        assertEquals("看过就不再显示", 0, reuploadNoticeCountOf(ReuploadNoticePrefs(dir).load()))

        var notifiedAgain = false
        noteReuploadNotice(prefs, setOf("b", "c"), now = 2L) { notifiedAgain = true }
        assertEquals("新一批要重新显示", 2, reuploadNoticeCountOf(prefs.load()))
        assertTrue("acknowledge 之后的新一批是一次新的跃变，该发通知", notifiedAgain)
    }

    // ── 不重试通知：同一批状态只发一条 ────────────────────

    @Test
    fun a_pending_notice_never_sends_a_second_system_notification() {
        val dir = tempDir("once")
        val prefs = ReuploadNoticePrefs(dir)
        var notifications = 0

        noteReuploadNotice(prefs, setOf("a"), now = 1L) { notifications++ }
        // 同一批又来一次（MOB-33: 手动通道与周期通道可以并发校准）。
        noteReuploadNotice(prefs, setOf("a"), now = 2L) { notifications++ }
        // 用户还没点「知道了」时来了新的一批——**照样不许再发一条**。
        // 「不重试通知」是本卡的显式定调：重试只制造骚扰，治不了
        // 「用户当时没看」。兜底是那条状态在 App 里等他。
        noteReuploadNotice(prefs, setOf("b"), now = 3L) { notifications++ }

        assertEquals("同一条待看告知只许发一次系统通知", 1, notifications)
        assertEquals("但 App 内的张数要跟上", setOf("a", "b"), prefs.load().lost)
    }

    @Test
    fun the_same_batch_twice_never_inflates_the_count() {
        // MOB-33 并发双发：两轮都在对方 removeMissing 之前看到同一批 3 个
        // hash。累加计数会报「6 张」——一个编出来的数字。并集是幂等的。
        val dir = tempDir("union")
        val prefs = ReuploadNoticePrefs(dir)
        noteReuploadNotice(prefs, setOf("a", "b", "c"), now = 1L) {}
        noteReuploadNotice(prefs, setOf("a", "b", "c"), now = 2L) {}
        assertEquals(3, reuploadNoticeCountOf(prefs.load()))
    }

    @Test
    fun nothing_lost_writes_nothing() {
        val dir = tempDir("empty")
        var notified = false
        noteReuploadNotice(ReuploadNoticePrefs(dir), emptySet(), now = 1L) { notified = true }
        assertFalse(notified)
        assertFalse("空集不许留下文件", File(dir, "reupload_notice.json").isFile)
    }

    // ── 接进真校准内核：通知炸了也不许卡住 removeMissing ──────

    @Test
    fun calibration_prunes_the_cache_even_when_the_notification_throws() {
        // 为什么这条也钉在「落盘先于通知」上：onLost 跑在 removeMissing
        // **之前**、同一个 try 里。让通知的异常往上冒 → removeMissing 被
        // 跳过 → 这批 hash 留在 confirmed 里 → 下一轮校准重新算出同一批
        // → **又发一条通知**。那正好破了「不重试通知」。
        val stateDir = tempDir("calib")
        val store = ConfirmedStore(stateDir)
        store.recordRun(confirmed = setOf("a", "b"), lastSuccessAt = 1L)
        val prefs = ReuploadNoticePrefs(stateDir)

        val ok = runBlocking {
            calibrateConfirmed(
                store,
                existCheck = { setOf("a") },
                onLost = { lost ->
                    noteReuploadNotice(prefs, lost, now = 9L) {
                        throw IllegalStateException("notification manager exploded")
                    }
                },
            )
        }

        assertTrue("交互成功即算可达", ok)
        assertEquals("告知落盘了", setOf("a"), prefs.load().lost)
        assertEquals("缓存照常剪枝（否则下一轮会重发通知）", setOf("b"), store.load().confirmed)
    }
}
