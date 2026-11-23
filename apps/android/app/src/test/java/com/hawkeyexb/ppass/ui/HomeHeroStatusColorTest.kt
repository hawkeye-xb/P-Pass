package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1962：英雄卡空闲状态行（`idleLine`）颜色必须按状态裁决，对齐 iOS `HeroCard.statusColor`——
 * 绿色只给「已确认的安全」（`AllSafe` 且五条闸门全过），等待用琥珀，其余退回系统次级色。
 * 反证：把 `HomeScreen.kt` 里那行改回写死 `PPColor.Ink60`，接线断言立刻红。
 */
class HomeHeroStatusColorTest {
    private fun source(path: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) dir = dir.parentFile ?: error("apps/android 无法找到")
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$path").readText()
    }

    @Test
    fun waitingReasonWinsOverEverything() {
        assertEquals(PPColor.Waiting, heroIdleLineColor(waitReason = 1, line = StatusLine.AllSafe, allSafeAllowed = true))
        assertEquals(PPColor.Waiting, heroIdleLineColor(waitReason = 1, line = StatusLine.Pending(3), allSafeAllowed = false))
    }

    @Test
    fun confirmedSafeIsGreenOnlyWhenTheGateAllows() {
        assertEquals(PPColor.Safe, heroIdleLineColor(waitReason = null, line = StatusLine.AllSafe, allSafeAllowed = true))
        assertEquals(
            "闸门不放行时不能说成「安全」的绿色",
            PPColor.Ink60,
            heroIdleLineColor(waitReason = null, line = StatusLine.AllSafe, allSafeAllowed = false),
        )
    }

    @Test
    fun everyOtherLineFallsBackToSecondaryInk() {
        assertEquals(PPColor.Ink60, heroIdleLineColor(waitReason = null, line = StatusLine.Pending(3), allSafeAllowed = true))
        assertEquals(PPColor.Ink60, heroIdleLineColor(waitReason = null, line = StatusLine.Paused, allSafeAllowed = true))
        assertEquals(PPColor.Ink60, heroIdleLineColor(waitReason = null, line = StatusLine.Trouble, allSafeAllowed = true))
        assertEquals(PPColor.Ink60, heroIdleLineColor(waitReason = null, line = StatusLine.Ready, allSafeAllowed = true))
    }

    @Test
    fun homeScreenWiresTheStatusColorInsteadOfHardcodingInk60() {
        val home = source("ui/HomeScreen.kt")
        assertTrue(
            "idleLine 必须走 heroIdleLineColor 裁决",
            home.contains("heroIdleLineColor(waitReason = waitReason, line = line, allSafeAllowed = allSafeAllowed)"),
        )
        assertFalse(
            "idleLine 不得再把颜色写死成 PPColor.Ink60",
            home.contains(
                "color = PPColor.Ink60,\n" +
                    "                                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },",
            ),
        )
    }

    @Test
    fun noticeBannerIsNotMountedOnTwoTabs() {
        val twoTabs = source("ui/TwoTabs.kt")
        val body = twoTabs.substringAfter("fun TwoTabs(")
        assertFalse("TwoTabs 不再接收 notice 槽", body.contains("notice: (@Composable"))
        assertFalse("TwoTabs 不再渲染系统告示条", body.contains("if (notice != null)"))
    }
}
