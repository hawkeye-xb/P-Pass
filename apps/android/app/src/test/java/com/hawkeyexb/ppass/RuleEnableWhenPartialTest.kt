package com.hawkeyexb.ppass

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

    /** 反证：部分权限分支改回 `rulePermission.launch`，本条红。 */
    @Test
    fun partial_access_opens_app_settings_instead_of_requesting_again() {
        val toggle = main.substringAfter("val onToggleRule: (Pairing, Boolean) -> Unit").substringBefore("// 从系统设置回来")
        val partial = toggle.substringAfter("== MediaAccess.PARTIAL) {").substringBefore("} else {")
        assertTrue(partial.contains("openAppDetailsSettings(context)"))
        assertTrue(partial.contains("ruleAwaitingSettings = true"))
        assertFalse("部分权限下不再申请", partial.contains("rulePermission.launch"))
        assertFalse("不预写开关", partial.contains("rulePrefs.set(true)"))
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
        assertFalse(File("src/main/res/values/strings.xml").readText().contains("auto_backup_rule_limited_sent"))
        assertFalse(File("src/main/res/values-zh/strings.xml").readText().contains("picked_result_with_existing"))
    }
}
