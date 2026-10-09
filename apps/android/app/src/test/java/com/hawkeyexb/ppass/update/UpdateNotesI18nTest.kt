// #741：手写更新说明的客户端侧——清单 notes_i18n 解析（宽松）、按语言选取、拒收兜底。
//
// 反证：把 isSafeUpdateNotes 改成恒 true，下面每个「拒收」用例必红；把 updateNotesLang
// 改成恒 "en"，中文选取用例必红；把 notesI18nMap 的宽松处理去掉（形状不对就抛），
// 「坏形状照常出弹窗」用例必红。
package com.hawkeyexb.ppass.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateNotesI18nTest {

    private val zh = "更新弹窗按 App 语言显示说明。\n修复了一处安全问题，建议尽快更新。"
    private val en = "The update dialog now follows the app language.\nFixed a security issue. Please update soon."

    private fun manifest(extra: String) = """
        {"version":"0.9.10","notes":"中文说明。",$extra
         "platforms":{"android-arm64":{"url":"u","signature":"s","sha256":"h"}}}
    """.trimIndent()

    // ── 清单解析 ──

    @Test
    fun parsesNotesI18n() {
        val body = manifest(""""notes_i18n":{"zh":"中文说明。","en":"English notes."},""")
        val info = parseUpdateManifest(body, "0.9.9")
        assertNotNull(info)
        assertEquals(mapOf("zh" to "中文说明。", "en" to "English notes."), info!!.notesI18n)
        assertEquals("中文说明。", info.notes)
    }

    @Test
    fun legacyManifestWithOnlyNotesStillShows() {
        // 旧格式清单（只有 notes）：照常出更新、照常显示 notes（两种语言都回落到它）
        val info = parseUpdateManifest(manifest(""), "0.9.9")
        assertNotNull(info)
        assertTrue(info!!.notesI18n.isEmpty())
        assertEquals("中文说明。", displayUpdateNotes(info.notesI18n, info.notes, "zh-CN"))
        assertEquals("中文说明。", displayUpdateNotes(info.notesI18n, info.notes, "en-US"))
    }

    @Test
    fun malformedNotesI18nNeverBreaksTheUpdateCheck() {
        // null / 数组 / 值不是字符串：只当没有 notes_i18n，更新照常出、回落 notes
        for (bad in listOf("null", "[1,2]", """{"zh":1,"en":null}""", "\"str\"")) {
            val info = parseUpdateManifest(manifest(""""notes_i18n":$bad,"""), "0.9.9")
            assertNotNull("notes_i18n=$bad 不该让整份清单解析失败", info)
            assertTrue("notes_i18n=$bad", info!!.notesI18n.isEmpty())
            assertEquals("中文说明。", displayUpdateNotes(info.notesI18n, info.notes, "en"))
        }
        // 混合：合法的键保留，非法的丢
        val mixed = parseUpdateManifest(manifest(""""notes_i18n":{"zh":"中。","en":3},"""), "0.9.9")
        assertEquals(mapOf("zh" to "中。"), mixed!!.notesI18n)
    }

    // ── 按语言选取 ──

    @Test
    fun zhFamilyPicksZhOthersPickEn() {
        for (tag in listOf("zh", "zh-CN", "zh-Hans", "zh-Hans-CN", "zh-TW", "zh-Hant-HK", "zh_CN", "ZH-cn")) {
            assertEquals(tag, "zh", updateNotesLang(tag))
        }
        for (tag in listOf("en", "en-US", "fr-FR", "ja", "und", "")) {
            assertEquals(tag, "en", updateNotesLang(tag))
        }
    }

    @Test
    fun selectsByLanguage() {
        val i18n = mapOf("zh" to zh, "en" to en)
        assertEquals(zh, displayUpdateNotes(i18n, zh, "zh-Hans-CN"))
        assertEquals(en, displayUpdateNotes(i18n, zh, "en-US"))
        assertEquals(en, displayUpdateNotes(i18n, zh, "fr-FR"))
    }

    @Test
    fun missingOrBlankLanguageFallsBackToNotesThenDefault() {
        assertEquals(zh, displayUpdateNotes(mapOf("zh" to zh), zh, "en-US"))
        assertEquals(zh, displayUpdateNotes(mapOf("zh" to zh, "en" to "  "), zh, "en"))
        // 什么都没有 ⇒ ""（调用方显示默认文案）
        assertEquals("", displayUpdateNotes(emptyMap(), "", "zh-CN"))
    }

    // ── 拒收：每类一个反例 ──

    private fun assertRejected(label: String, raw: String) {
        assertFalse("$label 应被拒收: $raw", isSafeUpdateNotes(raw))
        // 被选中的那份含禁止内容 ⇒ 整段丢弃、显示默认文案（不回落另一种语言或 notes）
        assertEquals(label, "", displayUpdateNotes(mapOf("zh" to raw, "en" to en), zh, "zh-CN"))
    }

    @Test
    fun cleanNotesAreAccepted() {
        assertTrue(isSafeUpdateNotes(zh))
        assertTrue(isSafeUpdateNotes(en))
        assertTrue(isSafeUpdateNotes("升级到 0.9.10 后，12:30 的定时备份不再跳过。"))
        assertTrue(isSafeUpdateNotes("修复一\r\n修复二\t（旧清单的换行与制表符放行）"))
    }

    @Test fun rejectsUrl() = assertRejected("网址", "详情见 https://evil.example/x")
    @Test fun rejectsUrlHiddenInMarkdownLink() = assertRejected("链接里的网址", "点[这里](https://evil.example)下载")
    @Test fun rejectsUrlGluedToChinese() {
        // 汉字与协议头之间没有空格：java/ICU 的 \b 会把汉字当单词字符而漏判
        assertRejected("贴中文的 IP 网址", "请到https://10.0.0.1下载")
        assertRejected("贴中文的无点主机", "打开http://localhost:8080")
        assertRejected("贴中文的应用市场跳转", "去market://details?id=x")
        assertRejected("贴中文的 www", "去www.evil下载")
    }
    @Test fun schemeWordInsideAnotherWordIsNotAUrl() = assertTrue(isSafeUpdateNotes("Hotel: no change."))
    @Test fun rejectsWww()= assertRejected("www", "访问 www.evil 下载")
    @Test fun rejectsDomain() = assertRejected("域名", "到 evil-mirror.cn 下载新版")
    @Test fun rejectsEmail() = assertRejected("邮箱", "把配对串发到 help@evil")
    @Test fun rejectsFullWidthEmail() = assertRejected("全角邮箱", "联系 help＠evil")
    @Test fun rejectsPhone() = assertRejected("电话", "客服电话 400-123-4567")
    @Test fun rejectsBidiOverride() = assertRejected("双向控制符 U+202E", "修复了‮一处问题")
    @Test fun rejectsBidiIsolate() = assertRejected("双向控制符 U+2066", "修复⁦问题")
    @Test fun rejectsBidiMark() = assertRejected("双向控制符 U+200F / U+061C", "修复‏问؜题")
    @Test fun rejectsZeroWidth() = assertRejected("零宽字符 U+200B", "修复了​一处问题")
    @Test fun rejectsBom() = assertRejected("BOM U+FEFF", "﻿修复了一处问题")
    @Test fun rejectsControlChar() = assertRejected("控制字符 U+0007", "修复了\u0007一处问题")

    @Test
    fun rejectionAppliesToLegacyNotesToo() {
        // 旧清单的 notes（例如 release 正文）含网址 ⇒ 同样整段丢弃
        assertEquals("", displayUpdateNotes(emptyMap(), "构建台账见 https://github.example/x", "zh"))
    }
}
