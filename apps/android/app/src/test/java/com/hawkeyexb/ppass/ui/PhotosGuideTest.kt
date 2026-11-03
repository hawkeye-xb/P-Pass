// #1322 照片页可选引导（docs/decisions/2026-11-03-onboarding-gate.md 结论 6、7）：只有决定页是必经，进照片页之后
// 按当前开关现算引导位给哪一张；点 × 整条结束（按手机记）；范围里暂无照片是状态提示，不受 × 影响。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.BackgroundBackupOfferStore
import com.hawkeyexb.ppass.backup.DisconnectDisposition
import com.hawkeyexb.ppass.backup.DisconnectState
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * #1272 §6：权限提示收缩成一种（开关下方一行小字 + 通知），照片页不再有权限卡——引导位只看开关，不看权限档。
 * #1322：引导位按开关现算（开启范围备份 → 开启后台备份 → 结束），「还没选相册」并入第一步。
 */
class PhotosGuideTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun facts(scopeOn: Boolean = false, firstUploaded: Boolean = false, backgroundOn: Boolean = false, finished: Boolean = false) =
        GuideFacts(scopeOn = scopeOn, firstUploaded = firstUploaded, backgroundOn = backgroundOn, finished = finished)

    @Test
    fun the_guide_follows_the_current_switches() {
        assertEquals("没开范围备份 → 第一步", PhotosGuide.EnableScope, photosGuideOf(facts()))
        assertEquals("单张传过也一样先引导开范围备份", PhotosGuide.EnableScope, photosGuideOf(facts(firstUploaded = true)))
        assertEquals("范围已开、还没传成功 → 不出卡", PhotosGuide.None, photosGuideOf(facts(scopeOn = true)))
        assertEquals("范围已开、第一张已传、后台没开 → 第二步", PhotosGuide.EnableBackground, photosGuideOf(facts(scopeOn = true, firstUploaded = true)))
        // 反证：去掉「已开启不出现」判断（后台开了仍出第二步），这条红。
        assertEquals("都开了 → 结束", PhotosGuide.None, photosGuideOf(facts(scopeOn = true, firstUploaded = true, backgroundOn = true)))
    }

    @Test
    fun the_starting_point_is_the_current_state_not_step_one() {
        // 决定页直接选了范围备份：不出现「开启范围备份」，第一张成功后直接出后台备份卡。
        // 反证：把起点写死为第一步（按「走到第几步」记），这条红。
        val decidedScope = facts(scopeOn = true)
        assertTrue(photosGuideOf(decidedScope) != PhotosGuide.EnableScope)
        assertEquals(PhotosGuide.EnableBackground, photosGuideOf(decidedScope.copy(firstUploaded = true)))
        // 后台备份早就开了（老用户）：一张卡都不出。
        assertEquals(PhotosGuide.None, photosGuideOf(facts(scopeOn = true, firstUploaded = true, backgroundOn = true)))
    }

    @Test
    fun dismissing_ends_the_whole_guide_whatever_the_switches_do_later() {
        for (scope in listOf(false, true)) for (up in listOf(false, true)) for (bg in listOf(false, true)) {
            assertEquals("点过 × 不再出卡（$scope/$up/$bg）", PhotosGuide.None, photosGuideOf(facts(scope, up, bg, finished = true)))
        }
    }

    @Test
    fun the_dismissal_is_per_phone_and_survives_disconnect_and_a_new_desktop() {
        val store = BackgroundBackupOfferStore(tmp.root)
        store.dismiss()
        assertTrue(BackgroundBackupOfferStore(tmp.root).dismissed())
        // 断开 / 配对失效 / 换电脑都走断开清单：这一行必须是 KEEP。反证：换电脑时清掉标记，这条红。
        assertEquals(DisconnectDisposition.KEEP, DisconnectState.BACKGROUND_BACKUP_OFFER.disposition)
        assertTrue(DisconnectState.BACKGROUND_BACKUP_OFFER.matches(BackgroundBackupOfferStore.FILE_NAME))
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val pairing = main.substringAfter("is PairOutcome.Joined -> {").substringBefore("is PairOutcome.Refused ->")
        assertFalse("配对 / 换电脑不碰「已走完」", pairing.contains("offerStore") || pairing.contains("BackgroundBackupOfferStore"))
    }

    @Test
    fun the_empty_scope_hint_is_a_status_line_not_a_guide() {
        assertTrue("范围开着、范围里还没有照片 → 说现状", scopeEmptyHintShown(facts(scopeOn = true), 0L))
        // 反证：提示也看 ×（点过 × 就不说），这条红。
        assertTrue("不受 × 影响", scopeEmptyHintShown(facts(scopeOn = true, finished = true), 0L))
        assertFalse("有了第一张就不说", scopeEmptyHintShown(facts(scopeOn = true), 1L))
        assertFalse("范围备份没开不说（那是引导位的事）", scopeEmptyHintShown(facts(), 0L))
        assertFalse("还没数出来不说", scopeEmptyHintShown(facts(scopeOn = true), null))
    }

    @Test
    fun the_photos_tab_wires_one_guide_slot_and_a_buttonless_hint() {
        val photos = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()
        assertTrue("同一时间最多一张：只有一个引导位", photos.split("PhotosGuideCard(").size - 1 == 2) // 定义 + 唯一调用
        val hint = photos.substringAfter("if (scopeEmptyHint != null) {").substringBefore("\n        }\n")
        assertFalse("现状提示不带按钮", hint.contains("Button") || hint.contains("clickable"))
        assertTrue(photos.contains("photos-guide: shown"))
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        assertTrue(main.contains("photos-guide: dismissed"))
        assertTrue("× 落盘「已走完」", main.substringAfter("onGuideDismiss = {").substringBefore("},").contains("offerStore.dismiss()"))
    }

    @Test
    fun the_access_cards_are_gone_and_the_hint_sits_under_the_switch() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        val photos = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        assertFalse(home.contains("MediaAccessCardContent"))
        assertFalse(photos.contains("MediaAccessCard"))
        val photosCall = main.substringAfter("PhotosScreen(").substringBefore("backup = {")
        assertFalse("照片页不再接权限档", photosCall.contains("mediaAccess ="))
        val homeCall = main.substringAfter("HomeScreen(")
        assertTrue(homeCall.contains("mediaAccess == MediaAccess.PARTIAL -> R.string.auto_backup_rule_partial_hint"))
        assertTrue(homeCall.contains("mediaAccess == MediaAccess.NONE -> R.string.auto_backup_rule_none_hint"))
    }
}
