package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UI08BucketScreenTest {
    private fun bucketScreenSource(): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt",
        ).readText()
    }

    /**
     * #1797：相册、文件夹和「添加文件夹」都必须走 #1796 的基础组件（SourceCard / AddSourceCard），
     * 同一网格与尺寸由组件保证；不再有平行的自绘卡片（自画角标、自画类型图形、自画描边点击）。
     * 反证：恢复自绘平行实现（如旧 BucketCard / SelectBadge / SourceTypeGlyph）后本条变红。
     */
    @Test
    fun source_cards_use_the_shared_standard_components_not_a_parallel_self_drawn_implementation() {
        val source = bucketScreenSource()
        assertTrue("相册卡必须用标准 SourceCard（按类型入口断言）", source.contains("SourceKind.ALBUM"))
        assertTrue("文件夹卡必须用标准 SourceCard（按类型入口断言）", source.contains("SourceKind.FOLDER"))
        assertTrue("必须导入基础组件 SourceCard", source.contains("import com.hawkeyexb.ppass.ui.components.SourceCard"))
        assertTrue("添加动作必须用标准 AddSourceCard", source.contains("AddSourceCard("))
        assertFalse("自绘勾选角标不许回来", source.contains("SelectBadge"))
        assertFalse("自绘类型图形不许回来", source.contains("SourceTypeGlyph"))
        assertFalse("卡片自绘点击不许回来", source.contains(".clickable(onClick = onToggle)"))
        assertFalse("卡片自绘封面比例不许回来（同尺寸由组件的固定封面高度保证）", source.contains("aspectRatio(1.6f)"))
    }

    /**
     * #1797：返回也交给标准 IconButton——不再用自绘「‹」字符承载点击（与 FolderScreen 同款）。
     * 反证：恢复「‹」+ clickable 后本条变红。
     */
    @Test
    fun back_action_uses_a_standard_icon_button_not_a_self_drawn_glyph() {
        val source = bucketScreenSource()
        assertTrue("返回用标准 IconButton", source.contains("IconButton(onClick = onCancel)"))
        assertTrue("返回图标用平台箭头", source.contains("Icons.AutoMirrored.Filled.ArrowBack"))
        assertTrue("返回描述用本地化词条", source.contains("R.string.back"))
        assertFalse("自绘「‹」返回不许回来", source.contains("\"‹\""))
    }

    /**
     * #1797：同名来源要有类型标识——相册与文件夹的卡分别给各自类型词，由组件用标准图标 + 读屏描述呈现。
     * 反证：两张卡的 kindLabel 互换后，本条红（标签必须各自出现在对应的卡片调用里）。
     */
    @Test
    fun same_name_sources_get_distinct_type_labels() {
        val source = bucketScreenSource()
        val albumBlock = source.substringAfter("items(visibleAlbumBuckets").substringBefore("items(folderBuckets")
        val folderBlock = source.substringAfter("items(folderBuckets").substringBefore("item(key = \"add-folder\")")
        assertTrue(
            "相册卡要带相册类型词",
            albumBlock.contains("kindLabel = stringResource(R.string.source_kind_album)"),
        )
        assertTrue(
            "文件夹卡要带文件夹类型词",
            folderBlock.contains("kindLabel = stringResource(R.string.source_kind_folder)"),
        )
    }

    @Test
    fun album_and_folder_cards_keep_their_selection_semantics() {
        val source = bucketScreenSource()
        assertTrue("相册勾选仍按相册 id 记", source.contains("selected = b.id in checked"))
        assertTrue("文件夹勾选仍按文件夹 key 记", source.contains("folder.key in checkedFolders"))
        assertTrue(
            "相册空名仍走本地化词条",
            source.contains("b.name ?: stringResource(R.string.bucket_unnamed)"),
        )
        assertTrue(
            "选中/未选中状态要给读屏文案",
            source.contains("selectedDescription = stringResource(R.string.source_selected)") &&
                source.contains("unselectedDescription = stringResource(R.string.source_unselected)"),
        )
    }

    @Test
    fun bucket_cover_requests_measured_display_dimensions() {
        val source = bucketScreenSource()
        assertTrue("cover size must come from the measured display bounds", source.contains("onSizeChanged"))
        assertTrue("thumbnail loading must wait for a non-zero measured size", source.contains("displaySize != IntSize.Zero"))
        assertTrue("the request must use both measured dimensions", source.contains("Size(displaySize.width, displaySize.height)"))
        assertTrue("a size change must restart the request", source.contains("key2 = displaySize"))
        assertFalse("the old fixed low-resolution request must not return", source.contains("Size(200, 200)"))
    }

    @Test
    fun folders_and_alums_share_one_atomic_save() {
        val source = bucketScreenSource()
        assertTrue(source.contains("folderBuckets: List<FolderBucketUi>"))
        assertTrue(source.contains("selectedFolderKeys: Set<String>"))
        assertTrue("一个保存动作同时提交两类来源", source.contains("onDone(checked, checkedFolders, time)"))
        assertTrue("保存期间禁止重复提交", source.contains("enabled = !saving"))
        assertTrue(source.contains("R.string.folder_add"))
        assertTrue("新目录先默认选中但只进编辑暂存", source.contains("!it.registered && it.key !in seenFolderKeys"))
    }

    /**
     * #1797：失效目录的重新授权与移除收进标准菜单；重新授权仍直连授权动作、只挂在权限失效
     * 条件里，移除仍先过原确认弹窗。反证：菜单丢掉任一动作、绕过确认弹窗、
     * 或权限条件反转（needsPermission 为真反而不给重新授权）后，本条红。
     */
    @Test
    fun needs_permission_folder_keeps_reauthorize_and_remove_actions() {
        val source = bucketScreenSource()
        val folderBlock = source.substringBefore("item(key = \"add-folder\")")
            .substringAfter("items(folderBuckets")
        assertTrue("文件夹卡的动作收进标准菜单", folderBlock.contains("menuActions = buildList"))
        assertTrue("重新授权必须挂在 needsPermission 条件里", folderBlock.contains("if (folder.needsPermission) {"))
        val guarded = folderBlock.substringAfter("if (folder.needsPermission) {")
            .substringBefore("add(SourceMenuAction(stringResource(R.string.folder_remove))")
        assertTrue("失效目录仍显示重新授权", guarded.contains("SourceMenuAction(stringResource(R.string.folder_reauthorize))"))
        assertTrue("失效目录的重新授权仍直连 onReauthorizeFolder(folder.key)", guarded.contains("onReauthorizeFolder(folder.key)"))
        assertTrue("失效目录同时保留移除", folderBlock.contains("SourceMenuAction(stringResource(R.string.folder_remove))"))
        assertTrue("移除仍进入原确认弹窗", folderBlock.contains("removing = folder"))
        assertFalse("移除不许在确认前（网格块里）直接触发 onRemoveFolder", folderBlock.contains("onRemoveFolder("))
        val dialog = source.substringAfter("removing?.let")
        assertTrue("确认后才回调 onRemoveFolder(folder.key)", dialog.contains("onRemoveFolder(folder.key)"))
    }

    /**
     * #1794 / #1961：范围页始终能进（对齐 iOS）。相册自动备份只认完整照片权限：只有 FULL 给选相册，
     * PARTIAL / NONE 都只说明现状并给开启入口；文件夹区和「添加文件夹」照常可用。
     * 反证：把 PARTIAL 重新放宽成可选相册（旧 `access != NONE`），本条红。
     */
    @Test
    fun only_full_photo_access_offers_album_choices_but_folders_still_work() {
        assertFalse("部分照片权限对相册自动备份与无权限相同，不给选相册", bucketScreenOffersAlbumChoices(MediaAccess.PARTIAL))
        assertFalse("没有相册权限时不给选相册", bucketScreenOffersAlbumChoices(MediaAccess.NONE))
        assertTrue("完整照片权限才给选相册", bucketScreenOffersAlbumChoices(MediaAccess.FULL))
        val source = bucketScreenSource()
        assertTrue(
            "相册卡只展示可见相册（完整授权全部 / 未完整授权仅已勾选）",
            source.contains("items(visibleAlbumBuckets(buckets, checked, albumAccess)"),
        )
        assertTrue("未完整授权时相册区要有开启入口", source.contains("onRequestAlbumAccess"))
        assertTrue("开启入口用共享词条", source.contains("R.string.scope_album_no_access_action"))
        val addFolder = source.indexOf("item(key = \"add-folder\")")
        val folderItems = source.indexOf("items(folderBuckets")
        assertTrue("「添加文件夹」无条件出现", addFolder > folderItems)
        assertFalse("「添加文件夹」不能被相册权限门控", source.substring(folderItems, addFolder).contains("offersAlbums"))
    }

    /**
     * #1961 / #1811：未完整授权（含部分权限）时不展示没勾选的受限相册，避免诱使用户误选；
     * 已勾选的仍保留可见以便取消，完整授权显示全部。反证：`visibleAlbumBuckets` 在 PARTIAL 下
     * 直接返回全部或直接返回空列表，本条红。
     */
    @Test
    fun visible_album_buckets_keep_only_checked_ones_until_full_access() {
        val a = MediaScanner.Bucket(1L, "A", 3)
        val b = MediaScanner.Bucket(2L, "B", 4)
        assertEquals("完整授权显示全部", listOf(a, b), visibleAlbumBuckets(listOf(a, b), emptySet(), MediaAccess.FULL))
        assertEquals("部分权限下已勾选的保留、没勾的不展示", listOf(a), visibleAlbumBuckets(listOf(a, b), setOf(1L), MediaAccess.PARTIAL))
        assertEquals("无权限下同样只保留已勾选的（可取消）", listOf(a), visibleAlbumBuckets(listOf(a, b), setOf(1L), MediaAccess.NONE))
        assertEquals("部分权限下一个都没勾就不展示任何相册", emptyList<MediaScanner.Bucket>(), visibleAlbumBuckets(listOf(a, b), emptySet(), MediaAccess.PARTIAL))
    }

    /**
     * #1794：整机空文案在 2 列网格里必须整行居中，不能和「添加文件夹」卡片并排只占一格。
     * 反证：去掉 `span = { GridItemSpan(maxLineSpan) }`，本条红。
     */
    @Test
    fun whole_phone_empty_copy_spans_the_whole_row() {
        val empty = bucketScreenSource().substringAfter("item(key = \"empty\"")
        assertTrue(
            "整机空文案必须占满整行",
            empty.take(80).contains("span = { GridItemSpan(maxLineSpan) }"),
        )
    }

    /** 只有完整权限才读得到全部照片：部分权限同样不能把「只能读一部分」说成整机没有照片。 */
    @Test
    fun whole_phone_empty_copy_needs_full_photo_access() {
        assertTrue(bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.FULL))
        assertFalse(
            "部分照片权限时读不到全部照片，不得声称整机没有照片",
            bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.PARTIAL),
        )
        assertFalse(
            "没有相册权限时不得声称整机没有照片",
            bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.NONE),
        )
        assertFalse(
            "还有文件夹来源时不算整机为空",
            bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = false, access = MediaAccess.FULL),
        )
    }

    /**
     * #1797 / #1868：「添加文件夹」用标准 AddSourceCard；保存期间通过组件层 `enabled` 显式禁用
     * （无障碍树暴露 disabled），不再靠调用点闭包里的 `if (!saving)` 静默吞点击。
     */
    @Test
    fun add_action_uses_the_standard_card_and_keeps_its_save_guard() {
        val source = bucketScreenSource()
        assertTrue("添加动作必须用标准 AddSourceCard", source.contains("AddSourceCard("))
        val addFolderBlock = source.substringAfter("item(key = \"add-folder\")").substringBefore("}")
        assertTrue("保存期间必须以 enabled = !saving 禁用添加动作", addFolderBlock.contains("enabled = !saving"))
        assertFalse("不再靠闭包内 if (!saving) 静默吞点击", addFolderBlock.contains("if (!saving) onAddFolder()"))
    }
}
