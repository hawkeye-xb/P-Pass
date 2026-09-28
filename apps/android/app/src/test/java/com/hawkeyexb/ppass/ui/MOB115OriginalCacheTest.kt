// MOB-115（#458）：视频长期缓存的命中判据必须校长度。升级前旧判据
// `isFile && length() > 0` 留下的截断缓存，必须被识别、删掉并重下。
//
// 反证（行为层）：把 isCompleteOriginal 改回 `file.isFile && file.length() > 0`
// → truncatedLegacyCache… / expectedUnknown… 红（download 未被调用）。
package com.hawkeyexb.ppass.ui

import java.io.File
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MOB115OriginalCacheTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val full = ByteArray(4096) { it.toByte() }

    private class CountingDownload(private val bytes: ByteArray) {
        var calls = 0
        val fn: suspend (File) -> Unit = { dest -> calls++; dest.writeBytes(bytes) }
    }

    @Test
    fun completeCacheIsAHitWithoutDownload() = runBlocking {
        val cache = File(tmp.root, "video-abc.mp4").apply { writeBytes(full) }
        val dl = CountingDownload(full)
        fetchOriginalCached(cache, full.size.toLong(), dl.fn)
        assertEquals("完整缓存直接命中", 0, dl.calls)
        assertEquals(full.size.toLong(), cache.length())
    }

    @Test
    fun truncatedLegacyCacheIsDroppedAndRedownloaded() = runBlocking {
        // 升级前断流留下的坏缓存：非空、但比 asset.bytes 短。
        val cache = File(tmp.root, "video-abc.mp4").apply { writeBytes(full.copyOf(1000)) }
        val dl = CountingDownload(full)
        fetchOriginalCached(cache, full.size.toLong(), dl.fn)
        assertEquals("长度不符必须重下", 1, dl.calls)
        assertEquals(full.size.toLong(), cache.length())
    }

    @Test
    fun oversizedCacheIsAlsoAMiss() = runBlocking {
        val cache = File(tmp.root, "video-abc.mp4").apply { writeBytes(full + full) }
        val dl = CountingDownload(full)
        fetchOriginalCached(cache, full.size.toLong(), dl.fn)
        assertEquals(1, dl.calls)
        assertEquals(full.size.toLong(), cache.length())
    }

    @Test
    fun expectedUnknownNeverTrustsCache() = runBlocking {
        // asset.bytes 缺失（0）时无从校验——宁可重下，也不信任现有文件。
        val cache = File(tmp.root, "video-abc.mp4").apply { writeBytes(full.copyOf(10)) }
        val dl = CountingDownload(full)
        fetchOriginalCached(cache, 0L, dl.fn)
        assertEquals(1, dl.calls)
    }

    @Test
    fun failedRedownloadLeavesNoBadCacheBehind() = runBlocking {
        val cache = File(tmp.root, "video-abc.mp4").apply { writeBytes(full.copyOf(1000)) }
        File(tmp.root, "video-abc.mp4.part").writeBytes(ByteArray(10))
        try {
            fetchOriginalCached(cache, full.size.toLong()) { throw IOException("stream reset") }
            fail("下载失败应上抛")
        } catch (_: IOException) {
        }
        assertFalse("坏缓存已被删除，下次不会再命中", cache.exists())
        assertFalse(".part 残留也被清掉", File(tmp.root, "video-abc.mp4.part").exists())
    }

    @Test
    fun hitCheckIsLengthExact() {
        val f = File(tmp.root, "x").apply { writeBytes(full) }
        assertTrue(isCompleteOriginal(f, full.size.toLong()))
        assertFalse(isCompleteOriginal(f, full.size.toLong() + 1))
        assertFalse("不符即删", f.exists())
    }
}
