package com.hawkeyexb.ppass.ui

import android.content.Intent
import androidx.compose.ui.text.font.FontWeight
import io.mockk.mockk
import io.mockk.verify
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class WelcomeDesktopLinkTest {
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
    fun welcome_desktop_link_copy_matches_en_and_zh() {
        assertEquals("No desktop app yet? Get the link", stringValue("values", "welcome_desktop_link"))
        assertEquals("还没装电脑端？获取下载链接", stringValue("values-zh", "welcome_desktop_link"))
    }

    @Test
    fun share_text_intent_builds_action_send_chooser_for_desktop_download_url() {
        assertEquals("https://p-pass.hawkeye-xb.com", DESKTOP_DOWNLOAD_URL)
        val send = mockk<Intent>(relaxed = true)
        val chooser = mockk<Intent>()
        var capturedAction: String? = null
        var capturedTarget: Intent? = null
        var capturedTitle: CharSequence? = null

        val result = shareTextIntent(
            text = DESKTOP_DOWNLOAD_URL,
            chooserTitle = "Share to…",
            makeIntent = { action ->
                capturedAction = action
                send
            },
            makeChooser = { target, title ->
                capturedTarget = target
                capturedTitle = title
                chooser
            },
        )

        assertEquals(Intent.ACTION_SEND, capturedAction)
        assertSame(send, capturedTarget)
        assertEquals("Share to…", capturedTitle)
        assertSame(chooser, result)
        verify {
            send.type = "text/plain"
            send.putExtra(Intent.EXTRA_TEXT, "https://p-pass.hawkeye-xb.com")
        }
    }

    @Test
    fun welcome_copy_exists_and_is_distinct_in_en_and_zh() {
        for (key in listOf(
            "welcome_headline",
            "welcome_sub",
            "welcome_step1",
            "welcome_step2",
            "welcome_step3",
            "welcome_scan",
            "scan_manual_link",
            "welcome_desktop_link",
        )) {
            val en = stringValue("values", key)
            val zh = stringValue("values-zh", key)
            assertTrue("en $key 不能为空", en.isNotBlank())
            assertTrue("zh $key 不能为空", zh.isNotBlank())
            assertNotEquals("$key 中英文不应相同", en, zh)
        }
        assertEquals("Can\\'t scan? Pair manually", stringValue("values", "scan_manual_link"))
        assertEquals("无法扫码？手动配对", stringValue("values-zh", "scan_manual_link"))
    }

    @Test
    fun welcome_hierarchy_separates_pairing_group_from_weakened_desktop_footer() {
        val manual = welcomeManualLinkAppearance()
        val desktop = welcomeDesktopLinkAppearance()

        assertEquals("无法扫码保持 Ink60 次级强调色", PPColor.Ink60, manual.color)
        assertEquals("无法扫码保持粗体次级文字按钮", FontWeight.Bold, manual.fontWeight)
        assertTrue("无法扫码与主按钮紧贴（6–8dp）", manual.topGapDp in 6..8)
        assertTrue("无法扫码最小触摸高度 ≥48dp", manual.minTouchHeightDp >= 48)

        assertEquals("还没装电脑端弱化为三级文字 Ink40", PPColor.Ink40, desktop.color)
        assertEquals("还没装电脑端字重降为常规（非 Bold）", FontWeight.Normal, desktop.fontWeight)
        assertTrue("还没装电脑端至少留出 28dp 间距", desktop.topGapDp >= 28)
        assertTrue("还没装电脑端最小触摸高度 ≥48dp", desktop.minTouchHeightDp >= 48)
        assertTrue("页脚退路间距必须大于操作组内间距", desktop.topGapDp > manual.topGapDp)
    }
}
