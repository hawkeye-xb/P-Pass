// NET-09: APK 下载的三种失败（字节停滞 / HTTP 非 200 / 连接失败）必须分得开。
//
// 两组用例：
//  - 假 HttpURLConnection：逐阶段注入异常，钉住「按阶段分类」——尤其是同一个
//    SocketTimeoutException 在 connect 阶段算连接失败、在读阶段才算停滞。
//  - 本机回环真 socket：用 JDK 真实的 HttpURLConnection 确认上面的阶段假设
//    与真实实现一致（拒绝连接在 connect() 抛、等头/读 body 超时是
//    SocketTimeoutException、404 不碰 inputStream）。
package com.hawkeyexb.ppass.update

import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException
import kotlin.concurrent.thread
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NET09ApkDownloadFailureKindsTest {

    private val dir = File(System.getProperty("java.io.tmpdir"), "net09-apk-${System.nanoTime()}").apply { mkdirs() }
    private val dest = File(dir, "ppass-update.apk")

    @After
    fun cleanup() {
        dir.deleteRecursively()
    }

    /** 假连接：每个阶段可单独注入行为。 */
    private class FakeConn(
        private val onConnect: () -> Unit = {},
        private val onResponseCode: () -> Int = { 200 },
        private val body: () -> InputStream = { ByteArrayInputStream(ByteArray(0)) },
        private val length: Long = -1,
        private val headers: Map<String, String> = emptyMap(),
        at: String = "https://example.invalid/ppass.apk",
    ) : HttpURLConnection(URL(at)) {
        var inputStreamTouched = false
        var disconnected = false
        override fun connect() = onConnect()
        override fun getResponseCode(): Int = onResponseCode()
        override fun getInputStream(): InputStream {
            inputStreamTouched = true
            // 与真实实现一致：非 2xx 时 inputStream 抛 IOException。
            if (onResponseCode() >= 400) throw FileNotFoundException(url.toString())
            return body()
        }
        override fun getContentLengthLong(): Long = length
        override fun getHeaderField(name: String): String? = headers[name]
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
    }

    /** 先吐 [chunks] 块、每块 [chunkSize] 字节，然后抛 [then]（null = 正常 EOF）。 */
    private fun chunkedThen(chunks: Int, chunkSize: Int, then: IOException?): InputStream =
        object : InputStream() {
            var served = 0
            override fun read(): Int = throw UnsupportedOperationException()
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (served == chunks) {
                    if (then != null) throw then
                    return -1
                }
                served++
                val n = minOf(len, chunkSize)
                b.fill(7, off, off + n)
                return n
            }
        }

    private fun run(conn: FakeConn) = downloadApk("https://example.invalid/ppass.apk", dest, open = { conn })

    // ── 连接失败：connect 阶段的一切网络异常 ──

    @Test
    fun refusedDnsAndTlsAreConnectionFailures() {
        for (e in listOf(
            ConnectException("Connection refused"),
            UnknownHostException("github.com"),
            SSLHandshakeException("handshake failed"),
        )) {
            val conn = FakeConn(onConnect = { throw e })
            val r = run(conn)
            assertTrue("$e → $r", r is ApkDownloadResult.ConnectionFailed)
            r as ApkDownloadResult.ConnectionFailed
            assertEquals(ApkDownloadResult.Phase.Connect, r.phase)
            assertTrue(r.cause.contains(e.javaClass.simpleName))
            assertFalse(conn.inputStreamTouched)
            assertTrue(conn.disconnected)
        }
    }

    @Test
    fun connectTimeoutIsConnectionFailureNotStall() {
        // 同一个 SocketTimeoutException：connect 阶段 = connectTimeout = 连不上。
        val r = run(FakeConn(onConnect = { throw SocketTimeoutException("connect timed out") }))
        assertTrue("$r", r is ApkDownloadResult.ConnectionFailed)
        assertEquals(ApkDownloadResult.Phase.Connect, (r as ApkDownloadResult.ConnectionFailed).phase)
    }

    // ── 字节停滞：连上之后 readTimeout 触发 ──

    @Test
    fun headersNeverArriveIsStall() {
        val r = run(FakeConn(onResponseCode = { throw SocketTimeoutException("Read timed out") }))
        assertEquals(
            ApkDownloadResult.Stalled(ApkDownloadResult.Phase.Headers, 0, APK_READ_TIMEOUT_MS),
            r,
        )
    }

    @Test
    fun bodyStopsAfterTwoChunksIsStallWithReceivedBytesAndNoLeftover() {
        val conn = FakeConn(
            body = { chunkedThen(2, 16 * 1024, SocketTimeoutException("Read timed out")) },
            length = 10L * 1024 * 1024,
        )
        val r = run(conn)
        assertEquals(
            ApkDownloadResult.Stalled(ApkDownloadResult.Phase.Body, 32L * 1024, APK_READ_TIMEOUT_MS),
            r,
        )
        assertFalse("半个 APK 不能留在 cache 里", dest.exists())
    }

    // ── HTTP 非 200：看状态码，不碰 inputStream ──

    @Test
    fun non200IsHttpStatusAndInputStreamIsNeverTouched() {
        for (code in listOf(404, 403, 500, 503)) {
            val conn = FakeConn(onResponseCode = { code })
            val r = run(conn)
            assertEquals(ApkDownloadResult.HttpStatus(code), r)
            assertFalse("非 200 不该去读 inputStream（会被误记成网络失败）", conn.inputStreamTouched)
        }
    }

    // ── 其余失败不得冒充上面三类 ──

    @Test
    fun midBodyResetIsConnectionFailureInBodyPhase() {
        val r = run(FakeConn(body = { chunkedThen(1, 1024, IOException("Connection reset")) }))
        assertTrue("$r", r is ApkDownloadResult.ConnectionFailed)
        r as ApkDownloadResult.ConnectionFailed
        assertEquals(ApkDownloadResult.Phase.Body, r.phase)
        assertEquals(1024L, r.receivedBytes)
    }

    @Test
    fun cleanEofShorterThanContentLengthIsNotOk() {
        val r = run(FakeConn(body = { chunkedThen(3, 1000, null) }, length = 5000))
        assertTrue("$r", r is ApkDownloadResult.ConnectionFailed)
        assertEquals(3000L, (r as ApkDownloadResult.ConnectionFailed).receivedBytes)
        assertFalse(dest.exists())
    }

    @Test
    fun localWriteFailureIsNotANetworkFailure() {
        dest.mkdirs() // 目标是目录 → outputStream() 抛 FileNotFoundException
        val r = run(FakeConn(body = { chunkedThen(1, 10, null) }))
        assertTrue("$r", r is ApkDownloadResult.LocalWriteFailed)
    }

    @Test
    fun runtimeExceptionIsUnexpectedAndDoesNotEscape() {
        val r = run(FakeConn(onConnect = { throw IllegalStateException("boom") }))
        assertTrue("$r", r is ApkDownloadResult.Unexpected)
    }

    @Test
    fun completeBodyIsOkAndLandsOnDisk() {
        val conn = FakeConn(body = { chunkedThen(4, 1000, null) }, length = 4000)
        val r = run(conn)
        assertEquals(ApkDownloadResult.Ok(4000), r)
        assertEquals(4000L, dest.length())
        assertEquals(APK_READ_TIMEOUT_MS, conn.readTimeout)
        assertEquals(APK_CONNECT_TIMEOUT_MS, conn.connectTimeout)
    }

    @Test
    fun logLinesNameTheCategory() {
        val url = "https://example.invalid/ppass.apk"
        val stall = ApkDownloadResult.Stalled(ApkDownloadResult.Phase.Body, 32768, 30000).logLine(url)
        assertTrue(stall, stall.contains("STALLED") && stall.contains("30000ms") && stall.contains("32768"))
        val http = ApkDownloadResult.HttpStatus(404).logLine(url)
        assertTrue(http, http.contains("HTTP 404"))
        val conn = ApkDownloadResult.ConnectionFailed(ApkDownloadResult.Phase.Connect, 0, "java.net.ConnectException: refused")
            .logLine(url)
        assertTrue(conn, conn.contains("CONNECTION FAILED") && conn.contains("connect") && conn.contains("ConnectException"))
    }

    // ── 重定向：生产 URL 是 GitHub 资产 → 302 → CDN，阶段必须逐跳判 ──

    @Test
    fun cdnConnectTimeoutAfterRedirectIsConnectionFailureNotStall() {
        val opened = mutableListOf<String>()
        val hops = ArrayDeque(listOf(
            FakeConn(onResponseCode = { 302 }, headers = mapOf("Location" to "https://cdn.invalid/blob?sig=1")),
            FakeConn(onConnect = { throw SocketTimeoutException("connect timed out") }),
        ))
        val r = downloadApk("https://example.invalid/ppass.apk", dest, open = { opened += it; hops.removeFirst() })
        assertEquals(listOf("https://example.invalid/ppass.apk", "https://cdn.invalid/blob?sig=1"), opened)
        assertTrue("$r", r is ApkDownloadResult.ConnectionFailed)
        assertEquals(ApkDownloadResult.Phase.Connect, (r as ApkDownloadResult.ConnectionFailed).phase)
    }

    @Test
    fun redirectLoopStopsAtCapAndReportsTheStatus() {
        var opens = 0
        val r = downloadApk("https://example.invalid/ppass.apk", dest, open = {
            opens++
            FakeConn(onResponseCode = { 302 }, headers = mapOf("Location" to "/again"))
        })
        assertEquals(ApkDownloadResult.HttpStatus(302), r)
        assertEquals(APK_MAX_REDIRECTS + 1, opens)
    }

    // ── 真 socket：JDK HttpURLConnection 的阶段行为与假连接的假设一致 ──

    private fun realOpen(url: String) = URL(url).openConnection() as HttpURLConnection

    @Test
    fun realRefusedPortIsConnectionFailure() {
        val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val r = downloadApk("http://127.0.0.1:$port/ppass.apk", dest, ::realOpen, readTimeoutMs = 500)
        assertTrue("$r", r is ApkDownloadResult.ConnectionFailed)
        assertEquals(ApkDownloadResult.Phase.Connect, (r as ApkDownloadResult.ConnectionFailed).phase)
    }

    /** 回环 HTTP 服务：收到请求后执行 [respond]，然后挂住直到测试结束。 */
    private fun serve(respond: (java.io.OutputStream) -> Unit, block: (Int) -> Unit) {
        val release = CountDownLatch(1)
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val t = thread(isDaemon = true) {
                runCatching {
                    server.accept().use { s ->
                        val input = s.getInputStream().bufferedReader()
                        while (input.readLine()?.isNotEmpty() == true) Unit
                        respond(s.getOutputStream())
                        s.getOutputStream().flush()
                        release.await(10, TimeUnit.SECONDS)
                    }
                }
            }
            try {
                block(server.localPort)
            } finally {
                release.countDown()
                t.join(2000)
            }
        }
    }

    @Test
    fun realHeadersNeverArriveIsStall() = serve({ /* 一个字节都不回 */ }) { port ->
        val r = downloadApk("http://127.0.0.1:$port/ppass.apk", dest, ::realOpen, readTimeoutMs = 500)
        assertEquals(ApkDownloadResult.Stalled(ApkDownloadResult.Phase.Headers, 0, 500), r)
    }

    @Test
    fun realBodyStallsAfterSomeBytesIsStall() = serve({ out ->
        out.write("HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n".toByteArray())
        out.write(ByteArray(2048))
    }) { port ->
        val r = downloadApk("http://127.0.0.1:$port/ppass.apk", dest, ::realOpen, readTimeoutMs = 500)
        assertEquals(ApkDownloadResult.Stalled(ApkDownloadResult.Phase.Body, 2048, 500), r)
        assertFalse(dest.exists())
    }

    @Test
    fun real404IsHttpStatus() = serve({ out ->
        out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".toByteArray())
    }) { port ->
        val r = downloadApk("http://127.0.0.1:$port/ppass.apk", dest, ::realOpen, readTimeoutMs = 500)
        assertEquals(ApkDownloadResult.HttpStatus(404), r)
    }

    private fun redirectTo(target: String): (java.io.OutputStream) -> Unit = { out ->
        out.write("HTTP/1.1 302 Found\r\nLocation: $target\r\nContent-Length: 0\r\n\r\n".toByteArray())
    }

    @Test
    fun realRedirectToRefusedHostIsConnectionFailureInConnectPhase() {
        val closed = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        serve(redirectTo("http://127.0.0.1:$closed/blob")) { port ->
            val r = downloadApk("http://127.0.0.1:$port/ppass.apk", dest, ::realOpen, readTimeoutMs = 500)
            assertTrue("$r", r is ApkDownloadResult.ConnectionFailed)
            assertEquals(ApkDownloadResult.Phase.Connect, (r as ApkDownloadResult.ConnectionFailed).phase)
        }
    }

    @Test
    fun realRedirectToSilentHostIsStallInHeadersPhase() = serve({ /* CDN 一个字节都不回 */ }) { cdn ->
        serve(redirectTo("http://127.0.0.1:$cdn/blob")) { port ->
            val r = downloadApk("http://127.0.0.1:$port/ppass.apk", dest, ::realOpen, readTimeoutMs = 500)
            assertEquals(ApkDownloadResult.Stalled(ApkDownloadResult.Phase.Headers, 0, 500), r)
        }
    }

    @Test
    fun realRedirectToOkHostDownloads() = serve({ out ->
        out.write("HTTP/1.1 200 OK\r\nContent-Length: 3000\r\n\r\n".toByteArray())
        out.write(ByteArray(3000))
    }) { cdn ->
        serve(redirectTo("http://127.0.0.1:$cdn/blob")) { port ->
            val r = downloadApk("http://127.0.0.1:$port/ppass.apk", dest, ::realOpen, readTimeoutMs = 2000)
            assertEquals(ApkDownloadResult.Ok(3000), r)
            assertEquals(3000L, dest.length())
        }
    }
}
