package com.hawkeyexb.ppass

import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.ScopeRead
import com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG
import com.hawkeyexb.ppass.ui.HeroRender
import com.hawkeyexb.ppass.ui.PhotosGuide
import com.hawkeyexb.ppass.ui.heroRenderOf
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

    private val albumScope = ScopeRead.Saved(setOf(7L, 8L))
    private val folderOnlyScope = ScopeRead.Saved(setOf(FOLDER_ID_FLAG or 3L))
    private val noScope = ScopeRead.NeverSaved

    /**
     * #1794：开关按范围实际需不需要相册判断，不再一律要完整相册权限。
     * 产品口径：只有从未保存过范围才首次引导；保存过任何值（包括空集）都是明确选择，off→on 只开关、不跳页。
     * 反证：把保存过空集当回 ChooseScope，或允许只读文件夹直接开，对应断言红。
     */
    @Test
    fun scope_decides_whether_album_permission_is_needed_at_all() {
        assertEquals("从未保存过范围：首次引导进范围页选来源", RuleEnableRoute.ChooseScope, ruleEnableRoute(MediaAccess.NONE, canPrompt = false, noScope, folderCount = 0))
        assertEquals("保存过空集是明确选择：只开关，不跳页", RuleEnableRoute.Apply, ruleEnableRoute(MediaAccess.FULL, canPrompt = true, ScopeRead.Saved(emptySet()), folderCount = 0))
        assertEquals("已有文件夹来源（没存过相册范围）：直接开", RuleEnableRoute.Apply, ruleEnableRoute(MediaAccess.NONE, canPrompt = false, noScope, folderCount = 1))
        assertEquals("只有文件夹来源：不需要相册权限", RuleEnableRoute.Apply, ruleEnableRoute(MediaAccess.NONE, canPrompt = false, folderOnlyScope, folderCount = 1))
        assertEquals("已有文件夹 + 相册：仍按权限走", RuleEnableRoute.Request, ruleEnableRoute(MediaAccess.NONE, canPrompt = false, ScopeRead.Saved(setOf(7L)), folderCount = 1))
    }

    /**
     * 产品负责人 2026-11-04 改定（Android 官方做法）：部分权限下先看系统还肯不肯弹框——
     * 肯弹（rationale=true）→ 照旧申请，用户在框里能选「全部允许」；被锁（rationale=false）→ 去系统设置。
     * 反证：部分权限一律走 Settings（不看 canPrompt），rationale=true 那条红。
     */
    @Test
    fun partial_access_requests_while_the_system_still_prompts_and_goes_to_settings_once_locked() {
        assertEquals(RuleEnableRoute.Request, ruleEnableRoute(MediaAccess.PARTIAL, canPrompt = true, albumScope, folderCount = 0))
        assertEquals(RuleEnableRoute.Settings, ruleEnableRoute(MediaAccess.PARTIAL, canPrompt = false, albumScope, folderCount = 0))
        assertEquals(RuleEnableRoute.Apply, ruleEnableRoute(MediaAccess.FULL, canPrompt = false, albumScope, folderCount = 0))
        assertEquals(RuleEnableRoute.Apply, ruleEnableRoute(MediaAccess.FULL, canPrompt = true, albumScope, folderCount = 0))
        assertEquals("没给过 / 拒绝：申请", RuleEnableRoute.Request, ruleEnableRoute(MediaAccess.NONE, canPrompt = false, albumScope, folderCount = 0))
        assertEquals("读不到按需要相册权限处理", RuleEnableRoute.Request, ruleEnableRoute(MediaAccess.NONE, canPrompt = false, ScopeRead.Unreadable(IllegalStateException("x")), folderCount = 0))
    }

    /** 接线：判断带上范围与文件夹数；ChooseScope 进范围页、Settings 只去设置、Request 申请；判断用系统的 rationale。 */
    @Test
    fun routes_are_wired_to_scope_settings_and_request() {
        val toggle = main.substringAfter("val onToggleRule: (Pairing, Boolean) -> Unit").substringBefore("\n    }\n")
        assertTrue(toggle.contains("ruleEnableRoute(mediaAccess(context), canPromptForFullMediaAccess(context), routeScope, routeFolderCount)"))
        assertTrue("判断必须带上已保存范围", toggle.contains("BackupScopeStore(context).readScope()"))
        assertTrue("判断必须带上已有文件夹来源", toggle.contains("FolderAccess.registry(context).allRecords().size"))
        val choose = toggle.substringAfter("RuleEnableRoute.ChooseScope ->").substringBefore("RuleEnableRoute.Apply")
        assertTrue("没有有效范围：进范围页选来源", choose.contains("screen = Screen.Buckets("))
        val settings = toggle.substringAfter("RuleEnableRoute.Settings -> {").substringBefore("RuleEnableRoute.Request")
        assertTrue(settings.contains("openAppDetailsSettings(context)"))
        assertTrue(settings.contains("ruleAwaitingSettings = true"))
        assertFalse("被锁时不再申请", settings.contains("rulePermission.launch"))
        assertFalse("不预写开关", settings.contains("rulePrefs.set(true)"))
        val request = toggle.substringAfter("RuleEnableRoute.Request -> {")
        // #1788：申请改走共用发射口（发射成功记「本机申请过一次」，rationale 分不清「没申请过」与「被锁」）。
        assertTrue("Request 经发射口申请", request.contains("launchAlbumAccessPrompt(rulePermission"))
        assertTrue("#1788：还能不能弹框由发射记录 + 系统 rationale 共同判定，且问的是本机实际申请的那支权限",
            main.contains("shouldShowRequestPermissionRationale(it, primary)") &&
                main.contains("requiredMediaPermissions().first()") &&
                main.contains("systemCanPromptAlbumAccess(") &&
                main.contains("AlbumAccessPromptPrefs(context).requestedOnce("))
    }

    /**
     * #1794：「备份范围」入口常驻设置卡——自动备份关着也看得到、进得去（对齐 iOS）。
     * 反证：把这一行移回 `if (autoBackupRuleOn)`（如 origin/main），备份范围行前面就会有一个尚未闭合的
     * 开关分支，本条红；上一版只看 brace 深度，行只是缩进不同也能过，判不出真假。
     */
    @Test
    fun settings_scope_row_is_always_shown() {
        val card = home.substringAfter("label = stringResource(R.string.auto_backup_rule_label)")
            .substringBefore("R.string.setting_wifi_only")
        val scope = card.indexOf("R.string.backup_scope")
        assertTrue("设置卡里要有备份范围行", scope > 0)
        val guarded = Regex("""if\s*\(\s*autoBackupRuleOn\s*\)\s*\{""").findAll(card.substring(0, scope))
            .firstOrNull { open ->
                val rest = card.substring(open.range.last + 1, scope)
                rest.count { it == '{' } - rest.count { it == '}' } >= 0
            }
        assertTrue("备份范围行不能在 if (autoBackupRuleOn) 分支里，否则开关关着就看不到", guarded == null)
    }

    /**
     * #1794 产品口径：没有任何来源时统一说「未选定自动备份范围」，不再说「未选相册」（目录来源也是来源）。
     * 反证：改回「未选相册」，本条红。
     */
    @Test
    fun no_scope_copy_says_the_scope_is_not_selected() {
        fun value(file: String): String =
            Regex("""<string name="backup_scope_none">([^<]*)</string>""").find(File(file).readText())!!.groupValues[1]
        assertEquals("未选定自动备份范围", value("src/main/res/values-zh/strings.xml"))
        assertEquals("No backup scope selected", value("src/main/res/values/strings.xml"))
        assertFalse("两种语言都不再说「未选相册」", File("src/main/res/values-zh/strings.xml").readText().contains("未选相册"))
    }

    /**
     * #1794 产品口径：只有从未保存过范围才引导一次；保存过空集（明确不选）后不再反复引导。
     * 反证：让 guideForCurrentScope 无条件放行 EnableScope，空集那条红。
     */
    @Test
    fun scope_guide_only_before_any_scope_is_saved() {
        assertEquals("从未保存过范围：引导一次", PhotosGuide.EnableScope, guideForCurrentScope(PhotosGuide.EnableScope, firstChoicePending = true))
        assertEquals("保存过空集：不再引导", PhotosGuide.None, guideForCurrentScope(PhotosGuide.EnableScope, firstChoicePending = false))
        assertEquals("第二步引导不受影响", PhotosGuide.EnableBackground, guideForCurrentScope(PhotosGuide.EnableBackground, firstChoicePending = false))
    }

    /** 存过范围但零来源：首页说「未选定自动备份范围」，不能说成读不到（把 noSources 带进 hero 的 scopeSaved）。 */
    @Test
    fun no_sources_scope_renders_as_not_selected_not_unreadable() {
        assertTrue("holder 的 scopeSaved 以「有效范围非空」为口径（含已登记目录）", main.contains("scopeSaved = holder.scopeSaved.value"))
        val holder = File("src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt").readText()
        assertTrue("零来源时 scopeSaved 必为 false", holder.contains("_scopeSaved.value = heroScopeSavedOf(lastNoAlbums)"))
        assertEquals(HeroRender.NoAlbums, heroRenderOf(MediaAccess.FULL, null, scopeSaved = false))
        assertEquals("有来源但三元组暂时读不到：仍说读不到", HeroRender.Unreadable, heroRenderOf(MediaAccess.FULL, null, scopeSaved = true))
    }

    /**
     * #1794 阻断：无存值用户拨开自动备份 → 进范围页 → 保存回首页，开关必须仍是开的。
     * ChooseScope 只导航不开开关、范围页保存分支又只在 firstTime 时开，旧实现会留下「开关仍关」。
     * 反证：撤掉 ChooseScope 里的 `rulePrefs.set(true)`，本条红。
     */
    @Test
    fun choose_scope_turns_the_rule_on_before_opening_the_scope_page() {
        val toggle = main.substringAfter("val onToggleRule: (Pairing, Boolean) -> Unit").substringBefore("\n    }\n")
        val choose = toggle.substringAfter("RuleEnableRoute.ChooseScope ->").substringBefore("RuleEnableRoute.Apply")
        val setOn = choose.indexOf("rulePrefs.set(true)")
        val open = choose.indexOf("screen = Screen.Buckets(")
        assertTrue("ChooseScope 必须先打开规则开关，保存回来才不会还是关的", setOn >= 0)
        assertTrue("开关状态也要同步到界面", choose.contains("ruleOn = true"))
        assertTrue("先开开关再进范围页", setOn < open)
        assertTrue("范围页以 firstTime=false 打开，保存分支不会替用户开会关", choose.contains(", false)"))
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
        // 不用的提示句连词条一起删掉（两种语言）。
        for (dir in listOf("values", "values-zh")) {
            assertFalse(dir, File("src/main/res/$dir/strings.xml").readText().contains("auto_backup_rule_limited_sent"))
        }
    }

    /**
     * 照片页第一张引导卡的按钮跟着「点了会去哪」说：开关关着且会去系统设置（部分权限、系统不再弹框）→「去设置」，否则「开启」。
     * 判断用的是开关链路同一个 [ruleEnableRoute]，两处不会说的和做的不一样。反证：按钮写死「开启」或不传这个判断，本条红。
     */
    @Test
    fun scope_guide_button_says_open_settings_when_enabling_would_go_to_settings() {
        val photos = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()
        assertTrue(main.contains("guideActionGoesToSettings = !ruleOn &&"))
        assertTrue(main.contains(") == RuleEnableRoute.Settings"))
        assertTrue(photos.contains("goesToSettings = guideActionGoesToSettings"))
        assertTrue(photos.contains("if (guide == PhotosGuide.EnableScope && goesToSettings) R.string.auto_backup_blocked_action else R.string.photos_guide_enable"))
        assertTrue(photos.contains("actionLabel = stringResource(label)"))
    }
    @Test
    fun home_counts_use_effective_scope_for_legacy_folders() {
        val block = main.substringAfter("var selectedBucketCount").substringBefore("val scope = rememberCoroutineScope()")
        assertTrue("首页必须先按旧目录兼容规则求有效范围", block.contains("effectiveBackupScope"))
        assertFalse("不能再直接数原始 selected", block.contains("selectedFolderCount = selected?.count"))
    }

    @Test
    fun cancel_is_ignored_while_scope_save_is_in_flight() {
        val cancel = main.substringAfter("onDone = { selectedAlbumIds, folderKeys, time ->")
            .substringAfter("onCancel = {").take(180)
        assertTrue(cancel.contains("if (!scopeSaving)"))
    }

    @Test
    fun pending_folder_uri_is_mapped_to_the_new_source_id_before_saving_scope() {
        val record = com.hawkeyexb.ppass.backup.folder.FolderRecord(
            id = "new-source-id",
            displayName = "Blackmagic Camera",
            treeUri = "content://android/externalstorage/documents/tree/DCIM%3ABlackmagic%20Camera",
            bucketId = com.hawkeyexb.ppass.backup.folder.FOLDER_ID_FLAG + 7,
        )
        assertEquals(
            setOf(record.bucketId),
            resolveFolderBucketIds(setOf(record.treeUri), mapOf(record.treeUri to record.id), listOf(record)),
        )
    }

    @Test
    fun enabling_rule_with_saved_scope_does_not_force_scope_editor() {
        val apply = main.substringAfter("val applyRuleAccess:").substringBefore("MediaAccess.PARTIAL")
        assertTrue(apply.contains("scopeNeedsFirstChoice"))
        assertTrue("已有范围只唤醒备份", apply.contains("requestFlowWake(context, TriggerReason.MANUAL)"))
        assertFalse("不能无条件打开范围页", apply.contains("screen = Screen.Buckets(pairing, BackupScopeStore(context).selectedBucketIds() ?: emptySet(), false)"))
    }

}
