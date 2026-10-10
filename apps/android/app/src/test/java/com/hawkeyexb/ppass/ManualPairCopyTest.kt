// #739：手动输入配对串页的占位符和说明，必须和真实配对串、桌面端真实入口对得上。
//
// 原来：占位符是 `PP-XXXX-XXXX-XXXX-XXXX`，真实配对串却是约 145 字符的
// `ppf://pair?node=…`——用户会以为自己复制错了。说明里的桌面按钮名英文版也和桌面端不一致。
package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class ManualPairCopyTest {

    private fun strings(dir: String) = File("src/main/res/$dir/strings.xml").readText()

    /**
     * 按 aapt 的规则还原用户实际看到的文字：`\'` `\"` 是转义；**没转义的 `"` 会被吞掉**
     * （真机实测：英文说明里按钮名两边的引号全没了）。
     */
    private fun res(xml: String, name: String): String =
        Regex("""<string name="$name"[^>]*>(.*?)</string>""").find(xml)?.groupValues?.get(1)
            ?.replace("\\\"", "\u0000")?.replace("\"", "")?.replace("\u0000", "\"")
            ?.replace("\\'", "'")
            ?: error("缺少字符串 $name")

    /** 桌面端文案的唯一来源：仓库根 `assets/i18n`（桌面壳 include_str! 的同一份）。 */
    private fun desktop(lang: String, key: String): String =
        Regex(""""${Regex.escape(key)}":\s*"(.*?)"""")
            .find(File("../../../assets/i18n/$lang.json").readText())?.groupValues?.get(1)
            ?: error("桌面 i18n 缺少 $key")

    @Test
    fun the_placeholder_shows_the_real_pairing_string_prefix() {
        for (dir in listOf("values", "values-zh")) {
            val placeholder = res(strings(dir), "scan_manual_placeholder")
            assertTrue(
                "[$dir] 占位符必须以真实配对串的开头示意（PeerAddrToken 只认 ppf://pair?）: $placeholder",
                placeholder.startsWith("ppf://pair?"),
            )
        }
    }

    @Test
    fun the_instructions_name_the_desktop_entries_that_really_exist() {
        for ((dir, lang) in listOf("values" to "en", "values-zh" to "zh")) {
            val body = res(strings(dir), "scan_manual_body")
            for (key in listOf("ui.add_device", "ui.qr_fallback")) {
                val label = desktop(lang, key)
                assertTrue("[$lang] 说明里的桌面入口名必须和桌面端 $key「$label」一致: $body", body.contains(label))
                if (lang == "en") {
                    assertTrue("[en] 按钮名必须带引号显示（未转义的 \" 会被 aapt 吞掉）: $body", body.contains("\"$label\""))
                }
            }
        }
    }
}
