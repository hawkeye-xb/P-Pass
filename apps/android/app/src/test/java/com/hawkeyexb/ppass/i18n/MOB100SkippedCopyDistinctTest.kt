// MOB-100：两条「已跳过」的文案区分。
//
// `missing_source_notice_body`（源缺失，**永久不可恢复**）与
// `cancelled_round_cell_label` / `_value`（用户取消，**点一下全回来**）
// 语义正好相反，此前中文都以「已跳过」开头，真机已同屏出现
// （docs/design/2026-09-22-home-notice-priority.md §4.3 真机组合 2）。
//
// 处置是**并存、不互斥**——`deliveryState` 本就互斥，同一张照片不会被两边
// 数到；强行互斥会重犯 MOB-59 那次「提示消失了，那批再也找不到」。并存的
// 前置条件是第一行就可区分，这里就是那条门禁。
//
// ⚠️ 卡面给的可判定形式是「前 4 个字符不得相同」，但那一条**今天就是绿的**：
// 旧文案 `已跳过 %1$d 张…` 的第 4 个字符是空格，`已跳过的照片` 的是「的」。
// 字面判据挡不住它要挡的东西，所以这里用它的**严格化形式**：去掉占位符与
// 空白后，两条文案的**公共前缀必须短于 4 个字符**，且不得共用起首词——
// 旧文案公共前缀 = 「已跳过」= 3 个字符 ⇒ 红。
package com.hawkeyexb.ppass.i18n

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class MOB100SkippedCopyDistinctTest {

    /** 共用起首词的上限：公共前缀 >= 这个长度就算「第一行分不出来」。 */
    private val maxSharedPrefix = 3

    private fun appRes(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        return File(dir, "apps/android/app/src/main/res")
    }

    private fun keys(localeDir: String): Map<String, String> {
        val xml = File(appRes(), "$localeDir/strings.xml")
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = true
        val doc = factory.newDocumentBuilder().parse(xml)
        val nodes = doc.getElementsByTagName("string")
        val result = LinkedHashMap<String, String>()
        for (i in 0 until nodes.length) {
            val el = nodes.item(i) as Element
            result[el.getAttribute("name")] = el.textContent?.trim().orEmpty()
        }
        return result
    }

    /** 去掉格式化占位符与空白——比的是用户读到的第一个词，不是排版。 */
    private fun normalize(text: String): String =
        text.replace(Regex("%\\d+\\\$[a-zA-Z]"), "")
            .replace(Regex("%[a-zA-Z]"), "")
            .filterNot { it.isWhitespace() }

    private fun sharedPrefix(a: String, b: String): Int =
        a.commonPrefixWith(b).length

    private fun assertDistinct(localeDir: String) {
        val strings = keys(localeDir)
        val missingSource = normalize(strings.getValue("missing_source_notice_body"))
        val cancelled = normalize(strings.getValue("cancelled_round_cell_label"))
        val shared = sharedPrefix(missingSource, cancelled)
        assertTrue(
            "$localeDir：「源已删除、不会再重传」与「用户取消、点一下全回来」" +
                "语义正好相反，第一行必须能分开。当前公共前缀 $shared 个字符" +
                "（「${missingSource.take(shared)}」）：\n" +
                "  missing_source_notice_body   = ${strings.getValue("missing_source_notice_body")}\n" +
                "  cancelled_round_cell_label   = ${strings.getValue("cancelled_round_cell_label")}",
            shared < maxSharedPrefix,
        )
    }

    @Test
    fun zh_the_two_skipped_notices_do_not_share_a_leading_word() = assertDistinct("values-zh")

    @Test
    fun en_the_two_skipped_notices_do_not_share_a_leading_word() = assertDistinct("values")
}
