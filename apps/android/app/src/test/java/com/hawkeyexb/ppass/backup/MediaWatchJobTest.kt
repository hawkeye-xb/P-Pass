// MOB-27：监听与干活分家的回归锁。
//
// 这张卡的所有结论都来自 AOSP 一手文档（本机
// ~/Library/Android/sdk/sources/android-36/android/app/job/JobInfo.java:1763
// 逐字核对），下面每条断言都标了它锁的是哪一句。
//
// JVM 侧的硬限制：mockable android.jar 下 `JobInfo.Builder` 造不出来
// （ComponentName / MediaStore 静态字段皆为 null），所以接线证据只能走
// **源码级断言**（codeOf 剥注释，DOG-01d 同款手法）+ 真机验收。纯逻辑
// （队列去重判据）走真单测。
package com.hawkeyexb.ppass.backup

import androidx.work.WorkInfo
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaWatchJobTest {

    /** 源码级断言的公共前处理：**剥掉所有注释**（块注释 + 行注释）。
     *
     *  教训 A（2026-08-19）：`src.contains("foo()")` 拦不住回归——把那行注释掉，
     *  字符串照样在文件里，测试依旧绿。反证跑出来不红才发现。
     *
     *  教训 B（同日，写本文件时当场撞到）：只剥 `//` 不够。KDoc 里引用
     *  javadoc 原文时写了 `jobFinished()`，于是"不该出现 jobFinished"
     *  这条断言被自己的注释判红。**否定式断言必须先剥干净块注释**，
     *  否则解释性文字会伪造成代码。 */
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

    private fun watchSrc(): String = codeOf(
        File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/MediaWatchJob.kt")
    )

    private fun workerSrc(): String = codeOf(
        File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt")
    )

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

    // ── 队列去重（纯逻辑，真单测）──

    @Test
    fun dispatches_when_nothing_is_waiting() {
        assertTrue("没有任何 work → 必须派活", shouldDispatchWatchBackup(emptyList()))
    }

    @Test
    fun dispatches_even_while_one_is_running() {
        // 这条是整个 MOB-27 的核心：**正在跑的那个不算数**。
        // 它可能已经扫过水位了，这次事件的照片它未必看得到——必须再排一个
        // 跟在它后面。旧实现（KEEP）正是在这里把事件吞掉，于是"备份期间拍
        // 的照片要等下一个事件"。
        assertTrue(
            "RUNNING 不构成去重理由（它可能已扫过水位）",
            shouldDispatchWatchBackup(listOf(WorkInfo.State.RUNNING)),
        )
    }

    @Test
    fun skips_when_something_is_already_waiting() {
        // ENQUEUED = 等约束（比如没连 Wi-Fi）；BLOCKED = 排在前一个后面。
        // 两者都是"还没跑，跑起来会扫水位以上全部"，所以这次事件被它覆盖。
        assertFalse(
            "已有等约束的 → 不必再排",
            shouldDispatchWatchBackup(listOf(WorkInfo.State.ENQUEUED)),
        )
        assertFalse(
            "已有排队的 → 不必再排",
            shouldDispatchWatchBackup(listOf(WorkInfo.State.BLOCKED)),
        )
        assertFalse(
            "跑着的 + 排队的 → 队列已满足，不再叠加",
            shouldDispatchWatchBackup(listOf(WorkInfo.State.RUNNING, WorkInfo.State.BLOCKED)),
        )
    }

    @Test
    fun terminal_states_do_not_block_dispatch() {
        // 上一条链跑完/失败/被取消之后，新事件必须能重新排——否则一次失败
        // 就把这条通道永久堵死。
        assertTrue(shouldDispatchWatchBackup(listOf(WorkInfo.State.SUCCEEDED)))
        assertTrue(shouldDispatchWatchBackup(listOf(WorkInfo.State.FAILED)))
        assertTrue(shouldDispatchWatchBackup(listOf(WorkInfo.State.CANCELLED)))
    }

    @Test
    fun job_id_is_a_stable_constant() {
        // 支点：系统的"运行期间变更转交给下一个 job"是**按 job ID 认人**的
        // （javadoc: "schedule a new JobInfo using the same job ID"）。
        // ID 一变，队列就断了——所以它必须是硬编码常量，不许算出来。
        assertEquals(20260819, MEDIA_WATCH_JOB_ID)
        assertTrue("派活通道要有独立 unique name", MEDIA_WATCH_BACKUP_WORK_NAME.isNotBlank())
        assertTrue(MEDIA_WATCH_BACKUP_WORK_NAME != BACKUP_WORK_NAME)
        assertTrue(MEDIA_WATCH_BACKUP_WORK_NAME != CATCHUP_WORK_NAME)
        assertTrue(MEDIA_WATCH_BACKUP_WORK_NAME != PROCESS_CATCHUP_WORK_NAME)
    }

    // ── 看门 Job 的接线（源码级）──

    @Test
    fun watch_job_listens_for_descendants() {
        // MOB-08 根因回归锁，**全项目最贵的一个教训**，随载体搬家而来：
        // MediaProvider 在 insert 后 notifyChange 发的是带行 id 的 item URI
        // （.../images/media/1000000299），不是集合 URI。精确匹配永远收不到
        // 通知，content trigger 从此一次都不触发（用户看到的就是"不主动同步"）。
        val src = watchSrc()
        assertTrue(
            "必须 FLAG_NOTIFY_FOR_DESCENDANTS，否则收不到 item URI 通知",
            src.contains("JobInfo.TriggerContentUri.FLAG_NOTIFY_FOR_DESCENDANTS"),
        )
        assertTrue(
            "不允许退回精确匹配（flag=0）",
            !src.contains("TriggerContentUri(it, 0)"),
        )
        assertTrue(
            "必须监听 MediaStore 两集合",
            src.contains("MediaStore.Images.Media.EXTERNAL_CONTENT_URI") &&
                src.contains("MediaStore.Video.Media.EXTERNAL_CONTENT_URI"),
        )
    }

    @Test
    fun watch_job_carries_the_burst_aggregation_delays() {
        // MOB-11 的两个节奏参数随载体搬家，语义不变：
        // update delay 是**尾沿防抖**——连拍期间计时不断重置，停手 1s 才响
        // 一次。所以 100ms 连拍 5 秒（50 张）只触发 1 次，不是 50 次。
        // max delay 是从**第一次**变化起算的强制闸，防持续 churn 把备份饿死。
        assertEquals(1L * 1000, CONTENT_UPDATE_DELAY_MS)
        assertEquals(30L * 1000, CONTENT_MAX_DELAY_MS)
        assertTrue(
            "max delay 必须秒级封顶（不得超过 update delay 的 60 倍）",
            CONTENT_MAX_DELAY_MS <= CONTENT_UPDATE_DELAY_MS * 60,
        )
        val src = watchSrc()
        assertTrue(
            "update delay 必须接线",
            src.contains("setTriggerContentUpdateDelay(CONTENT_UPDATE_DELAY_MS)"),
        )
        assertTrue(
            "max delay 必须接线",
            src.contains("setTriggerContentMaxDelay(CONTENT_MAX_DELAY_MS)"),
        )
    }

    @Test
    fun watch_job_has_no_constraints() {
        // MOB-27 顺手堵的第二个洞：旧的 content trigger 带着 UNMETERED +
        // batteryNotLow 约束，意味着**不连 Wi-Fi 时监听压根不会被投递**——
        // 出门拍一天照，那一天的通知全丢，只能等 5h 周期兜底或用户开 App。
        //
        // 约束属于派出去的备份 work，不属于监听：有新照片立刻知道，能不能
        // 传是另一回事。
        val body = sliceBetween(watchSrc(), "fun buildMediaWatchJobInfo(", "private fun jobScheduler(")
        for (forbidden in listOf(
            "setRequiredNetworkType",
            "setRequiresCharging",
            "setRequiresBatteryNotLow",
            "setRequiresDeviceIdle",
            "setRequiresStorageNotLow",
        )) {
            assertFalse(
                "监听不许带约束（$forbidden）——带了就等于条件不满足时收不到通知",
                body.contains(forbidden),
            )
        }
        // 反过来：约束必须出现在派活那一段。
        val dispatch = sliceBetween(watchSrc(), "internal fun dispatchWatchBackup(", "\nclass MediaWatchJob")
        assertTrue(
            "备份 work 必须带后台档约束（Wi-Fi 随设置 + 电量不低）",
            dispatch.contains("constraintsFor(BackupTier.BACKGROUND, settings)"),
        )
    }

    @Test
    fun watch_job_dispatches_before_it_rearms() {
        // **顺序是承重的。** javadoc 原文：
        //   "Scheduling the new job before or during processing will cause the
        //    current job to be stopped […] your app process may be killed since
        //    it will no longer be in a valid component lifecycle."
        // 先重挂的话，派活的代码可能根本跑不到——监听是活的，但这一波照片
        // 没人管。调换顺序 → 本测试必红。
        val body = sliceAfter(watchSrc(), "override fun onStartJob(")
        val dispatchAt = body.indexOf("dispatchWatchBackup(ctx)")
        val rearmAt = body.indexOf("scheduleMediaWatchNow(ctx)")
        assertTrue("onStartJob 必须派活", dispatchAt >= 0)
        assertTrue("onStartJob 必须重挂", rearmAt >= 0)
        assertTrue("必须先派活、后重挂", dispatchAt < rearmAt)
        // 重挂必须在 finally：派活抛异常最多丢一轮（水位没动，下个事件捞得
        // 回来），重挂没跑到是**监听永久消失**。
        assertTrue("重挂必须在 finally 里", sliceAfter(body, "finally").contains("scheduleMediaWatchNow(ctx)"))
    }

    @Test
    fun watch_job_replaces_jobfinished_with_schedule() {
        // javadoc: "you do not need to call jobFinished() if you call
        // schedule() using the same job ID as the currently running job."
        // 我们靠 schedule(同 ID) 结束当前 job——这正是官方的"释放"动作。
        // 若有人补一句 jobFinished()，会在 schedule 之外多一条结束路径，
        // 破坏"处理完才释放"的时序。
        val src = watchSrc()
        assertTrue("不该出现 jobFinished（schedule 同 ID 已经终结当前 job）", !src.contains("jobFinished("))
        assertTrue(
            "onStartJob 必须返回 true（派活要等落库，是异步工作）",
            sliceBetween(src, "override fun onStartJob(", "override fun onStopJob").contains("return true"),
        )
    }

    @Test
    fun dispatch_queues_instead_of_dropping_or_preempting() {
        val dispatch = sliceAfter(watchSrc(), "internal fun dispatchWatchBackup(")
        assertTrue(
            "派活必须排队（APPEND_OR_REPLACE）——KEEP 会吞掉事件，REPLACE 会打断正在传的照片",
            dispatch.contains("ExistingWorkPolicy.APPEND_OR_REPLACE"),
        )
        assertTrue(
            "派活必须等落库（onStartJob 之后进程随时可能被回收）",
            dispatch.contains(".result.get()"),
        )
    }

    @Test
    fun ensure_is_guard_then_schedule() {
        // MOB-14 的教训随载体搬家：覆盖一个**正在 pending** 的 trigger job
        // 会丢掉它已积累的变更并重置 1s 防抖。javadoc 承诺的"变更转交"只
        // 覆盖 job **running** 期，不覆盖 pending 期。
        val body = sliceBetween(watchSrc(), "fun ensureMediaWatch(", "internal fun scheduleMediaWatchNow(")
        assertTrue("必须先查再挂", body.contains("if (isMediaWatchScheduled(context)) return"))
        assertTrue("查过之后才 schedule", body.contains("scheduleMediaWatchNow(context)"))
    }

    @Test
    fun schedule_failure_is_not_silent() {
        // OEM 上 JobScheduler.schedule 会**返回失败而不抛异常**（配额/限制）。
        // 静默失败 = 监听没挂上，而日志里什么都看不到。
        val body = sliceAfter(watchSrc(), "internal fun scheduleMediaWatchNow(")
        assertTrue(
            "schedule 的返回值必须检查并留痕",
            body.contains("JobScheduler.RESULT_SUCCESS") && body.contains("Log.w"),
        )
    }

    // ── 与备份链路的接线 ──

    @Test
    fun backup_worker_no_longer_owns_the_listener() {
        val src = workerSrc()
        // 旧机关必须彻底消失——留着任何一个都意味着两套监听在打架。
        for (dead in listOf(
            "ContentTriggerRearmWorker",
            "enqueueContentTriggerRearm",
            "CONTENT_TRIGGER_WORK_NAME",
            "CONTENT_REARM_WORK_NAME",
            "KEY_REARM_CATCH_UP",
            "REARM_INITIAL_DELAY_SECONDS",
        )) {
            assertFalse("旧的重挂机关必须删干净：$dead", src.contains(dead))
        }
        // 用户定调（2026-08-19）："你强行用时间来做判断的话，是不太合适的。"
        // 补捞判据不许回到"上一轮有没有照片"这种启发式。
        assertFalse(
            "不许恢复基于批次大小的补捞启发式",
            src.contains("catchUp = batchSize > 0"),
        )
    }

    @Test
    fun every_backup_round_reconfirms_the_listener() {
        // 看门 job 自己会重挂，这里是**外力清空后的复活路径**：
        // trigger URI 与 setPersisted 互斥（javadoc 明文），重启后监听必然
        // 消失；OEM 清理、schedule 被拒同理。幂等，已挂着就是 no-op。
        val finallyBody = sliceAfter(workerSrc(), "withContext(NonCancellable)")
        assertTrue(
            "每轮备份结束必须确认监听在位（5h 周期任务因此成为兜底自检）",
            finallyBody.contains("ensureMediaWatch(ctx)"),
        )
    }

    @Test
    fun process_start_must_rearm_the_listener() {
        // 承重路径：重启后 WorkManager 拉起进程跑周期任务（或 MOB-28 的开机
        // receiver）→ 判定 → 重挂。看门 job 与 setPersisted 互斥，重启必死，
        // 所以"进程起来时把监听挂回去"是唯一的复活途径。
        //
        // ⚠️ MOB-28 之后这里**不再是无条件重挂**：同一次开机内监听凭空消失
        // （force-stop / OEM 清理）时要提示、等用户点。区分靠开机时刻，见
        // WatchRecoveryTest。本测试只锁"重启这一支确实会重挂"。
        val health = codeOf(File(repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupHealth.kt"))
        val branch = sliceBetween(health, "WatchRecovery.NORMAL, WatchRecovery.AUTO_REARM -> {", "}")
        assertTrue(
            "重启/正常这一支必须重挂监听（scheduleAutoBackup 内含 ensureMediaWatch）",
            branch.contains("scheduleAutoBackup(context)"),
        )
        assertTrue("并补捞一次空窗期的照片", branch.contains("triggerProcessStartCatchup(context)"))
        // 进程启动的两个入口都必须走这段共用判定，不许各写一份。
        val app = codeOf(File(repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/PPassApplication.kt"))
        assertTrue(app.contains("reconcileWatchOnProcessStart("))
    }

    @Test
    fun upgrade_kills_the_legacy_workmanager_trigger() {
        // 真机 dumpsys 实锤（2026-08-19，RFCX1040SNE 装 0.3.3(8) 之后）：
        // `adb install -r` 保留应用数据，WorkManager 库里 `ppass-content-trigger`
        // 那条 unique work 原封不动活着，还挂着旧的带约束 trigger
        // （batteryNotLow=true + NOT_METERED + Trigger content URIs）。
        // 不清理 → 升级窗口内同一波 MediaStore 变化同时唤醒新旧两个监听，
        // 两条独立 unique 通道之间没有串行保证，会并行扫同一水位重复推字节。
        val src = watchSrc()
        assertTrue(
            "必须取消历史遗留的 content trigger unique work",
            src.contains("cancelUniqueWork(\"ppass-content-trigger\")"),
        )
        assertTrue(
            "重挂中转的遗留通道也要取消",
            src.contains("cancelUniqueWork(\"ppass-content-trigger-rearm\")"),
        )
        // 必须挂在 App 启动路径上——进程被系统拉起时也要清，不能只靠用户开 App。
        val schedule = sliceBetween(workerSrc(), "fun scheduleAutoBackup(", "\n}")
        assertTrue(
            "升级清理必须在 scheduleAutoBackup 里（进程启动即执行）",
            schedule.contains("cancelLegacyContentTriggerWork(context)"),
        )
    }

    @Test
    fun job_service_is_registered_in_manifest() {
        // BIND_JOB_SERVICE 是 JobService 的硬要求——漏了系统拒绝 bind，
        // 监听静默失效（挂得上，但永远起不来）。
        val manifest = File(repoRoot(), "apps/android/app/src/main/AndroidManifest.xml").readText()
        assertTrue(
            "看门 job 必须在 manifest 注册",
            manifest.contains("android:name=\".backup.MediaWatchJob\""),
        )
        val service = sliceBetween(manifest, ".backup.MediaWatchJob", "/>")
        assertTrue(
            "必须声明 BIND_JOB_SERVICE，否则系统拒绝 bind",
            service.contains("android.permission.BIND_JOB_SERVICE"),
        )
    }
}
