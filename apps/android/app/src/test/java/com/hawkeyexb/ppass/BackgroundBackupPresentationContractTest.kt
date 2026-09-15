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
    fun ui12_non_blocking_notices_get_a_dismiss_action_distinct_from_the_primary_action() {
        // UI-12: 之前只有一个 actionLabel（"处理"），逼用户要么处理要么
        // 把整个自动备份开关关掉。新增 dismissLabel/onDismiss 是独立的
        // "知道了、暂不处理"语义。
        val notices = source("ui/HomeNotices.kt")
        assertTrue(
            "HomeNotice must carry a dismiss action distinct from actionLabel",
            notices.contains("val dismissLabel: String? = null"),
        )
        val noticeHostBody = notices.substringAfter("fun NoticeHost(")
        assertTrue(
            "the background-backup candidate must wire a dismiss action",
            noticeHostBody.contains("dismissLabel = stringResource(R.string.notice_dismiss_label)"),
        )
    }
}
