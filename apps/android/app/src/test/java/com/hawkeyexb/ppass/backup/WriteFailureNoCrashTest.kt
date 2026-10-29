// #1039（#1020 之外的写盘点，对位 iOS #969 / #971 / #974）：完成页标记、通知询问标记、中断确认、配对分支、断开清单、
// 配对文件、回到前台的对账、首页补记、启动时定老用户——写失败不崩溃、盘上停在真实值、该提示的提示；
// 存储空间恢复后再做一次就能正常落盘。
//
// 写失败是真实制造的：把目录设成只读，store 的 tmp 文件写不进去（与真机「存储满」同一条抛出路径），不是 mock。
// 界面接线（MainActivity 是否真的走这些边界）由最后两条源码门禁钉住。
//
// 反证（脚本逐个施加，见 PR）：SettingsWriter.quiet 去掉 catch / savePairingOrError 去掉 catch /
// applyDisconnectManifest 去掉逐行 catch / acknowledgeInterruptionThenRearm 先重挂再确认 /
// MainActivity 任一处改回裸调用——对应的测试变红。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class WriteFailureNoCrashTest {
    private val logs = mutableListOf<String>()
    private val notices = mutableListOf<Int>()
    private val writer = SettingsWriter { notices += it }
    private lateinit var dir: File
    private val nodeId = "b".repeat(64)

    @Before
    fun setUp() {
        PLog.sink = PLog.Sink { _, _, m -> logs += m }
        dir = Files.createTempDirectory("write-failure").toFile()
    }

    @After
    fun tearDown() {
        dir.setWritable(true)
        dir.deleteRecursively()
        PLog.resetSink()
    }

    /** 存储满：之后的写盘失败。 */
    private fun breakWrites() {
        check(dir.setWritable(false))
        check(!File(dir, "probe").let { runCatching { it.writeText("x") }.isSuccess }) { "read-only dir is writable (running as root?)" }
    }

    /** 用户清出了空间。 */
    private fun spaceFreed() {
        check(dir.setWritable(true))
    }

    // ── 完成页 ─────────────────────────────────────────────────

    @Test
    fun onboarded_mark_failure_is_reported_and_succeeds_after_space_is_freed() {
        val store = OnboardedDesktopsStore(dir)
        breakWrites()

        val saved = writer.write("onboarded", nodeId.take(8)) { store.markOnboarded(nodeId) }

        assertFalse(saved)
        assertFalse("没记下来就按新电脑算（偏安全的一侧）", store.wasOnboarded(nodeId))
        assertEquals(listOf(R.string.setting_save_failed), notices)
        assertTrue(logs.any { it.startsWith("settings: write failed (onboarded)") })

        spaceFreed()
        assertTrue(writer.write("onboarded", nodeId.take(8)) { store.markOnboarded(nodeId) })
        assertTrue(store.wasOnboarded(nodeId))
    }

    @Test
    fun notify_prefs_init_failure_on_launch_means_off_and_retries_next_launch() {
        val prefs = NotifyOnFailurePrefs(dir)
        breakWrites()

        assertTrue(runCatching { prefs.initIfAbsent(existingUser = true) }.isFailure)
        assertFalse("文件没落下 = 关（偏隐私的一侧）", prefs.enabled())

        spaceFreed()
        prefs.initIfAbsent(existingUser = true)
        assertTrue(prefs.enabled())
    }

    // ── 中断卡「恢复备份」 ─────────────────────────────────────

    @Test
    fun interruption_ack_failure_keeps_the_card_and_does_not_rearm() {
        val health = BackupHealthPrefs(dir)
        health.recordInterrupted(now = 1L)
        var rearmed = 0
        breakWrites()

        val resumed = writer.write("backupInterruption", "acknowledged") {
            acknowledgeInterruptionThenRearm(dir) { rearmed++ }
        }

        assertFalse(resumed)
        assertEquals("确认没存上就不重挂——否则卡片还在、任务已经在跑", 0, rearmed)
        assertTrue("中断卡留着", health.load().interruptedUnacknowledged)
        assertEquals(listOf(R.string.setting_save_failed), notices)

        spaceFreed()
        assertTrue(writer.write("backupInterruption", "acknowledged") { acknowledgeInterruptionThenRearm(dir) { rearmed++ } })
        assertEquals(1, rearmed)
        assertFalse(health.load().interruptedUnacknowledged)
    }

    // ── 配对 ──────────────────────────────────────────────────

    @Test
    fun pairing_save_failure_is_a_pairing_failure_not_a_crash() {
        val store = PairingStore(dir)
        val pairing = Pairing(nodeId, "token", "Mac", pairedAt = 1L, pairingId = "e1")
        breakWrites()

        val error = savePairingOrError { store.save(pairing) }

        assertNotNull("写失败要交给调用方进失败页", error)
        assertNull("不许留下重启即丢的「已配对」", store.load())
        assertTrue(logs.any { it.startsWith("pair: cannot persist pairing.json") })

        spaceFreed()
        assertNull(savePairingOrError { store.save(pairing) })
        assertEquals(pairing, store.load())
    }

    @Test
    fun new_desktop_intent_clear_failure_is_reported_and_the_finish_page_rewrite_stops_the_silent_resume() {
        val prefs = AutoBackupPrefs(dir)
        prefs.set(requested = true, enabled = false) // 断开旧电脑后：停生产者、留意图（MOB-93）
        breakWrites()

        assertFalse(writer.write("autoBackup", "new desktop, ask again") { prefs.setRequested(false) })
        assertEquals(listOf(R.string.setting_save_failed), notices)
        assertTrue("旧意图还在盘上", prefs.requested())

        spaceFreed()
        // 不再写一次的话：回到前台的 #540 对账会把新电脑的后台备份悄悄打开——这正是完成页「进入」要再写一次的原因。
        val wouldResume = restoreAutoBackupIfAuthorized(dir, paired = true, backgroundAuthorized = true, awaitingUserConsent = false) {}
        assertEquals(AuthorizationRestore.RESUMED, wouldResume)

        prefs.set(requested = true, enabled = false)
        // 完成页点「进入」：按用户的选择写下「不开」（生产里是 disableAutoBackup 的落盘一半）。
        assertTrue(writer.write("autoBackup", false) { prefs.set(requested = false, enabled = false) })
        assertEquals(
            AuthorizationRestore.NONE,
            restoreAutoBackupIfAuthorized(dir, paired = true, backgroundAuthorized = true, awaitingUserConsent = false) {},
        )
    }

    @Test
    fun background_restore_on_resume_failure_is_quiet_and_retries_next_time() {
        markAutoBackupSuspended(dir)
        var scheduled = 0
        breakWrites()

        val restored = writer.quiet("autoBackup", "restore on resume") {
            restoreAutoBackupIfAuthorized(dir, paired = true, backgroundAuthorized = true, awaitingUserConsent = false) { scheduled++ }
        }

        assertFalse(restored)
        assertEquals(0, scheduled)
        assertTrue(notices.isEmpty())
        assertFalse(AutoBackupPrefs(dir).enabled())

        spaceFreed()
        assertTrue(
            writer.quiet("autoBackup", "restore on resume") {
                restoreAutoBackupIfAuthorized(dir, paired = true, backgroundAuthorized = true, awaitingUserConsent = false) { scheduled++ }
            },
        )
        assertEquals(1, scheduled)
        assertTrue(AutoBackupPrefs(dir).enabled())
    }

    @Test
    fun home_backfill_failure_is_quiet() {
        val store = OnboardedDesktopsStore(dir)
        breakWrites()
        assertFalse(writer.quiet("onboarded", "backfill") { backfillOnboardedOnHome(store, nodeId) { true } })
        assertTrue(notices.isEmpty())
        spaceFreed()
        assertTrue(writer.quiet("onboarded", "backfill") { backfillOnboardedOnHome(store, nodeId) { true } })
        assertTrue(store.wasOnboarded(nodeId))
    }

    // ── 断开 ──────────────────────────────────────────────────

    @Test
    fun disconnect_runs_every_row_even_when_the_prefs_write_fails() {
        AutoBackupPrefs(dir).set(requested = true, enabled = true)
        val stopped = mutableListOf<String>()
        val runtime = object : DisconnectRuntime {
            override fun stopFlowRuntime() { stopped += "flow" }
            override fun cancelUniqueWork(name: String) { stopped += "work:$name" }
            override fun cancelMediaWatch() { stopped += "mediaWatch" }
            override fun clearPreviewCache() { stopped += "thumbs" }
        }
        breakWrites()

        assertThrows("第一个错误照样抛出，不吞（调用方记日志）", Exception::class.java) {
            applyDisconnectManifest(dir, File(dir.parentFile, "cache"), runtime)
        }

        assertTrue("偏好那一行（AUTO_BACKUP_PREFS）后面的停止行必须照常执行", "mediaWatch" in stopped)
        DisconnectState.AUTO_BACKUP_WORKS.workNames.forEach { assertTrue("work:$it" in stopped) }
        val prefs = AutoBackupPrefs(dir)
        // 只证明「写失败时盘上停在原值」；「意图 + 生产者一次落盘」由 AutoBackupPrefs.set 的写法保证（只读目录下两次写也是第一次就失败，测不出区别）。
        assertTrue("写失败时盘上停在原值", prefs.requested() && prefs.enabled())

        spaceFreed()
        stopped.clear()
        applyDisconnectManifest(dir, File(dir.parentFile, "cache"), runtime)
        assertTrue("留意图", prefs.requested())
        assertFalse("停生产者", prefs.enabled())
    }

    // ── 界面接线门禁 ──────────────────────────────────────────

    private val main by lazy { File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText() }

    /** [call] 在 MainActivity 里的每一处，前面 [window] 个字符内都要有 [wrapper]。 */
    private fun assertEveryCallWrapped(call: String, wrapper: String, window: Int = 160) {
        var i = main.indexOf(call)
        assertTrue("MainActivity 里找不到 `$call`", i >= 0)
        while (i >= 0) {
            val before = main.substring(maxOf(0, i - window), i)
            assertTrue("`$call`（offset $i）没有经过 `$wrapper`", before.contains(wrapper))
            i = main.indexOf(call, i + call.length)
        }
    }

    @Test
    fun activity_routes_the_1039_writes_through_the_boundaries() {
        assertEveryCallWrapped(".markOnboarded(s.pairing.daemonNodeId)", "settingsWriter.write(\"onboarded\"")
        assertEveryCallWrapped("notifyOnFailurePrefs.markSystemAsked()", "settingsWriter.quiet(\"notifyOnFailure\", \"system asked\")")
        assertEveryCallWrapped("resumeAfterInterruption(context)", "settingsWriter.write(\"backupInterruption\", \"acknowledged\")")
        assertEveryCallWrapped("BackupHealthPrefs(context.filesDir).acknowledge()", "settingsWriter.write(\"backupInterruption\", \"acknowledged\")")
        assertEveryCallWrapped("AutoBackupPrefs(context.filesDir).setRequested(false)", "settingsWriter.write(\"autoBackup\", \"new desktop, ask again\")")
        assertEveryCallWrapped("restoreAutoBackupAfterRepair(", "settingsWriter.quiet(\"autoBackup\"")
        assertEveryCallWrapped("restoreAutoBackupAfterAuthorizationReturned(context", "settingsWriter.")
        assertEveryCallWrapped("backfillOnboardedOnHome(", "settingsWriter.quiet(\"onboarded\", \"backfill\")")
        assertEveryCallWrapped("pairings.save(outcome.pairing)", "savePairingOrError {")
        assertFalse(
            "断开 / 重新扫码不许直接调会抛出的 clearLocalPairing",
            main.contains("withContext(Dispatchers.IO) { clearLocalPairing(context"),
        )
        assertTrue(main.contains("clearLocalPairingLogged(context, s.pairing)"))
    }

    @Test
    fun finish_page_enter_rewrites_the_intent_and_pair_save_failure_goes_to_the_trouble_page() {
        assertTrue(
            "完成页「进入」要按用户的选择把意图再写一次",
            main.contains("onEnter = onEnterWithoutBackgroundBackup,"),
        )
        val enter = main.substringAfter("val onEnterWithoutBackgroundBackup = {").substringBefore("\n            }")
        assertTrue(enter.contains("settingsWriter.write(\"autoBackup\", false) { disableAutoBackup(context) }"))
        val joined = main.substringAfter("val saveError = savePairingOrError").substringBefore("return@LaunchedEffect")
        assertTrue("配对文件存不下来 → 配对失败页（对位 iOS pair_save_failed）", joined.contains("R.string.pair_save_failed"))
    }
}
