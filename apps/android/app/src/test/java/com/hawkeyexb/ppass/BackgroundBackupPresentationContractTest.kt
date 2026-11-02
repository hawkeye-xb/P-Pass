package com.hawkeyexb.ppass

import com.hawkeyexb.ppass.backup.BackgroundBackupState
import com.hawkeyexb.ppass.ui.backgroundBackupNoticeRes
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundBackupPresentationContractTest {
    private fun source(path: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) dir = dir.parentFile ?: error("apps/android not found")
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$path").readText()
    }

    @Test
    fun onboarding_asks_for_neither_background_authorization_nor_notifications() {
        // #1263：onboarding 里不再问后台备份（首页卡片引导开启）；#1262：也不再申请通知。
        val main = source("MainActivity.kt")
        val buckets = main.substringAfter("\n        is Screen.Buckets -> {").substringBefore("onCancel = { screen = Screen.Home(s.pairing) }")
        assertTrue(buckets.contains("if (s.firstTime) {"))
        assertFalse("onboarding 不许申请后台授权", buckets.contains("requestIntent()"))
        assertFalse("onboarding 不许申请通知权限", buckets.contains("POST_NOTIFICATIONS"))
        assertFalse("完成页已删除", main.contains("Screen.Started"))
        // #1272：首页「开启后台备份」卡片已删（「App 关着也传」就在「自动备份」下面）；设置页开关照旧。
        assertTrue(main.contains("onToggleAutoBackup = onToggleAutoBackup,"))
        assertFalse("卡片已删", main.contains("offerBackgroundBackup"))
        assertFalse("卡片已删", source("ui/HomeScreen.kt").contains("ENABLE_BACKGROUND_BACKUP"))
        val host = source("ui/HomeNotices.kt").substringAfter("fun NoticeHost(")
        assertFalse(host.contains("background_backup_offer"))
        assertFalse(source("ui/PhotosScreen.kt").contains("background_backup_offer"))
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

    @Test
    fun ui12_background_backup_states_are_wired_into_the_global_notice_host() {
        // UI-12: 后台备份被系统限制这件事此前只埋在设置页 CellRow 里，
        // 跟 NoticeHost 自己声明的"全局唯一提示宿主"契约矛盾（用户反馈
        // "起不到通知作用"）。RED（改前）：NoticeHost 函数体不引用
        // BackgroundBackupState；GREEN（改后）：NoticeHost 消费该状态并
        // 生成 BACKUP_INTERRUPTED 候选，MainActivity 的调用点把状态传进去。
        val notices = source("ui/HomeNotices.kt")
        val noticeHostBody = notices.substringAfter("fun NoticeHost(")

        assertTrue(
            "NoticeHost must consume BackgroundBackupState, not just reupload count",
            noticeHostBody.contains("backgroundBackupState"),
        )
        assertTrue(noticeHostBody.contains("BackgroundBackupState.NeedsSystemAuthorization"))
        assertTrue(noticeHostBody.contains("BackgroundBackupState.SystemStoppedWatcher"))
        assertTrue(
            "the background-backup candidate must join BACKUP_INTERRUPTED, the kind already ranked in HOME_NOTICE_PRIORITY",
            noticeHostBody.contains("HomeNoticeKind.BACKUP_INTERRUPTED"),
        )

        val mainActivityNoticeCall = source("MainActivity.kt")
            .substringAfter("NoticeHost(")
            .substringBefore("}\n                } else null,")
        assertTrue(
            "MainActivity's NoticeHost call site must pass the resolved background-backup state through",
            mainActivityNoticeCall.contains("backgroundBackupState = backgroundBackupState"),
        )
    }

    @Test
    fun ui12_backup_interrupted_notice_has_no_dismiss_action() {
        // UI-12 二次修正（2026-09-15，用户判断）：横幅和设置页 hint 描述
        // 同一个事实，不能给两个不同的承诺（横幅"已读不打扰" vs hint
        // "问题还在"）。RED（改前）：BACKUP_INTERRUPTED 候选带 dismissLabel；
        // GREEN（改后）：唯一退出路径是把配置改成跟现状一致（关开关），
        // 不维护独立的"已忽略"状态。
        val notices = source("ui/HomeNotices.kt")
        val noticeHostBody = notices.substringAfter("fun NoticeHost(")
        val backupInterruptedBlock = noticeHostBody
            .substringAfter("kind = HomeNoticeKind.BACKUP_INTERRUPTED,")
            .substringBefore(")\n        )")

        assertFalse(
            "BACKUP_INTERRUPTED must not carry an independent dismiss action",
            backupInterruptedBlock.contains("dismissLabel"),
        )
        assertFalse(
            "NoticeHost must not carry a separate dismissed-state parameter",
            noticeHostBody.contains("backgroundBackupNoticeDismissed"),
        )
    }

    @Test
    fun b11_banner_button_says_what_tapping_it_does_per_state() {
        // 10-29 文案 B11：一个笼统的「去处理」拆成按状态的按钮。反证：两个状态共用一个按钮文案 → 红。
        assertEquals(
            R.string.background_backup_needs_authorization to R.string.background_backup_action_allow,
            backgroundBackupNoticeRes(BackgroundBackupState.NeedsSystemAuthorization),
        )
        assertEquals(
            R.string.background_backup_system_stopped to R.string.background_backup_action_turn_on,
            backgroundBackupNoticeRes(BackgroundBackupState.SystemStoppedWatcher),
        )
        assertNull(backgroundBackupNoticeRes(BackgroundBackupState.OffByUser))
        assertNull(backgroundBackupNoticeRes(BackgroundBackupState.Armed))
        assertFalse(source("ui/HomeNotices.kt").contains("background_backup_notice_action"))
    }
}
