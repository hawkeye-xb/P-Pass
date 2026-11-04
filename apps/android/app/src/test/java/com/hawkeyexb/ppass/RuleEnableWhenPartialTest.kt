package com.hawkeyexb.ppass

import com.hawkeyexb.ppass.backup.MediaAccess
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #1353（产品负责人 2026-11-04 三星验收）：
 * 1. 已是「部分照片」时开自动备份不再申请权限（拒绝两次后 READ_MEDIA_IMAGES 是 USER_FIXED，系统不再弹框），
 *    直接打开本 App 的系统设置页；回到前台按真实权限现算，只接一次（同 iOS）。
 * 2. 不再弹「已把你允许的 N 张传到电脑…」：弹出时照片还没传。
 * 3. 手选结果行只说「送达 N 张」。
 */
class RuleEnableWhenPartialTest {
    private val main by lazy { File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText() }
    private val home by lazy { File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText() }

    /**
     * 产品负责人 2026-11-04 改定（Android 官方做法）：部分权限下先看系统还肯不肯弹框——
     * 肯弹（rationale=true）→ 照旧申请，用户在框里能选「全部允许」；被锁（rationale=false）→ 去系统设置。
     * 反证：部分权限一律走 Settings（不看 canPrompt），rationale=true 那条红。
     */
    @Test
    fun partial_access_requests_while_the_system_still_prompts_and_goes_to_settings_once_locked() {
        assertEquals(RuleEnableRoute.Request, ruleEnableRoute(MediaAccess.PARTIAL, canPrompt = true))
        assertEquals(RuleEnableRoute.Settings, ruleEnableRoute(MediaAccess.PARTIAL, canPrompt = false))
        assertEquals(RuleEnableRoute.Apply, ruleEnableRoute(MediaAccess.FULL, canPrompt = false))
        assertEquals(RuleEnableRoute.Apply, ruleEnableRoute(MediaAccess.FULL, canPrompt = true))
        assertEquals("没给过 / 拒绝：申请", RuleEnableRoute.Request, ruleEnableRoute(MediaAccess.NONE, canPrompt = false))
    }

    /** 接线：Settings 分支只去设置、不申请、不预写开关；Request 分支申请；判断用系统的 rationale。 */
    @Test
    fun routes_are_wired_to_settings_and_request() {
        val toggle = main.substringAfter("val onToggleRule: (Pairing, Boolean) -> Unit").substringBefore("\n    }\n")
        assertTrue(toggle.contains("ruleEnableRoute(mediaAccess(context), canPromptForFullMediaAccess(context))"))
        val settings = toggle.substringAfter("RuleEnableRoute.Settings -> {").substringBefore("RuleEnableRoute.Request")
        assertTrue(settings.contains("openAppDetailsSettings(context)"))
        assertTrue(settings.contains("ruleAwaitingSettings = true"))
        assertFalse("被锁时不再申请", settings.contains("rulePermission.launch"))
        assertFalse("不预写开关", settings.contains("rulePrefs.set(true)"))
        val request = toggle.substringAfter("RuleEnableRoute.Request -> {")
        assertTrue(request.contains("rulePermission.launch"))
        assertTrue(main.contains("shouldShowRequestPermissionRationale(activity, Manifest.permission.READ_MEDIA_IMAGES)"))
    }

    /**
     * 场景 C（产品负责人 2026-11-04）：开关开着时权限被收回、用户没点「去设置」而是自己去设置改回全部再回来——
     * ON_RESUME 重读真实权限，状态卡按 `blockedHeroOffersSettings` 现算消失，开关不动。
     */
    @Test
    fun user_restores_full_access_on_their_own_and_the_blocked_card_goes_away() {
        val resume = main.substringAfter("Lifecycle.Event.ON_RESUME -> {").substringBefore("resumeCount++")
        assertTrue(resume.contains("mediaAccess = mediaAccess(context)"))
        assertFalse(resume.contains("rulePrefs.set("))
        assertFalse(com.hawkeyexb.ppass.ui.blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.FULL))
    }

    /** 反证：去掉 resume 里的接续，或不清标记（会重复接），本条红。 */
    @Test
    fun back_from_settings_resumes_once_by_real_access() {
        val resume = main.substringAfter("LaunchedEffect(resumeCount) {").substringBefore("\n    }\n")
        assertTrue(resume.contains("if (!ruleAwaitingSettings) return@LaunchedEffect"))
        assertTrue(resume.contains("ruleAwaitingSettings = false"))
        assertTrue(resume.contains("applyRuleAccess(pairings.load(), now)"))
        assertTrue(resume.contains("mediaAccess(context)"))
    }

    @Test
    fun no_limited_sent_snackbar_and_picked_line_only_says_delivered() {
        assertFalse(main.contains("auto_backup_rule_limited_sent"))
        assertFalse(home.contains("picked_result_with_existing"))
        assertFalse(File("src/main/res/values-zh/strings.xml").readText().contains("picked_result_with_existing"))
    }
}
