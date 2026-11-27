package com.hawkeyexb.ppass.ui

import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2113：Android 底部导航 Tab 选中/未选中态的配色、字重与图标形态规格单测（JVM E2）。
 */
class TwoTabsTest {

    @Test
    fun selected_tab_uses_primary_ink_and_bold_weight() {
        val style = tabCellStyle(selected = true)
        assertEquals(PPColor.Ink, style.tint)
        assertEquals(FontWeight.Bold, style.fontWeight)
    }

    @Test
    fun unselected_tab_uses_secondary_ink40_and_medium_weight() {
        val style = tabCellStyle(selected = false)
        assertEquals(PPColor.Ink40, style.tint)
        assertEquals(FontWeight.Medium, style.fontWeight)
    }

    @Test
    fun selected_and_unselected_tab_styles_are_distinct() {
        val selected = tabCellStyle(selected = true)
        val unselected = tabCellStyle(selected = false)
        assertNotEquals(selected.tint, unselected.tint)
        assertNotEquals(selected.fontWeight, unselected.fontWeight)
    }

    @Test
    fun photos_tab_icon_switches_between_outlined_and_filled_morphology() {
        val unselected = photosTabIconSpec(selected = false)
        val selected = photosTabIconSpec(selected = true)

        assertEquals(TabIconRenderMode.OUTLINED, unselected.mode)
        assertTrue("未选中照片图标必须为非零线宽线框", unselected.strokeWidthUnits > 0f)
        assertNull("未选中照片图标不需要实心留白细节色", unselected.detailColor)

        assertEquals(TabIconRenderMode.FILLED, selected.mode)
        assertEquals(0f, selected.strokeWidthUnits, 0.0001f)
        assertEquals(PPColor.Paper, selected.detailColor)
        assertNotEquals(unselected.mode, selected.mode)
    }

    @Test
    fun backup_tab_icon_switches_between_light_outline_and_bold_filled_arrows() {
        val unselected = backupTabIconSpec(selected = false)
        val selected = backupTabIconSpec(selected = true)

        assertEquals(TabIconRenderMode.OUTLINED, unselected.mode)
        assertFalse("未选中备份图标箭头为轻态折线", unselected.filledArrowHeads)
        assertTrue(unselected.strokeWidthUnits > 0f)

        assertEquals(TabIconRenderMode.FILLED, selected.mode)
        assertTrue("选中备份图标箭头必须为实心强调态", selected.filledArrowHeads)
        assertTrue(
            "选中备份图标弧线必须明显加粗（selected=${selected.strokeWidthUnits}, unselected=${unselected.strokeWidthUnits}）",
            selected.strokeWidthUnits > unselected.strokeWidthUnits,
        )
        assertTrue(
            "选中态弧线扫角应收窄为实心箭头留出空间",
            selected.arcSweepDegrees < unselected.arcSweepDegrees,
        )
        assertNotEquals(unselected.mode, selected.mode)
    }
}
