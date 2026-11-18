package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess
import org.junit.Assert.assertEquals
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

    // ── #1799：设置与英雄区改用 Material 3 标准组件与默认语义 ──────────────

    /**
     * #1799：开关行交给 M3 标准 toggleable 语义——Role.Switch、开合状态与点击动作挂在整行
     * 一个节点上，行内 Switch 只画状态（onCheckedChange = null，Compose 官方推荐的开关行写法）。
     * 反证：退回「行无语义 + Switch 自带 onCheckedChange」的旧写法，前三条断言红。
     */
    @Test
    fun switch_rows_carry_standard_toggleable_semantics() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        val row = home.substringAfter("private fun RuleSwitchRow(").substringBefore("/** 设计稿的 cell 行")
        assertTrue("开关行必须用 toggleable 承载动作", row.contains(".toggleable("))
        assertTrue("开关行的角色必须是 Role.Switch", row.contains("role = Role.Switch"))
        assertFalse(
            "行内 Switch 不许再自带 onCheckedChange（动作归整行）",
            row.contains("onCheckedChange = onCheckedChange"),
        )
        assertTrue("行内 Switch 只画状态（onCheckedChange = null）", row.contains("onCheckedChange = null"))
        // 行级 toggleable 合并语义后，状态 hint 的独立点击出口（嵌套 clickable 是独立语义节点）必须保留，
        // 且带标准 button 语义（#1879 评审：改断言锁定 role 写法，出口保留的意图不变）。
        assertTrue(
            "后台状态 hint 的点击出口保留，且带 Role.Button（onHintClick）",
            row.contains("onHintClick") && row.contains("clickable(role = Role.Button, onClick = onHintClick)"),
        )
    }

    /**
     * #1799：「更多 / 存储电脑」两个二级页的返回交给标准 IconButton + ArrowBack，
     * 与 #1797 范围页两端同款；触控区、涟漪与「返回」描述由组件给出。
     * 反证：恢复自绘「‹」+ clickable，两条断言红。
     */
    @Test
    fun secondary_pages_use_the_standard_back_button() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        assertFalse("自绘「‹」返回不许回来", home.contains("\"‹\""))
        assertEquals(
            "两个二级页各一个 ArrowBack IconButton",
            2,
            Regex("Icons.AutoMirrored.Filled.ArrowBack").findAll(home).count(),
        )
        assertEquals(
            "返回图标的无障碍描述用既有 back 词条",
            2,
            Regex("contentDescription = stringResource\\(R.string.back\\)").findAll(home).count(),
        )
    }

    /**
     * #1799：英雄区失败卡的「查看技术详情」开合交给 TextButton——role、最小触控区与涟漪由组件给出。
     * 反证：换回自绘 clickable 文本，本条红。
     */
    @Test
    fun the_trouble_details_toggle_is_a_standard_button() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        val block = home.substringAfter("if (copy.detail.isNotEmpty()) {").substringBefore("Spacer(Modifier.height(12.dp))")
        assertTrue("技术详情开合必须用 TextButton", block.contains("TextButton("))
        assertFalse("不许自绘 clickable 文本开合", block.contains(".clickable("))
        assertTrue("开合文案不变", block.contains("R.string.trouble_details_hide") && block.contains("R.string.trouble_details_show"))
    }
}
