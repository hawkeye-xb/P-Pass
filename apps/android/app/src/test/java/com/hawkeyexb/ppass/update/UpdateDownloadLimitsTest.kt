// #1151：更新清单 / 安装包的大小上限与总时长上限（TUF 的 endless data / slow retrieval）。
//
// 每条上限都有反证：同样的输入在上限之内必须照常成功（对照），超出上限必须中止；
// 把 downloadApk / readTextBounded 的上限判断拿掉，对应用例必红。
package com.hawkeyexb.ppass.update

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateDownloadLimitsTest {

    private companion object {
        const val HARD_CAP = 4L * 1024 * 1024
    }

    private val dir = File(System.getProperty("java.io.tmpdir"), "upd1151-${System.nanoTime()}").apply { mkdirs() }
    private val dest = File(dir, "ppass-update.apk")

    @After
    fun cleanup() {
        dir.deleteRecursively()
    }

    private class Conn(
        private val body: () -> InputStream,
        private val length: Long = -1,
    ) : HttpURLConnection(URL("https://example.invalid/ppass.apk")) {
        var inputStreamTouched = false
        override fun connect() {}
        override fun getResponseCode(): Int = 200
        override fun getInputStream(): InputStream {
            inputStreamTouched = true
            return body()
        }
        override fun getContentLengthLong(): Long = length
        override fun getHeaderField(name: String): String? = null
        override fun disconnect() {}
        override fun usingProxy() = false
    }

    /**
     * 「无限长」的流（chunked、不声明长度的恶意 / 故障源）。每次读可以让假时钟前进。
     * **自带硬上限**：喂到 [HARD_CAP] 字节就抛 IOException——被测代码若丢了上限判断（做变异反证时），
     * 测试也只会失败，不会把磁盘 / 内存写爆。
     */
    private fun endless(clock: (() -> Unit)? = null): InputStream = object : InputStream() {
        private var served = 0L
        override fun read(): Int = throw UnsupportedOperationException()
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            clock?.invoke()
            if (served >= HARD_CAP) throw java.io.IOException("test guard: stream exceeded $HARD_CAP bytes")
            val n = minOf(len, 1024)
            b.fill(1, off, off + n)
            served += n
            return n
        }
    }

    // ── 清单 ──

    @Test
    fun manifestWithinLimitIsRead() {
        val r = readTextBounded(ByteArrayInputStream("""{"version":"1.0.0"}""".toByteArray()), 1024, 1_000)
        assertEquals(BoundedRead.Text("""{"version":"1.0.0"}"""), r)
    }

    @Test
    fun endlessManifestIsCutAtSizeLimit() {
        val r = readTextBounded(endless(), maxBytes = 64 * 1024, timeoutMs = 60_000)
        assertEquals(BoundedRead.TooLarge(64 * 1024), r)
    }

    @Test
    fun manifestExactlyAtLimitIsStillRead() {
        val r = readTextBounded(ByteArrayInputStream(ByteArray(2048) { 'a'.code.toByte() }), 2048, 1_000)
        assertTrue(r is BoundedRead.Text)
    }

    @Test
    fun slowManifestIsCutAtTotalTimeLimit() {
        var t = 0L
        // 每读一块过去 10 秒：字节一直在来（readTimeout 不会触发），但总时长超了。
        val r = readTextBounded(endless { t += 10_000 }, maxBytes = Long.MAX_VALUE, timeoutMs = 30_000, nowMs = { t })
        assertEquals(BoundedRead.TimedOut, r)
    }

    @Test
    fun productionManifestLimitsAreSane() {
        assertTrue(MANIFEST_MAX_BYTES in 64 * 1024..16L * 1024 * 1024)
        assertTrue(MANIFEST_TOTAL_TIMEOUT_MS in 5_000..120_000)
    }

    // ── 安装包 ──

    @Test
    fun declaredLengthOverLimitAbortsBeforeReadingBody() {
        val conn = Conn({ endless() }, length = 10_000)
        val r = downloadApk("https://example.invalid/ppass.apk", dest, open = { conn }, maxBytes = 5_000)
        assertEquals(ApkDownloadResult.LimitExceeded(ApkDownloadResult.Limit.Size, 0), r)
        assertFalse("声明超限就不该碰 body", conn.inputStreamTouched)
        assertFalse(dest.exists())
    }

    @Test
    fun undeclaredLengthOverLimitIsCutMidBodyAndPartialIsDeleted() {
        val conn = Conn({ endless() }) // 不声明长度
        val r = downloadApk("https://example.invalid/ppass.apk", dest, open = { conn }, maxBytes = 8 * 1024)
        assertTrue(r is ApkDownloadResult.LimitExceeded && r.limit == ApkDownloadResult.Limit.Size)
        assertFalse("大小超限不是瞬时故障，残包要删", dest.exists())
        assertFalse(isTransientDownloadFailure(r))
        assertEquals(DownloadVerdict.GiveUp, retryVerdictOf(r, runAttemptCount = 0))
    }

    @Test
    fun lyingShortContentLengthDoesNotBypassTheLimit() {
        // 声明 100 字节、实际无限长：按实际收到的字节卡。
        val conn = Conn({ endless() }, length = 100)
        val r = downloadApk("https://example.invalid/ppass.apk", dest, open = { conn }, maxBytes = 8 * 1024)
        assertTrue(r is ApkDownloadResult.LimitExceeded)
    }

    @Test
    fun resumeBytesCountTowardTheSizeLimit() {
        dest.writeBytes(ByteArray(6_000))
        val conn = object : HttpURLConnection(URL("https://example.invalid/ppass.apk")) {
            override fun connect() {}
            override fun getResponseCode() = 206
            override fun getInputStream(): InputStream = endless()
            override fun getContentLengthLong(): Long = -1
            override fun getHeaderField(name: String): String? = if (name == "Content-Range") "bytes 6000-" else null
            override fun disconnect() {}
            override fun usingProxy() = false
        }
        val r = downloadApk("https://example.invalid/ppass.apk", dest, open = { conn }, resumeFromBytes = 6_000, maxBytes = 8_000)
        assertTrue("断点已有的 6000 字节要算进上限", r is ApkDownloadResult.LimitExceeded)
    }

    @Test
    fun slowDownloadIsCutAtTotalTimeLimitAndPartialIsKeptForResume() {
        var t = 0L
        val conn = Conn({ endless { t += 10 * 60_000 } }) // 每块 10 分钟：字节在来，但整次超过 1 小时
        val r = downloadApk(
            "https://example.invalid/ppass.apk", dest, open = { conn },
            maxBytes = Long.MAX_VALUE, totalTimeoutMs = 60 * 60_000L, nowMs = { t },
        )
        assertTrue(r is ApkDownloadResult.LimitExceeded && r.limit == ApkDownloadResult.Limit.Time)
        assertTrue("总时长超限是瞬时故障：残包留给下一跑续传", dest.exists())
        assertTrue(isTransientDownloadFailure(r))
        assertEquals(DownloadVerdict.Retry, retryVerdictOf(r, runAttemptCount = 0))
    }

    @Test
    fun withinLimitsTheDownloadStillSucceeds() {
        val body = ByteArray(4_000) { 3 }
        val conn = Conn({ ByteArrayInputStream(body) }, length = body.size.toLong())
        val r = downloadApk("https://example.invalid/ppass.apk", dest, open = { conn }, maxBytes = 8_000)
        assertEquals(ApkDownloadResult.Ok(4_000), r)
        assertEquals(4_000, dest.length())
    }

    @Test
    fun failureKindsAndLogLine() {
        assertEquals(UpdateFailureKind.Server, failureKindOf(ApkDownloadResult.LimitExceeded(ApkDownloadResult.Limit.Size, 1)))
        assertEquals(UpdateFailureKind.Stalled, failureKindOf(ApkDownloadResult.LimitExceeded(ApkDownloadResult.Limit.Time, 1)))
        assertTrue(ApkDownloadResult.LimitExceeded(ApkDownloadResult.Limit.Size, 5).logLine("u").contains("size limit"))
    }

    @Test
    fun productionPackageLimitsAreSane() {
        // 当前 APK 约 42–58MB：上限要留足余量，又不能大到失去意义。
        assertTrue(APK_MAX_BYTES in 128L * 1024 * 1024..1024L * 1024 * 1024)
        assertTrue(APK_TOTAL_TIMEOUT_MS >= 30 * 60_000L)
    }
}
