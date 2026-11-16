package com.hawkeyexb.ppass.ui

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
