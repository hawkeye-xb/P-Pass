package com.hawkeyexb.ppass.i18n

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * T-072: UI 层新 key 的双语覆盖——Android 自己的 strings.xml 必须
 * en/zh 键集一致且无空翻译（与 diag 字典同纪律）。新增任何 UI 文案时
 * 漏掉一种语言，本测试立刻红。
 *
 * T-042b: 用真实 XML 解析器（javax.xml DOM）替代正则——旧正则
 * `name="...">([^<]*)</string>` 会静默跳过带属性（如 `translatable="false"`、
 * 格式化参数 `formatted="false"`）或多行内容的条目，漏检即无保护。
 */
class StringsSymmetryTest {

    private fun appRes(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        return File(dir, "apps/android/app/src/main/res")
    }

    /** 解析 strings.xml 为 key→text 映射（真实 DOM，不丢任何条目）。 */
    private fun keys(resDir: File, localeDir: String): Map<String, String> {
        val xml = File(resDir, localeDir).listFiles()?.firstOrNull { it.name == "strings.xml" }
            ?: error("strings.xml missing under $localeDir")
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = true
        val doc = factory.newDocumentBuilder().parse(xml)
        val nodes = doc.getElementsByTagName("string")
        val result = LinkedHashMap<String, String>()
        for (i in 0 until nodes.length) {
            val el = nodes.item(i) as Element
            val name = el.getAttribute("name")
            // 文本内容 = 全部子节点文本（含 CDATA/多行），trim 后保留
            val text = el.textContent?.trim().orEmpty()
            check(name.isNotEmpty()) { "strings.xml ($localeDir) 有缺 name 的 <string> 节点" }
            check(!result.containsKey(name)) { "strings.xml ($localeDir) 重复 key: $name" }
            result[name] = text
        }
        return result
    }

    @Test
    fun en_and_zh_have_identical_key_sets_and_nonempty_values() {
        val res = appRes()
        val en = keys(res, "values")
        val zh = keys(res, "values-zh")
        assertEquals("en/zh strings.xml 键集不一致", en.keys.sorted(), zh.keys.sorted())
        for ((k, v) in en) {
            assertTrue("en 的 $k 为空", v.isNotBlank())
            assertTrue("zh 的 $k 为空", zh.getValue(k).isNotBlank())
        }
    }

    /** plurals：name → (quantity → text)。 */
    private fun plurals(resDir: File, localeDir: String): Map<String, Map<String, String>> {
        val xml = File(resDir, "$localeDir/strings.xml")
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(xml)
        val nodes = doc.getElementsByTagName("plurals")
        val result = LinkedHashMap<String, Map<String, String>>()
        for (i in 0 until nodes.length) {
            val el = nodes.item(i) as Element
            val items = el.getElementsByTagName("item")
            result[el.getAttribute("name")] = (0 until items.length).associate { j ->
                val item = items.item(j) as Element
                item.getAttribute("quantity") to item.textContent.trim()
            }
        }
        return result
    }

    // #418 回归：N=1 时英文显示成「Cancel remaining 1 photos」。带数量的文案一律 plurals：
    // en 必须有 one + other，且 one 里不许出现复数名词；zh 没有复数，只给 other（给 one 会被 lint 报 UnusedQuantity）。
    // 反证：把 cancel_remaining_label 改回 <string> → 下面的键集断言缺这个 key，红；
    // 把 en 的 one 写成「%1$d photos」→ 复数名词断言红。
    @Test
    fun counted_copy_uses_plurals_with_a_real_english_singular() {
        val res = appRes()
        val en = plurals(res, "values")
        val zh = plurals(res, "values-zh")
        val required = setOf(
            "cancel_remaining_label", "cancel_remaining_confirm_title", "state_pending",
            "missing_source_notice_body", "notif_backup_failed_body", "photos_lost_body_days", "backup_scope_n",
        )
        assertTrue("缺 plurals：${required - en.keys}", en.keys.containsAll(required))
        assertEquals("en/zh plurals 键集不一致", en.keys.sorted(), zh.keys.sorted())
        // 只看紧跟数字的那个名词（「Your photos are…」这种与 N 无关的复数不算）。
        val pluralNoun = Regex("""%1\${'$'}d\s+(photos|albums|days|items|files)\b|\(s\)""")
        for ((name, items) in en) {
            assertEquals("en 的 $name 应有 one + other", setOf("one", "other"), items.keys)
            val one = items.getValue("one")
            assertTrue("en 的 $name 单数写成了复数：$one", !pluralNoun.containsMatchIn(one))
            items.values.forEach { assertTrue("en 的 $name 缺 %1\$d：$it", it.contains("%1\$d")) }
        }
        for ((name, items) in zh) {
            assertEquals("zh 的 $name 只应有 other", setOf("other"), items.keys)
            assertTrue("zh 的 $name 缺 %1\$d", items.getValue("other").contains("%1\$d"))
        }
    }

    @Test
    fun main_kotlin_has_no_chinese_outside_comments() {
        val app = appRes().parentFile!!.parentFile!!.parentFile!!
        val files = listOf(
            File(app, "src/main/java/com/hawkeyexb/ppass/MainActivity.kt"),
            File(app, "src/main/java/com/hawkeyexb/ppass/transport/PairFlow.kt"),
            File(app, "src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt"),
        )
        for (file in files) {
            val offending = codeLines(file.readText()).filter(::hasChinese).toList()
            assertTrue(
                "${file.name} 的非注释代码不得硬编码中文: $offending",
                offending.isEmpty(),
            )
        }
    }

    private fun codeLines(source: String): Sequence<String> = sequence {
        var inBlockComment = false
        for (raw in source.lineSequence()) {
            var line = raw
            val code = StringBuilder()
            while (line.isNotEmpty()) {
                if (inBlockComment) {
                    val end = line.indexOf("*/")
                    if (end < 0) {
                        line = ""
                    } else {
                        inBlockComment = false
                        line = line.substring(end + 2)
                    }
                } else {
                    val block = line.indexOf("/*")
                    val lineComment = line.indexOf("//")
                    if (lineComment >= 0 && (block < 0 || lineComment < block)) {
                        code.append(line.substring(0, lineComment))
                        line = ""
                    } else if (block < 0) {
                        code.append(line)
                        line = ""
                    } else {
                        code.append(line.substring(0, block))
                        inBlockComment = true
                        line = line.substring(block + 2)
                    }
                }
            }
            yield(code.toString())
        }
    }

    private fun hasChinese(line: String): Boolean = line.any { it in '\u4e00'..'\u9fff' }

    /**
     * T-042b 回归：带属性（translatable/formatted）或多行内容的条目必须被
     * 解析器抓到——旧正则静默跳过它们。构造一个带属性 + CDATA 的临时
     * strings.xml，断言两个条目都进映射。
     */
    @Test
    fun parser_captures_attributed_and_multiline_entries() {
        val tmp = File.createTempFile("strings", ".xml")
        tmp.writeText(
            """
            <resources>
                <string name="plain">hello</string>
                <string name="attributed" translatable="false">no-translate</string>
                <string name="multiline"><![CDATA[line one
            line two]]></string>
            </resources>
            """.trimIndent()
        )
        val factory = DocumentBuilderFactory.newInstance()
        val doc = factory.newDocumentBuilder().parse(tmp)
        val nodes = doc.getElementsByTagName("string")
        val captured = (0 until nodes.length).map { (nodes.item(it) as Element).getAttribute("name") }
        tmp.delete()
        assertTrue("带属性条目被跳过: $captured", captured.contains("attributed"))
        assertTrue("多行/CDATA 条目被跳过: $captured", captured.contains("multiline"))
        assertEquals("应恰好 3 个条目: $captured", 3, captured.size)
    }
}
