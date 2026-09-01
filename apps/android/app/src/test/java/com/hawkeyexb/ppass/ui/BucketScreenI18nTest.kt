package com.hawkeyexb.ppass.ui

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class BucketScreenI18nTest {
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
    fun unnamed_bucket_card_uses_localized_resource() {
        val source = File(
            repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt",
        ).readText()

        assertTrue(
            "BucketCard must localize a null bucket name",
            source.contains("bucket.name ?: stringResource(R.string.bucket_unnamed)"),
        )
    }

    @Test
    fun unnamed_bucket_has_english_and_chinese_translations() {
        assertEquals("Unnamed", stringValue("values", "bucket_unnamed"))
        assertEquals("未命名", stringValue("values-zh", "bucket_unnamed"))
    }
}
