// #130（#515 后续）：onboarding 只问一次通知权限——只问一次 / 拒绝不再问 / 老用户不问 / 授予后开关同步。
package com.hawkeyexb.ppass.backup

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingNotificationAskTest {
    private val dir: File = Files.createTempDirectory("notif-ask").toFile()

    /** 每次都新建实例 = 每次都是一次新进程，只有盘上的标记留下来。 */
    private fun ask() = OnboardingNotificationAsk(dir)

    @Test
    fun a_fresh_install_is_asked_exactly_once() {
        ask().initIfAbsent(existingUser = false)
        assertTrue(ask().shouldAsk(sdkInt = 34, alreadyGranted = false))
        ask().markAsked()
        assertFalse("问过就不再问（含重启）", ask().shouldAsk(sdkInt = 34, alreadyGranted = false))
    }

    @Test
    fun a_denial_is_never_asked_again_and_leaves_the_switch_off() {
        val prefs = NotifyOnFailurePrefs(dir)
        ask().initIfAbsent(existingUser = false)
        ask().markAsked()
        ask().onResult(granted = false, prefs = prefs)
        assertFalse("拒绝后开关保持关闭", prefs.enabled())
        // 之后配对成功、再走一次 onboarding 都不再问；init 再跑也不会把标记冲掉。
        ask().initIfAbsent(existingUser = false)
        assertFalse(ask().shouldAsk(sdkInt = 34, alreadyGranted = false))
    }

    @Test
    fun a_grant_turns_the_switch_on() {
        val prefs = NotifyOnFailurePrefs(dir)
        prefs.setEnabled(false)
        ask().initIfAbsent(existingUser = false)
        ask().markAsked()
        ask().onResult(granted = true, prefs = prefs)
        assertTrue("授予后开关视为开启，不许出现系统已授权但开关显示关", prefs.enabled())
    }

    @Test
    fun an_existing_user_upgrading_is_never_asked() {
        ask().initIfAbsent(existingUser = true)
        assertFalse(ask().shouldAsk(sdkInt = 34, alreadyGranted = false))
    }

    @Test
    fun the_first_run_decides_new_vs_existing_and_later_pairing_does_not_flip_it() {
        ask().initIfAbsent(existingUser = false) // 新装：第一次打开 App 时还没配对
        ask().initIfAbsent(existingUser = true)  // 配对成功后再次启动：不许被当成老用户
        assertTrue(ask().shouldAsk(sdkInt = 34, alreadyGranted = false))
    }

    @Test
    fun android_12_and_below_or_an_already_granted_permission_is_not_asked() {
        ask().initIfAbsent(existingUser = false)
        assertFalse(ask().shouldAsk(sdkInt = 32, alreadyGranted = false))
        assertFalse(ask().shouldAsk(sdkInt = 34, alreadyGranted = true))
    }

    @Test
    fun a_missing_or_corrupt_marker_means_do_not_ask() {
        assertFalse("没初始化过：宁可少问", ask().shouldAsk(sdkInt = 34, alreadyGranted = false))
        File(dir, "onboarding_notification_ask.json").writeText("{not json")
        assertFalse("文件损坏：宁可少问", ask().shouldAsk(sdkInt = 34, alreadyGranted = false))
    }

    @Test
    fun main_activity_marks_existing_users_by_disk_facts_and_syncs_the_switch() {
        var root = File(System.getProperty("user.dir"))
        while (!File(root, "apps/android").isDirectory) root = root.parentFile ?: error("apps/android not found")
        val main = File(root, "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val init = main.substringAfter("OnboardingNotificationAsk(context.filesDir)").substringBefore("}\n    }")
        assertTrue(
            "老用户 = 已有配对或走完过 onboarding（落盘事实，不看版本号）",
            init.contains("pairings.load() != null || OnboardedDesktopsStore(context.filesDir).anyOnboarded()"),
        )
        assertFalse("不许靠版本号判老用户", init.contains("VERSION_NAME") || init.contains("versionCode"))
        assertTrue("弹窗结果同步到开关", main.contains("notificationAsk.onResult(granted, "))
    }
}
