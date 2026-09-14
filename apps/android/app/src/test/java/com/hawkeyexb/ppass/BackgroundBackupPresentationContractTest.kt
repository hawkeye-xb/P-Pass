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
}
