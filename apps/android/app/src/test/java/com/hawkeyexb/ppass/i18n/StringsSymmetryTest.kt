package com.hawkeyexb.ppass.i18n

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * T-072: UI 层新 key 的双语覆盖——Android 自己的 strings.xml 必须
 * en/zh 键集一致且无空翻译（与 diag 字典同纪律）。新增任何 UI 文案时
 * 漏掉一种语言，本测试立刻红。
 */
class StringsSymmetryTest {

    private fun appRes(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        return File(dir, "apps/android/app/src/main/res")
    }

    private fun keys(resDir: File, localeDir: String): Map<String, String> {
        val xml = File(resDir, localeDir).listFiles()?.firstOrNull { it.name == "strings.xml" }
            ?: error("strings.xml missing under $localeDir")
        val text = xml.readText()
        val keys = Regex("""name="([^"]+)">([^<]*)</string>""").findAll(text)
        return keys.associate { it.groupValues[1] to it.groupValues[2] }
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
}
