// 产品负责人 2026-11-04 定的引导文案：决定页标题下说清照片传到哪台电脑；欢迎页起全 App 不加「家里的」之类修饰词。
package com.hawkeyexb.ppass.onboarding

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DecisionCopyTest {
    private val res = "src/main/res"
    private fun strings(dir: String): Map<String, String> =
        Regex("""<string name="([^"]+)"[^>]*>([^<]*)</string>""")
            .findAll(File("$res/$dir/strings.xml").readText()).associate { it.groupValues[1] to it.groupValues[2] }

    /** 决定页标题下一行带电脑名；没有电脑名时退回默认叫法，不出现「传到 。」。反证：去掉这一行或不传电脑名，本条红。 */
    @Test
    fun decision_page_says_where_photos_go() {
        val ui = File("src/main/java/com/hawkeyexb/ppass/ui/DecisionScreen.kt").readText()
        assertTrue(ui.contains("stringResource(R.string.decision_destination, name)"))
        assertTrue(ui.contains("computerName.ifBlank { stringResource(R.string.storage_device_default) }"))
        assertEquals("选好相册和时间范围后，每次打开 App，范围内的照片会自动传到 %1\$s。", strings("values-zh")["decision_destination"])
        assertTrue(strings("values")["decision_destination"]!!.contains("%1\$s"))
    }

    @Test
    fun no_home_qualifier_in_phone_copy() {
        for (dir in listOf("values", "values-zh")) {
            val s = File("$res/$dir/strings.xml").readText()
            assertFalse(dir, s.contains("家里"))
            assertFalse(dir, Regex("(?i)\\bhome computer\\b").containsMatchIn(s))
        }
        assertEquals("电脑", strings("values-zh")["storage_device_default"])
        assertEquals("无法扫码？手动配对", strings("values-zh")["scan_manual_link"])
        assertEquals("不经过云端，不用注册账号。", strings("values-zh")["welcome_sub"])
    }
}
