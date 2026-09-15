package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundBackupPresentationContractTest {
    private fun source(path: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) dir = dir.parentFile ?: error("apps/android not found")
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$path").readText()
    }

    @Test
    fun onboarding_requests_only_background_authorization_when_the_user_chooses_it() {
        val main = source("MainActivity.kt")
        val started = main.substringAfter("\n        is Screen.Started -> {")
            .substringBefore("private fun requiredMediaPermissions")

        assertTrue(started.contains("backgroundAuthorization.requestIntent()"))
        assertFalse("notification permission must not be requested during onboarding", started.contains("POST_NOTIFICATIONS"))
    }

    @Test
    fun background_interruption_is_not_a_global_notice_and_viewers_hide_shell_notices() {
        val notices = source("ui/HomeNotices.kt")
        val tabsCall = source("MainActivity.kt").substringAfter("TwoTabs(")
            .substringBefore("photos = {")

        assertFalse(notices.substringAfter("fun NoticeHost(").contains("backupInterrupted"))
        assertTrue(tabsCall.contains("if (!photoViewerOpen && !storageDetailOpen)"))
    }

    @Test
    fun settings_tab_alert_is_not_raised_by_a_healthy_running_background_backup() {
        // 2026-09-15 用户反馈：设置图标红点一直亮着不消失。根因是
        // `settingsAlert` 曾用 `!= OffByUser` 判后台备份，把正常运行中的
        // `Armed` 状态也算作"需要提示"——只要用户开着后台备份就永久亮红点。
        // 红点只应在两个真出问题的状态触发：待授权白名单 / 监听被系统清掉。
        val tabsCall = source("MainActivity.kt").substringAfter("TwoTabs(")
            .substringBefore("notice = if")

        assertFalse(
            "settingsAlert must not treat every non-OffByUser state as an alert",
            tabsCall.contains("!= BackgroundBackupState.OffByUser"),
        )
        assertTrue(tabsCall.contains("BackgroundBackupState.NeedsSystemAuthorization"))
        assertTrue(tabsCall.contains("BackgroundBackupState.SystemStoppedWatcher"))
    }
}
