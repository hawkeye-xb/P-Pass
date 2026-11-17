package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess
import java.io.File
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

    @Test
    fun album_name_is_one_line_and_ellipsized_without_changing_bucket_selection() {
        val source = bucketScreenSource()
        assertTrue("album name must have a single-line limit", source.contains("maxLines = 1"))
        assertTrue(
            "album name must show an ellipsis when the row is constrained",
            source.contains("overflow = TextOverflow.Ellipsis"),
        )
        assertTrue("album name must reserve the remaining row width", source.contains("Modifier.weight(1f)"))
        assertFalse("the old unconstrained row width must not return", source.contains("weight(1f, fill = false)"))
        assertTrue("selection semantics must still be keyed by bucket id", source.contains("selected = b.id in checked"))
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

    @Test
    fun needs_permission_folder_keeps_reauthorize_and_remove_actions() {
        val source = bucketScreenSource()
        assertTrue("卡片必须支持第二个独立动作", source.contains("secondaryActionLabel: String? = null"))
        assertTrue(source.contains("onSecondaryAction: (() -> Unit)? = null"))
        assertTrue("第二个动作必须实际渲染", source.contains("if (secondaryActionLabel != null && onSecondaryAction != null)"))
        val folderBlock = source.substringBefore("item(key = \"add-folder\")")
            .substringAfter("items(folderBuckets")
        assertTrue("失效目录仍显示重新授权", folderBlock.contains("onReauthorizeFolder(folder.key)"))
        assertTrue("失效目录同时保留移除", folderBlock.contains("if (folder.needsPermission) stringResource(R.string.folder_remove) else null"))
        assertTrue("失效目录的移除仍进入原确认弹窗", folderBlock.contains("onSecondaryAction = if (folder.needsPermission) { { removing = folder } } else null"))
    }

    /**
     * #1794：范围页始终能进（对齐 iOS），没有相册权限时相册区不给选、只说明现状并给申请入口，
     * 文件夹区和「添加文件夹」照常可用。反证：相册卡不做权限门控或「添加文件夹」被并进门控里，本条红。
     */
    @Test
    fun without_photo_access_albums_are_not_selectable_but_folders_still_are() {
        assertFalse("没有相册权限时不给选相册", bucketScreenOffersAlbumChoices(MediaAccess.NONE))
        assertTrue(bucketScreenOffersAlbumChoices(MediaAccess.PARTIAL))
        assertTrue(bucketScreenOffersAlbumChoices(MediaAccess.FULL))
        val source = bucketScreenSource()
        val gated = source.substringAfter("if (offersAlbums) {").substringBefore("items(folderBuckets")
        assertTrue("相册卡按相册权限门控", gated.contains("items(buckets"))
        assertTrue("无权限时相册区要有申请入口", source.contains("onRequestAlbumAccess"))
        assertTrue("申请入口用无权限文案", source.contains("R.string.scope_album_no_access_action"))
        val addFolder = source.indexOf("item(key = \"add-folder\")")
        val folderItems = source.indexOf("items(folderBuckets")
        assertTrue("「添加文件夹」无条件出现", addFolder > folderItems)
        assertFalse("「添加文件夹」不能被相册权限门控", gated.contains("add-folder"))
    }

    /** 没有相册权限时读不到照片，不能把「读不到」说成整机没有照片。 */
    @Test
    fun whole_phone_empty_copy_needs_readable_photo_access() {
        assertTrue(bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.FULL))
        assertTrue(bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.PARTIAL))
        assertFalse(
            "没有相册权限时不得声称整机没有照片",
            bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.NONE),
        )
        assertFalse(
            "还有文件夹来源时不算整机为空",
            bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = false, access = MediaAccess.FULL),
        )
    }

    @Test
    fun source_cards_and_add_action_share_grid_geometry_and_type_glyphs() {
        val source = bucketScreenSource()
        assertTrue("相册与文件夹必须有不同类型图标", source.contains("SourceTypeGlyph(isFolder)"))
        assertTrue("相册卡使用相册图标", source.contains("isFolder = false"))
        assertTrue("文件夹卡使用文件夹图标", source.contains("isFolder = true"))
        assertTrue("来源卡和添加动作必须同高", source.split("Modifier.height(72.dp)").size >= 3)
        assertTrue("添加动作也使用同一封面比例", source.contains("Modifier.fillMaxWidth().aspectRatio(1.6f)"))
        assertFalse("移除不能作为卡片外的一行撑高", source.contains("Row(Modifier.padding(start = 8.dp, top = 4.dp))"))
    }

}
