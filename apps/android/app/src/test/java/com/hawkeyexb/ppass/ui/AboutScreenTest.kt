package com.hawkeyexb.ppass.ui

import android.content.Intent
import android.net.Uri
import com.hawkeyexb.ppass.R
import io.mockk.mockk
import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class AboutScreenTest {
    private fun stringResourceValue(localeDir: String, name: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        val xml = File(dir, "apps/android/app/src/main/res/$localeDir/strings.xml")
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(xml)
            .getElementsByTagName("string")
        for (i in 0 until nodes.length) {
            val element = nodes.item(i) as Element
            if (element.getAttribute("name") == name) return element.textContent.trim()
        }
        error("string/$name missing from $localeDir/strings.xml")
    }

    @Test
    fun about_feedback_labels_are_concise_in_zh_and_en() {
        assertEquals("邮件反馈", stringResourceValue("values-zh", "about_feedback_email"))
        assertEquals("社区反馈", stringResourceValue("values-zh", "about_feedback_discussions"))
        assertEquals("Email feedback", stringResourceValue("values", "about_feedback_email"))
        assertEquals("Community", stringResourceValue("values", "about_feedback_discussions"))
    }
    @Test
    fun chinese_locale_detection_matches_zh_only() {
        assertTrue(isChineseLocale(Locale.SIMPLIFIED_CHINESE))
        assertTrue(isChineseLocale(Locale("zh", "TW")))
        assertFalse(isChineseLocale(Locale.US))
        assertFalse(isChineseLocale(Locale.JAPAN))
    }

    @Test
    fun about_links_map_expected_resource_ids_and_localized_urls() {
        val en = aboutLinks(isChinese = false)
        assertEquals(
            listOf(
                R.string.about_website,
                R.string.about_faq,
                R.string.about_feedback_email,
                R.string.about_feedback_discussions,
                R.string.about_source_code,
                R.string.about_privacy,
            ),
            en.map { it.labelRes },
        )
        assertEquals(
            listOf(
                "https://p-pass.hawkeye-xb.com/",
                "https://p-pass.hawkeye-xb.com/faq/",
                "mailto:ppass@hawkeye-xb.com",
                "https://github.com/hawkeye-xb/P-Pass/discussions",
                "https://github.com/hawkeye-xb/P-Pass",
                "https://p-pass.hawkeye-xb.com/privacy/",
            ),
            en.map { it.url },
        )
        assertEquals(R.string.about_source_license, en.first { it.id == "source" }.valueRes)
        assertEquals("ppass@hawkeye-xb.com", en.first { it.id == "feedback_email" }.literalValue)
        assertEquals("GitHub", en.first { it.id == "feedback_discussions" }.literalValue)

        val zh = aboutLinks(isChinese = true)
        assertEquals(en.map { it.labelRes }, zh.map { it.labelRes })
        assertEquals(
            listOf(
                "https://p-pass.hawkeye-xb.com/zh/",
                "https://p-pass.hawkeye-xb.com/zh/faq/",
                "mailto:ppass@hawkeye-xb.com",
                "https://github.com/hawkeye-xb/P-Pass/discussions",
                "https://github.com/hawkeye-xb/P-Pass",
                "https://p-pass.hawkeye-xb.com/zh/privacy/",
            ),
            zh.map { it.url },
        )
    }

    @Test
    fun app_version_line_formats_with_and_without_build_stamp() {
        assertEquals("0.12.1 (72)", appVersionLine("0.12.1", 72, ""))
        assertEquals("0.12.1 (72)", appVersionLine("0.12.1", 72, "   "))
        assertEquals("0.12.1 (72) 11-26 16:00", appVersionLine("0.12.1", 72, "11-26 16:00"))
    }

    @Test
    fun open_external_url_intent_uses_sendto_for_mailto_and_view_for_https() {
        val mailUri = mockk<Uri>()
        val mailIntent = mockk<Intent>()
        var mailAction: String? = null
        var mailTargetUri: Uri? = null
        val resMail = openExternalUrlIntent(
            url = "mailto:ppass@hawkeye-xb.com",
            parseUri = { mailUri },
            makeIntent = { action, uri ->
                mailAction = action
                mailTargetUri = uri
                mailIntent
            },
        )
        assertEquals(Intent.ACTION_SENDTO, mailAction)
        assertSame(mailUri, mailTargetUri)
        assertSame(mailIntent, resMail)

        val webUri = mockk<Uri>()
        val webIntent = mockk<Intent>()
        var webAction: String? = null
        var webTargetUri: Uri? = null
        val resWeb = openExternalUrlIntent(
            url = "https://p-pass.hawkeye-xb.com/faq/",
            parseUri = { webUri },
            makeIntent = { action, uri ->
                webAction = action
                webTargetUri = uri
                webIntent
            },
        )
        assertEquals(Intent.ACTION_VIEW, webAction)
        assertSame(webUri, webTargetUri)
        assertSame(webIntent, resWeb)
    }
}
