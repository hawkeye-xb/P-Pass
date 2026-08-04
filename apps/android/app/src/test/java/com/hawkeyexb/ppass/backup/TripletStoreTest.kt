// DOG-01: triplet computation + persistence tests.
// 反证：exist-check 全 missing（ingested+duplicates=0）→ K 必须 = N。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TripletStoreTest {

    @Test
    fun triplet_all_missing_means_k_equals_n() {
        // 反证：exist-check 响应 mock 成全 missing → 全部待备份（K = N，M = 0）
        val t = tripletOf(offered = 12, ingested = 0, duplicates = 0, lastSuccessAt = 1000)
        assertEquals(12L, t.n)
        assertEquals(0L, t.m)
        assertEquals("K 必须 = N", 12L, t.k)
    }

    @Test
    fun triplet_nothing_missing_means_all_safe() {
        val t = tripletOf(offered = 12, ingested = 5, duplicates = 7, lastSuccessAt = 1000)
        assertEquals(12L, t.m)
        assertEquals(0L, t.k)
    }

    @Test
    fun triplet_partial() {
        val t = tripletOf(offered = 10, ingested = 3, duplicates = 1, lastSuccessAt = 1000)
        assertEquals(4L, t.m)
        assertEquals(6L, t.k)
    }

    @Test
    fun store_roundtrip_and_reload_survives() {
        val dir = java.nio.file.Files.createTempDirectory("ppass-triplet").toFile()
        val store = TripletStore(dir)
        assertNull("首次无缓存", store.load())

        store.save(tripletOf(5, 2, 0, 42_000))
        val reloaded = TripletStore(dir).load()
        assertTrue("重载非空", reloaded != null)
        val r = reloaded!!
        assertEquals(5L, r.n)
        assertEquals(2L, r.m)
        assertEquals(3L, r.k)
        assertEquals(42_000L, r.lastSuccessAt)
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_cache_returns_null_not_crash() {
        val dir = java.nio.file.Files.createTempDirectory("ppass-triplet-bad").toFile()
        File(dir, "backup.triplet.json").writeText("{not json")
        assertNull("损坏缓存返回 null", TripletStore(dir).load())
        dir.deleteRecursively()
    }

    @Test
    fun k_is_never_negative() {
        val t = tripletOf(offered = 3, ingested = 5, duplicates = 0, lastSuccessAt = 1)
        assertTrue("K 不为负", t.k >= 0)
    }
}
