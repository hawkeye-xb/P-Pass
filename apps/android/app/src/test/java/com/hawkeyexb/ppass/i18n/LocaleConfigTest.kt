package com.hawkeyexb.ppass.i18n

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * #557: Android 13+ 系统级单应用语言（系统设置 → 应用 → P-Pass → 语言）。
 *
 * 系统只认 manifest 上 `android:localeConfig` 指向的列表；列表必须恰好是
 * App 实际带的语言——`values/`（默认，英文）+ `values-zh/`。多列一种语言
 * 系统会让用户选一个没有翻译的语言；少列则那种语言在系统设置里选不到。
 *
 * 反证：删掉 manifest 上的属性，或往 locales_config.xml 加一个 `ja`，本测试红。
 */
class LocaleConfigTest {

    private fun appMain(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        return File(dir, "apps/android/app/src/main")
    }

    @Test
    fun manifest_points_at_the_locale_config() {
        val manifest = File(appMain(), "AndroidManifest.xml").readText()
        assertTrue(
            "manifest <application> 缺 android:localeConfig=\"@xml/locales_config\"",
            manifest.contains("android:localeConfig=\"@xml/locales_config\""),
        )
    }

    @Test
    fun locale_config_lists_exactly_the_shipped_languages() {
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = true
        val doc = factory.newDocumentBuilder().parse(File(appMain(), "res/xml/locales_config.xml"))
        val nodes = doc.getElementsByTagName("locale")
        val listed = (0 until nodes.length)
            .map { (nodes.item(it) as Element).getAttributeNS("http://schemas.android.com/apk/res/android", "name") }
            .sorted()

        // 默认 values/ 是英文；其余语言来自 values-<lang>/ 下带 strings.xml 的目录。
        val shipped = (appMain().resolve("res").listFiles().orEmpty())
            .filter { it.isDirectory && File(it, "strings.xml").isFile }
            .map { if (it.name == "values") "en" else it.name.removePrefix("values-") }
            .sorted()

        assertEquals("locales_config.xml 与 res/values*/strings.xml 的语言不一致", shipped, listed)
    }
}
