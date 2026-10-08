// #421：拒绝摄像头权限后必须仍能到「手动输入配对串」，且不再追弹权限。
//
// 原来：cameraPermission 回调 `if (granted) screen = Screen.Scan`，拒绝什么都不做，
// 用户停在欢迎页；手动入口只长在扫码页底部——被摄像头权限挡在后面。
package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraDeniedManualPairRouteTest {

    private fun main() = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
    private fun scan() = File("src/main/java/com/hawkeyexb/ppass/ui/ScanScreen.kt").readText()
    private fun welcome() = File("src/main/java/com/hawkeyexb/ppass/ui/Onboarding.kt").readText()

    @Test
    fun denying_the_camera_lands_on_manual_pairing() {
        assertEquals(Screen.ManualPair, cameraPermissionResultTarget(granted = false))
        assertEquals(Screen.Scan, cameraPermissionResultTarget(granted = true))
    }

    @Test
    fun the_permission_callback_routes_every_result_and_never_asks_again() {
        val callback = main().substringAfter("val cameraPermission = rememberLauncherForActivityResult(")
            .substringBefore("\n\n")
        assertTrue(
            "回调必须对 granted 两种结果都给落点（拒绝不能停在原地）",
            callback.contains("screen = cameraPermissionResultTarget(granted)"),
        )
        assertFalse("拒绝分支不许再弹一次权限", callback.contains(".launch("))
    }

    @Test
    fun manual_pairing_screen_starts_in_manual_mode_and_leaves_to_welcome() {
        val branch = main().substringAfter("is Screen.ManualPair -> ScanScreen(").substringBefore("\n        )")
        assertTrue(branch.contains("startManual = true"))
        assertTrue("手动页返回回欢迎页，不落进会开相机的取景页", branch.contains("onCancel = { screen = Screen.Welcome }"))
        assertEquals(Screen.Welcome, systemBackTarget(Screen.ManualPair))
        val src = scan()
        assertTrue(src.contains("var manual by remember { mutableStateOf(startManual) }"))
        assertTrue("以手动页起步时，返回 = 离开扫码流程", src.contains("if (startManual) {\n                onCancel()"))
    }

    @Test
    fun the_scan_route_without_camera_permission_degrades_to_manual() {
        // Waiting / Trouble 的返回与「重新扫码」都回 Screen.Scan——从手动串过来的人没有
        // 摄像头权限，这里不能去绑一个没授权的相机，也不能弹权限。
        val branch = main().substringAfter("is Screen.Scan -> ScanScreen(").substringBefore("\n        )")
        assertTrue(branch.contains("startManual = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)"))
        assertTrue(branch.contains("!= PackageManager.PERMISSION_GRANTED"))
        assertFalse(branch.contains(".launch("))
    }

    @Test
    fun welcome_offers_the_manual_entry_directly() {
        val w = welcome().substringAfter("fun WelcomeScreen(").substringBefore("\n/**")
        assertTrue(w.contains("onManual: () -> Unit"))
        assertTrue("复用扫码页同一句文案", w.contains("R.string.scan_manual_link"))
        assertTrue(w.contains(".clickable(onClick = onManual)"))
        assertTrue(main().contains("onManual = { screen = Screen.ManualPair }"))
    }
}
