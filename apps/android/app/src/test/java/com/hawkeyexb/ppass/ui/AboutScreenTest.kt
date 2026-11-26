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
    fun about_copy_exists_in_en_and_zh() {
        assertEquals("About", stringValue("values", "about_label"))
        assertEquals("关于", stringValue("values-zh", "about_label"))
        assertEquals("A cross-platform family photo hub, without the server setup.", stringValue("values", "about_tagline").replace("\\'", "'"))
        assertEquals("跨生态家庭的照片中心，不用自己搭服务器。", stringValue("values-zh", "about_tagline"))
        assertEquals("AGPL-3.0", stringValue("values", "about_source_license"))
        assertEquals("AGPL-3.0", stringValue("values-zh", "about_source_license"))
        for (key in listOf(
            "about_website",
            "about_faq",
            "about_feedback_email",
            "about_feedback_discussions",
            "about_source_code",
            "about_privacy",
        )) {
            assertTrue("$key en non-empty", stringValue("values", key).isNotBlank())
            assertTrue("$key zh non-empty", stringValue("values-zh", key).isNotBlank())
        }
    }

    @Test
    fun chinese_locale_detection_matches_zh_only() {
        assertTrue(isChineseLocale(Locale.SIMPLIFIED_CHINESE))
        assertTrue(isChineseLocale(Locale("zh", "TW")))
        assertFalse(isChineseLocale(Locale.US))
        assertFalse(isChineseLocale(Locale.JAPAN))
    }

    @Test
    fun about_links_match_language_and_include_all_required_entries() {
        val en = aboutLinks(isChinese = false)
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

        val zh = aboutLinks(isChinese = true)
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
