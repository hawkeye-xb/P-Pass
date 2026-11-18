package com.hawkeyexb.ppass.ui

import java.io.File
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
        assertTrue("授权动作用标准 TextButton", source.contains("TextButton("))
        assertFalse("自绘「‹」返回不许回来", source.contains("\"‹\""))
        assertFalse("重新授权不许再用 clickable 文本", source.contains("Modifier.clickable { onReauthorize(folder) }"))
        assertFalse("移除不许再用 clickable 文本", source.contains("Modifier.clickable { removing = folder }"))
        assertFalse("添加动作不许再用 clickable 块", source.contains("Column(Modifier.clickable(onClick = onAdd)"))
    }

    /** 移除仍先过确认弹窗，确认后才回调 onRemove；语义与替换前一致。 */
    @Test
    fun remove_still_goes_through_the_confirm_dialog() {
        val source = folderScreenSource()
        assertTrue("移除仍先弹确认", source.contains("removing = folder"))
        assertTrue("确认弹窗仍是标准 AlertDialog", source.contains("AlertDialog("))
        assertTrue("确认后仍回调 onRemove(folder)", source.contains("onRemove(folder)"))
        assertTrue("确认弹窗有取消", source.contains("R.string.folder_cancel"))
    }

    /** 添加动作用 Material3 Card(onClick) 承载，点击仍直连 onAdd。 */
    @Test
    fun add_action_uses_a_standard_clickable_card() {
        val source = folderScreenSource()
        assertTrue("添加动作用标准 Card", source.contains("Card("))
        assertTrue("点击仍直连 onAdd", source.contains("onClick = onAdd"))
        assertTrue("添加文案仍用 folder_add", source.contains("R.string.folder_add"))
    }

    /** 授权状态展示不变：状态由调用方按真实 SAF 可用性传入，两档文案照旧。 */
    @Test
    fun permission_status_display_is_unchanged() {
        val source = folderScreenSource()
        assertTrue("needsPermission 仍由调用方传入", source.contains("val needsPermission: Boolean"))
        assertTrue(source.contains("R.string.folder_status_needs_permission"))
        assertTrue(source.contains("R.string.folder_status_ok"))
    }
}
