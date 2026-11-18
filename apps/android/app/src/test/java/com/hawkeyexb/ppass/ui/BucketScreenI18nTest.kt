package com.hawkeyexb.ppass.ui

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class BucketScreenI18nTest {
    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        return dir
    }

    private fun stringValue(localeDir: String, name: String): String {
        val xml = File(repoRoot(), "apps/android/app/src/main/res/$localeDir/strings.xml")
        val strings = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(xml)
            .getElementsByTagName("string")
        for (i in 0 until strings.length) {
            val element = strings.item(i) as Element
            if (element.getAttribute("name") == name) return element.textContent.trim()
        }
        error("$name missing from $localeDir")
    }

    @Test
    fun unnamed_bucket_card_uses_localized_resource() {
        val source = File(
            repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt",
        ).readText()

        assertTrue(
            "BucketCard must localize a null bucket name",
            source.contains("b.name ?: stringResource(R.string.bucket_unnamed)"),
        )
        assertTrue(
            "folder card must localize a null bucket name too (deleting either fallback must fail)",
            source.contains("folder.bucket.name ?: stringResource(R.string.bucket_unnamed)"),
        )
    }

    @Test
    fun unnamed_bucket_has_english_and_chinese_translations() {
        assertEquals("Unnamed", stringValue("values", "bucket_unnamed"))
        assertEquals("未命名", stringValue("values-zh", "bucket_unnamed"))
    }

    /**
     * #1797：同名来源要有类型标识——相册与文件夹的类型词两种语言都要有，且互不相同，
     * 由 SourceCard 用标准图标与读屏描述区分。
     */
    @Test
    fun source_type_labels_are_localized_and_distinct() {
        assertEquals("Album", stringValue("values", "source_kind_album"))
        assertEquals("Folder", stringValue("values", "source_kind_folder"))
        assertEquals("相册", stringValue("values-zh", "source_kind_album"))
        assertEquals("文件夹", stringValue("values-zh", "source_kind_folder"))
        assertFalse(
            "同一名字的相册与文件夹必须能靠类型词区分",
            stringValue("values", "source_kind_album") == stringValue("values", "source_kind_folder"),
        )
    }

    /** #1797：来源卡的选中/未选中状态交给标准读屏语义，两种语言都要有。 */
    @Test
    fun selection_state_copy_is_localized() {
        assertEquals("Selected", stringValue("values", "source_selected"))
        assertEquals("已选择", stringValue("values-zh", "source_selected"))
        assertEquals("Not selected", stringValue("values", "source_unselected"))
        assertEquals("未选择", stringValue("values-zh", "source_unselected"))
    }

    /** #1797：文件夹卡的菜单按钮描述要本地化（组件默认是写死的中文，不许沿用）。 */
    @Test
    fun menu_copy_is_localized_and_wired_to_the_folder_menu() {
        assertEquals("More actions", stringValue("values", "source_more_actions"))
        assertEquals("更多操作", stringValue("values-zh", "source_more_actions"))
        val source = File(
            repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt",
        ).readText()
        assertTrue(
            "文件夹菜单按钮要接本地化描述",
            source.contains("menuContentDescription = stringResource(R.string.source_more_actions)"),
        )
    }

    /** #1788：范围页相册提示的动作分流——系统还肯弹框（rationale=true）就申请；不再弹框（被锁）改「去设置」。 */
    @Test
    fun notice_action_follows_whether_the_system_still_prompts() {
        assertFalse("还肯弹框：动作是页内申请", albumNoAccessNoticeOpensSettings(canPrompt = true))
        assertTrue("不再弹框（问过至少一次后被锁）：动作改「去设置」", albumNoAccessNoticeOpensSettings(canPrompt = false))
    }

    /** #1788：被锁那档复用状态卡的「去设置」词条（同一个目的地同一个词），两种语言都得有。 */
    @Test
    fun locked_notice_action_uses_the_same_copy_as_the_blocked_hero() {
        assertEquals("Open settings", stringValue("values", "auto_backup_blocked_action"))
        assertEquals("去设置", stringValue("values-zh", "auto_backup_blocked_action"))
    }
}
