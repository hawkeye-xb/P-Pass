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
        assertTrue("部分", blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.PARTIAL, hasSelectedAlbum = true))
        assertTrue("全拒", blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.NONE, hasSelectedAlbum = true))
        assertFalse("全部：不出", blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.FULL, hasSelectedAlbum = true))
        assertFalse("开关关：不出", blockedHeroOffersSettings(ruleOn = false, access = MediaAccess.PARTIAL, hasSelectedAlbum = true))
        assertFalse("开关关：不出", blockedHeroOffersSettings(ruleOn = false, access = MediaAccess.NONE, hasSelectedAlbum = true))
    }

    /**
     * #1788 评审定案（同判据同步到 Android 消费端）：保存了空范围时缺的是**来源**不是权限，
     * 去设置授权也不会添加来源——「去设置」只给真的选了相册的范围。folder-only 由英雄区分支另行处理（不出这张卡）。
     * 反证：去掉 `hasSelectedAlbum` 条件，空范围两条红。
     */
    @Test
    fun empty_scope_does_not_offer_the_settings_exit() {
        assertFalse("空范围 + 部分授权：缺的是来源，不出「去设置」",
            blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.PARTIAL, hasSelectedAlbum = false))
        assertFalse("空范围 + 全拒：同上",
            blockedHeroOffersSettings(ruleOn = true, access = MediaAccess.NONE, hasSelectedAlbum = false))
    }

    /** 接线：状态卡的按钮点下去走 onOpenAppSettings，MainActivity 把它接到本 App 的系统设置页并记日志；回到前台重读权限、变了记一行。
     * #1789：出口按两态现算——调用点把 hasSelectedAlbum 一并传给 [blockedHeroOffersSettings]。 */
    @Test
    fun blocked_hero_button_is_wired_to_app_settings_and_resume_rereads_access() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        val blocked = home.substringAfter("R.string.auto_backup_blocked_hero), color").substringBefore("} else {")
        assertTrue(blocked.contains("blockedHeroOffersSettings(autoBackupRuleOn, mediaAccess, hasSelectedAlbum)"))
        assertTrue(blocked.contains("onClick = onOpenAppSettings"))
        assertTrue(blocked.contains("R.string.auto_backup_blocked_action"))
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val opener = main.substringAfter("onOpenAppSettings = {").substringBefore("},")
        assertTrue(opener.contains("openAppDetailsSettings(context)"))
        assertTrue(opener.contains("opening app settings"))
        assertTrue(main.contains("photo access on resume: \$accessBefore -> \$mediaAccess"))
    }
}
