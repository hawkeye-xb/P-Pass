// MOB-33（2026-08-26 真机走查升 L0）：暂停是**管线级**动作，不是通道级。
//
// 验收人定的原则：「咱们的传输不是只有一个路径吗？那暂停是不是也得在一个
// 路径？你这还分什么自动手动？上传都不分自动手动了，只有触发会区分自动手动。」
// ——与 MOB-19 的既有定调一致（备份只有一条管线，手动是第 6 种触发方式）。
//
// 原来的三个缺陷：
//   ① cancelManualBackup 只取消 MANUAL_BACKUP_WORK_NAME，而界面按 tag 观察
//      全部五条通道 → 自动触发的备份也显示进度条、也出现暂停按钮，点下去
//      取消不了它（验收人：「暂停按钮没有任何用处」）。
//   ② 点完 `_state.value = BackupUiState.Idle` 让界面当场假装停了，字节还在
//      传——界面与传输脱钩。
//   ③ uiStateOf 用 firstOrNull { RUNNING } 挑，两条同时 RUNNING 时随机挑一条，
//      界面在两轮进度之间来回跳（验收人：「正在读文件后，有长时间 pending，
//      然后在展示读文件，再上传」）。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnePipelineOnePauseTest {

    /** 源码断言的前处理：剥注释行——正向 contains 会被「把那行注释掉」骗过，
     *  反向禁令会被注释里引用的旧写法误判（ReuploadCompensationTest 同款）。 */
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

    private fun sliceBetween(s: String, from: String, to: String): String {
        assertTrue("源码锚点已消失，断言失效：$from", s.contains(from))
        val tail = s.substringAfter(from)
        assertTrue("源码结束锚点已消失，断言失效：$to", tail.contains(to))
        return tail.substringBefore(to)
    }

    // ── ① 暂停取消的是「正在跑的那条」，不是固定通道 ──

    @Test
    fun pause_cancels_the_running_work_not_the_manual_channel() {
        val body = sliceBetween(
            codeOf("backup/BackupUiStateHolder.kt"),
            "fun backupNow()",
            "triggerManualBackup(context)",
        )
        assertTrue(
            "暂停必须按 id 取消当前正在跑的那条 work（管线级，不认通道）",
            body.contains("cancelWorkById"),
        )
        assertTrue(
            "id 必须来自 runningWorkId（与界面显示的是同一条）",
            body.contains("runningWorkId"),
        )
    }

    @Test
    fun pause_does_not_fake_an_idle_state() {
        // ② 的判据：点完不许自己把状态置成 Idle。状态必须等 WorkManager 把
        // CANCELLED 回报回来，否则界面说停了而字节还在传。
        val body = sliceBetween(
            codeOf("backup/BackupUiStateHolder.kt"),
            "fun backupNow()",
            "triggerManualBackup(context)",
        )
        assertFalse(
            "暂停后不许自己置 Idle——那会让界面与传输脱钩（MOB-33 症状②）",
            body.contains("_state.value = BackupUiState.Idle"),
        )
    }

    @Test
    fun the_pause_target_and_the_displayed_run_are_the_same_one() {
        // 「界面在显示谁的进度」和「暂停会停掉谁」必须是同一条——两处都走
        // runningInfoOf。少了这条一致性，暂停又会停错。
        val holder = codeOf("backup/BackupUiStateHolder.kt")
        assertTrue(
            "记 runningWorkId 必须用 runningInfoOf",
            holder.contains("runningWorkId = runningInfoOf("),
        )
        val uiState = sliceBetween(holder, "fun uiStateOf(", "val finished =")
        assertTrue(
            "uiStateOf 也必须用 runningInfoOf 选正在跑的那条",
            uiState.contains("runningInfoOf(infos)"),
        )
        assertFalse(
            "不许再用 firstOrNull { RUNNING }——两条同时跑时它随机挑（症状③）",
            uiState.contains("firstOrNull"),
        )
    }

    // ── ③ RUNNING 的选取是确定性的 ──

    @Test
    fun running_selection_is_stable_regardless_of_list_order() {
        // 纯逻辑判据：同一批 work 换个顺序，选出来必须是同一条。
        // 这里不构造真的 WorkInfo（它的构造函数是 @RestrictTo），改为断言
        // 选取键是「按 id 排序」而不是「取列表第一个」。
        val fn = sliceBetween(
            codeOf("backup/BackupUiStateHolder.kt"),
            "fun runningInfoOf(",
            "fun uiStateOf(",
        )
        assertTrue("必须先筛出全部 RUNNING", fn.contains("State.RUNNING"))
        assertTrue(
            "必须按 id 排序取最小——保证同一批输入永远选出同一条",
            fn.contains("minByOrNull") && fn.contains("id.toString()"),
        )
    }

    // ── ④ 一次只跑一轮备份 ──

    @Test
    fun only_one_backup_runs_at_a_time() {
        val worker = codeOf("backup/BackupWorker.kt")
        assertTrue(
            "必须有进程级互斥门",
            worker.contains("backupInFlight") && worker.contains("AtomicBoolean"),
        )
        val doWork = sliceBetween(worker, "override suspend fun doWork()", "private suspend fun runBackup")
        assertTrue(
            "doWork 入口必须 CAS 抢门",
            doWork.contains("backupInFlight.compareAndSet(false, true)"),
        )
        // 钉**不变量**而不是字面形状：抢不到时必须以「成功」收场，不许 retry
        // （会按退避重排出一串无意义的重试）也不许 failure（界面会报错）。
        // 具体走 `Result.success()` 还是 `successStamped(…)` 是实现细节——
        // 本测试第一版钉的是前者，于是我把它改成 successStamped（为满足
        // MOB-31 的盖戳不变量，正当改动）就被自己误伤变红。
        assertFalse("抢不到不许 retry", doWork.contains("Result.retry()"))
        assertFalse("抢不到不许 failure", doWork.contains("Result.failure()"))
        assertTrue(
            "抢不到必须以成功收场（Result.success 或 successStamped 皆可）",
            doWork.contains("Result.success(") || doWork.contains("successStamped("),
        )
        assertTrue(
            "必须在 finally 里放门，否则一次异常就永久卡死备份",
            doWork.contains("finally") && doWork.contains("backupInFlight.set(false)"),
        )
    }

    @Test
    fun a_skipped_run_is_stamped_but_never_displayed() {
        // 空转那一轮（抢不到互斥门）是终态返回，按 MOB-31 的不变量必须盖戳；
        // 但它不是一个结果，必须被 uiStateOf 排除。两件事分开表达。
        //
        // 不排除的具体后果：用户点暂停 → 那条 work 变 CANCELLED，而
        // WorkManager 取消时拿不到 outputData → 无戳 → 被当上古记录；空转那条
        // 有戳且更「新」→ 被选中 → 界面显示「已备份 0 张」而不是 Idle。
        val worker = codeOf("backup/BackupWorker.kt")
        val doWork = sliceBetween(
            worker, "override suspend fun doWork()", "private suspend fun runBackup",
        )
        assertTrue(
            "空转必须走 successStamped（盖戳），不许裸 Result.success",
            doWork.contains("successStamped(KEY_SKIPPED to true)"),
        )
        val holder = codeOf("backup/BackupUiStateHolder.kt")
        val pick = sliceBetween(holder, "val finished = infos.filter", "return when {")
        assertTrue(
            "uiStateOf 必须把空转那条排除掉",
            pick.contains("KEY_SKIPPED"),
        )
    }

    // ── ⑤ 进度条 UI：M3 1.3 的两个默认值必须被覆盖 ──

    @Test
    fun progress_bar_overrides_the_material3_defaults() {
        // compose-bom:2024.12.01 = material3 1.3.x，它给 LinearProgressIndicator
        // 加了默认 gapSize = 4.dp（指示条与轨道之间一道缝，跟着进度头走，看起来
        // 像一个洞在移动）和 drawStopIndicator（末端一个圆点）。两个都要显式关掉，
        // 否则就是验收人说的「有断层……看着不是标准的」。
        // ⚠️ 不能用 sliceBetween(…, ")")——第一个 `)` 落在
        // `Modifier.fillMaxWidth()` 里，切片会在参数列表中间截断（本测试
        // 第一版就是这么红的）。改取调用之后的**有界窗口**：这个调用总共
        // 不到十行，600 字符足够覆盖且不会跨到下一个组件。
        val home = codeOf("ui/HomeScreen.kt")
        val at = home.indexOf("LinearProgressIndicator(")
        assertTrue("源码锚点已消失：LinearProgressIndicator(", at >= 0)
        val bar = home.substring(at, minOf(at + 600, home.length))
        assertTrue("必须关掉 gapSize（那道缝）", bar.contains("gapSize = 0.dp"))
        assertTrue("必须关掉末端圆点", bar.contains("drawStopIndicator = {}"))
    }

    @Test
    fun compose_bom_is_still_the_version_these_defaults_come_from() {
        // 上一条钉的是「覆盖了 M3 1.3 的默认值」。如果哪天升了 bom 而默认值
        // 变了，上一条会变成无意义的教条——这里把版本前提也钉住，升级时会
        // 顺带看到这条注释。
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        val gradle = File(dir, "apps/android/app/build.gradle.kts").readText()
        assertNotNull(
            "找不到 compose-bom 声明——上一条断言的版本前提失效了",
            Regex("compose-bom:(\\d{4})\\.(\\d{2})\\.(\\d{2})").find(gradle),
        )
        assertEquals(
            "compose-bom 变了：请复核 LinearProgressIndicator 的默认 gapSize / " +
                "drawStopIndicator 是否还需要覆盖（M3 1.3 起才有）",
            "2024.12.01",
            Regex("compose-bom:([0-9.]+)").find(gradle)!!.groupValues[1],
        )
    }
}
