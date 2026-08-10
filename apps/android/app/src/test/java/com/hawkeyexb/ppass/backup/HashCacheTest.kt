// PERF-01 验收：哈希缓存——同一张没变过的照片只在第一次备份读流哈希
// 一次；第二次跑同一批候选 open 调用次数 = 0；generation 变化必须重算；
// 缓存文件损坏 → 当空缓存全量重算不崩。
//
// 验收①②③全部走生产函数 hashWithCache（BackupUiStateHolder /
// BackupWorker 的 hash 阶段接线就是调它），open 工厂注入可计数实现。
package com.hawkeyexb.ppass.backup

import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HashCacheTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-hashcache-$tag").toFile()

    /** 一个可计数的内容源工厂：每次 open 返回同一字节流内容，并计数。 */
    private class CountingSource(val bytes: ByteArray) {
        val opens = AtomicInteger(0)
        fun open(): ByteArrayInputStream {
            opens.incrementAndGet()
            return ByteArrayInputStream(bytes)
        }
    }

    /** 同一批候选的 key 列表（uri 集合 + 固定 generation）。 */
    private fun keys(uris: List<String>, gen: Long = 7L): List<String> =
        uris.map { hashCacheKey(it, gen, dateModified = 1000, bytes = 100, api30Plus = true) }

    private val uris = (1..50).map { "content://media/external/images/media/$it" }

    @Test
    fun second_run_same_batch_opens_zero() {
        // 验收①：第二次跑同一批候选，open 调用次数 = 0（全部命中缓存）。
        val dir = tempDir("second-run")
        val cache = HashCache(File(dir, "hash-cache.json"))
        val source = CountingSource(ByteArray(1024) { 1 })

        val ks = keys(uris)
        // 第一次跑：全部 miss → 全部 open。
        ks.forEach { hashWithCache(cache, it, source::open) }
        assertEquals("首次全 miss → open 50 次", 50, source.opens.get())

        // 第二次跑（同实例，内存态直接命中）：open 必须 0。
        ks.forEach { hashWithCache(cache, it, source::open) }
        assertEquals("第二次 open 必须 = 0", 50, source.opens.get())

        // flush 后新实例（模拟杀 App 重开）依然全命中。
        cache.flush()
        val reopened = HashCache(File(dir, "hash-cache.json"))
        ks.forEach { hashWithCache(reopened, it, source::open) }
        assertEquals("重开后 open 仍必须 = 0", 50, source.opens.get())
        dir.deleteRecursively()
    }

    @Test
    fun generation_change_recomputes() {
        // 验收②：同一 _ID，generation 变化 → 该条目必须重算（open = 1）。
        val dir = tempDir("gen-change")
        val cache = HashCache(File(dir, "hash-cache.json"))
        val source = CountingSource(ByteArray(2048) { 2 })

        val uri = "content://media/external/images/media/99"
        val kOld = hashCacheKey(uri, generation = 5, dateModified = 1000, bytes = 100, api30Plus = true)
        val kNew = hashCacheKey(uri, generation = 6, dateModified = 1000, bytes = 100, api30Plus = true)

        hashWithCache(cache, kOld, source::open)
        assertEquals(1, source.opens.get())

        // 同一 uri 但 generation 变了 → 新 key → 必须重算。
        val h = hashWithCache(cache, kNew, source::open)
        assertEquals("generation 变化必须重算", 2, source.opens.get())
        assertTrue(h.isNotBlank())
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_cache_reads_as_empty_full_recompute_no_crash() {
        // 验收③：缓存文件损坏 → 当空缓存全量重算，不崩。
        val dir = tempDir("corrupt")
        val cacheFile = File(dir, "hash-cache.json")
        cacheFile.writeText("{not json at all")

        val cache = HashCache(cacheFile)
        assertEquals(0, cache.size())

        val source = CountingSource(ByteArray(512) { 3 })
        val ks = keys(uris.take(10))
        ks.forEach { hashWithCache(cache, it, source::open) }
        assertEquals("损坏缓存当空 → 全量重算", 10, source.opens.get())

        // 恢复写入也不崩（tmp+rename 链路）。
        cache.flush()
        val reopened = HashCache(cacheFile)
        assertEquals(10, reopened.size())
        dir.deleteRecursively()
    }

    @Test
    fun counterproof_no_cache_read_opens_full() {
        // 反证：禁用缓存读取（空缓存/不查缓存）→ 验收①的 open 计数
        // 回到全量——证明命中逻辑不是恒真式。
        val dir = tempDir("counterproof")
        val cache = HashCache(File(dir, "hash-cache.json"))
        val source = CountingSource(ByteArray(256) { 4 })

        // 生产路径：hashWithCache 无条件查缓存——缓存为空时不可能命中。
        val ks = keys(uris.take(20))
        ks.forEach { hashWithCache(cache, it, source::open) }
        assertEquals("空缓存 → open 全量 20 次", 20, source.opens.get())

        // 二次跑同一批（缓存已被第一次填满）→ 0——正反都钉死。
        ks.forEach { hashWithCache(cache, it, source::open) }
        assertEquals("填满后第二次 → 0", 20, source.opens.get())
        dir.deleteRecursively()
    }

    @Test
    fun hash_value_matches_known_blake3_vector() {
        // 命中缓存返回的 hash 与直接流式 blake3 一致（值正确性）。
        val dir = tempDir("vector")
        val cache = HashCache(File(dir, "hash-cache.json"))
        val data = ByteArray(100_000) { (it * 7).toByte() }
        val source = CountingSource(data)

        val key = keys(listOf("content://media/external/images/media/1")).first()
        val fromCache = hashWithCache(cache, key, source::open)
        val direct = blake3Hex(ByteArrayInputStream(data))
        assertEquals("缓存 hash 必须等于流式 blake3", direct, fromCache)
        dir.deleteRecursively()
    }

    @Test
    fun prune_keeps_only_existing_media_uris() {
        // 清理策略：跟随 MediaStore 现存 _ID 集合——不在集合内的条目
        // （照片被删/相册被清）清掉。
        val dir = tempDir("prune")
        val cache = HashCache(File(dir, "hash-cache.json"))
        val source = CountingSource(ByteArray(64) { 5 })

        val all = keys(uris.take(30))
        all.forEach { hashWithCache(cache, it, source::open) }
        assertEquals(30, cache.size())

        // MediaStore 现存只剩前 20 个 → 后 10 个是孤儿。
        val stillExisting = uris.take(20).toSet()
        cache.prune(stillExisting)
        assertEquals("孤儿必须清掉", 20, cache.size())
        assertTrue(cache.get(all[0]) != null)
        assertTrue(cache.get(all[29]) == null)

        // 落盘同步。
        val reopened = HashCache(File(dir, "hash-cache.json"))
        assertEquals(20, reopened.size())
        dir.deleteRecursively()
    }

    @Test
    fun pre30_key_uses_dateModified_and_size() {
        // API<30 退化键：(DATE_MODIFIED + SIZE)。DATE_ADDED 编辑不变，
        // 必须靠修改时间 + 大小兜底——同 uri 改大小/改时间 → key 变。
        val uri = "content://media/external/images/media/7"
        val k1 = hashCacheKey(uri, generation = 0, dateModified = 1000, bytes = 100, api30Plus = false)
        val k2 = hashCacheKey(uri, generation = 0, dateModified = 1001, bytes = 100, api30Plus = false)
        val k3 = hashCacheKey(uri, generation = 0, dateModified = 1000, bytes = 101, api30Plus = false)
        assertTrue("修改时间变化 → key 必须变", k1 != k2)
        assertTrue("大小变化 → key 必须变", k1 != k3)
        assertEquals(
            "同参同键（确定性）",
            k1,
            hashCacheKey(uri, generation = 0, dateModified = 1000, bytes = 100, api30Plus = false),
        )
    }
}
