package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #1353：权限被收回后「自动备份已停止」状态卡的出口。开关开 + 权限部分 / 全拒 → 带「去设置」；
 * 开关开 + 全部 → 不出；开关关 → 不出（没开是正常状态）。开关本身不动，回来按真实权限现算。
 */
class BlockedHeroSettingsTest {

    /** 反证：去掉 `access != FULL` 或 `ruleOn` 任一条件，对应断言红。 */
    @Test
    fun settings_button_shows_only_when_rule_on_and_access_not_full() {
        assertTrue("部分", blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.PARTIAL))
        assertTrue("全拒", blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.NONE))
        assertFalse("全部：不出", blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.FULL))
        assertFalse("开关关：不出", blockedHeroOffersSettings(ruleOn = false, access = MediaAccess.PARTIAL))
        assertFalse("开关关：不出", blockedHeroOffersSettings(ruleOn = false, access = MediaAccess.NONE))
    }

    /** 接线：状态卡的按钮点下去走 onOpenAppSettings，MainActivity 把它接到本 App 的系统设置页并记日志；回到前台重读权限、变了记一行。 */
    @Test
    fun blocked_hero_button_is_wired_to_app_settings_and_resume_rereads_access() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        val blocked = home.substringAfter("R.string.auto_backup_blocked_hero), color").substringBefore("} else {")
        assertTrue(blocked.contains("blockedHeroOffersSettings(autoBackupRuleOn, mediaAccess)"))
        assertTrue(blocked.contains("onClick = onOpenAppSettings"))
        assertTrue(blocked.contains("R.string.auto_backup_blocked_action"))
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val opener = main.substringAfter("onOpenAppSettings = {").substringBefore("},")
        assertTrue(opener.contains("openAppDetailsSettings(context)"))
        assertTrue(opener.contains("opening app settings"))
        assertTrue(main.contains("photo access on resume: \$accessBefore -> \$mediaAccess"))
    }
}
