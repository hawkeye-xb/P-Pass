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
     * #1797 / #2067：相册走标准 SourceCard（SourceKind.ALBUM）；添加文件夹移入顶栏克制目录图标按钮，
     * 网格内不再有 AddSourceCard，也不再回退到旧的自绘卡片。
     */
    @Test
    fun album_cards_use_source_card_and_add_folder_moved_to_top_bar() {
        val source = bucketScreenSource()
        assertTrue("相册卡必须用标准 SourceCard（SourceKind.ALBUM）", source.contains("SourceKind.ALBUM"))
        assertTrue("必须导入基础组件 SourceCard", source.contains("import com.hawkeyexb.ppass.ui.components.SourceCard"))
        assertFalse("网格内不许再放 AddSourceCard", source.contains("AddSourceCard"))
        assertFalse("自绘勾选角标不许回来", source.contains("SelectBadge"))
        assertFalse("自绘类型图形不许回来", source.contains("SourceTypeGlyph"))
        assertFalse("卡片自绘点击不许回来", source.contains(".clickable(onClick = onToggle)"))
        assertFalse("卡片自绘封面比例不许回来", source.contains("aspectRatio(1.6f)"))
        val topBar = source.substringAfter("topBar = {").substringBefore(") { innerPadding ->")
        assertTrue("顶栏右侧必须提供添加文件夹图标按钮", topBar.contains("onAddFolder"))
        assertTrue("顶栏添加文件夹图标走 ic_create_new_folder", topBar.contains("R.drawable.ic_create_new_folder"))
        assertTrue("顶栏添加文件夹按钮必须带无障碍标签", topBar.contains("contentDescription = stringResource(R.string.folder_add)"))
        assertTrue("保存期间禁用顶栏添加文件夹按钮", topBar.contains("enabled = !saving"))
    }

    /**
     * #1797：返回也交给标准 IconButton——不再用自绘「‹」字符承载点击（与 FolderScreen 同款）。
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
     * #1797 / #2067：同名来源保持类型标识——相册卡带相册类型词，文件夹分组行带文件夹图标类型词，
     * 且文件夹分组走原生 Material 3 ListItem（与相册双列网格明确区分）。
     */
    @Test
    fun album_grid_and_compact_folder_rows_keep_distinct_types_and_visual_forms() {
        val source = bucketScreenSource()
        val albumCardBlock = source.substringAfter("private fun BucketAlbumCard").substringBefore("private fun BucketFolderRow")
        val folderRowBlock = source.substringAfter("private fun BucketFolderRow").substringBefore("internal fun bucketScreenOffersAlbumChoices")
        assertTrue(
            "相册卡要带相册类型词",
            albumCardBlock.contains("kindLabel = stringResource(R.string.source_kind_album)"),
        )
        assertTrue(
            "文件夹行要带文件夹类型词",
            folderRowBlock.contains("contentDescription = stringResource(R.string.source_kind_folder)"),
        )
        assertTrue("文件夹行必须使用原生 Material3 ListItem", folderRowBlock.contains("ListItem("))
        assertTrue("文件夹行使用 Checkbox 勾选", folderRowBlock.contains("Checkbox("))
    }

    /**
     * #2067：未添加文件夹时不渲染文件夹区块（无空分组占位）；添加过文件夹后按需在相册网格下方出现。
     */
    @Test
    fun folder_section_appears_only_when_folders_exist_and_sits_below_albums() {
        assertFalse(
            "未添加文件夹时完全不出现文件夹区块",
            bucketScreenShowsFoldersSection(emptyList()),
        )
        val folder = FolderBucketUi(
            key = "content://f1",
            bucket = MediaScanner.Bucket(10L, "Blackmagic", 5),
            registered = true,
        )
        assertTrue(
            "已有文件夹时按需显示文件夹分组",
            bucketScreenShowsFoldersSection(listOf(folder)),
        )
        val source = bucketScreenSource()
        val albumGridIdx = source.indexOf("items(visibleAlbums")
        val folderSectionIdx = source.indexOf("if (showFoldersSection)")
        assertTrue("文件夹分组必须位于相册网格下方", folderSectionIdx > albumGridIdx && albumGridIdx > 0)
        assertTrue("文件夹分组标题必须使用 scope_folders_section", source.contains("R.string.scope_folders_section"))
    }

    @Test
    fun album_and_folder_selections_keep_their_selection_semantics() {
        val source = bucketScreenSource()
        assertTrue("相册勾选仍按相册 id 记", source.contains("selected = b.id in checked"))
        assertTrue("文件夹勾选仍按文件夹 key 记", source.contains("folder.key in checkedFolders"))
        assertTrue(
            "相册空名仍走本地化词条",
            source.contains("b.name ?: stringResource(R.string.bucket_unnamed)"),
        )
        assertTrue(
            "文件夹空名仍走本地化词条",
            source.contains("folder.bucket.name ?: stringResource(R.string.bucket_unnamed)"),
        )
        assertTrue(
            "选中/未选中状态要给读屏文案",
            source.contains("R.string.source_selected") && source.contains("R.string.source_unselected"),
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
    fun folders_and_albums_share_one_atomic_save() {
        val source = bucketScreenSource()
        assertTrue(source.contains("folderBuckets: List<FolderBucketUi>"))
        assertTrue(source.contains("selectedFolderKeys: Set<String>"))
        assertTrue("一个保存动作同时提交两类来源", source.contains("onDone(checked, checkedFolders, time)"))
        assertTrue("保存期间禁止重复提交", source.contains("enabled = !saving"))
        assertTrue(source.contains("R.string.folder_add"))
        assertTrue("新目录先默认选中但只进编辑暂存", source.contains("!it.registered && it.key !in seenFolderKeys"))
    }

    /**
     * #1797 / #2063 / #2067：失效文件夹行必须显性标出「需要重新允许」并提供直达重授按钮，
     * 菜单保留重授与移除，移除仍先过原确认弹窗。
     */
    @Test
    fun needs_permission_folder_row_shows_explicit_status_direct_reauthorize_and_confirm_remove() {
        val source = bucketScreenSource()
        val folderRow = source.substringAfter("private fun BucketFolderRow")
            .substringBefore("internal fun bucketScreenOffersAlbumChoices")
        assertTrue("失效行必须按 needsPermission 分流", folderRow.contains("if (folder.needsPermission)"))
        assertTrue("失效行必须显性标出「需要重新允许」", folderRow.contains("R.string.folder_status_needs_permission"))
        assertTrue("失效行必须提供直达重授按钮", folderRow.contains("OutlinedButton(") && folderRow.contains("onReauthorize"))
        assertTrue("文件夹行菜单保留移除动作", folderRow.contains("R.string.folder_remove"))
        assertFalse("移除不许在确认前直接触发 onRemoveFolder", folderRow.contains("onRemoveFolder("))
        val groupBlock = source.substringAfter("if (showFoldersSection)").substringBefore("Spacer(Modifier.height(14.dp))")
        assertTrue("移除触发确认弹窗挂起态", groupBlock.contains("removing = folder"))
        val dialog = source.substringAfter("removing?.let")
        assertTrue("确认后才回调 onRemoveFolder(folder.key)", dialog.contains("onRemoveFolder(folder.key)"))

        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) dir = dir.parentFile ?: error("apps/android not found")
        val enXml = File(dir, "apps/android/app/src/main/res/values/strings.xml").readText()
        val zhXml = File(dir, "apps/android/app/src/main/res/values-zh/strings.xml").readText()
        val enWaiting = enXml.substringAfter("name=\"state_waiting_source_unavailable\">").substringBefore("</string>")
        val zhWaiting = zhXml.substringAfter("name=\"state_waiting_source_unavailable\">").substringBefore("</string>")
        assertFalse("英文提示不得再指向不存在的 settings 入口", enWaiting.contains("in settings", ignoreCase = true))
        assertFalse("中文提示不得再指向不存在的「设置」入口", zhWaiting.contains("设置里"))
    }

    /**
     * #1794 / #1961 / #2067：部分照片权限继续直接视同无权限（顶部权限卡、只留已勾选相册供取消、不给新选）；
     * 顶栏目录入口与文件夹分组不受相册权限门控。
     */
    @Test
    fun only_full_photo_access_offers_album_choices_but_folders_still_work() {
        assertFalse("部分照片权限对相册自动备份与无权限相同，不给选相册", bucketScreenOffersAlbumChoices(MediaAccess.PARTIAL))
        assertFalse("没有相册权限时不给选相册", bucketScreenOffersAlbumChoices(MediaAccess.NONE))
        assertTrue("完整照片权限才给选相册", bucketScreenOffersAlbumChoices(MediaAccess.FULL))
        val source = bucketScreenSource()
        assertTrue(
            "相册卡只展示可见相册（完整授权全部 / 未完整授权仅已勾选）",
            source.contains("items(visibleAlbums, key = { \"album:\${it.id}\" })"),
        )
        assertTrue("未完整授权时相册区要有开启入口", source.contains("onRequestAlbumAccess"))
        assertTrue("开启入口用共享词条", source.contains("R.string.scope_album_no_access_action"))
        val topBar = source.substringAfter("topBar = {").substringBefore(") { innerPadding ->")
        assertFalse("顶栏目录入口不能被相册权限门控", topBar.contains("offersAlbums"))
        assertTrue(
            "文件夹分组显示只看文件夹是否非空，不受相册权限门控",
            bucketScreenShowsFoldersSection(
                listOf(FolderBucketUi("k", MediaScanner.Bucket(1L, "F", 1), registered = true)),
            ),
        )
        val folderGroupBlock = source.substringAfter("item(key = \"folders-group\"").substringBefore("Spacer(Modifier.height(14.dp))")
        assertFalse("文件夹分组内容不能被相册权限门控", folderGroupBlock.contains("offersAlbums"))
    }

    @Test
    fun visible_album_buckets_keep_only_checked_ones_until_full_access() {
        val a = MediaScanner.Bucket(1L, "A", 3)
        val b = MediaScanner.Bucket(2L, "B", 4)
        assertEquals("完整授权显示全部", listOf(a, b), visibleAlbumBuckets(listOf(a, b), emptySet(), MediaAccess.FULL))
        assertEquals("部分权限下已勾选的保留、没勾的不展示", listOf(a), visibleAlbumBuckets(listOf(a, b), setOf(1L), MediaAccess.PARTIAL))
        assertEquals("无权限下同样只保留已勾选的（可取消）", listOf(a), visibleAlbumBuckets(listOf(a, b), setOf(1L), MediaAccess.NONE))
        assertEquals("部分权限下一个都没勾就不展示任何相册", emptyList<MediaScanner.Bucket>(), visibleAlbumBuckets(listOf(a, b), emptySet(), MediaAccess.PARTIAL))
    }

    @Test
    fun whole_phone_empty_copy_spans_the_whole_row() {
        val empty = bucketScreenSource().substringAfter("item(key = \"empty\"")
        assertTrue(
            "整机空文案必须占满整行",
            empty.take(80).contains("span = { GridItemSpan(maxLineSpan) }"),
        )
    }

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

    /** #2067：底部已选摘要在各种组合（相册+文件夹 / 仅相册 / 仅文件夹 / 空选，保存与首次开始备份）下清晰准确。 */
    @Test
    fun bottom_action_summary_counts_visible_checked_albums_and_folders_accurately() {
        val a = MediaScanner.Bucket(1L, "Camera", 10)
        val b = MediaScanner.Bucket(2L, "Screenshots", 4)
        val f1 = FolderBucketUi("k1", MediaScanner.Bucket(101L, "Raw", 3), registered = true)
        val f2 = FolderBucketUi("k2", MediaScanner.Bucket(102L, "Docs", 2), registered = true)

        assertEquals(2, visibleSelectedAlbumCount(listOf(a, b), setOf(1L, 2L, 99L), MediaAccess.FULL))
        assertEquals(1, visibleSelectedAlbumCount(listOf(a, b), setOf(1L), MediaAccess.PARTIAL))
        assertEquals(0, visibleSelectedAlbumCount(emptyList(), setOf(1L), MediaAccess.NONE))
        assertEquals(1, selectedFolderCount(listOf(f1, f2), setOf("k1", "stale")))

        val withSummaryZh: (String, String) -> String = { base, s -> "$base（已选 $s）" }
        val emptyZh: (String) -> String = { base -> "$base（未选来源）" }
        assertEquals(
            "保存（已选 2 相册 · 1 文件夹）",
            formatBucketActionLabel("保存", "2 相册", "1 文件夹", withSummaryZh, emptyZh),
        )
        assertEquals(
            "保存（已选 2 相册）",
            formatBucketActionLabel("保存", "2 相册", null, withSummaryZh, emptyZh),
        )
        assertEquals(
            "开始备份（已选 1 文件夹）",
            formatBucketActionLabel("开始备份", null, "1 文件夹", withSummaryZh, emptyZh),
        )
        assertEquals(
            "开始备份（未选来源）",
            formatBucketActionLabel("开始备份", null, null, withSummaryZh, emptyZh),
        )
    }
}
