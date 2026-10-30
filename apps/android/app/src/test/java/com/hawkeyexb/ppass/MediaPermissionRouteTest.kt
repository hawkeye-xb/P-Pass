package com.hawkeyexb.ppass

import com.hawkeyexb.ppass.backup.MediaAccess
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1259（10-29 改决定）：照片权限框前面不加说明屏。流程是 扫码 → 验证码 → 系统照片权限框 → 选范围页 → 首页。
 * 没问过权限就直接弹系统框；只给了部分照片也进选范围页（页顶说明一行，只备份允许的那些）；
 * 全拒落到首页，由首页权限卡（`no_media_access_*`）和对话框兜底。
 */
class MediaPermissionRouteTest {
    private val pairing = com.hawkeyexb.ppass.transport.Pairing(daemonNodeId = "a".repeat(64), daemonAddrToken = "t", storageDeviceName = "Home")
    private val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
    private val res = File("src/main/res").let { r ->
        listOf("values", "values-zh").associateWith { File(r, "$it/strings.xml").readText() }
    }

    @Test
    fun missing_permission_requests_the_system_prompt_directly() {
        assertEquals(BucketPickerEntry.RequestPermission, bucketPickerEntry(permissionsMissing = true))
        assertEquals(BucketPickerEntry.Buckets, bucketPickerEntry(permissionsMissing = false))
        // 反证：缺权限那一支要是改回先进某个中间屏，这里就不再是直接 launch。
        val picker = main.substringAfter("fun enterBucketPicker(").substringBefore("\n    }\n")
        val requestBranch = picker.substringAfter("BucketPickerEntry.RequestPermission -> {").substringBefore("}")
        assertTrue(requestBranch.contains("bucketMediaPermission.launch(withMediaLocation(needed))"))
        assertEquals("系统框只有 enterBucketPicker 这一个入口", 1, Regex("bucketMediaPermission\\.launch\\(").findAll(main).count())
    }

    @Test
    fun full_access_goes_on_to_the_scope_page() {
        assertEquals(MediaPermissionLanding.Buckets, mediaPermissionLanding(allGranted = true, access = MediaAccess.FULL))
    }

    /** 10-29：部分授权以前直接回首页、范围是空的，三星上 `pending=0 nothing to transfer`，用户看不出为什么不传。 */
    @Test
    fun partial_access_goes_to_the_scope_page_and_can_save() {
        assertEquals(MediaPermissionLanding.Buckets, mediaPermissionLanding(allGranted = false, access = MediaAccess.PARTIAL))
        val buckets = main.substringAfter("is Screen.Buckets -> {").substringBefore("onCancel = { screen = Screen.Home(s.pairing) },")
        assertTrue("页顶说明跟着部分授权走", buckets.contains("partialAccess = mediaAccess == MediaAccess.PARTIAL,"))
        assertFalse("部分授权不许再跳过保存范围", buckets.contains("hasPartialMediaAccess"))
        assertTrue(buckets.contains("scopeStore.saveScope("))
    }

    @Test
    fun denial_leaves_the_pairing_page_for_home_and_explains() {
        assertEquals(MediaPermissionLanding.HomeWithDeniedDialog, mediaPermissionLanding(allGranted = false, access = MediaAccess.NONE))
        val denied = main.substringAfter("MediaPermissionLanding.HomeWithDeniedDialog -> {").substringBefore("}")
        assertTrue("拒绝后不能停在配对页", denied.contains("screen = Screen.Home(pairing)"))
        assertTrue(denied.contains("ruleHintRes = R.string.auto_backup_rule_denied_hint"))
    }

    @Test
    fun update_dialog_does_not_cover_the_first_scope_page() {
        assertTrue(main.contains("if (!isOnboardingScreen(screen) && !updateDialogSuppressed)"))
        assertTrue(isOnboardingScreen(Screen.Buckets(pairing, emptySet(), firstTime = true)))
        assertFalse("设置里重选范围不算 onboarding", isOnboardingScreen(Screen.Buckets(pairing, emptySet(), firstTime = false)))
    }

    @Test
    fun intro_copy_is_gone_and_fallback_copy_exists() {
        for ((dir, xml) in res) {
            assertFalse("$dir 还留着 photo_intro_*", xml.contains("name=\"photo_intro_"))
            for (k in listOf("partial_access_title", "partial_access_body", "partial_access_action", "notif_media_partial_body", "bucket_partial_access_note")) {
                assertTrue("$dir 缺兜底文案 $k", xml.contains("name=\"$k\""))
            }
        }
    }
}
