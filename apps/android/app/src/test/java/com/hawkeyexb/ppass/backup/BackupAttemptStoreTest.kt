// MOB-02 §五: 失败重试计数测试——连续失败落盘、成功/放弃清零。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class BackupAttemptStoreTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-attempt-$tag").toFile()

    @Test
    fun consecutive_failures_increment_and_persist() {
        val dir = tempDir("increment")
        val store = BackupAttemptStore(dir)
        assertEquals(0, store.current())
        assertEquals(1, store.recordFailure())
        assertEquals(2, store.recordFailure())
        // 重开实例（模拟 WorkManager 重试新进程）仍读到 2。
        assertEquals(2, BackupAttemptStore(dir).current())
        dir.deleteRecursively()
    }

    @Test
    fun success_resets_counter() {
        val dir = tempDir("reset")
        val store = BackupAttemptStore(dir)
        store.recordFailure()
        store.recordFailure()
        store.reset()
        assertEquals(0, BackupAttemptStore(dir).current())
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_file_reads_as_zero() {
        val dir = tempDir("corrupt")
        File(dir, "backup-attempt.txt").apply {
            parentFile.mkdirs()
            writeText("not-a-number")
        }
        assertEquals(0, BackupAttemptStore(dir).current())
        dir.deleteRecursively()
    }
}
