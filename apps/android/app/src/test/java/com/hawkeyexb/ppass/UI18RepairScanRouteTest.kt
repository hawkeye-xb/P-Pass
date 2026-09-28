// UI-18（#355）：配对失效红卡「重新扫码连接」是恢复路径，不是开场路径。
//
// 原来：clearLocalPairing → Screen.Welcome（onboarding 第一页）→ 再点「扫码」
// → Scan。多一屏一次点击；而且 #455 让连回同一台电脑也走 Buckets → Started，
// 用户以为自己被重置了。
package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UI18RepairScanRouteTest {

    private fun main() = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

    @Test
    fun rescanning_goes_straight_to_the_scanner_when_the_camera_is_already_granted() {
        assertEquals("点「重新扫码连接」必须直达扫码，中间零多余屏", Screen.Scan, repairScanTarget(cameraGranted = true))
    }

    @Test
    fun a_revoked_camera_is_asked_once_over_the_welcome_underlay() {
        // 相机被系统收回才请求；垫在下面的屏不能是 Scan（没权限开不了相机）。
        assertEquals(Screen.Welcome, repairScanTarget(cameraGranted = false))
    }

    @Test
    fun the_red_card_button_is_wired_to_the_recovery_route() {
        val repair = main().substringAfter("val onRepairPairing = {").substringBefore("\n            }")
        assertTrue("红卡按钮必须走恢复路由", repair.contains("screen = repairScanTarget(cameraGranted)"))
        assertFalse("不许再把老用户丢回 onboarding 第一页", repair.contains("screen = Screen.Welcome"))
        assertTrue(
            "只在相机没授权时才请求权限——已授予的不许再问",
            repair.contains("if (!cameraGranted) cameraPermission.launch(Manifest.permission.CAMERA)"),
        )
        // 照片页和设置页两张红卡都走同一个 lambda。
        assertTrue(main().contains("onReconnect = onRepairPairing"))
        assertTrue(main().contains("onRepair = onRepairPairing"))
    }

    @Test
    fun a_successful_rescan_to_the_same_desktop_returns_home_without_asking_anything() {
        val fastPath = main().substringAfter("if (hasExistingLedgerFor(outcome.pairing)) {")
            .substringBefore("} else {")
        assertTrue("连过的电脑直接回首页，不过 Buckets / Started", fastPath.contains("screen = Screen.Home(outcome.pairing)"))
        assertFalse("快速重连路径上不许发起任何权限 / 授权请求", fastPath.contains(".launch("))
        assertFalse(fastPath.contains("enterBucketPicker"))
    }

    @Test
    fun the_tab_the_user_was_on_survives_the_round_trip() {
        // tab 是 PPassApp 顶层 remember，Screen 切换不重置；唯一的写入点是底栏
        // 的 onTab。有人在配对路径上把它设回 0，回来就不是点击前那个 tab 了。
        val src = main()
        assertTrue(src.contains("var tab by remember { mutableStateOf(0) }"))
        val writes = Regex("""(?<![\w.])tab\s*=(?!=)[^\n]*""").findAll(src).map { it.value.trim() }.toList()
        assertEquals(listOf("tab = tab,", "tab = it },"), writes)
    }
}
