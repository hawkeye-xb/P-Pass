package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1797：素材文件夹页的返回、授权动作与添加动作改用 Material 3 标准组件，
 * 不再有平行的自绘点击实现；业务状态（授权状态、移除确认）保持不变。
 */
class FolderScreenTest {
    private fun folderScreenSource(): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/FolderScreen.kt",
        ).readText()
    }

    /**
     * 动作不再用自绘 clickable 文本与「‹」字符承载。
     * 反证：恢复自绘平行实现（clickable 文本 / 「‹」返回 / clickable 添加块）后本条变红。
     */
    @Test
    fun actions_use_standard_components_not_clickable_text() {
        val source = folderScreenSource()
        assertTrue("返回用标准 IconButton", source.contains("IconButton(onClick = onBack)"))
        assertTrue("返回图标用平台箭头", source.contains("Icons.AutoMirrored.Filled.ArrowBack"))
        assertTrue("返回描述用本地化词条", source.contains("R.string.back"))
        assertTrue("授权动作是 needsPermission 分支里的标准 TextButton", source.contains("TextButton(onClick = { onReauthorize(folder) })"))
        assertFalse("自绘「‹」返回不许回来", source.contains("\"‹\""))
        assertFalse("重新授权不许再用 clickable 文本", source.contains("Modifier.clickable { onReauthorize(folder) }"))
        assertFalse("重新授权也不许再用 clickable(onClick) 文本", source.contains("Modifier.clickable(onClick = { onReauthorize(folder) })"))
        assertFalse("移除不许再用 clickable 文本", source.contains("Modifier.clickable { removing = folder }"))
        assertFalse("添加动作不许再用 clickable 块", source.contains("Column(Modifier.clickable(onClick = onAdd)"))
    }

    /** 移除仍先过确认弹窗，确认后才回调 onRemove；语义与替换前一致。
     *  反证：移除入口先调 onRemove 再设 removing（弹窗拦不住移除）后，本条红。 */
    @Test
    fun remove_still_goes_through_the_confirm_dialog() {
        val source = folderScreenSource()
        assertTrue("移除仍先弹确认", source.contains("removing = folder"))
        assertTrue("确认弹窗仍是标准 AlertDialog", source.contains("AlertDialog("))
        val dialogStart = source.indexOf("AlertDialog(")
        val confirmIdx = source.indexOf("onRemove(folder)")
        assertTrue("onRemove(folder) 必须在确认弹窗的确认回调里", confirmIdx > dialogStart)
        assertEquals(
            "onRemove(folder) 只能出现一次（先移除再弹窗的写法不许回来）",
            -1,
            source.indexOf("onRemove(folder)", confirmIdx + 1),
        )
        assertTrue("确认弹窗有取消", source.contains("R.string.folder_cancel"))
    }

    /** 添加动作用 Material3 Card(onClick) 承载，点击仍直连 onAdd，且文案在卡片内。
     *  反证：folder_add 文案被挪出 Card（卡片变空、点击失效）后，本条红。 */
    @Test
    fun add_action_uses_a_standard_clickable_card() {
        val source = folderScreenSource()
        assertTrue("添加动作用标准 Card", source.contains("Card("))
        // 卡片块 = Card( 到其后第一个收尾 Spacer 之间；文案与 onClick 必须同在这一块里。
        val cardBlock = source.substringAfter("Card(").substringBefore("Spacer(Modifier.height(12.dp))")
        assertTrue("点击仍直连 onAdd", cardBlock.contains("onClick = onAdd"))
        assertTrue("添加文案仍用 folder_add 且在卡片内", cardBlock.contains("R.string.folder_add"))
    }

    /** 授权状态展示不变：状态由调用方按真实 SAF 可用性传入，两档文案照旧。
     *  反证：needsPermission 两个分支的文案键互换后，本条红。 */
    @Test
    fun permission_status_display_is_unchanged() {
        val source = folderScreenSource()
        assertTrue("needsPermission 仍由调用方传入", source.contains("val needsPermission: Boolean"))
        assertTrue(
            "需要授权的文件夹显示 needs_permission 文案",
            source.contains("if (folder.needsPermission) R.string.folder_status_needs_permission"),
        )
        assertTrue(
            "已授权的文件夹显示 ok 文案",
            source.contains("else R.string.folder_status_ok"),
        )
    }
}
