// UPD-02: HTTP Range 断点续传的计划与协议行为锁。
//  - ResumePlan：0/负 → 不发 Range；N>0 → "bytes=N-"。
//  - 206 = 服务端接受断点 → 追加在残包后面；
//  - 200 = 服务端不理会 Range → 截断从头来（不许把残包当前缀）；
//  - 416 = 残包与远端对不上 → 删残包、摘 Range、完整重试一次，再 416 就如实报。
//  - UPD-19: 206 的 Content-Range 起点 ≠ 残包长度 → 同 416 处理（不许错位拼接）。
package com.hawkeyexb.ppass.update

import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateResumePlanTest {

    private val dir = File(System.getProperty("java.io.tmpdir"), "resume-test-${System.nanoTime()}")
        .apply { mkdirs() }
    private val dest = File(dir, "ppass-update.apk")

    @After
    fun cleanup() {
        dir.deleteRecursively()
    }

    /** 记录请求头的假连接（服务端行为按用例注入）。 */
    private class FakeConn(
        private val code: Int,
        body: ByteArray = ByteArray(0),
        private val headers: Map<String, String> = emptyMap(),
        at: String = "https://example.invalid/ppass.apk",
    ) : HttpURLConnection(URL(at)) {
        private val body = body
        val requestHeaders = mutableMapOf<String, String>()
        override fun setRequestProperty(key: String, value: String) {
            requestHeaders[key] = value
        }
        override fun connect() {}
        override fun getResponseCode(): Int = code
        override fun getHeaderField(name: String): String? = headers[name]
        override fun getInputStream(): InputStream {
            if (code >= 400) throw FileNotFoundException(url.toString())
            return ByteArrayInputStream(body)
        }
        override fun getContentLengthLong(): Long = body.size.toLong()
        override fun disconnect() {}
        override fun usingProxy() = false
    }

    @Test
    fun rangeHeaderOnlyWhenResumableBytesExist() {
        assertNull(ResumePlan(0).rangeHeader)
        assertNull(resumePlanFor(-5).rangeHeader) // 负值按 0 处理，防御落盘损坏
        assertEquals("bytes=1234-", ResumePlan(1234).rangeHeader)
    }

    @Test
    fun http206AppendsToPartialFile() {
        val prefix = ByteArray(100) { 1 }
        dest.writeBytes(prefix)
        val rest = ByteArray(50) { 2 }
        val conn = FakeConn(206, rest)
        val progress = mutableListOf<Pair<Long, Long>>()

        val r = downloadApk(
            "https://example.invalid/ppass.apk", dest,
            open = { conn },
            resumeFromBytes = prefix.size.toLong(),
            onProgress = { received, total -> progress += received to total },
        )

        assertEquals("bytes=100-", conn.requestHeaders["Range"])
        assertEquals(ApkDownloadResult.Ok(150), r)
        assertTrue(dest.readBytes().contentEquals(prefix + rest))
        // 进度以「含断点的总已收 / 总大小」汇报。
        assertEquals(150L to 150L, progress.last())
    }

    @Test
    fun http206WithMatchingContentRangeAppends() {
        val prefix = ByteArray(100) { 1 }
        dest.writeBytes(prefix)
        val rest = ByteArray(50) { 2 }
        val conn = FakeConn(206, rest, headers = mapOf("Content-Range" to "bytes 100-149/150"))

        val r = downloadApk(
            "https://example.invalid/ppass.apk", dest,
            open = { conn },
            resumeFromBytes = 100,
        )

        assertEquals(ApkDownloadResult.Ok(150), r)
        assertTrue(dest.readBytes().contentEquals(prefix + rest))
    }

    @Test
    fun http206WithMisalignedContentRangeRestartsFreshInsteadOfSplicing() {
        dest.writeBytes(ByteArray(100) { 1 }) // 残包 100 字节
        val wrongSlice = ByteArray(50) { 9 }
        val full = ByteArray(120) { 5 }
        val conns = ArrayDeque(
            listOf(
                // 服务端回 206，但给的是从 0 开始的那段——追加就是错位拼接。
                FakeConn(206, wrongSlice, headers = mapOf("Content-Range" to "bytes 0-49/120")),
                FakeConn(200, full),
            )
        )
        val opened = mutableListOf<FakeConn>()

        val r = downloadApk(
            "https://example.invalid/ppass.apk", dest,
            open = { conns.removeFirst().also { opened += it } },
            resumeFromBytes = 100,
        )

        assertEquals(ApkDownloadResult.Ok(120), r)
        assertEquals(2, opened.size)
        assertNull("错位后必须摘掉 Range 完整重下", opened[1].requestHeaders["Range"])
        assertTrue("不许把错位片段拼进残包", dest.readBytes().contentEquals(full))
    }

    @Test
    fun contentRangeStartParsing() {
        assertEquals(100L, contentRangeStartOf("bytes 100-149/150"))
        assertEquals(0L, contentRangeStartOf("bytes 0-49/*"))
        assertNull(contentRangeStartOf(null))
        assertNull(contentRangeStartOf("bytes */150")) // 416 形态，没有起点
    }

    @Test
    fun http200IgnoresRangeAndTruncates() {
        dest.writeBytes(ByteArray(100) { 1 }) // 残包
        val full = ByteArray(80) { 3 }
        val conn = FakeConn(200, full)

        val r = downloadApk(
            "https://example.invalid/ppass.apk", dest,
            open = { conn },
            resumeFromBytes = 100,
        )

        assertEquals(ApkDownloadResult.Ok(80), r)
        assertTrue("服务器不理会 Range 时必须整包覆盖，不许拼接", dest.readBytes().contentEquals(full))
    }

    @Test
    fun http416DeletesPartialAndRetriesFreshOnce() {
        dest.writeBytes(ByteArray(100) { 1 }) // 比远端还大的错位残包
        val full = ByteArray(60) { 4 }
        val conns = ArrayDeque(listOf(FakeConn(416), FakeConn(200, full)))
        val opened = mutableListOf<FakeConn>()

        val r = downloadApk(
            "https://example.invalid/ppass.apk", dest,
            open = { conns.removeFirst().also { opened += it } },
            resumeFromBytes = 100,
        )

        assertEquals(ApkDownloadResult.Ok(60), r)
        assertEquals(2, opened.size)
        assertEquals("bytes=100-", opened[0].requestHeaders["Range"])
        assertNull("重试必须摘掉 Range 头", opened[1].requestHeaders["Range"])
        assertTrue(dest.readBytes().contentEquals(full))
    }

    @Test
    fun persistentHttp416GivesUpAndLeavesNoPartial() {
        dest.writeBytes(ByteArray(100) { 1 })
        var opens = 0
        val r = downloadApk(
            "https://example.invalid/ppass.apk", dest,
            open = { opens++; FakeConn(416) },
            resumeFromBytes = 100,
        )
        assertEquals(ApkDownloadResult.HttpStatus(416), r)
        assertEquals("只完整重试一次", 2, opens)
        assertFalse(dest.exists())
    }
}
