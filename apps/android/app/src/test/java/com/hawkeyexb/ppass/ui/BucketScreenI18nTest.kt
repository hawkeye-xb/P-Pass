package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
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

    private fun xmlValues(localeDir: String, fileName: String, tag: String, name: String): Element {
        val xml = File(repoRoot(), "apps/android/app/src/main/res/$localeDir/$fileName")
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(xml)
            .getElementsByTagName(tag)
        for (i in 0 until nodes.length) {
            val element = nodes.item(i) as Element
            if (element.getAttribute("name") == name) return element
        }
        error("$tag/$name missing from $localeDir/$fileName")
    }

    private fun stringValue(localeDir: String, name: String, fileName: String = "strings.xml"): String =
        xmlValues(localeDir, fileName, "string", name).textContent.trim()

    private fun pluralValue(localeDir: String, name: String, count: Int): String {
        val el = xmlValues(localeDir, "strings.xml", "plurals", name)
        val items = el.getElementsByTagName("item")
        val map = (0 until items.length).associate { idx ->
            val item = items.item(idx) as Element
            item.getAttribute("quantity") to item.textContent.trim()
        }
        val tpl = if (count == 1 && "one" in map) map.getValue("one") else map.getValue("other")
        return String.format(tpl, count)
    }

    private fun renderActionSummary(localeDir: String, firstTime: Boolean, albumCount: Int, folderCount: Int): String {
        val spec = bucketActionSummarySpec(firstTime = firstTime, albumCount = albumCount, folderCount = folderCount)
        val baseKey = when (spec.baseRes) {
            R.string.bucket_start -> "bucket_start"
            R.string.bucket_save -> "bucket_save"
            else -> error("unexpected baseRes ${spec.baseRes}")
        }
        val tplKey = when (spec.templateRes) {
            R.string.bucket_action_empty -> "bucket_action_empty"
            R.string.bucket_action_with_summary -> "bucket_action_with_summary"
            else -> error("unexpected templateRes ${spec.templateRes}")
        }
        val base = stringValue(localeDir, baseKey)
        val albumPart = if (spec.albumCount > 0) pluralValue(localeDir, "backup_scope_n", spec.albumCount) else null
        val folderPart = if (spec.folderCount > 0) pluralValue(localeDir, "backup_scope_folder_n", spec.folderCount) else null
        val summary = listOfNotNull(albumPart, folderPart).joinToString(" · ")
        val template = stringValue(localeDir, tplKey)
        return if (summary.isEmpty()) String.format(template, base) else String.format(template, base, summary)
    }

    @Test
    fun unnamed_bucket_has_english_and_chinese_translations() {
        assertEquals("Unnamed", stringValue("values", "bucket_unnamed"))
        assertEquals("未命名", stringValue("values-zh", "bucket_unnamed"))
    }

    /**
     * #1797：同名来源要有类型标识——相册与文件夹的类型词两种语言都要有，且互不相同。
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

    /** #1797 / #2067：文件夹行菜单与重授/时间区块/文件夹分组文案双语齐全。 */
    @Test
    fun bucket_scope_section_and_folder_action_copy_are_localized() {
        assertEquals("More actions", stringValue("values", "source_more_actions"))
        assertEquals("更多操作", stringValue("values-zh", "source_more_actions"))
        assertEquals("Backup time", stringValue("values", "scope_time_section"))
        assertEquals("备份时间", stringValue("values-zh", "scope_time_section"))
        assertEquals("Folders", stringValue("values", "scope_folders_section"))
        assertEquals("文件夹", stringValue("values-zh", "scope_folders_section"))
        assertEquals("Permission needed", stringValue("values", "folder_status_needs_permission", "strings_android_only.xml"))
        assertEquals("需要重新允许", stringValue("values-zh", "folder_status_needs_permission", "strings_android_only.xml"))
    }

    /** #2067：生产函数 bucketActionSummarySpec 配合真实中英 strings.xml 渲染全部组合。 */
    @Test
    fun action_button_summary_renders_real_strings_in_en_and_zh() {
        assertEquals("保存（已选 2 相册 · 1 文件夹）", renderActionSummary("values-zh", firstTime = false, albumCount = 2, folderCount = 1))
        assertEquals("保存（已选 2 相册）", renderActionSummary("values-zh", firstTime = false, albumCount = 2, folderCount = 0))
        assertEquals("开始备份（已选 1 文件夹）", renderActionSummary("values-zh", firstTime = true, albumCount = 0, folderCount = 1))
        assertEquals("保存（未选来源）", renderActionSummary("values-zh", firstTime = false, albumCount = 0, folderCount = 0))

        assertEquals("Save (2 albums · 1 folder)", renderActionSummary("values", firstTime = false, albumCount = 2, folderCount = 1))
        assertEquals("Save (1 album)", renderActionSummary("values", firstTime = false, albumCount = 1, folderCount = 0))
        assertEquals("Start backup (2 folders)", renderActionSummary("values", firstTime = true, albumCount = 0, folderCount = 2))
        assertEquals("Start backup (none selected)", renderActionSummary("values", firstTime = true, albumCount = 0, folderCount = 0))
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
