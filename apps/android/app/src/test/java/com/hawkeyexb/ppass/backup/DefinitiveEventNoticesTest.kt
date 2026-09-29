// #130 第 1 层：确定事件通知的去重 / 复位状态机、开关闸控、各事件判定，以及接线点。
package com.hawkeyexb.ppass.backup

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DefinitiveEventNoticesTest {

    private class FakeNotifier(var on: Boolean = true) : DefinitiveEventNotifier {
        val posted = mutableListOf<DefinitiveNotice>()
        val cancelled = mutableListOf<DefinitiveEvent>()
        override fun enabled(): Boolean = on
        override fun post(notice: DefinitiveNotice) { posted += notice }
        override fun cancel(event: DefinitiveEvent) { cancelled += event }
    }

    private val healthy = DefinitiveFacts(
        pairingEpoch = "e1",
        pairingLost = false,
        mediaAccess = MediaAccess.FULL,
        backgroundRequested = true,
        interruptionDetectedAt = null,
        batteryWhitelisted = true,
    )

    private val dir: File = Files.createTempDirectory("definitive").toFile()

    /** 每次都新建 store + monitor：等于每次评估都是一次新进程（只有盘上的状态留下来）。 */
    private fun run(facts: DefinitiveFacts, notifier: FakeNotifier) =
        DefinitiveEventMonitor(DefinitiveNoticeStore(dir), notifier).evaluate(facts)

    // ---- 配对失效 ----

    @Test
    fun pairing_lost_is_posted_once_per_epoch_even_across_process_restarts() {
        val n = FakeNotifier()
        run(healthy, n)
        run(healthy.copy(pairingLost = true), n)
        run(healthy.copy(pairingLost = true), n)
        // 进程重启：内存里的 lostEpoch 没了（isLost = false），epoch 还是同一个——不算恢复。
        run(healthy.copy(pairingLost = false), n)
        run(healthy.copy(pairingLost = true), n)
        assertEquals(listOf<DefinitiveNotice>(DefinitiveNotice.PairingLost), n.posted)
        assertTrue("isLost 变 false 不是恢复，不许撤通知", DefinitiveEvent.PAIRING_LOST !in n.cancelled)
    }

    @Test
    fun pairing_lost_resets_after_repair_and_fires_again_for_the_new_pairing() {
        val n = FakeNotifier()
        run(healthy.copy(pairingLost = true), n)
        // 用户点「重新扫码」：本地配对清掉 → 复位并撤掉旧通知。
        run(healthy.copy(pairingEpoch = null), n)
        assertEquals(listOf(DefinitiveEvent.PAIRING_LOST), n.cancelled)
        run(healthy.copy(pairingEpoch = "e2"), n)
        run(healthy.copy(pairingEpoch = "e2", pairingLost = true), n)
        assertEquals(2, n.posted.count { it == DefinitiveNotice.PairingLost })
    }

    @Test
    fun a_new_epoch_alone_resets_the_pairing_latch() {
        val n = FakeNotifier()
        run(healthy.copy(pairingLost = true), n)
        run(healthy.copy(pairingEpoch = "e2", pairingLost = true), n)
        assertEquals(2, n.posted.size)
    }

    // ---- 相册权限 ----

    @Test
    fun first_ever_evaluation_only_records_the_media_baseline() {
        val n = FakeNotifier()
        run(healthy.copy(mediaAccess = MediaAccess.PARTIAL), n)
        assertEquals(emptyList<DefinitiveNotice>(), n.posted)
    }

    @Test
    fun full_to_partial_posts_once_and_restoring_full_resets() {
        val n = FakeNotifier()
        run(healthy, n)
        run(healthy.copy(mediaAccess = MediaAccess.PARTIAL), n)
        run(healthy.copy(mediaAccess = MediaAccess.PARTIAL), n)
        assertEquals(listOf<DefinitiveNotice>(DefinitiveNotice.MediaAccessRevoked(MediaAccess.PARTIAL)), n.posted)
        run(healthy, n)
        assertEquals(listOf(DefinitiveEvent.MEDIA_ACCESS_REVOKED), n.cancelled)
        run(healthy.copy(mediaAccess = MediaAccess.PARTIAL), n)
        assertEquals(2, n.posted.size)
    }

    @Test
    fun each_further_downgrade_is_a_new_change_and_upgrades_never_post() {
        val n = FakeNotifier()
        run(healthy, n)
        run(healthy.copy(mediaAccess = MediaAccess.NONE), n)
        run(healthy.copy(mediaAccess = MediaAccess.PARTIAL), n) // 变好（没回到 FULL）：不发、不复位
        run(healthy.copy(mediaAccess = MediaAccess.NONE), n)    // 再变差：发
        assertEquals(
            listOf<DefinitiveNotice>(
                DefinitiveNotice.MediaAccessRevoked(MediaAccess.NONE),
                DefinitiveNotice.MediaAccessRevoked(MediaAccess.NONE),
            ),
            n.posted,
        )
        assertEquals(emptyList<DefinitiveEvent>(), n.cancelled)
    }

    @Test
    fun media_downgrade_while_unpaired_is_recorded_but_not_posted() {
        val n = FakeNotifier()
        run(healthy.copy(pairingEpoch = null), n)
        run(healthy.copy(pairingEpoch = null, mediaAccess = MediaAccess.NONE), n)
        assertEquals(emptyList<DefinitiveNotice>(), n.posted)
    }

    // ---- 系统停止了后台备份 ----

    @Test
    fun an_interruption_is_posted_once_per_detection_and_resets_when_resumed() {
        val n = FakeNotifier()
        run(healthy, n)
        run(healthy.copy(interruptionDetectedAt = 100L), n)
        run(healthy.copy(interruptionDetectedAt = 100L), n)
        assertEquals(listOf<DefinitiveNotice>(DefinitiveNotice.BackgroundStopped(batteryOnly = false)), n.posted)
        run(healthy, n) // 用户点了「恢复备份」
        assertEquals(listOf(DefinitiveEvent.BACKGROUND_STOPPED), n.cancelled)
        run(healthy.copy(interruptionDetectedAt = 200L), n)
        assertEquals(2, n.posted.size)
    }

    @Test
    fun battery_optimization_turned_back_on_posts_once_and_resets_when_whitelisted_again() {
        val n = FakeNotifier()
        run(healthy, n)
        run(healthy.copy(batteryWhitelisted = false), n)
        run(healthy.copy(batteryWhitelisted = false), n)
        assertEquals(listOf<DefinitiveNotice>(DefinitiveNotice.BackgroundStopped(batteryOnly = true)), n.posted)
        run(healthy, n)
        assertEquals(listOf(DefinitiveEvent.BACKGROUND_STOPPED), n.cancelled)
        run(healthy.copy(batteryWhitelisted = false), n)
        assertEquals(2, n.posted.size)
    }

    @Test
    fun battery_without_a_true_baseline_or_without_background_intent_never_posts() {
        val n = FakeNotifier()
        run(healthy.copy(batteryWhitelisted = false), n) // 从没记过：只记基线
        run(healthy, n)
        run(healthy.copy(batteryWhitelisted = false, backgroundRequested = false), n) // 用户没要后台备份
        assertEquals(emptyList<DefinitiveNotice>(), n.posted)
    }

    @Test
    fun interruption_and_battery_together_post_a_single_interruption_notice() {
        val n = FakeNotifier()
        run(healthy, n)
        run(healthy.copy(interruptionDetectedAt = 5L, batteryWhitelisted = false), n)
        assertEquals(listOf<DefinitiveNotice>(DefinitiveNotice.BackgroundStopped(batteryOnly = false)), n.posted)
    }

    // ---- 开关闸控 ----

    @Test
    fun switch_off_suppresses_posting_but_the_state_still_advances() {
        val n = FakeNotifier(on = false)
        run(healthy, n)
        run(healthy.copy(pairingLost = true, mediaAccess = MediaAccess.PARTIAL, interruptionDetectedAt = 9L), n)
        assertEquals(emptyList<DefinitiveNotice>(), n.posted)
        // 用户后来打开开关：关着时发生过的事不许集中补发。
        n.on = true
        run(healthy.copy(pairingLost = true, mediaAccess = MediaAccess.PARTIAL, interruptionDetectedAt = 9L), n)
        assertEquals(emptyList<DefinitiveNotice>(), n.posted)
        // 之后的新变化照常发。
        run(healthy.copy(pairingLost = true, mediaAccess = MediaAccess.NONE, interruptionDetectedAt = 9L), n)
        assertEquals(listOf<DefinitiveNotice>(DefinitiveNotice.MediaAccessRevoked(MediaAccess.NONE)), n.posted)
    }

    @Test
    fun a_notifier_that_throws_never_breaks_state_persistence() {
        val boom = object : DefinitiveEventNotifier {
            override fun enabled() = true
            override fun post(notice: DefinitiveNotice) = error("boom")
            override fun cancel(event: DefinitiveEvent) = error("boom")
        }
        DefinitiveEventMonitor(DefinitiveNoticeStore(dir), boom).evaluate(healthy.copy(pairingLost = true))
        assertEquals("e1", DefinitiveNoticeStore(dir).load().notifiedLostEpoch)
    }

    // ---- 接线点（源文本）：四个评估入口都在，且都不在 #162 的文件里 ----

    private fun src(rel: String): String {
        var root = File(System.getProperty("user.dir"))
        while (!File(root, "apps/android").isDirectory) root = root.parentFile ?: error("apps/android not found")
        return File(root, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$rel").readText()
    }

    @Test
    fun the_notify_switch_explains_itself_in_a_neutral_non_clickable_hint() {
        val row = src("ui/HomeScreen.kt").substringAfter("label = stringResource(R.string.rule_notify),").substringBefore(")\n")
        assertTrue("开关下有说明小字", row.contains("hint = stringResource(R.string.rule_notify_hint)"))
        assertTrue("说明小字用默认中性色、不可点", !row.contains("hintColor") && !row.contains("onHintClick"))
    }

    @Test
    fun every_run_of_the_app_evaluates_definitive_events() {
        val app = src("PPassApplication.kt")
        val boot = app.substringAfter("thread(name = \"ppass-boot-check\") {").substringBefore("registerNetworkCallback()")
        assertTrue("进程启动在 MOB-28 对账之后评估", boot.indexOf("evaluateDefinitiveEvents(") > boot.indexOf("reconcileWatchOnProcessStart("))
        assertTrue("配对失效记下时评估", app.contains("flowDeliveryPairingLoss.changes.collect { evaluateDefinitiveEvents("))
        val foreground = app.substringAfter("override fun onActivityStarted").substringBefore("override fun onActivityStopped")
        assertTrue("进前台评估", foreground.contains("evaluateDefinitiveEvents("))
        val work = src("backup/BackupWorker.kt").substringAfter("override suspend fun doWork()").substringBefore("Result.success()")
        assertTrue(
            "Worker 唤醒在后台开关闸门之前评估",
            work.indexOf("evaluateDefinitiveEvents(") in 0 until work.indexOf("AutoBackupPrefs("),
        )
    }
}
