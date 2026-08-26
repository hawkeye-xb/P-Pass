// UX-14（2026-08-26 真机 0.4.0-test.8）：失败重试被渲染成「被暂停」。
//
// 验收人原话：「怎么传一半自己暂停了，你查看下日志，是否是我误触了，按道理
// 我没碰到。」——**没有误触**。logcat：
//
//   17:12:48.643  cancelled by system, stopReason=CANCELLED_BY_APP(1)
//                 ← 验收人主动按的暂停 → 落盘 pausedAt = 17:12:48
//                 ← 点「继续」→ 新一轮开跑，sending 54/198 …
//   17:16:48.545  auto backup failed, will retry
//                 IrohError { kind: Stream, message: "ConnectionLost(TimedOut)" }
//   17:18:31.896  auto backup: offered=228 pushed=68 ingested=214   ← 约 2 分钟后自愈
//
// 根因：UX-13 的判据拿「最新的带戳完成记录」判断这次暂停有没有被覆盖，而失败
// 重试走 `Result.retry()`——**WorkManager 的 retry 结构上拿不到 outputData**，
// 那一轮不可能盖 KEY_FINISHED_AT。于是续传那一轮确实开跑过，却没留下任何带戳
// 终态，判据眼里那次暂停「还没被覆盖」→ 又冒出「继续」。
//
// 锚点因此从「跑完」扩到「开跑」：一轮开跑就意味着这次暂停被消费掉了。
package com.hawkeyexb.ppass

import com.hawkeyexb.ppass.backup.pausedAfterOf
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FailedRetryIsNotPausedTest {

    private fun codeOf(rel: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$rel")
            .readText().lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")
    }

    // ── ① 本卡的本体判据 ──

    @Test
    fun a_run_that_started_after_the_pause_expires_it_even_without_a_stamp() {
        // 真机那一幕的数值化：暂停在 1000，续传那一轮 1100 开跑，跑挂了走
        // retry → 一条带戳终态都没新增（newestFinishedAt 还是暂停之前的 500）。
        assertFalse(
            "开跑过就说明这次暂停被消费了——失败重试不许被显示成「被暂停」",
            pausedAfterOf(
                pausedAt = 1_000L,
                newestFinishedAt = 500L,
                anyRunning = false,
                lastStartedAt = 1_100L,
            ),
        )
    }

    @Test
    fun a_pause_with_nothing_started_after_it_is_still_a_pause() {
        // UX-13 的本体不许被改坏：暂停之后什么都没跑 → 仍然是被暂停态，
        // 「继续」按钮必须在原地（含杀 App 重开的场景）。
        assertTrue(
            "暂停之后没有任何一轮开跑 → 仍然是被暂停",
            pausedAfterOf(
                pausedAt = 1_000L,
                newestFinishedAt = 500L,
                anyRunning = false,
                lastStartedAt = 900L, // 上一轮开跑在暂停之前
            ),
        )
    }

    @Test
    fun bytes_still_flying_wins_over_everything() {
        // MOB-33 红线不受本卡影响：有 work 在跑就是进行中，不管两个锚点怎么排。
        assertFalse(
            "有 work 在跑就不是暂停态",
            pausedAfterOf(
                pausedAt = 1_000L, newestFinishedAt = 0L,
                anyRunning = true, lastStartedAt = 1_100L,
            ),
        )
    }

    @Test
    fun the_two_anchors_are_both_honoured() {
        // 两个锚点是「或」的关系（任一晚于暂停就过期），不是只看新加的那个。
        assertFalse(
            "只有完成锚点晚于暂停 → 也算过期（UX-13 的原判据不许失效）",
            pausedAfterOf(
                pausedAt = 1_000L, newestFinishedAt = 2_000L,
                anyRunning = false, lastStartedAt = 0L,
            ),
        )
        assertFalse(
            "只有开跑锚点晚于暂停 → 也算过期（本卡新增）",
            pausedAfterOf(
                pausedAt = 1_000L, newestFinishedAt = 0L,
                anyRunning = false, lastStartedAt = 2_000L,
            ),
        )
    }

    // ── ② 落盘的位置是承重的 ──

    @Test
    fun the_start_stamp_is_written_after_winning_the_mutex_and_before_scanning() {
        // 两条位置约束，各有一个具体的坏后果：
        //
        // 「抢到互斥门之后」——空转那一轮（MOB-33 的 CAS 抢门失败）什么也没干，
        //   算它开跑就会把**别人**的暂停误判成已覆盖。判据：落盘语句在
        //   runBackup 里，而不是在 doWork 的抢门分支里。
        // 「扫描之前」——失败重试留不下终态戳，开跑这个事实是唯一一定能落下
        //   的东西，所以不能等到扫描/传输之后再写。
        val worker = codeOf("backup/BackupWorker.kt")
        val write = worker.indexOf("RunStartPrefs(stateDir).setStartedAt(")
        assertTrue("源码锚点已消失：RunStartPrefs(stateDir).setStartedAt(", write >= 0)

        val doWorkAt = worker.indexOf("override suspend fun doWork()")
        val runBackupAt = worker.indexOf("private suspend fun runBackup(")
        assertTrue("源码锚点已消失：doWork / runBackup", doWorkAt >= 0 && runBackupAt >= 0)
        assertTrue(
            "落盘必须在 runBackup 里（doWork 的空转早退分支不算开跑）",
            write > runBackupAt,
        )

        val scan = worker.indexOf("scanner.scanSince(")
        assertTrue("源码锚点已消失：scanner.scanSince(", scan >= 0)
        assertTrue("落盘必须在扫描之前", write < scan)
    }

    @Test
    fun the_ui_reads_the_start_stamp_and_feeds_it_to_the_verdict() {
        // 判据对了不等于界面用上了。钉接线：holder 读盘 + 把它传进 uiStateOf。
        // **不钉参数列表的字面形状**——本仓已经为此误伤五次。
        val holder = codeOf("backup/BackupUiStateHolder.kt")
        assertTrue("holder 必须读开跑时刻", holder.contains("runStartPrefs.startedAt()"))
        val call = holder.substringAfter("uiStateOf(infos").substringBefore(")")
        assertTrue(
            "holder 必须把开跑时刻传给 uiStateOf（当前实参：$call）",
            call.contains("lastStartedAt"),
        )
        val verdict = holder.substringAfter("pausedAfterOf(").substringBefore("))")
        assertTrue(
            "判据调用必须带上开跑时刻这个锚点",
            verdict.contains("lastStartedAt"),
        )
    }
}
