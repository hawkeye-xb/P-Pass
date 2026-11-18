package com.hawkeyexb.ppass.ui

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    /** #1788：范围页相册提示的动作分流——系统还肯弹框（rationale=true）就申请；不再弹框（被锁）改「去设置」。 */
    @Test
    fun notice_action_follows_whether_the_system_still_prompts() {
        assertFalse("还肯弹框：动作是页内申请", albumNoAccessNoticeOpensSettings(canPrompt = true))
        assertTrue("不再弹框（问过至少一次后被锁）：动作改「去设置」", albumNoAccessNoticeOpensSettings(canPrompt = false))
    }

    /** #1788：被锁那档复用状态卡的「去设置」词条（同一个目的地同一个词），两种语言都得有。 */
    @Test
    fun locked_notice_action_uses_the_same_copy_as_the_blocked_hero() {
        assertEquals("Open settings", stringValue("values", "auto_backup_blocked_action"))
        assertEquals("去设置", stringValue("values-zh", "auto_backup_blocked_action"))
    }
}
