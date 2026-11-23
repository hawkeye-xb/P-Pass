package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1964 双端对齐的接线（本仓没有 Robolectric，按源码形状钉住，同 `OnboardingSlimWiringTest`）：
 * 配对等待页补系统转圈；欢迎页与等待页在系统最大字号下可纵向滚（且不踩可滚 Column 里 weight 的无限高度崩溃）；
 * `MainActivity` 的 Asking 分支真的把 `loading = true` 传下去。
 */
class OnboardingAlignmentTest {
    private val onboarding = File("src/main/java/com/hawkeyexb/ppass/ui/Onboarding.kt").readText()
    private val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
    private val pairStatus = onboarding.substringAfter("fun PairStatusScreen(")
    private val welcome = onboarding.substringAfter("fun WelcomeScreen(").substringBefore("/**")

    @Test
    fun pair_status_shows_a_spinner_while_waiting() {
        assertTrue("等待页要有 loading 开关", pairStatus.contains("loading: Boolean = false"))
        assertTrue("等待页要有系统转圈", pairStatus.contains("CircularProgressIndicator("))
        assertTrue("大字号下等待页要能滚", pairStatus.contains("verticalScroll(rememberScrollState())"))
    }

    @Test
    fun welcome_scrolls_under_large_font_without_a_weight_spacer() {
        assertTrue("欢迎页要能纵向滚", welcome.contains("verticalScroll(rememberScrollState())"))
        assertTrue("内容矮时用 SpaceBetween 撑开", welcome.contains("Arrangement.SpaceBetween"))
        assertTrue("高度下限来自可用高度", welcome.contains("heightIn(min = maxHeight)"))
        // 反证：在可滚动的 Column 里留 weight 占位会因无限高度约束崩溃。
        assertFalse("可滚动的欢迎页不许用 weight 占位", welcome.contains("Modifier.weight("))
    }

    @Test
    fun main_activity_passes_loading_for_the_asking_phase() {
        val asking = main.substringAfter("PairPhase.Asking -> PairStatusScreen(").substringBefore("is PairPhase.Code")
        assertTrue("PairPhase.Asking 要传 loading = true", asking.contains("loading = true"))
    }
}
