// MOB-28：监听中断的区分与"用户点了才恢复"的回归锁。
//
// 这张卡的存在理由是一句用户原话（2026-08-19）：
//   "不要做静默恢复，就是要提醒。"
//   "必须点了才恢复。你都提示了，就别自作主张。"
// 当初 MOB-18 做不到，因为监听是 WorkManager 的 work，ForceStopRunnable
// 会在我们任何代码之前自愈。MOB-27 把监听搬到我们自己的 JobScheduler job
// 之后，WorkManager 碰不到它，这个语义才成立——所以本文件的断言同时在
// 保护 MOB-27 的架构前提。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchRecoveryTest {

    private fun codeOf(file: File): String =
        file.readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    private fun src(rel: String): String =
        codeOf(File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/$rel"))

    /** 源码切片——**必须先确认锚点存在**。
     *
     *  教训 C（2026-08-20，反证实测撞到）：Kotlin 的 `substringAfter` /
     *  `substringBefore` 在**找不到分隔符时返回整个字符串**
     *  （`missingDelimiterValue` 默认就是 receiver 本身）。于是
     *  `sliceAfter(src, "finally").contains("pending.finish()")`
     *  在把 finally 整块删掉之后**反而变成对全文求 contains，照样绿**——
     *  反证跑出来不红才发现。切片类断言一律走这里。 */
    private fun sliceAfter(src: String, marker: String): String {
        assertTrue("源码锚点已消失，断言失效：$marker", src.contains(marker))
        return src.substringAfter(marker)
    }

    private fun sliceBetween(src: String, from: String, to: String): String {
        val tail = sliceAfter(src, from)
        assertTrue("源码结束锚点已消失，断言失效：$to", tail.contains(to))
        return tail.substringBefore(to)
    }

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-watchrec-$tag").toFile()

    // ── 判据：开机时刻 ──

    @Test
    fun boot_stamp_is_stable_within_one_boot() {
        // 同一次开机：墙上时钟和 elapsedRealtime 同步前进，差值不变。
        val t0 = 1_700_000_000_000L
        val a = bootStampOf(nowMs = t0, elapsedRealtimeMs = 10_000L)
        val b = bootStampOf(nowMs = t0 + 3_600_000L, elapsedRealtimeMs = 10_000L + 3_600_000L)
        assertEquals("同一次开机内开机时刻必须稳定", a, b)
        assertTrue(isSameBoot(a, b))
    }

    @Test
    fun boot_stamp_changes_across_reboot() {
        // 重启：elapsedRealtime 归零，而墙上时钟继续走 → 开机时刻变大。
        val before = bootStampOf(nowMs = 1_700_000_000_000L, elapsedRealtimeMs = 7_200_000L)
        val after = bootStampOf(nowMs = 1_700_000_060_000L, elapsedRealtimeMs = 5_000L)
        assertFalse("重启后必须判为不同次开机", isSameBoot(before, after))
    }

    @Test
    fun small_clock_drift_still_counts_as_same_boot() {
        // NTP 校时会让墙上时钟小跳几秒，不能因此把同一次开机误判成重启
        // ——误判的后果是"被 force-stop 过"被当成"重启过"，提示不出来。
        val a = 1_700_000_000_000L
        assertTrue("校时 5 秒仍是同一次开机", isSameBoot(a, a + 5_000L))
        assertTrue("容差边界内", isSameBoot(a, a + BOOT_STAMP_TOLERANCE_MS))
        assertFalse("超出容差就算重启", isSameBoot(a, a + BOOT_STAMP_TOLERANCE_MS + 1))
    }

    @Test
    fun never_recorded_boot_stamp_reads_as_a_different_boot() {
        // 首次安装：lastBootStamp = 0 → 必须判为"不同次开机" → 自动挂上，
        // 而不是把全新用户当成"被强停过"，一上来就弹提示。
        assertFalse(isSameBoot(bootStampOf(1_700_000_000_000L, 5_000L), 0L))
    }

    // ── 判定表：八种组合全覆盖 ──

    @Test
    fun listener_present_is_the_normal_path() {
        assertEquals(
            WatchRecovery.NORMAL,
            decideRecovery(watchScheduled = true, sameBootAsLastRun = true, awaitingUserConsent = false),
        )
        assertEquals(
            WatchRecovery.NORMAL,
            decideRecovery(watchScheduled = true, sameBootAsLastRun = false, awaitingUserConsent = false),
        )
    }

    @Test
    fun reboot_recovers_by_itself() {
        // 用户没做任何"停止"的意思表示——重启导致的消失自动挂回来才符合预期。
        assertEquals(
            WatchRecovery.AUTO_REARM,
            decideRecovery(watchScheduled = false, sameBootAsLastRun = false, awaitingUserConsent = false),
        )
    }

    @Test
    fun vanishing_within_one_boot_must_ask_the_user() {
        // 这是本卡的核心：同一次开机内监听凭空消失 = force-stop 或 OEM 清理。
        // 不许自动恢复。
        assertEquals(
            WatchRecovery.ASK_USER,
            decideRecovery(watchScheduled = false, sameBootAsLastRun = true, awaitingUserConsent = false),
        )
    }

    @Test
    fun a_pending_question_survives_a_reboot() {
        // 顺序承重：awaitingUserConsent 排在最前面。已经在等用户点了，
        // **重启也不许悄悄替他决定**——否则用户重启一次手机，提示就凭空
        // 消失，"备份被谁停过"这件事他永远不会知道。
        for (watch in listOf(true, false)) {
            for (same in listOf(true, false)) {
                assertEquals(
                    "等用户点的时候，任何组合都不许自作主张（watch=$watch same=$same）",
                    WatchRecovery.ASK_USER,
                    decideRecovery(watch, same, awaitingUserConsent = true),
                )
            }
        }
    }

    // ── 落盘 ──

    @Test
    fun recording_interruption_keeps_the_boot_stamp() {
        // 回归锁：recordInterrupted 若整体覆盖而不是 copy，会把 lastBootStamp
        // 抹成 0；下一次进程启动 isSameBoot(stamp, 0) = false，"被清"就被
        // 误判成"重启"，于是自动恢复、提示永远出不来。
        val dir = tempDir("keep")
        val prefs = BackupHealthPrefs(dir)
        prefs.recordBootStamp(1_700_000_000_000L)
        prefs.recordInterrupted(1_700_000_123_456L)
        val st = prefs.load()
        assertTrue(st.interruptedUnacknowledged)
        assertEquals("开机时刻不能被抹掉", 1_700_000_000_000L, st.lastBootStamp)
        dir.deleteRecursively()
    }

    @Test
    fun acknowledging_keeps_the_boot_stamp_too() {
        val dir = tempDir("ack")
        val prefs = BackupHealthPrefs(dir)
        prefs.recordBootStamp(1_700_000_000_000L)
        prefs.recordInterrupted(1_700_000_123_456L)
        prefs.acknowledge()
        val st = prefs.load()
        assertFalse(st.interruptedUnacknowledged)
        assertEquals(1_700_000_000_000L, st.lastBootStamp)
        assertEquals("时间戳保留（排查用）", 1_700_000_123_456L, st.detectedAt)
        dir.deleteRecursively()
    }

    // ── 三处闸门（源码级）──

    @Test
    fun reconcile_records_the_boot_stamp_before_branching() {
        // 漏记开机时刻 → 下一次启动把同一次开机误判成重启 → 提示出不来。
        val s = src("backup/BackupHealth.kt")
        val body = sliceAfter(s, "fun reconcileWatchOnProcessStart(")
        val stampAt = body.indexOf("prefs.recordBootStamp(stamp)")
        val branchAt = body.indexOf("when (decision)")
        assertTrue("必须记开机时刻", stampAt >= 0)
        assertTrue("必须在分支之前记", stampAt in 0 until branchAt)
    }

    @Test
    fun ask_user_branch_never_rearms() {
        // 本卡的字面要求：ASK_USER 分支里既不重挂、也不跑备份。
        val s = src("backup/BackupHealth.kt")
        val branch = sliceBetween(s, "WatchRecovery.ASK_USER -> {", "}")
        assertFalse("提示分支不许重挂", branch.contains("scheduleAutoBackup"))
        assertFalse("提示分支不许重挂监听", branch.contains("ensureMediaWatch"))
        assertFalse("提示分支不许跑备份", branch.contains("triggerProcessStartCatchup"))
        assertTrue("必须记录中断", branch.contains("recordInterrupted"))
    }

    @Test
    fun opening_the_app_does_not_silently_recover() {
        // 用户实测两次都栽在这条路径上："还是没有提示，强行停止立即就恢复了。"
        // Application 的对账和 MainActivity 的 LaunchedEffect 是两条独立入口，
        // 闸门缺一处就等于没有。
        //
        // MOB-35（2026-08-25）改了这条断言的**形状**，没改它守的**不变量**：
        // 原来断言的是 `if (backupInterrupted) return@LaunchedEffect` 这个具体
        // 写法，但那一个 return 同时挡住了「重挂后台监听」（该挡）和「用户在
        // 前台的补捞」（不该挡）。用户定调："前台情况下，都无法上传，是不是
        // 不合理呢？"——前台 = 人在场 = 该传。
        // 于是断言改成盯不变量本身：**重挂必须受中断标志门控**。谁把门控去掉
        // （写成裸的 scheduleAutoBackup），这条照样红。
        val s = src("MainActivity.kt")
        val effect = sliceBetween(s, "LaunchedEffect(backupInterrupted) {", "}")
        assertTrue(
            "打开 App 不许悄悄重挂后台监听——重挂必须受中断标志门控",
            effect.contains("if (!backupInterrupted) scheduleAutoBackup"),
        )
        // 反面：块内不许有「命中中断标志就整块早退」的写法，那会把前台补捞
        // 一起冻住（MOB-35 回归）。
        assertFalse(
            "不许整块早退——那会连前台补捞一起冻住（MOB-35）",
            effect.contains("if (backupInterrupted) return"),
        )
        // 恢复的唯一入口：提示卡上的按钮。
        assertTrue("必须接上恢复入口", s.contains("resumeAfterInterruption(context)"))
    }

    @Test
    fun resume_is_the_only_door_back() {
        val s = src("backup/BackupHealth.kt")
        val body = sliceAfter(s, "fun resumeAfterInterruption(")
        assertTrue("必须清标志", body.contains("acknowledge()"))
        assertTrue("必须重挂", body.contains("scheduleAutoBackup(context)"))
        assertTrue("必须立刻补跑一次（人在操作）", body.contains("triggerUserPresentBackup(context)"))
    }

    @Test
    fun boot_receiver_is_registered_and_survives_the_broadcast() {
        val manifest = File(repoRoot(), "apps/android/app/src/main/AndroidManifest.xml").readText()
        assertTrue(
            "开机 receiver 必须注册——看门 job 不可持久化，重启必死",
            manifest.contains("android:name=\".backup.BootWatchReceiver\""),
        )
        assertTrue(
            "必须声明 RECEIVE_BOOT_COMPLETED",
            manifest.contains("android.permission.RECEIVE_BOOT_COMPLETED"),
        )
        val receiver = sliceBetween(manifest, ".backup.BootWatchReceiver", "</receiver>")
        assertTrue(
            "BOOT_COMPLETED 来自系统，exported 必须为 true",
            receiver.contains("android:exported=\"true\""),
        )
        assertTrue(receiver.contains("android.intent.action.BOOT_COMPLETED"))

        val s = src("backup/BootWatchReceiver.kt")
        assertTrue(
            "必须 goAsync——onReceive 返回后进程即可被回收，对账要读文件+发 binder",
            s.contains("goAsync()") && s.contains("pending.finish()"),
        )
        assertTrue(
            "finish 必须在 finally（异常路径漏 finish 会挂住广播）",
            sliceAfter(s, "finally").contains("pending.finish()"),
        )
        assertTrue("只认 BOOT_COMPLETED", s.contains("Intent.ACTION_BOOT_COMPLETED"))
    }

    @Test
    fun process_start_goes_through_the_shared_reconcile() {
        // Application 与开机 receiver 必须共用同一段判定——两份实现会漂移，
        // 而漂移的后果是"某条路径悄悄恢复了"，正是本卡要防的事。
        val app = src("PPassApplication.kt")
        assertTrue(app.contains("reconcileWatchOnProcessStart("))
        assertFalse("Application 不许自己判定/自己重挂", app.contains("scheduleAutoBackup("))
        val recv = src("backup/BootWatchReceiver.kt")
        assertTrue(recv.contains("reconcileWatchOnProcessStart("))
        assertFalse("receiver 不许自己判定/自己重挂", recv.contains("scheduleAutoBackup("))
    }
}
