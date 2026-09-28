// MOB-115（#458）：下载中途断流时不得把截断文件当完整文件返回，也不得留下
// 可被当作缓存命中的文件。receiveVerified 是 downloadAsset 的字节接收段，
// 这里用假的 readChunk（语义同 iroh RecvStream.readExact）驱动它。
//
// 反证（行为层）：
//  - 删掉 receiveVerified 里 readChunk 失败时的 DownloadTruncated 包装、改回
//    `break` → truncatedStream… 红（抛的不再是 DownloadTruncated / dest 出现）。
//  - 删掉 BLAKE3 比对 → sameLengthWrongContent… 红。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.backup.blake3Hex
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MOB115VerifiedDownloadTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val payload = ByteArray(700 * 1024) { (it * 31 + 7).toByte() }
    private val hash = blake3Hex(payload)

    /** 假流：按 readExact 语义交付 [bytes]；交付满 [cutAt] 字节后抛错（模拟断流）。 */
    private fun stream(bytes: ByteArray, cutAt: Int = Int.MAX_VALUE): suspend (UInt) -> ByteArray {
        var pos = 0
        return { n ->
            val want = n.toInt()
            if (pos + want > minOf(cutAt, bytes.size)) {
                throw IOException("stream reset (simulated) at $pos")
            }
            bytes.copyOfRange(pos, pos + want).also { pos += want }
        }
    }

    private fun leftovers(dir: File) = dir.listFiles()!!.map { it.name }.sorted()

    @Test
    fun completeStreamLandsAtDestAndLeavesNoPart() = runBlocking {
        val dir = tmp.newFolder()
        val dest = File(dir, "video-x.mp4")
        val got = receiveVerified(dest, payload.size.toLong(), hash, stream(payload))
        assertEquals(payload.size.toLong(), got)
        assertArrayEquals(payload, dest.readBytes())
        assertEquals(listOf("video-x.mp4"), leftovers(dir))
    }

    @Test
    fun truncatedStreamThrowsAndLeavesNoCacheFile() = runBlocking {
        val dir = tmp.newFolder()
        val dest = File(dir, "video-x.mp4")
        val progress = mutableListOf<Long>()
        try {
            // 声明 700 KiB，只送到 300 KiB 就断——正是 relay/停服务时的形状。
            receiveVerified(
                dest, payload.size.toLong(), hash,
                stream(payload, cutAt = 300 * 1024),
            ) { r, _ -> progress += r }
            fail("断流必须抛错，不能返回截断文件")
        } catch (e: DownloadTruncated) {
            assertEquals(payload.size.toLong(), e.total)
            assertTrue("断流前确实收到过部分字节：${e.received}", e.received in 1 until e.total)
        }
        assertFalse("断流不得留下缓存文件", dest.exists())
        assertEquals("也不得留下 .part 残留", emptyList<String>(), leftovers(dir))
        assertTrue(progress.isNotEmpty())
    }

    @Test
    fun streamThatEndsCleanButShortIsTruncatedToo() = runBlocking {
        val dir = tmp.newFolder()
        val dest = File(dir, "a.bin")
        // 对端 finish 得比声明早：readExact 拿不够字节同样抛错。
        val short = payload.copyOf(payload.size - 1)
        try {
            receiveVerified(dest, payload.size.toLong(), hash, stream(short))
            fail("长度不足必须抛错")
        } catch (e: DownloadTruncated) {
            assertEquals("前两整块已收，第三块读不满", 2L * 256 * 1024, e.received)
        }
        assertFalse(dest.exists())
        assertEquals(emptyList<String>(), leftovers(dir))
    }

    @Test
    fun sameLengthWrongContentIsRejectedByHash() = runBlocking {
        val dir = tmp.newFolder()
        val dest = File(dir, "a.bin")
        val corrupt = payload.copyOf().also { it[123_456] = (it[123_456] + 1).toByte() }
        try {
            receiveVerified(dest, payload.size.toLong(), hash, stream(corrupt))
            fail("内容与 hash 不符必须抛错")
        } catch (e: DownloadHashMismatch) {
            assertEquals(hash, e.expected)
        }
        assertFalse(dest.exists())
        assertEquals(emptyList<String>(), leftovers(dir))
    }

    @Test
    fun failedRedownloadDoesNotClobberAndLeavesNoDest() = runBlocking {
        // 失败的重下不会用坏字节覆盖 dest（dest 只经原子改名产生）。
        val dir = tmp.newFolder()
        val dest = File(dir, "a.bin")
        runCatching {
            receiveVerified(dest, payload.size.toLong(), hash, stream(payload, cutAt = 1))
        }
        assertFalse(dest.exists())
    }

    @Test
    fun cancellationIsNotWrappedAndCleansPart() = runBlocking {
        val dir = tmp.newFolder()
        val dest = File(dir, "a.bin")
        var calls = 0
        try {
            receiveVerified(dest, payload.size.toLong(), hash, { n ->
                if (++calls == 2) throw CancellationException("viewer closed")
                ByteArray(n.toInt())
            })
            fail("取消必须上抛")
        } catch (e: CancellationException) {
            assertFalse(e is AssetDownloadException)
        }
        assertEquals(emptyList<String>(), leftovers(dir))
    }
}
