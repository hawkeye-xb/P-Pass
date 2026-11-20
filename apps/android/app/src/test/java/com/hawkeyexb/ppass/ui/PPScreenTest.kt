// #112：背景亮度 → 系统栏图标深浅的纯函数（浅色背景深色图标，深色背景浅色图标）。
package com.hawkeyexb.ppass.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PPScreenTest {

    @Test
    fun light_backgrounds_use_dark_system_bar_icons() {
        assertTrue(isAppearanceLightFor(Color.White))
        assertTrue(isAppearanceLightFor(0.9f))
    }

    @Test
    fun dark_backgrounds_use_light_system_bar_icons() {
        assertFalse(isAppearanceLightFor(Color.Black))
        assertFalse(isAppearanceLightFor(0.1f))
    }

    @Test
    fun threshold_luminance_is_treated_as_light_background() {
        // 0.5 是分界：恰好 0.5 走深色图标（isAppearanceLight* = true），略低走浅色图标。
        assertTrue(isAppearanceLightFor(SYSTEM_BAR_LIGHT_APPEARANCE_THRESHOLD))
        assertFalse(isAppearanceLightFor(SYSTEM_BAR_LIGHT_APPEARANCE_THRESHOLD - 0.0001f))
    }

    @Test
    fun opening_and_closing_viewer_switches_top_level_background_and_restores_light_status_bars() {
        // #1926：首页（浅色）→ 打开查看器（深色）→ 退出查看器（恢复浅色）。
        // 唯一顶层 PPScreen 的 background 随 viewerOpen 切换，从而触发系统栏明暗同步：
        // 首页 true（深色图标）→ 查看器 false（浅色图标）→ 退出后必须恢复 true（深色图标）。
        val homeBg = twoTabsBackground(viewerOpen = false)
        val viewerBg = twoTabsBackground(viewerOpen = true)
        val restoredBg = twoTabsBackground(viewerOpen = false)

        org.junit.Assert.assertEquals(PPColor.Paper, homeBg)
        org.junit.Assert.assertEquals(PPColor.SurfaceDark, viewerBg)
        org.junit.Assert.assertEquals(PPColor.Paper, restoredBg)

        assertTrue("浅色首页必须使用深色状态栏图标", isAppearanceLightFor(homeBg))
        assertFalse("深色查看器必须使用浅色状态栏图标", isAppearanceLightFor(viewerBg))
        assertTrue("退出查看器回到首页后必须恢复深色状态栏图标", isAppearanceLightFor(restoredBg))
    }
}
