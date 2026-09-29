// MOB-122（#540）：电池白名单在 App 外加回之后，后台备份必须自己回来。
//
// 2026-09-29 模拟器取证（#130 评论）：移出白名单 → 打开 App（挂起：autoEnabled=false、userRequested=true，
// 周期任务与 MediaWatchJob 全部 cancel）→ 在系统设置里加回 → 回到 App。结果 JobScheduler 里 0 个任务，
// autoEnabled 一直是 false，而设置页开关是开、状态行写「插电 + Wi-Fi 时自动进行」；`am kill` 重开也不恢复。
//
// 已定语义（MOB-93 #275/#279、#413/#424）：用户意图 userRequested 是真相源，白名单是前提。前提回来了就按
// 意图恢复；用户自己关掉的（userRequested=false）绝不替他打开。
//
// 行为用例把 AutoBackupPrefs 的文件 IO 真走一遍；WorkManager/JobScheduler 走 AutoBackupScheduler 端口。
// 两条入口（前台 ON_RESUME、进程启动对账）的接线是源文本断言——它们在 Android 组件里，JVM 起不来。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MOB122ResumeAfterWhitelistRestoredTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private var scheduled = 0
    private val scheduler = AutoBackupScheduler { scheduled++ }

    /** 用户开着后台备份，随后白名单被移出、App 走了挂起（生产里 suspendAutoBackupUntilAuthorized 的落盘一半）。 */
    private fun suspendedByWhitelistLoss() {
        markAutoBackupEnabled(tmp.root)
        markAutoBackupSuspended(tmp.root)
        val prefs = AutoBackupPrefs(tmp.root)
        check(!prefs.enabled() && prefs.requested()) { "前置：挂起态应是 意图在、生产者停" }
    }

    private fun restore(
        authorized: Boolean = true,
        paired: Boolean = true,
        awaitingUserConsent: Boolean = false,
    ) = restoreAutoBackupIfAuthorized(tmp.root, paired, authorized, awaitingUserConsent, scheduler)

    // ── 行为 ──────────────────────────────────────────────────

    @Test
    fun whitelist_restored_outside_the_app_resumes_background_backup_on_return() {
        suspendedByWhitelistLoss()

        val outcome = restore(authorized = true)

        assertEquals(AuthorizationRestore.RESUMED, outcome)
        val prefs = AutoBackupPrefs(tmp.root)
        assertTrue("白名单回来、意图还在 → 生产者必须重新开起来", prefs.enabled())
        assertTrue("意图不许被这一步改掉", prefs.requested())
        assertEquals("周期任务与相册监听必须重新登记一次", 1, scheduled)
    }

    @Test
    fun a_cold_start_reads_the_suspended_state_from_disk_and_resumes_the_same_way() {
        // 冷启动 = 新进程只剩磁盘上的文件。`am kill` 重开也不恢复是原症状之一。
        File(tmp.root, "auto_backup_prefs.json").writeText("""{"autoEnabled":false,"userRequested":true}""")

        assertEquals(AuthorizationRestore.RESUMED, restore(authorized = true))
        assertTrue(AutoBackupPrefs(tmp.root).enabled())
        assertEquals(1, scheduled)
    }

    @Test
    fun still_not_whitelisted_stays_suspended() {
        suspendedByWhitelistLoss()

        assertEquals(AuthorizationRestore.NONE, restore(authorized = false))
        assertFalse("前提没满足，不许开生产者", AutoBackupPrefs(tmp.root).enabled())
        assertEquals(0, scheduled)
    }

    @Test
    fun a_user_who_turned_background_backup_off_is_never_turned_back_on() {
        // 用户自己在设置里关的（disableAutoBackup 的落盘：意图 false、生产者 false）。
        AutoBackupPrefs(tmp.root).apply {
            setRequested(false)
            setEnabled(false)
        }

        assertEquals(AuthorizationRestore.NONE, restore(authorized = true))
        assertFalse(AutoBackupPrefs(tmp.root).enabled())
        assertFalse("意图也不许被凭空写成 true", AutoBackupPrefs(tmp.root).requested())
        assertEquals(0, scheduled)
    }

    @Test
    fun a_legacy_file_without_intent_is_not_mistaken_for_one() {
        // 老文件只有 autoEnabled=false：requested() 回退到 false——不是「挂起中的意图」。
        File(tmp.root, "auto_backup_prefs.json").writeText("""{"autoEnabled":false}""")

        assertEquals(AuthorizationRestore.NONE, restore(authorized = true))
        assertFalse(AutoBackupPrefs(tmp.root).enabled())
    }

    @Test
    fun unpaired_leaves_the_pairing_change_suspension_to_mob93() {
        // 断开留下的也是 意图在、生产者停；连回旧电脑由 restoreAutoBackupAfterRepair 兑现，
        // 换新电脑由 onboarding 重新问——没配对时这里不许抢先打开。
        suspendedByWhitelistLoss()

        assertEquals(AuthorizationRestore.NONE, restore(authorized = true, paired = false))
        assertFalse(AutoBackupPrefs(tmp.root).enabled())
        assertEquals(0, scheduled)
    }

    @Test
    fun an_unacknowledged_interruption_re_enables_but_never_rearms() {
        // MOB-28 红线：监听被清、等用户点「恢复」期间，重挂的唯一入口是 resumeAfterInterruption。
        suspendedByWhitelistLoss()

        assertEquals(AuthorizationRestore.RESUMED_AWAITING_CONSENT, restore(awaitingUserConsent = true))
        assertTrue("生产者开关要回来，否则用户点了恢复也被 enabled() 闸门挡住", AutoBackupPrefs(tmp.root).enabled())
        assertEquals("等用户确认期间不许重挂", 0, scheduled)
    }

    @Test
    fun already_running_producers_are_left_alone() {
        markAutoBackupEnabled(tmp.root)

        assertEquals(AuthorizationRestore.NONE, restore(authorized = true))
        assertEquals("每次回前台都跑这条，已开着时不许重复登记、不许重复写恢复日志", 0, scheduled)
    }

    @Test
    fun every_write_advances_the_revision_the_ui_reads_from() {
        // 界面据 revision 重读 enabled()：进程启动线程改掉的状态，界面也得看得到。
        suspendedByWhitelistLoss()
        val before = AutoBackupPrefs.revision.value

        restore(authorized = true)

        assertTrue("恢复落盘必须推进 revision", AutoBackupPrefs.revision.value > before)
    }

    @Test
    fun the_hero_line_only_promises_automatic_backup_when_it_is_armed() {
        // 原症状里的「插电 + Wi-Fi 时自动进行」就是这一句；挂起期间与设置行 hint 说同一句话。
        val auto = com.hawkeyexb.ppass.R.string.idle_auto_hint
        assertEquals(auto, com.hawkeyexb.ppass.ui.idleHintRes(BackgroundBackupState.Armed))
        assertEquals(
            com.hawkeyexb.ppass.R.string.background_backup_system_stopped,
            com.hawkeyexb.ppass.ui.idleHintRes(BackgroundBackupState.SystemStoppedWatcher),
        )
        assertEquals(
            com.hawkeyexb.ppass.R.string.background_backup_needs_authorization,
            com.hawkeyexb.ppass.ui.idleHintRes(BackgroundBackupState.NeedsSystemAuthorization),
        )
    }

    // ── 两条入口的接线（源码级）──────────────────────────────────

    @Test
    fun resume_restores_before_the_foreground_catchup_reads_enabled() {
        val s = code("MainActivity.kt")
        val onResume = s.substringAfter("Lifecycle.Event.ON_RESUME -> {").substringBefore("Lifecycle.Event.ON_STOP")
        val restoreAt = onResume.indexOf("restoreAutoBackupAfterAuthorizationReturned(")
        val catchupAt = onResume.indexOf("foregroundCatchup()")
        assertTrue("ON_RESUME 必须在白名单回来时恢复", restoreAt >= 0)
        assertTrue("必须排在 foregroundCatchup() 之前——它门控在 enabled() 上", restoreAt in 0 until catchupAt)
    }

    @Test
    fun process_start_restores_before_the_disabled_early_return_and_the_recovery_verdict() {
        val body = code("backup/BackupHealth.kt").substringAfter("fun reconcileWatchOnProcessStart(")
        val restoreAt = body.indexOf("restoreAutoBackupAfterAuthorizationReturned(")
        val earlyReturnAt = body.indexOf("if (!AutoBackupPrefs(context.filesDir).enabled()) return")
        val verdictAt = body.indexOf("decideRecovery(")
        assertTrue("进程启动对账必须恢复", restoreAt >= 0)
        assertTrue("必须在 !enabled 早退之前，否则冷启动永远停着", restoreAt in 0 until earlyReturnAt)
        assertTrue("必须在 decideRecovery 之前，否则自己 cancel 掉的 job 会被判成 force-stop", restoreAt < verdictAt)
    }

    @Test
    fun the_settings_state_reads_the_real_producer_state() {
        val s = code("MainActivity.kt")
        val call = s.substringAfter("backgroundBackupStateOf(").substringBefore(")")
        assertTrue("状态行必须接上生产者真相", call.contains("producerEnabled = autoBackupProducing"))
        assertTrue(
            "生产者真相必须随任意线程的落盘刷新，而不是只在界面回调里刷",
            s.contains("AutoBackupPrefs.revision.collectAsState()") &&
                s.contains("remember(autoPrefsRevision) { prefs.enabled() }"),
        )
    }

    @Test
    fun the_hero_idle_line_is_wired_to_the_background_state() {
        val s = code("ui/HomeScreen.kt")
        assertTrue(
            "空闲态那一句必须经 idleHintRes 看后台状态",
            s.contains("is StatusLine.Ready -> stringResource(idleHintRes(backgroundBackupState))"),
        )
    }

    private fun code(rel: String): String =
        File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/$rel").readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }
}
