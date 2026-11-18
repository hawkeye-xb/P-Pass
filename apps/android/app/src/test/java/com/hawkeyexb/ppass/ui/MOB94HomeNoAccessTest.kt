// MOB-94: 首页在拿不到相册时不许说「照片都存好了」。
//
// HomeScreen 是 Compose，本仓没有 Robolectric，所以这里测的是两件能测的
// 事：① 渲染分支的判据（纯函数 visibleWaitReasonRes / desktopLowSpaceHintVisible 同一口径）；
// ② 源文本门禁——绿卡分支必须被非 FULL 挡在外面，且两档文案不共用。
//
// ②是源文本，只能证明写法，证明不了效果；判据本身由 MOB94MediaAccessTest
// 的真行为测试守着。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB94HomeNoAccessTest {

    private fun homeScreen() =
        File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()

    @Test
    fun the_waiting_hint_is_suppressed_whenever_the_library_is_not_fully_readable() {
        // 拿不到完整相册时 N/M 是假数，"将在连上 Wi-Fi 后进行"也就无从谈起。
        // #413：这句话现在是等待中（WIFI）的状态行，闸门在 visibleWaitReasonRes。
        val wifi = BackupUiState.Waiting(com.hawkeyexb.ppass.backup.flow.WaitReason.WIFI)
        val res = com.hawkeyexb.ppass.R.string.wifi_deferred_hint
        assertTrue(visibleWaitReasonRes(wifi, MediaAccess.FULL, pairingLost = false, reasonRes = res) == res)
        for (blocked in listOf(MediaAccess.PARTIAL, MediaAccess.NONE)) {
            assertTrue(
                "拿不到完整相册（$blocked）时不许显示排队提示",
                visibleWaitReasonRes(wifi, blocked, pairingLost = false, reasonRes = res) == null,
            )
            assertFalse(
                "拿不到完整相册（$blocked）时也不许显示桌面低空间预警",
                desktopLowSpaceHintVisible(lowSpace = true, mediaAccess = blocked, pairingLost = false),
            )
        }
    }

    @Test
    fun the_hero_card_is_gated_on_full_access_not_on_partial_alone() {
        val source = homeScreen()

        // #1789 接线（#1788 交付判定、本卡消费）：blocked 分支必须同时要求「不是 FULL」与「没有可用来源」——
        // 漏掉后者会把 folder-only 也压成「自动备份已停止」，正是验收 5 要挡的「全局权限卡顶替真实进度」。
        // 评审 Bg：断言限定到渲染 blocked 卡的分支行（heroBlocked 赋值与 else-if 分支），
        // 不再全文件匹配——同名判据在 heroRenderOf / visibleWaitReasonRes 里出现是正常的。
        val blockedLine = source.lineSequence().firstOrNull { it.contains("val heroBlocked =") }
        assertTrue("英雄卡要有一处 blocked 汇总判据（heroBlocked）", blockedLine != null)
        assertTrue(
            "blocked 汇总判据必须是「开关开 且 不是 FULL 且没有可用来源 且 已选相册」",
            blockedLine!!.contains("autoBackupRuleOn && mediaAccess != MediaAccess.FULL && !hasUsableSource && hasSelectedAlbum"),
        )
        val blockedBranch = source.lineSequence().firstOrNull { it.trimStart().startsWith("} else if (mediaAccess != MediaAccess.FULL") }
        assertTrue(
            "渲染分支判据必须带 hasSelectedAlbum——空范围缺的是来源不是权限",
            blockedBranch?.contains("&& hasSelectedAlbum") == true,
        )
        assertFalse(
            "不许再留布尔 partialAccess 参数——两档互斥，布尔并列表示不了",
            source.contains("partialAccess: Boolean"),
        )
    }

    /**
     * #1789（#1788 评审定案接线，评审 Ak）：空范围（没有已选相册）缺的是**来源**不是权限——
     * 权限不完整也不出「自动备份已停止」（[HeroRender.AccessBlocked]），落到空范围自己的状态；
     * 真的选了相册且没有可用目录时照旧报权限阻断。判据本体 [heroRenderOf] 是纯函数，JVM 直接测——
     * 反证：heroRenderOf 第一分支去掉 `hasSelectedAlbum` 条件，前两条红。
     */
    @Test
    fun empty_scope_does_not_render_the_access_blocked_hero() {
        val t = com.hawkeyexb.ppass.backup.tripletOf(n = 10, confirmedCount = 3, lastSuccessAt = 1)
        for (blocked in listOf(MediaAccess.PARTIAL, MediaAccess.NONE)) {
            org.junit.Assert.assertNotEquals(
                "空范围 + $blocked：缺的是来源，不出权限引导卡",
                HeroRender.AccessBlocked,
                heroRenderOf(blocked, t, hasUsableSource = false, hasSelectedAlbum = false),
            )
            org.junit.Assert.assertEquals(
                "已选相册 + $blocked + 没有可用目录：照旧出权限引导卡",
                HeroRender.AccessBlocked,
                heroRenderOf(blocked, t, hasUsableSource = false, hasSelectedAlbum = true),
            )
        }
    }

    /**
     * #1789（评审 A4）：手选的传输不依赖相册权限——还有未结束的单次项时，等待原因不被 ACCESS 压制，
     * 用户看得到文件传输为什么没开始。反证：visibleWaitReasonRes 的 ACCESS 判据去掉 `!pickedOpen`，本条红。
     */
    @Test
    fun picked_transfer_wait_reason_is_not_suppressed_by_album_access() {
        val wifi = BackupUiState.Waiting(com.hawkeyexb.ppass.backup.flow.WaitReason.WIFI)
        val res = com.hawkeyexb.ppass.R.string.wifi_deferred_hint
        org.junit.Assert.assertEquals(
            "自动备份开着 + 权限不全 + 没有可用来源：没有单次在途时照旧压制",
            null,
            visibleWaitReasonRes(wifi, MediaAccess.PARTIAL, pairingLost = false, reasonRes = res, hasUsableSource = false, pickedOpen = false),
        )
        org.junit.Assert.assertEquals(
            "有未结束的单次项：等待原因照常说（文件传输不需要相册权限）",
            res,
            visibleWaitReasonRes(wifi, MediaAccess.PARTIAL, pairingLost = false, reasonRes = res, hasUsableSource = false, pickedOpen = true),
        )
    }

    /**
     * #1789（#1784 验收 5，真行为测试）：folder-only 且照片权限非完整时，英雄区仍显示真实进度与等待原因，
     * 不被全局权限卡顶替。判据本体 [heroRenderOf] / [visibleWaitReasonRes] 是纯函数，JVM 直接测——
     * 反证：任一处把「不是 FULL 且没有可用来源」改回只看 access，对应断言红。
     */
    @Test
    fun folder_only_keeps_the_real_progress_and_wait_reason_when_photo_access_is_not_full() {
        val t = com.hawkeyexb.ppass.backup.tripletOf(n = 10, confirmedCount = 3, lastSuccessAt = 1)
        for (blocked in listOf(MediaAccess.PARTIAL, MediaAccess.NONE)) {
            org.junit.Assert.assertEquals(
                "folder-only：$blocked 照常渲染三元组，不出权限引导卡",
                HeroRender.Triplet,
                heroRenderOf(blocked, t, hasUsableSource = true),
            )
            org.junit.Assert.assertEquals(
                "纯相册：$blocked 仍然出权限引导卡（不显示假 0/0）",
                HeroRender.AccessBlocked,
                heroRenderOf(blocked, t, hasUsableSource = false),
            )
        }
        val wifi = BackupUiState.Waiting(com.hawkeyexb.ppass.backup.flow.WaitReason.WIFI)
        val res = com.hawkeyexb.ppass.R.string.wifi_deferred_hint
        org.junit.Assert.assertEquals(
            "folder-only 等 Wi-Fi：等待原因照常说",
            res,
            visibleWaitReasonRes(wifi, MediaAccess.PARTIAL, pairingLost = false, reasonRes = res, hasUsableSource = true),
        )
    }

    // #1272 §6：两档各说各的——现在落在开关下方的小字上（部分 / 没有访问权限），权限卡与长正文已删。
    @Test
    fun the_two_blocked_tiers_do_not_share_one_string() {
        for (loc in listOf("values", "values-zh")) {
            val strings = File("src/main/res/$loc/strings.xml").readText()
            assertTrue("$loc 缺部分授权小字", strings.contains("\"auto_backup_rule_partial_hint\""))
            assertTrue("$loc 缺无权限小字", strings.contains("\"auto_backup_rule_none_hint\""))
            assertTrue("$loc 缺 no_media_access_title（通知标题仍用）", strings.contains("\"no_media_access_title\""))
            assertFalse("$loc 长正文已删", strings.contains("\"no_media_access_body\""))
        }
    }
}
