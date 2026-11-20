package com.hawkeyexb.ppass

import com.hawkeyexb.ppass.backup.AlbumAccessPromptPrefs
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1259（10-29 改决定）：照片权限框前面不加说明屏。流程是 扫码 → 验证码 → 系统照片权限框 → 选范围页 → 首页。
 * 没问过权限就直接弹系统框；只给了部分照片也进选范围页（页顶说明一行，只备份允许的那些）；
 * 全拒落到首页，由首页权限卡（`no_media_access_*`）和对话框兜底。
 */
class MediaPermissionRouteTest {
    private val pairing = com.hawkeyexb.ppass.transport.Pairing(daemonNodeId = "a".repeat(64), daemonAddrToken = "t", storageDeviceName = "Home")
    private val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
    private val res = File("src/main/res").let { r ->
        listOf("values", "values-zh").associateWith { File(r, "$it/strings.xml").readText() }
    }

    /**
     * #1794：范围页始终能进——没有相册权限也能进去管理文件夹（对齐 iOS），
     * 相册区在页内说明并给申请入口，不再在进页前先弹照片权限框。
     * 反证：改回「进页前先申请」，或把申请入口挪回 enterBucketPicker，本条红。
     */
    @Test
    fun scope_page_opens_without_asking_for_photo_permission_first() {
        val picker = main.substringAfter("fun enterBucketPicker(").substringBefore("\n    }\n")
        assertTrue("范围页直接打开", picker.contains("screen = Screen.Buckets("))
        assertFalse("进范围页不再先申请相册权限", picker.contains("launch("))
        assertFalse("旧的「进页前申请」通道已撤", main.contains("bucketMediaPermission"))
        assertFalse("旧的进页分支枚举已撤", main.contains("bucketPickerEntry"))
    }

    /** 相册权限在页内申请：拒绝后仍停在范围页，文件夹照常管理。 */
    @Test
    fun denying_album_access_keeps_the_scope_page() {
        val launcher = main.substringAfter("val bucketAlbumPermission = rememberLauncherForActivityResult")
            .substringBefore("\n    }\n")
        assertFalse("拒绝后不能把人踢出范围页", launcher.contains("screen = "))
        assertTrue("按真实权限刷新", launcher.contains("mediaAccess = mediaAccess(context)"))
        assertTrue("范围页拿得到当前权限档", main.contains("albumAccess = mediaAccess"))
    }

    /** 10-29：部分授权以前直接回首页、范围是空的，三星上 `pending=0 nothing to transfer`，用户看不出为什么不传。 */
    @Test
    fun partial_access_goes_to_the_scope_page_and_can_save() {
        val buckets = main.substringAfter("is Screen.Buckets -> {").substringBefore("onCancel = { screen = Screen.Home(s.pairing) },")
        assertFalse("#1272：选范围页的部分授权说明已删（进选范围页的前提是有全部权限）", buckets.contains("partialAccess"))
        assertFalse("部分授权不许再跳过保存范围", buckets.contains("hasPartialMediaAccess"))
        assertTrue(buckets.contains("scopeStore.saveScope("))
    }

    /**
     * #1788（产品定案 #1783）：系统不再允许弹窗时，范围页相册提示的动作改为「去设置」，返回后按真实权限更新。
     * 对齐 iOS 同位置的 requestAccess / openAppSettings 分流。反证：撤掉页内分流，
     * 或去掉申请返回 / ON_RESUME 两处的重读，本条红。
     */
    @Test
    fun locked_album_access_switches_the_scope_notice_to_open_settings() {
        val screen = File("src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt").readText()
        assertTrue("动作分流是页内纯判定", screen.contains("internal fun albumNoAccessNoticeOpensSettings(canPrompt: Boolean)"))
        assertTrue("被锁时动作用「去设置」（与状态卡同一个词）", screen.contains("R.string.auto_backup_blocked_action"))
        assertTrue("页内提示带上系统还肯不肯弹框", screen.contains("canPrompt = albumAccessCanPrompt"))
        assertTrue("点击按分流走：被锁点「去设置」，可弹点页内申请", screen.contains("onClick = if (opensSettings) onOpenSettings else onRequest"))
        assertTrue("「去设置」出口由 MainActivity 接到应用详情页", main.contains("onOpenAlbumSettings = { openAppDetailsSettings(context) }"))
        val launcher = main.substringAfter("val bucketAlbumPermission = rememberLauncherForActivityResult")
            .substringBefore("\n    }\n")
        assertTrue("申请返回也要重读：被锁时点了不弹框，动作要当场翻面", launcher.contains("albumAccessCanPrompt = canPromptForFullMediaAccess(context)"))
        val resume = main.substringAfter("Lifecycle.Event.ON_RESUME -> {").substringBefore("resumeCount++")
        assertTrue("从设置回来按真实状态重算页内动作", resume.contains("albumAccessCanPrompt = canPromptForFullMediaAccess(context)"))
    }

    /**
     * #1788（评审阻断）：shouldShowRequestPermissionRationale 把「从没申请过」与「被永久拒绝」都读成
     * false，单靠 rationale 区分不开；API<33 旧实现又无条件返回 true，被永久拒绝的用户永远换不到「去设置」。
     * 「还能不能弹框」提纯成双输入纯判定，四种入参组合直接跑，不比对源码。
     * 反证：退回 rationale 单输入（旧 SDK 33+ 分支），前两条红；退回无条件可弹（旧 API<33 分支），末条红。
     */
    @Test
    fun can_prompt_follows_request_history_and_rationale() {
        assertTrue("从没申请过：首次申请必弹框（rationale=false 也会弹）",
            systemCanPromptAlbumAccess(requestedOnce = false, rationale = false))
        assertTrue("从没申请过且 rationale=true：不该出现的状态，仍按可弹算",
            systemCanPromptAlbumAccess(requestedOnce = false, rationale = true))
        assertTrue("申请过、拒了一次但系统还会再弹",
            systemCanPromptAlbumAccess(requestedOnce = true, rationale = true))
        assertFalse("申请过且系统不再弹：被锁，只剩「去设置」",
            systemCanPromptAlbumAccess(requestedOnce = true, rationale = false))
    }

    /**
     * #1788：申请记录没存值时按当前真实状态算初值（AGENTS.md「读现状初始化，不写迁移」）——
     * 已授权、或被拒过一次（rationale=true）都说明申请过；rationale=false 分不出「没申请过」与
     * 「被永久拒绝」，按没申请过算（点击才申请；真被锁的用户点一次后当场翻面）。
     * 反证：一律按「问过」算（旧实现的隐含状态），末两条红。
     */
    @Test
    fun requested_once_starts_from_the_real_state_when_never_recorded() {
        assertTrue("已授权：按申请过算", AlbumAccessPromptPrefs.initialAlbumRequestedOnce(photoGranted = true, rationale = null))
        assertTrue("拒过一次（rationale=true）：按申请过算",
            AlbumAccessPromptPrefs.initialAlbumRequestedOnce(photoGranted = false, rationale = true))
        assertFalse("rationale=false：按没申请过算，点击才申请",
            AlbumAccessPromptPrefs.initialAlbumRequestedOnce(photoGranted = false, rationale = false))
        assertFalse("读不到 rationale（context 不是 Activity）：按没申请过算",
            AlbumAccessPromptPrefs.initialAlbumRequestedOnce(photoGranted = false, rationale = null))
    }

    /**
     * #1788（评审阻断）：rationale 分不清「从没申请过」与「被永久拒绝」，只能靠自己的发射记录补这一维，
     * 所以每个相册权限申请口发射时都要记一笔。本仓没有 Robolectric，接线按源码形状钉住
     * （MOB92ScopeWiringTest 同做法）：三个申请口必须都走同一个发射口；决定页不申请。
     */
    @Test
    fun every_album_permission_launch_goes_through_the_recording_gate() {
        assertFalse("决定页不发照片权限请求", main.contains("val decisionPermission ="))
        for (launcher in listOf("rulePermission", "mediaPermission", "bucketAlbumPermission")) {
            assertTrue("$launcher 没走发射口（漏记「申请过」）", main.contains("launchAlbumAccessPrompt($launcher,"))
            assertFalse("$launcher 绕过发射口直接 launch", main.contains("$launcher.launch(withMediaLocation("))
        }
        assertTrue("发射口要记下「申请过」（读写都在发射记录 store，不让 Activity 当 owner）",
            main.contains("AlbumAccessPromptPrefs(context).markRequested()") &&
                main.contains("AlbumAccessPromptPrefs(context).requestedOnce("))
    }

    @Test
    fun update_dialog_does_not_cover_the_first_scope_page() {
        assertTrue(main.contains("if (!isOnboardingScreen(screen) && !updateDialogSuppressed)"))
        assertTrue(isOnboardingScreen(Screen.Buckets(pairing, emptySet(), firstTime = true)))
        assertTrue("#1321 决定页也不压更新对话框", isOnboardingScreen(Screen.Decision(pairing)))
        assertFalse("设置里重选范围不算 onboarding", isOnboardingScreen(Screen.Buckets(pairing, emptySet(), firstTime = false)))
    }

    @Test
    fun intro_copy_is_gone_and_fallback_copy_exists() {
        for ((dir, xml) in res) {
            assertFalse("$dir 还留着 photo_intro_*", xml.contains("name=\"photo_intro_"))
            for (k in listOf("partial_access_title", "notif_media_partial_body", "auto_backup_rule_denied_hint")) {
                assertTrue("$dir 缺兜底文案 $k", xml.contains("name=\"$k\""))
            }
        }
    }
}
