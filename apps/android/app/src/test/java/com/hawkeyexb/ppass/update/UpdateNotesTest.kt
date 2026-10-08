// UPD-03（#580）：更新弹窗正文的清洗与截断。
// 现象：弹窗直接 take(200) 展示 release 正文，`##`、`**`、反引号、`>` 原样露出，
// 并在第 200 个字符处半个词/半句话截断。这里锁住：输出无 markdown 记号、
// 截断落在句/词边界、空或纯符号输入回落（返回 ""，由弹窗显示默认文案）。
package com.hawkeyexb.ppass.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateNotesTest {

    /** 0.6.2-test.x 时期的 release 正文骨架（#580 截图里的那段），即旧 manifest 的 notes。 */
    private val skeleton = """
        ## P-Pass 0.6.2-test.1

        构建自 `9a19b9e` · 2026-09-30T08:00:00Z

        > 各平台产物正在陆续上传（Android 最快，Windows 最慢——vcpkg 首次
        > 从源码编 libheif）。签名状态与资产 SHA-256 在全部平台就绪后补齐。

        ### 面向人类的资产（H-10c）
        - **P-Pass-macos-arm64.dmg** — macOS 桌面 App
        - **P-Pass-android.apk** — Android APK（keystore 签名，可直接安装）
    """.trimIndent()

    private fun assertNoMarkdown(s: String) {
        assertFalse("含 ##: $s", s.contains("#"))
        assertFalse("含 **: $s", s.contains("**"))
        assertFalse("含反引号: $s", s.contains("`"))
        assertFalse("含行首 >: $s", s.lines().any { it.trimStart().startsWith(">") })
        assertFalse("含链接语法: $s", s.contains("]("))
    }

    @Test
    fun stripsHeadingsBoldCodeQuotes() {
        val out = userFacingNotes(skeleton)
        assertNoMarkdown(out)
        assertTrue(out, out.startsWith("P-Pass 0.6.2-test.1\n"))
        assertTrue(out, out.contains("构建自 9a19b9e"))
        assertTrue(out, out.contains("各平台产物正在陆续上传"))
    }

    @Test
    fun bulletsLinksAndIssueRefsBecomePlainText() {
        val out = userFacingNotes(
            """
            ### Fixed
            - 磁盘写满时不再被误报成「照片库文件夹无法打开」。(#555)
            * 详见 [排障文档](https://example.com/doc)（#667、#732）。
            1. 第三条用 _斜体_ 强调。
            """.trimIndent(),
        )
        assertEquals(
            "Fixed\n· 磁盘写满时不再被误报成「照片库文件夹无法打开」。\n· 详见 排障文档。\n· 第三条用 斜体 强调。",
            out,
        )
    }

    @Test
    fun shortCleanTextIsUnchanged() {
        val s = "· 更新弹窗不再显示 markdown 原文。"
        assertEquals(s, userFacingNotes(s))
    }

    @Test
    fun truncatesAtChineseSentenceEnd() {
        val first = "第一句说明更新内容。".repeat(12) // 120 字，以句号结尾
        val tail = "第二段很长没有句号" + "字".repeat(200)
        val out = userFacingNotes(first + tail)
        assertTrue("应以省略号结尾: $out", out.endsWith("…"))
        assertEquals("截在最后一个句号之后", "$first…", out)
        assertTrue(out.length <= UPDATE_NOTES_MAX_CHARS + 1)
    }

    @Test
    fun truncatesAtEnglishWordBoundary() {
        val words = (1..80).joinToString(" ") { "word$it" } // 远超 200 字符，无句号
        val out = userFacingNotes(words)
        assertTrue(out, out.endsWith("…"))
        val body = out.removeSuffix("…")
        assertTrue("不得超过上限: ${body.length}", body.length <= UPDATE_NOTES_MAX_CHARS)
        // 截断点之前是完整的词：去掉省略号后的最后一个词必须是原文里的一个完整词
        val last = body.trimEnd().substringAfterLast(' ')
        assertTrue("最后一个词被切断: $last", words.split(' ').contains(last))
    }

    @Test
    fun hardCutOnlyWhenNoBoundaryAndNeverSplitsSurrogatePair() {
        val noBoundary = "字".repeat(199) + "😀" + "字".repeat(50)
        val out = userFacingNotes(noBoundary)
        assertTrue(out.endsWith("…"))
        val body = out.removeSuffix("…")
        assertFalse("不得留下半个代理对", body.last().isHighSurrogate())
        assertTrue(body.length <= UPDATE_NOTES_MAX_CHARS)
    }

    @Test
    fun skeletonIsCutOnBoundaryNotMidWord() {
        // 旧实现 take(200) 在「· P-Pass-macos-arm64.dmg — macOS 桌面 App\n· **P-Pass-and」这类
        // 位置硬切；现在退到最近的行尾（换行算句界），整行保留、加省略号。
        val expected = """
            P-Pass 0.6.2-test.1

            构建自 9a19b9e · 2026-09-30T08:00:00Z

            各平台产物正在陆续上传（Android 最快，Windows 最慢——vcpkg 首次
            从源码编 libheif）。签名状态与资产 SHA-256 在全部平台就绪后补齐。

            面向人类的资产（H-10c）
            · P-Pass-macos-arm64.dmg — macOS 桌面 App…
        """.trimIndent()
        assertEquals(expected, userFacingNotes(skeleton))
    }

    @Test
    fun backslashEscapesAreUnescaped() {
        // v2026.10.2 线上 manifest-android.json 的 notes 里就有 `\<macOS 版本\>` 这种转义。
        val out = userFacingNotes("- **P-Pass_\\<Android 版本\\>_android.apk** — Android APK")
        assertEquals("· P-Pass_<Android 版本>_android.apk — Android APK", out)
    }

    @Test
    fun emptyOrSymbolOnlyFallsBackToDefault() {
        assertEquals("", userFacingNotes(""))
        assertEquals("", userFacingNotes("   \n\n "))
        assertEquals("", userFacingNotes("## \n---\n> \n- \n**  **\n``"))
    }

    @Test
    fun crlfInputHandled() {
        assertEquals("标题\n· 一条", userFacingNotes("## 标题\r\n- 一条\r\n"))
    }
}
