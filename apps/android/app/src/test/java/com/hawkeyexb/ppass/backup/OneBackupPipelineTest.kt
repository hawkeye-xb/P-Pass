// MOB-19：备份只有一条管线，手动是第 6 种触发方式。
//
// 用户定稿（2026-08-20）："不是说应该自动和手动触发的备份一样吗？一个就是
// 机器自动去触发，一个是我们主动去触发。触发的种类不一样……手动就相当于
// 第 5 种触发方式。你为什么这里弄了两条路径去做备份呢？"
//
// 在此之前 BackupUiStateHolder 里有**另一份**扫描+哈希+传输实现（约 130 行），
// 于是 MOB-09 的「一条坏记录不许炸整批」只修了 BackupWorker 那一份，手动那
// 份照旧一条读不了就整批失败、水位不推进、永久卡死。本文件锁住"只有一份"。
package com.hawkeyexb.ppass.backup

import androidx.work.Data
import androidx.work.WorkInfo
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.hawkeyexb.ppass.ui.BackupUiState

class OneBackupPipelineTest {

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

    private fun sliceAfter(s: String, marker: String): String {
        assertTrue("源码锚点已消失，断言失效：$marker", s.contains(marker))
        return s.substringAfter(marker)
    }

    /** 带右边界的切片。
     *
     *  ⚠️ 教训（2026-08-20 反证实测撞到）：`sliceAfter` 把锚点之后的**整个
     *  文件**都带进来，于是"triggerManualBackup 里必须是 KEEP"这条断言实际
     *  是在全文找 KEEP——而 `triggerProcessStartCatchup` 里正好有一个。把
     *  KEEP 改成 REPLACE，测试照样绿。**函数级断言必须夹出函数体。** */
    private fun sliceBetween(s: String, from: String, to: String): String {
        val tail = sliceAfter(s, from)
        assertTrue("源码结束锚点已消失，断言失效：$to", tail.contains(to))
        return tail.substringBefore(to)
    }

    private fun info(
        state: WorkInfo.State,
        progress: Data = Data.EMPTY,
        output: Data = Data.EMPTY,
    ) = WorkInfo(
        id = UUID.randomUUID(),
        state = state,
        tags = setOf(BackupWorker::class.java.name),
        outputData = output,
        progress = progress,
    )

    // ── 手动这一档的条件：零约束 ──

    @Test
    fun manual_tap_skips_every_constraint_check() {
        // 用户定稿："ABCDE 种触发方式都会过 Wi-Fi 电量的监测，那手动能不能
        // 在检测-发起之间，直接人工点击-发起？"
        // 人已经在场、亲手点的 = 当场的明确指令，压过「仅 Wi-Fi 时备份」
        // 那条**给自动备份定的规则**。点了不动是反直觉的。
        for (wifiOnly in listOf(true, false)) {
            val spec = constraintsFor(BackupTier.MANUAL, BackupSettingsState(wifiOnly = wifiOnly))
            assertFalse("手动不查 Wi-Fi（wifiOnly=$wifiOnly）", spec.requiresUnmetered)
            assertFalse("手动不查电量", spec.requiresBatteryNotLow)
        }
    }

    @Test
    fun automatic_tiers_still_honour_the_settings() {
        // 反面：把手动改成零约束**不许**顺手把自动也放开。
        val bg = constraintsFor(BackupTier.BACKGROUND, BackupSettingsState(wifiOnly = true))
        assertTrue("后台档仍查 Wi-Fi", bg.requiresUnmetered)
        assertTrue("后台档仍查电量", bg.requiresBatteryNotLow)
        val present = constraintsFor(BackupTier.USER_PRESENT, BackupSettingsState(wifiOnly = true))
        assertTrue("用户在场档仍查 Wi-Fi", present.requiresUnmetered)
    }

    @Test
    fun manual_trigger_asks_for_a_full_rescan_and_keeps_a_running_batch() {
        val body = sliceBetween(
            src("backup/BackupWorker.kt"),
            "fun triggerManualBackup(", "fun cancelManualBackup(",
        )
        assertTrue("必须走 MANUAL 档", body.contains("constraintsFor(BackupTier.MANUAL, settings)"))
        assertTrue("必须要求全量重扫", body.contains("KEY_FULL_RESCAN to true"))
        assertTrue("必须用独立 unique name", body.contains("MANUAL_BACKUP_WORK_NAME"))
        assertTrue(
            "KEEP——跑着的时候再点不许打断正在传的那批",
            body.contains("ExistingWorkPolicy.KEEP"),
        )
        assertTrue(MANUAL_BACKUP_WORK_NAME != BACKUP_WORK_NAME)
        assertTrue(MANUAL_BACKUP_WORK_NAME != MEDIA_WATCH_BACKUP_WORK_NAME)
        assertTrue(MANUAL_BACKUP_WORK_NAME != PROCESS_CATCHUP_WORK_NAME)
    }

    // ── 只有一份管线 ──

    @Test
    fun calibration_never_opens_a_backup_session() {
        // MOB-32：`existCheck` 原本先发一次 `backup.BEGIN`。校准根本不需要
        // 会话（daemon 的 `manifest` 自己会建），而 daemon 侧会话是**按设备
        // NodeId** 索引的——「备份途中打开 App」于是把正在跑的那一轮清空，
        // 186 张照片传上来后被静默丢弃、commit 却报成功。
        //
        // 夹出 existCheck 的函数体再断言：全文找 BACKUP_BEGIN 一定命中
        // `run()` 里那个**正当的** begin（2026-08-20 那次教训）。
        val body = sliceBetween(
            src("backup/BackupRunner.kt"),
            "suspend fun existCheck(",
            "private suspend fun pushFile(",
        )
        assertFalse("漂移校准不许开备份会话（MOB-32）", body.contains("BACKUP_BEGIN"))
        assertTrue("但它仍然要问 manifest", body.contains("BACKUP_MANIFEST"))
    }

    @Test
    fun the_holder_no_longer_owns_a_second_pipeline() {
        val holder = src("backup/BackupUiStateHolder.kt")
        // "自己跑一遍备份"的标志物，一个都不许留。
        //
        // ⚠️ 断言要精确到**动作**，不能只看类名：holder 里合法地留着
        // `BackupRunner(client).existCheck`（DOG-01c 漂移校准，只查不传）和
        // `MediaScanner(...).countAll`（三元组的分母 N）。按类名一刀切会把
        // 这两个正当用途也判红——第一版就是这么错的。
        for (dead in listOf(
            ".scanSince(",              // 自己扫相册取候选
            "hashWithCache(",           // 自己算哈希
            "BackupRunner(client).run(", // 自己推送 + commit
            "WatermarkStore(",           // 自己推水位
            "buildCandidates(",          // 自己构建候选
        )) {
            assertFalse("手动链路不许再有第二份管线：$dead", holder.contains(dead))
        }
        // 反过来：这两个必须还在（删错了会让三元组和校准一起哑掉）。
        assertTrue("漂移校准要留", holder.contains("existCheck("))
        assertTrue("三元组分母要留", holder.contains("countAll("))
        // 它现在只做一件事：派活。
        assertTrue(
            "手动按钮必须走统一触发入口",
            sliceBetween(holder, "fun backupNow()", "\n    }").contains("triggerManualBackup(context)"),
        )
        assertTrue(
            "进行中再点 = 暂停（UX-01 语义保住）",
            sliceBetween(holder, "fun backupNow()", "\n    }").contains("cancelManualBackup(context)"),
        )
    }

    @Test
    fun an_empty_album_scope_never_says_all_safe() {
        // FIX-T6 回归锁：一个相册都没选（空集 = 一个都不备）。worker 必须
        // 在终态里带 KEY_NO_ALBUMS，否则界面按"成功且 0 张"渲染成
        // 「照片都存好了」——那是假话（什么都没备，不是都备好了）。
        val w = src("backup/BackupWorker.kt")
        // MOB-31 起所有成功终态都过 successStamped()（盖 KEY_FINISHED_AT）。
        assertTrue(
            "空相册必须显式发 NO_ALBUMS 终态",
            w.contains("successStamped(KEY_NO_ALBUMS to true)"),
        )
        assertTrue(
            "判据是空集而不是 null（null = 全量语义，不是没选）",
            w.contains("if (bucketIds != null && bucketIds.isEmpty())"),
        )
    }

    @Test
    fun the_worker_reports_progress_for_every_stage() {
        val w = src("backup/BackupWorker.kt")
        assertTrue(w.contains("reportProgress(PHASE_SCANNING"))
        assertTrue(w.contains("reportProgress(PHASE_HASHING"))
        assertTrue(w.contains("reportProgress(PHASE_SENDING"))
        // setProgressAsync 而不是 suspend 版：调用点在 buildCandidates 的
        // build lambda 与 BackupRunner 的回调里，都不是 suspend 上下文。
        assertTrue("上报必须用非 suspend 的 API", w.contains("setProgressAsync("))
        assertTrue(
            "上报失败绝不许影响备份本身（吞异常）",
            sliceBetween(w, "private fun reportProgress(", "\n    }").contains("runCatching {"),
        )
    }

    @Test
    fun progress_is_throttled_but_never_swallows_the_first_or_last_tick() {
        // MOB-11 的教训：进度条"像卡死然后突然全传完"是用户真机报过的。
        // 节流可以省中间的，但首末两次必须发出去。
        val t = ProgressThrottle(minIntervalMs = 250L)
        assertTrue("第一条必发", t.should(done = 1, total = 100, nowMs = 1_000))
        assertFalse("紧接着的中间条被节流", t.should(done = 2, total = 100, nowMs = 1_010))
        assertFalse(t.should(done = 3, total = 100, nowMs = 1_100))
        assertTrue("超过间隔就放行", t.should(done = 40, total = 100, nowMs = 1_400))
        assertFalse(t.should(done = 41, total = 100, nowMs = 1_410))
        assertTrue("最后一条必发", t.should(done = 100, total = 100, nowMs = 1_420))
    }

    // ── 界面状态从 work 上读（纯函数） ──

    @Test
    fun running_work_drives_the_status_line() {
        fun prog(phase: String, done: Int, total: Int, file: String = "") = Data.Builder()
            .putString(KEY_PHASE, phase).putInt(KEY_DONE, done)
            .putInt(KEY_TOTAL, total).putString(KEY_FILE, file).build()

        assertEquals(
            BackupUiState.Scanning(12),
            uiStateOf(listOf(info(WorkInfo.State.RUNNING, prog(PHASE_SCANNING, 12, 12)))),
        )
        assertEquals(
            BackupUiState.Hashing(3, 50),
            uiStateOf(listOf(info(WorkInfo.State.RUNNING, prog(PHASE_HASHING, 3, 50)))),
        )
        assertEquals(
            BackupUiState.Sending(7, 20, "IMG_1.jpg"),
            uiStateOf(listOf(info(WorkInfo.State.RUNNING, prog(PHASE_SENDING, 7, 20, "IMG_1.jpg")))),
        )
    }

    @Test
    fun a_running_work_without_progress_yet_still_says_something() {
        // 用户点了按钮，绑定 daemon / 校准阶段还没发出第一条进度——
        // 界面必须立刻有反应，不能沉默（点了没动静 = 以为坏了）。
        val s = uiStateOf(listOf(info(WorkInfo.State.RUNNING)))
        assertTrue("必须已经在'动'", s is BackupUiState.Scanning)
    }

    // ── MOB-31: 终态必须按时间挑，不能拿列表最后一个 ──

    private fun done(ingested: Int, finishedAt: Long) = info(
        WorkInfo.State.SUCCEEDED,
        output = Data.Builder()
            .putInt(KEY_INGESTED, ingested)
            .putInt(KEY_DUPLICATES, 0)
            .putLong(KEY_FINISHED_AT, finishedAt)
            .build(),
    )

    @Test
    fun every_terminal_outcome_carries_a_finish_stamp() {
        // MOB-31 的真正风险不是这次改错，是**以后有人加一个新的终态返回点
        // 而忘了盖戳**——那条路径在 uiStateOf 眼里永远是"上古记录"，
        // 永远选不中，界面就会继续显示别的通道的旧数字。
        val w = src("backup/BackupWorker.kt")
        // ⚠️ 断言必须夹在 successStamped 的函数体内。整文件 contains 是恒真式
        // ——失败分支里也有同一串，把成功分支的戳删掉照样绿（反证抓到过）。
        val body = sliceBetween(w, "private fun successStamped(", "private suspend fun calibrateIfReachable(")
        assertTrue(
            "successStamped 必须盖 KEY_FINISHED_AT",
            body.contains("KEY_FINISHED_AT to System.currentTimeMillis()"),
        )
        // 除了 successStamped 自己那一处，正文里不许再出现裸 Result.success。
        val bare = Regex("""(?<!fun )Result\.success\(""").findAll(w).count()
        assertEquals(
            "成功终态只能经由 successStamped()（裸 Result.success 只允许它内部那一处）",
            1, bare,
        )
        assertTrue(
            "失败终态也要盖戳（失败也是最近发生的事）",
            w.contains("KEY_ERROR to t.toString().take(500),"),
        )
    }

    @Test
    fun the_most_recent_finished_run_wins_regardless_of_list_order() {
        // 用户 2026-08-21 真机：刚同步完 12 张，界面报「186 张」——那是前一天
        // 那次全量运行留下的旧记录。五条通道各有独立 unique name，终态同时
        // 躺着最多五条，而 getWorkInfosByTagFlow 不保证按时间排序。
        val old = done(ingested = 186, finishedAt = 1_000L)
        val fresh = done(ingested = 12, finishedAt = 2_000L)

        // 新的排在前面（旧的是列表最后一个）——旧口径会挑中 186。
        assertEquals(
            BackupUiState.AllSafe(12, 0),
            uiStateOf(listOf(fresh, old)),
        )
        // 顺序反过来结果必须一样。
        assertEquals(
            BackupUiState.AllSafe(12, 0),
            uiStateOf(listOf(old, fresh)),
        )
    }

    @Test
    fun five_channels_of_history_still_yield_the_newest() {
        val infos = listOf(
            done(ingested = 186, finishedAt = 1_000L),
            done(ingested = 0, finishedAt = 1_500L),
            done(ingested = 12, finishedAt = 9_000L), // 最近
            done(ingested = 3, finishedAt = 2_000L),
            done(ingested = 40, finishedAt = 500L),
        )
        assertEquals(BackupUiState.AllSafe(12, 0), uiStateOf(infos))
    }

    @Test
    fun unstamped_history_never_beats_a_stamped_run() {
        // 升级前的存量终态没有时间戳（也拿不到 CANCELLED 的 outputData）
        // ——它们必须算最旧，否则一条上古记录会永久盖住新结果。
        val legacy = info(
            WorkInfo.State.SUCCEEDED,
            output = Data.Builder().putInt(KEY_INGESTED, 186).putInt(KEY_DUPLICATES, 0).build(),
        )
        val fresh = done(ingested = 12, finishedAt = 2_000L)
        assertEquals(BackupUiState.AllSafe(12, 0), uiStateOf(listOf(fresh, legacy)))
        assertEquals(BackupUiState.AllSafe(12, 0), uiStateOf(listOf(legacy, fresh)))
    }

    @Test
    fun all_unstamped_falls_back_to_list_order_not_null() {
        // 升级后首帧可能全是没戳的存量记录——不能因此变空白。
        // 两条而不是一条：只有一条时任何挑法结果都一样，那是弱断言。
        fun legacy(n: Int) = info(
            WorkInfo.State.SUCCEEDED,
            output = Data.Builder().putInt(KEY_INGESTED, n).putInt(KEY_DUPLICATES, 0).build(),
        )
        assertEquals(
            "全是存量记录时退回旧口径（列表最后一个），而不是空白",
            BackupUiState.AllSafe(7, 0),
            uiStateOf(listOf(legacy(186), legacy(7))),
        )
    }

    @Test
    fun running_wins_over_finished_history() {
        // 四条自动通道 + 手动通道共用同一个 tag，列表里会混着历史终态。
        // 正在跑的那条才是用户此刻该看到的。
        val infos = listOf(
            info(WorkInfo.State.SUCCEEDED, output = Data.Builder().putInt(KEY_INGESTED, 9).build()),
            info(
                WorkInfo.State.RUNNING,
                Data.Builder().putString(KEY_PHASE, PHASE_SENDING)
                    .putInt(KEY_DONE, 1).putInt(KEY_TOTAL, 2).build(),
            ),
        )
        assertTrue(uiStateOf(infos) is BackupUiState.Sending)
    }

    @Test
    fun terminal_states_carry_the_numbers_and_the_reasons() {
        assertEquals(
            BackupUiState.AllSafe(5, 2),
            uiStateOf(listOf(info(
                WorkInfo.State.SUCCEEDED,
                output = Data.Builder().putInt(KEY_INGESTED, 5).putInt(KEY_DUPLICATES, 2).build(),
            ))),
        )
        // FIX-T6: 一个相册都没选——必须说「没有可备份的相册」，
        // 绝不能说「照片都存好了」（那是假话）。
        assertEquals(
            BackupUiState.NoAlbums,
            uiStateOf(listOf(info(
                WorkInfo.State.SUCCEEDED,
                output = Data.Builder().putBoolean(KEY_NO_ALBUMS, true).build(),
            ))),
        )
        val trouble = uiStateOf(listOf(info(
            WorkInfo.State.FAILED,
            output = Data.Builder().putString(KEY_ERROR, "boom err.not_paired").build(),
        )))
        assertTrue(trouble is BackupUiState.Trouble)
        assertTrue("原始错误串要带上（「查看技术详情」折叠区用）",
            (trouble as BackupUiState.Trouble).text.contains("boom"))
        // UX-01: 用户按暂停 = 取消，回 Idle，不是"出错了"。
        assertEquals(BackupUiState.Idle, uiStateOf(listOf(info(WorkInfo.State.CANCELLED))))
    }

    @Test
    fun nothing_to_show_keeps_the_current_state() {
        // 返回 null = 调用方保持现状。绝不能擅自改回 Idle——那会让正在
        // 显示的进度闪回，用户看到的是"跑着的突然消失了"。
        assertNull(uiStateOf(emptyList()))
        assertNull("排队等约束不改状态行", uiStateOf(listOf(info(WorkInfo.State.ENQUEUED))))
    }

    @Test
    fun pairing_lost_is_recognised_from_the_error_string() {
        // work 的 outputData 只能带基本类型，异常对象过不来——所以配对失效
        // 的判据在字符串层，与 isPairingLostError 同一套。
        assertTrue(isPairingLostText("... err.not_paired ..."))
        assertTrue(isPairingLostText("... err.not_authorized ..."))
        assertFalse(isPairingLostText("java.net.SocketTimeoutException"))
    }
}
