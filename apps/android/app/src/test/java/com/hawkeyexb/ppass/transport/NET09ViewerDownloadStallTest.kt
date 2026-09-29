// NET-09（#116）：查看原图 / 视频的下载（downloadAsset → receiveVerified）加字节停滞
// 看门狗——对端流不再动时限期失败，慢但在动的传输不能被掐。
//
// 假流卡的是「线程」而不是协程（CountDownLatch.await），和 NET28BindTimeoutTest 同理：
// 若真实读卡在原生阻塞调用里，只靠取消协程的修法打断不了它；用 delay() 做的假流会让
// 那种修法也变绿。abort 回调扮演生产里的 conn.close：放开闸、让卡住的读报错返回。
//
// 反证（已实跑）：
//  - receiveVerified 里去掉 stall.read 包装（直接 readChunk）→ 停滞用例 @Test(timeout) 红。
//  - 看门狗改成整次下载的总时长上限 → 慢速在动用例红。
//  - CHUNK 改回 256 KiB → 涓流用例红（一块凑不满就判停滞）。
//
// @Test(timeout) 让回归变红而不是挂住整个测试套件。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.backup.blake3Hex
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NET09ViewerDownloadStallTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val latches = mutableListOf<CountDownLatch>()

    /** 假读卡住线程用的闸；@After 统一放开，不留钉死的线程。 */
    private fun gate() = CountDownLatch(1).also { latches += it }

    @After
    fun release() = latches.forEach { it.countDown() }

    private val payload = ByteArray(200 * 1024) { (it * 13 + 5).toByte() }
    private val hash = blake3Hex(payload)

    private fun leftovers(dir: File) = dir.listFiles()!!.map { it.name }.sorted()

    @Test(timeout = 10_000)
    fun `stream that stops after two chunks fails as DownloadStalled within the limit`() = runBlocking {
        val dir = tmp.newFolder()
        val dest = File(dir, "video-x.mp4")
        val hung = gate()
        val aborted = AtomicInteger()
        val guard = ByteStallGuard(stallMs = 300) {
            aborted.incrementAndGet()
            hung.countDown() // = conn.close：卡住的读随之报错返回
        }
        var pos = 0
        var calls = 0
        val readChunk: suspend (UInt) -> ByteArray = { n ->
            if (++calls > 2) {
                hung.await() // 真卡线程，直到 abort
                throw IOException("connection closed locally")
            }
            payload.copyOfRange(pos, pos + n.toInt()).also { pos += n.toInt() }
        }

        val started = System.nanoTime()
        try {
            receiveVerified(dest, payload.size.toLong(), hash, readChunk, stall = guard)
            fail("停滞必须抛错")
        } catch (e: DownloadStalled) {
            assertEquals(pos.toLong(), e.received)
            assertEquals(payload.size.toLong(), e.total)
            assertEquals(300L, e.stalledMs)
        }
        val tookMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        assertTrue("在阈值之前就失败了：${tookMs}ms", tookMs >= 300)
        assertTrue("远超阈值才失败：${tookMs}ms", tookMs < 3_000)
        assertEquals("停滞时必须关一次底层连接", 1, aborted.get())
        // 失败路径不留缓存、不留 .part。
        assertEquals(emptyList<String>(), leftovers(dir))
    }

    @Test(timeout = 10_000)
    fun `slow but moving stream longer than the limit in total is not cut`() = runBlocking {
        val dir = tmp.newFolder()
        val dest = File(dir, "a.bin")
        val aborted = AtomicInteger()
        // 每块间隔 120ms < 阈值 300ms；共 13 块 ≈ 1.5s，总时长是阈值的 5 倍。
        val guard = ByteStallGuard(stallMs = 300) { aborted.incrementAndGet() }
        var pos = 0
        val readChunk: suspend (UInt) -> ByteArray = { n ->
            Thread.sleep(120) // 同样卡线程，证明计时器每块都重置
            payload.copyOfRange(pos, pos + n.toInt()).also { pos += n.toInt() }
        }
        val started = System.nanoTime()
        val got = receiveVerified(dest, payload.size.toLong(), hash, readChunk, stall = guard)
        val tookMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        assertTrue("用例没覆盖到「总时长 > 阈值」：${tookMs}ms", tookMs > 900)
        assertEquals(payload.size.toLong(), got)
        assertArrayEquals(payload, dest.readBytes())
        assertEquals(0, aborted.get())
    }

    @Test(timeout = 10_000)
    fun `trickle within one chunk counts as progress at the requested granularity`() = runBlocking {
        // readExact 凑满才返回：每次要的字节数就是看门狗能看到的进展粒度。
        // 假链路速率固定为 100 KB/s，阈值 300ms 内能到 ~30 KB——够一块 16 KiB，
        // 不够一块 256 KiB。块开太大，慢而在动的链路会被误判停滞。
        val dir = tmp.newFolder()
        val dest = File(dir, "a.bin")
        val bytesPerMs = 100.0
        var pos = 0
        val readChunk: suspend (UInt) -> ByteArray = { n ->
            Thread.sleep((n.toInt() / bytesPerMs).toLong())
            payload.copyOfRange(pos, pos + n.toInt()).also { pos += n.toInt() }
        }
        val got = receiveVerified(
            dest, payload.size.toLong(), hash, readChunk, stall = ByteStallGuard(stallMs = 300),
        )
        assertEquals(payload.size.toLong(), got)
    }

    @Test(timeout = 10_000)
    fun `stall is a download failure, not a cancellation`() {
        val e = DownloadStalled(received = 1, total = 2, stalledMs = 60_000)
        assertFalse(e is CancellationException)
        assertTrue(e is AssetDownloadException)
    }

    @Test(timeout = 10_000)
    fun `guard also bounds the wait for the response head`() = runBlocking {
        val hung = gate()
        val guard = ByteStallGuard(stallMs = 200) { hung.countDown() }
        try {
            guard.read(received = 0, total = null) { hung.await(); ByteArray(4) }
            fail("等不到响应头也必须限期失败")
        } catch (e: DownloadStalled) {
            assertEquals(0L, e.received)
            assertNull(e.total)
        }
    }

    @Test(timeout = 10_000)
    fun `threshold is 60s and not below iroh's 30s connection idle window`() {
        assertEquals(60_000L, DOWNLOAD_BYTE_STALL_MS)
    }
}
