// UPD-19: 更新下载产物的两条锁（走 Worker 真实流程 runUpdateDownload，只把网络
// 换成假连接、把验签换成可注入的判定）：
//  1. 可重试失败（停滞 / 断连）后残包保留，下一跑请求带 `Range: bytes=N-` 续传；
//     不可重试（4xx、写盘失败、次数用尽）与校验失败仍删包。
//  2. 残包 / 完成标记属于 v1 时，以 v2 跑必须先清掉——不许拿 v1 整包去验 v2，
//     不许把 v2 的后半段 Range 接到 v1 的半包上，必须完整下载。
package com.hawkeyexb.ppass.update

import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UPD19UpdateDownloadArtifactsTest {

    private val dir = File(System.getProperty("java.io.tmpdir"), "upd19-${System.nanoTime()}")
    private val apk = updateApkFile(dir).apply { parentFile?.mkdirs() }
    private val marker = completeMarkerFile(dir)
    private val idFile = artifactIdentityFile(dir)

    private val url = "https://example.invalid/ppass.apk"
    private val v1 = downloadIdentityOf("0.9.2", "https://example.invalid/v1.apk", "aa".repeat(32))
    private val v2 = downloadIdentityOf("0.9.3", url, "bb".repeat(32))

    @After
    fun cleanup() {
        dir.deleteRecursively()
    }

    /** 假连接：状态码 / 响应头 / body 按用例注入，记录请求头。 */
    private class FakeConn(
        private val code: Int,
        private val body: () -> InputStream = { ByteArrayInputStream(ByteArray(0)) },
        private val length: Long = -1,
        private val headers: Map<String, String> = emptyMap(),
    ) : HttpURLConnection(URL("https://example.invalid/ppass.apk")) {
        val requestHeaders = mutableMapOf<String, String>()
        override fun setRequestProperty(key: String, value: String) {
            requestHeaders[key] = value
        }
        override fun connect() {}
        override fun getResponseCode(): Int = code
        override fun getHeaderField(name: String): String? = headers[name]
        override fun getInputStream(): InputStream {
            if (code >= 400) throw FileNotFoundException(url.toString())
            return body()
        }
        override fun getContentLengthLong(): Long = length
        override fun disconnect() {}
        override fun usingProxy() = false
    }

    /** 先吐 [bytes]，再抛 [failure]（null = 正常 EOF）。 */
    private fun bodyThen(bytes: ByteArray, failure: IOException?): InputStream =
        object : InputStream() {
            private var pos = 0
            override fun read(): Int = throw UnsupportedOperationException()
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (pos < bytes.size) {
                    val n = minOf(len, bytes.size - pos)
                    System.arraycopy(bytes, pos, b, off, n)
                    pos += n
                    return n
                }
                if (failure != null) throw failure
                return -1
            }
        }

    private val full = ByteArray(4000) { (it % 251).toByte() }

    /** 跑一次 Worker 流程；[conns] 依次作为每次 open 的连接，[opened] 收集它们。 */
    private fun run(
        identity: String,
        conns: List<FakeConn>,
        opened: MutableList<FakeConn> = mutableListOf(),
        runAttemptCount: Int = 0,
        verify: (File) -> ApkVerifier.Result = { f ->
            if (f.readBytes().contentEquals(full)) ApkVerifier.Result.Ok
            else ApkVerifier.Result.Sha256Mismatch("expected", "actual")
        },
    ): DownloadSettlement {
        val queue = ArrayDeque(conns)
        return runUpdateDownload(
            apk, marker, idFile, identity, runAttemptCount,
            fetch = { resume ->
                downloadApk(url, apk, open = { queue.removeFirst().also { opened += it } }, resumeFromBytes = resume)
            },
            verify = verify,
        )
    }

    // ── 1. 可重试失败保留残包并续传 ──

    @Test
    fun stallKeepsPartialAndNextRunResumesWithRange() {
        val first = mutableListOf<FakeConn>()
        val r1 = run(
            v2,
            listOf(FakeConn(200, { bodyThen(full.copyOf(1500), SocketTimeoutException("Read timed out")) }, 4000)),
            first,
        )
        assertEquals(DownloadSettlement.RetryKeepingPartial, r1)
        assertEquals("停滞后残包必须保留给续传", 1500L, apk.length())
        assertFalse(marker.exists())

        val second = mutableListOf<FakeConn>()
        val rest = full.copyOfRange(1500, 4000)
        val r2 = run(
            v2,
            listOf(
                FakeConn(206, { ByteArrayInputStream(rest) }, rest.size.toLong(), mapOf("Content-Range" to "bytes 1500-3999/4000")),
            ),
            second,
            runAttemptCount = 1,
        )
        assertEquals("bytes=1500-", second.single().requestHeaders["Range"])
        assertEquals(DownloadSettlement.Verified(4000), r2)
        assertTrue(apk.readBytes().contentEquals(full))
        assertTrue(marker.isFile)
    }

    @Test
    fun midBodyResetKeepsPartialAndNextRunResumesWithRange() {
        val r1 = run(v2, listOf(FakeConn(200, { bodyThen(full.copyOf(700), IOException("Connection reset")) }, 4000)))
        assertEquals(DownloadSettlement.RetryKeepingPartial, r1)
        assertEquals(700L, apk.length())

        val second = mutableListOf<FakeConn>()
        val rest = full.copyOfRange(700, 4000)
        run(v2, listOf(FakeConn(206, { ByteArrayInputStream(rest) }, rest.size.toLong())), second, runAttemptCount = 1)
        assertEquals("bytes=700-", second.single().requestHeaders["Range"])
    }

    @Test
    fun retryable5xxKeepsExistingPartial() {
        apk.writeBytes(full.copyOf(1000))
        idFile.writeText(v2)
        val r = run(v2, listOf(FakeConn(503)))
        assertEquals(DownloadSettlement.RetryKeepingPartial, r)
        assertEquals("5xx 没碰残包，下一跑接着续", 1000L, apk.length())
    }

    // ── 1'. 不可重试 / 校验失败照旧删包 ──

    @Test
    fun http404DeletesPartial() {
        apk.writeBytes(full.copyOf(1000))
        idFile.writeText(v2)
        val r = run(v2, listOf(FakeConn(404)))
        assertEquals(DownloadSettlement.Failed(UpdateFailureKind.Server), r)
        assertFalse(apk.exists())
    }

    @Test
    fun localWriteFailureGivesUpWithoutRetry() {
        idFile.writeText(v2) // 同身份：认领不动它
        apk.mkdirs() // 目标是目录 → 打开输出流失败
        val r = run(v2, listOf(FakeConn(200, { ByteArrayInputStream(full) }, 4000)))
        assertEquals(DownloadSettlement.Failed(UpdateFailureKind.Write), r)
    }

    @Test
    fun stallWithAttemptsExhaustedDeletesPartial() {
        val r = run(
            v2,
            listOf(FakeConn(200, { bodyThen(full.copyOf(1500), SocketTimeoutException("Read timed out")) }, 4000)),
            runAttemptCount = UpdateDownloadWorker.MAX_RUN_ATTEMPTS - 1,
        )
        assertEquals(DownloadSettlement.Failed(UpdateFailureKind.Stalled), r)
        assertFalse("次数用尽 = 放弃这条线，残包删干净", apk.exists())
    }

    @Test
    fun verifyFailureDeletesApkAndMarker() {
        val r = run(
            v2,
            listOf(FakeConn(200, { ByteArrayInputStream(full) }, 4000)),
            verify = { ApkVerifier.Result.NoSignature },
        )
        assertEquals(DownloadSettlement.Failed(UpdateFailureKind.Verify), r)
        assertFalse(apk.exists())
        assertFalse(marker.exists())
    }

    // ── 2. 产物绑定版本：v1 的东西不许带进 v2 ──

    @Test
    fun v1CompleteApkIsClearedAndV2DownloadsFully() {
        // 用户在系统安装器里取消了 v1：整包 + 完成标记都还在。
        apk.writeBytes(ByteArray(3000) { 7 })
        marker.writeText("ok")
        idFile.writeText(v1)
        val opened = mutableListOf<FakeConn>()

        val r = run(v2, listOf(FakeConn(200, { ByteArrayInputStream(full) }, 4000)), opened)

        assertEquals("v2 必须真的去下载，不能拿 v1 的包直接校验", 1, opened.size)
        assertNull("完整下载，不带 Range", opened.single().requestHeaders["Range"])
        assertEquals(DownloadSettlement.Verified(4000), r)
        assertTrue(apk.readBytes().contentEquals(full))
        assertEquals(v2, idFile.readText())
    }

    @Test
    fun v1PartialIsClearedAndV2DoesNotSpliceOntoIt() {
        apk.writeBytes(ByteArray(1500) { 7 }) // v1 的半包
        idFile.writeText(v1)
        val opened = mutableListOf<FakeConn>()

        val r = run(v2, listOf(FakeConn(200, { ByteArrayInputStream(full) }, 4000)), opened)

        assertNull("v1 半包不许被当作 v2 的断点", opened.single().requestHeaders["Range"])
        assertEquals(DownloadSettlement.Verified(4000), r)
        assertTrue(apk.readBytes().contentEquals(full))
    }

    @Test
    fun artifactsWithoutIdentityAreTreatedAsForeign() {
        // 升级前的旧版本留下的产物没有身份旁路文件：一律当作不认识，清掉。
        apk.writeBytes(ByteArray(1500) { 7 })
        marker.writeText("ok")
        assertTrue(claimUpdateArtifacts(apk, marker, idFile, v2))
        assertFalse(apk.exists())
        assertFalse(marker.exists())
        assertEquals(v2, idFile.readText())
    }

    @Test
    fun sameIdentityKeepsArtifacts() {
        apk.writeBytes(ByteArray(1500) { 7 })
        idFile.writeText(v2)
        assertFalse(claimUpdateArtifacts(apk, marker, idFile, v2))
        assertEquals(1500L, apk.length())
    }

    @Test
    fun identityCoversUrlAndShaNotJustVersion() {
        // 同版本号重发包（字节变了）：旧残包同样不能续。
        val a = downloadIdentityOf("0.9.3", url, "aa".repeat(32))
        val b = downloadIdentityOf("0.9.3", url, "bb".repeat(32))
        val c = downloadIdentityOf("0.9.3", "https://example.invalid/other.apk", "aa".repeat(32))
        assertTrue(a != b && a != c)
    }
}
