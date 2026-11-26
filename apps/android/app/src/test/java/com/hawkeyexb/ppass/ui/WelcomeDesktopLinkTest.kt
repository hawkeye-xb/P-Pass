package com.hawkeyexb.ppass.ui

import android.content.Intent
import io.mockk.mockk
import io.mockk.verify
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
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
}
