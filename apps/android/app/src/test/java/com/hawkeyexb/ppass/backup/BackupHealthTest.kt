// MOB-18: force-stop 检测与「不静默恢复」的落盘状态测试。
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
    fun application_checks_before_rescheduling() {
        // MOB-18 回归锁：**顺序不能反**。scheduleAutoBackup 会把监听重新排上，
        // 一旦先排后查，isBackupScheduled 永远返回 true，中断再也检测不到——
        // 这条断言锁的就是这个先后关系。
        val app = codeOf(File(repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/PPassApplication.kt"))
        val checkAt = app.indexOf("isBackupScheduled(this)")
        val scheduleAt = app.indexOf("scheduleAutoBackup(this)")
        assertTrue("必须调用 isBackupScheduled 做检测", checkAt >= 0)
        assertTrue("调度体系正常时仍要幂等兜底确认", scheduleAt >= 0)
        assertTrue("检测必须发生在重排之前，否则永远检测不到中断", checkAt < scheduleAt)
        assertTrue(
            "检测到中断必须落盘",
            app.contains("recordInterrupted("),
        )
        // 用户定调："必须点了才恢复。你都提示了，就别自作主张。"
        // 检测到中断后必须**立即返回**，不能顺手把调度重排上——否则提示
        // 变成马后炮，用户没有选择权。
        val afterRecord = app.substringAfter("recordInterrupted(")
        assertTrue(
            "检测到中断后必须直接返回，不得自作主张恢复调度",
            afterRecord.substringBefore("}").contains("return@thread") ||
                afterRecord.substringBefore("scheduleAutoBackup").contains("return@thread"),
        )
        // 不能在主线程做阻塞查询。
        assertTrue("阻塞检测必须放后台线程", app.contains("thread("))
    }

    @Test
    fun interruption_card_is_wired_in_ui() {
        val home = codeOf(File(repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt"))
        assertTrue("设置页必须渲染中断提示条", home.contains("if (backupInterrupted) {"))
        assertTrue("必须能被用户确认消除", home.contains("onAcknowledgeInterruption"))
        val main = codeOf(File(repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt"))
        assertTrue("MainActivity 必须接线", main.contains("backupInterrupted = backupInterrupted"))
        assertTrue("点确认必须落盘", main.contains("healthPrefs.acknowledge()"))
        // 恢复调度的唯一入口就是这个按钮（Application 那边只记录不恢复）。
        val handler = main.substringAfter("onAcknowledgeInterruption = {")
            .substringBefore("},")
        assertTrue("点击必须真正恢复调度", handler.contains("scheduleAutoBackup(context)"))
        assertTrue("点击必须顺手补跑一次", handler.contains("triggerUserPresentBackup(context)"))
    }
}
