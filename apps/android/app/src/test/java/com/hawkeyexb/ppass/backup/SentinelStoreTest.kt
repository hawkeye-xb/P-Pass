// SENT-01 遗留：可达时间存储读写（#1028 起只剩 lastReachableAt）。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class SentinelStoreTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-sentinel-$tag").toFile()

    @Test
    fun store_roundtrip() {
        val dir = tempDir("roundtrip")
        val store = SentinelStore(dir)
        assertEquals(0, store.load().lastReachableAt)

        val now = 5_000_000L
        store.recordReachable(now)
        assertEquals(now, store.load().lastReachableAt)
        dir.deleteRecursively()
    }

    @Test
    fun legacy_file_with_removed_fields_still_loads() {
        val dir = tempDir("legacy")
        File(dir, "sentinel.json").apply {
            parentFile.mkdirs()
            writeText("""{"lastReachableAt":1000,"failedAttempts":3,"lastNotifiedAt":2000}""")
        }
        assertEquals(SentinelState(lastReachableAt = 1_000L), SentinelStore(dir).load())
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_file_reads_as_empty() {
        val dir = tempDir("corrupt")
        File(dir, "sentinel.json").apply {
            parentFile.mkdirs()
            writeText("{ not json !!!")
        }
        assertEquals(SentinelState(), SentinelStore(dir).load())
        dir.deleteRecursively()
    }
}
