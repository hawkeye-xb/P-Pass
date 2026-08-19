// MOB-18: force-stop 中断记录的落盘状态测试。
//
// ⚠️ 功能本身 2026-08-19 由用户拍板 **pending 进 backlog**——WorkManager 的
// ForceStopRunnable 跑在 androidx.startup 的 ContentProvider 里，比
// Application.onCreate 还早就把 work 重排了，"检测到中断 → 只提示不恢复"
// 这个语义应用层实现不了。UI 与接线已撤，本文件只保留数据结构本身的测试
// （BackupHealthPrefs 是自洽的，将来若换判据可直接复用）。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupHealthTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-health-$tag").toFile()

    private fun codeOf(file: File): String =
        file.readText().lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    @Test
    fun defaults_to_no_interruption() {
        assertFalse(BackupHealthPrefs(tempDir("default")).load().interruptedUnacknowledged)
    }

    @Test
    fun interruption_survives_process_restart() {
        // 检测在 Application 的后台线程做、UI 在 MainActivity 里读，跨组件；
        // 且必须扛住进程重启，所以是落盘不是内存标志。
        val dir = tempDir("persist")
        BackupHealthPrefs(dir).recordInterrupted(1_700_000_000_000L)
        val reopened = BackupHealthPrefs(dir).load()
        assertTrue("重开后仍待确认", reopened.interruptedUnacknowledged)
        assertEquals(1_700_000_000_000L, reopened.detectedAt)
        dir.deleteRecursively()
    }

    @Test
    fun acknowledge_clears_flag_but_keeps_timestamp() {
        val dir = tempDir("ack")
        val prefs = BackupHealthPrefs(dir)
        prefs.recordInterrupted(1_700_000_000_000L)
        prefs.acknowledge()
        val after = prefs.load()
        assertFalse("用户点过「知道了」后不再提示", after.interruptedUnacknowledged)
        assertEquals("时间戳保留（排查用）", 1_700_000_000_000L, after.detectedAt)
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_file_reads_as_defaults_not_crash() {
        val dir = tempDir("corrupt")
        File(dir, "backup_health.json").apply {
            parentFile.mkdirs()
            writeText("{not json")
        }
        assertFalse(BackupHealthPrefs(dir).load().interruptedUnacknowledged)
        dir.deleteRecursively()
    }

    @Test
    fun triplet_follows_background_worker() {
        // MOB-21 回归锁：三元组必须跟住**后台** BackupWorker 的状态变化。
        // 真机实测：数据层 confirmed.json 完全正确（范围内 142 条），但界面
        // 上的大字一直停在打开 App 那一刻的 0——refreshTriplet 只在 init /
        // 手动备份完成 / 补齐后跑，后台自动备份跑完不通知 UI。
        val holder = codeOf(File(repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt"))
        assertTrue(
            "必须订阅 BackupWorker 的状态流（四条自动通道共用它，按 tag 订阅）",
            holder.contains("getWorkInfosByTagFlow(BackupWorker::class.java.name)"),
        )
        assertTrue(
            "状态变化时必须刷新三元组",
            holder.substringAfter("getWorkInfosByTagFlow").contains("refreshTriplet()"),
        )
    }
}
