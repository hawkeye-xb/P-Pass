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
}
