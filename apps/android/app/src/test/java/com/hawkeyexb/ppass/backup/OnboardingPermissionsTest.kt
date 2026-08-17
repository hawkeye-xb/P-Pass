// Onboarding「系统权限」步骤——纯判定函数 + 持久化 ask-state 的测试。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingPermissionsTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-onboard-$tag").toFile()

    // ── onboardingCanContinue：读取照片必需 ─────────────────────────
    @Test
    fun continue_requires_photo_permission_only() {
        assertFalse(onboardingCanContinue(photoGranted = false))
        assertTrue(onboardingCanContinue(photoGranted = true))
    }

    // ── shouldOfferNotificationPermission：API<33 恒不需要问 ────────
    @Test
    fun notification_not_offered_below_api_33() {
        assertFalse(
            shouldOfferNotificationPermission(sdkInt = 32, granted = false, alreadyAsked = false)
        )
    }

    @Test
    fun notification_offered_on_api_33_when_not_granted_and_not_asked() {
        assertTrue(
            shouldOfferNotificationPermission(sdkInt = 33, granted = false, alreadyAsked = false)
        )
    }

    @Test
    fun notification_not_offered_once_granted() {
        assertFalse(
            shouldOfferNotificationPermission(sdkInt = 33, granted = true, alreadyAsked = false)
        )
    }

    // 反证核心：跳过之后（alreadyAsked=true）不能再弹——否则「跳过」
    // 形同没生效，每次重进这个页面都又弹一次系统对话框。
    @Test
    fun notification_not_offered_again_after_being_asked_once() {
        assertFalse(
            shouldOfferNotificationPermission(sdkInt = 33, granted = false, alreadyAsked = true)
        )
    }

    // ── shouldOfferBatteryWhitelist：同款「问过一次不再问」哲学 ─────
    @Test
    fun battery_offered_when_not_whitelisted_and_not_asked() {
        assertTrue(shouldOfferBatteryWhitelist(whitelisted = false, alreadyAsked = false))
    }

    @Test
    fun battery_not_offered_once_whitelisted() {
        assertFalse(shouldOfferBatteryWhitelist(whitelisted = true, alreadyAsked = false))
    }

    @Test
    fun battery_not_offered_again_after_being_asked_once() {
        assertFalse(shouldOfferBatteryWhitelist(whitelisted = false, alreadyAsked = true))
    }

    // ── OnboardingPermissionsStore：持久化 + 崩溃安全 ────────────────
    @Test
    fun store_defaults_to_neither_asked() {
        val s = OnboardingPermissionsStore(tempDir("defaults")).load()
        assertFalse(s.notificationAsked)
        assertFalse(s.batteryAsked)
    }

    @Test
    fun store_marks_survive_reopen_independently() {
        val dir = tempDir("reopen")
        val store = OnboardingPermissionsStore(dir)
        store.markNotificationAsked()
        val reopened = OnboardingPermissionsStore(dir).load()
        assertTrue("通知已问过应该持久化", reopened.notificationAsked)
        assertFalse("电池不应该被连带标记", reopened.batteryAsked)
        OnboardingPermissionsStore(dir).markBatteryAsked()
        val both = OnboardingPermissionsStore(dir).load()
        assertTrue(both.notificationAsked)
        assertTrue(both.batteryAsked)
        dir.deleteRecursively()
    }

    @Test
    fun store_corrupted_file_reads_as_defaults_not_crash() {
        val dir = tempDir("corrupt")
        File(dir, "onboarding-ask-state.json").apply {
            parentFile.mkdirs()
            writeText("{not json")
        }
        val s = OnboardingPermissionsStore(dir).load()
        assertFalse(s.notificationAsked)
        assertFalse(s.batteryAsked)
        dir.deleteRecursively()
    }
}
