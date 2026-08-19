// MOB-02（2026-08-11 用户定稿）卡面验收 1/2/3/4/5/6 的纯函数层测试。
// 反证（卡面 §反证）：
//   - 把用户在场档的充电豁免去掉 → user_present_ignores_charging 必红；
//   - 把 content trigger 的 update/max delay 去掉 → 验收 2 必红。
package com.hawkeyexb.ppass.backup

import androidx.work.ExistingWorkPolicy
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TriggerPolicyTest {

    /** 源码级断言的公共前处理：**剥掉注释行**。
     *
     *  教训（2026-08-19）：`src.contains("foo()")` 这种断言拦不住回归——
     *  把那行代码注释掉，字符串照样在文件里，测试依旧绿。反证跑出来不红
     *  才发现。所有源码级断言都必须先过这一道。 */
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

    // ── 验收 1：两档条件（用户在场档忽略充电要求，后台档全查）──

    @Test
    fun user_present_ignores_battery_requirement() {
        // 卡面 §四事件①④：人在操作，电量门槛由用户自己判断——用户在场档
        // 不设 batteryNotLow。
        val spec = constraintsFor(
            BackupTier.USER_PRESENT,
            BackupSettingsState(wifiOnly = true),
        )
        assertFalse("用户在场档必须豁免电量要求", spec.requiresBatteryNotLow)
        assertTrue("用户在场档仍查 Wi-Fi", spec.requiresUnmetered)
    }

    @Test
    fun user_present_wifi_requirement_follows_setting() {
        val wifiOn = constraintsFor(
            BackupTier.USER_PRESENT,
            BackupSettingsState(wifiOnly = true),
        )
        assertTrue(wifiOn.requiresUnmetered)
        val wifiOff = constraintsFor(
            BackupTier.USER_PRESENT,
            BackupSettingsState(wifiOnly = false),
        )
        assertFalse("关闭需要 Wi-Fi 后用户在场档也不查", wifiOff.requiresUnmetered)
    }

    @Test
    fun background_requires_battery_not_low_unconditionally() {
        // MOB-10: 后台档恒设 batteryNotLow——它不再是用户开关，而是硬约束。
        // 反证：把 constraintsFor 的 BACKGROUND 分支改成 false → 本测试红。
        val wifiOn = constraintsFor(
            BackupTier.BACKGROUND,
            BackupSettingsState(wifiOnly = true),
        )
        assertTrue("后台档必须要求电量不低", wifiOn.requiresBatteryNotLow)
        assertTrue(wifiOn.requiresUnmetered)

        val wifiOff = constraintsFor(
            BackupTier.BACKGROUND,
            BackupSettingsState(wifiOnly = false),
        )
        assertTrue("关掉仅 Wi-Fi 不影响电量约束", wifiOff.requiresBatteryNotLow)
        assertFalse(wifiOff.requiresUnmetered)
    }

    @Test
    fun process_start_catchup_is_wired_in_application() {
        // MOB-15 回归锁：补捞必须挂在 Application.onCreate（进程因任何原因
        // 被拉起都要检查一次），而不是只挂在 Activity。
        // 用户原话："我肯定是需要 kill app 的啊，配置好了谁整天看你这个同步
        // 备份用的 app？"——挂在 Activity 上的补捞对他等于不存在。
                val app = codeOf(File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/PPassApplication.kt"))
        assertTrue(
            "Application.onCreate 必须触发进程启动补捞",
            app.contains("triggerProcessStartCatchup(this)"),
        )
        // MOB-16：挂载不能依赖用户打开 App。scheduleAutoBackup 若只在
        // MainActivity 调用，content trigger 监听和周期任务的存在就取决于
        // "用户打开过 App"——监听一旦丢失只有手动打开才能恢复。
        assertTrue(
            "Application.onCreate 必须确保监听与周期任务在位（不依赖打开 App）",
            app.contains("scheduleAutoBackup(this)"),
        )
        assertTrue("未配对不跑", app.contains("PairingStore(filesDir).load() == null"))
        assertTrue("暂停态不跑", app.contains("AutoBackupPrefs(filesDir).paused()"))

        val manifest = codeOf(File(repoRoot(), "apps/android/app/src/main/AndroidManifest.xml"))
        assertTrue(
            "Application 子类必须在 manifest 注册，否则 onCreate 根本不会跑",
            manifest.contains("android:name=\".PPassApplication\""),
        )

        // 补捞用后台档：进程被系统拉起 != 人在操作，不该享受在场档豁免。
        val worker = codeOf(File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt"))
        val body = worker.substringAfter("fun triggerProcessStartCatchup(")
            .substringBefore("\n}")
        assertTrue("补捞必须用后台档约束", body.contains("BackupTier.BACKGROUND"))
        assertTrue("补捞必须用独立 unique name", body.contains("PROCESS_CATCHUP_WORK_NAME"))
        assertTrue("补捞必须 KEEP（同进程内重复调用不叠加）", body.contains("ExistingWorkPolicy.KEEP"))
        assertNotEquals("补捞通道不能与 catchup 抢名字", CATCHUP_WORK_NAME, PROCESS_CATCHUP_WORK_NAME)
    }

    @Test
    fun paused_state_blocks_every_channel() {
        // UX-06 + MOB-15：暂停必须真的停住。进程启动补捞会在冷启时 enqueue，
        // 所以 doWork 内部需要第二道闸——否则「暂停自动备份」被进程重启绕过。
                val worker = codeOf(File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt"))
        assertTrue(
            "doWork 必须有暂停态早退",
            worker.contains("if (AutoBackupPrefs(ctx.filesDir).paused()) return Result.success()"),
        )
        val pauseBody = worker.substringAfter("fun pauseAutoBackup(").substringBefore("fun resumeAutoBackup(")
        assertTrue(
            "暂停必须取消进程启动补捞通道",
            pauseBody.contains("cancelUniqueWork(PROCESS_CATCHUP_WORK_NAME)"),
        )
        // MOB-27: 看门 job 在 JobScheduler 上，cancelUniqueWork 管不着它——
        // 漏了这一句，「暂停自动备份」对事件②完全失效（监听继续派活）。
        assertTrue("暂停必须取消看门 job", pauseBody.contains("cancelMediaWatch(context)"))
        assertTrue(
            "暂停必须取消看门 job 派活的通道",
            pauseBody.contains("cancelUniqueWork(MEDIA_WATCH_BACKUP_WORK_NAME)"),
        )
    }

    @Test
    fun app_start_does_not_clobber_a_pending_watch_job() {
        // MOB-14 回归锁，MOB-27 后换了载体但**教训一字未改**：App 启动路径
        // 不许覆盖一个正在 pending 的监听。覆盖会丢掉它已积累的 MediaStore
        // 变化并重置 1s 防抖——用户拍完照顺手开 App 看"传了没"就正好踩中，
        // 那张照片只能等 5h 周期兜底。
        //
        // javadoc 的"运行期间变更转交给下一个 job"只覆盖 job **running** 期，
        // **不覆盖 pending 期**，所以这里必须是 guard-then-schedule。
        val src = codeOf(File(repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt"))
        val body = src.substringAfter("fun scheduleAutoBackup(").substringBefore("\n}")
        assertTrue("App 启动路径必须走 ensureMediaWatch（幂等 guard）", body.contains("ensureMediaWatch(context)"))
        assertTrue(
            "App 启动路径不许裸 schedule（会覆盖 pending 的监听）",
            !body.contains("scheduleMediaWatchNow("),
        )
        // 改设置同理：约束已不在监听上，没有任何重建监听的理由。
        val reschedule = src.substringAfter("fun rescheduleAutoBackup(").substringBefore("\n}")
        assertTrue("改设置也只做存在性确认", reschedule.contains("ensureMediaWatch(context)"))
        assertTrue("改设置不许重建监听", !reschedule.contains("scheduleMediaWatchNow("))
    }

    @Test
    fun app_open_has_no_time_gate() {
        // MOB-14 回归锁：打开 App 必须无条件补跑一次，不能再卡 24h 门槛。
        // 门槛的后果：任何通知丢失（进程被杀/job 重排窗口期拍的照片）都要
        // 干等 6h 周期兜底，而用户开 App 的意图正是"看照片到家没有"。
                val src = codeOf(File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt"))
        assertTrue(
            "不允许恢复 App 打开的时间门槛",
            !src.contains("MOB_APP_OPEN_GATE_MS"),
        )
        assertTrue(
            "App 启动仍必须触发一次用户在场档备份",
            src.contains("triggerUserPresentBackup(context)"),
        )
    }

    @Test
    fun periodic_fallback_stays_low_frequency() {
        // MOB-17 用户定稿：兜底 5h，**刻意不做高频**。
        // "兜底太频繁会在系统的 log 里面被检测得到，反而没那么好，因为
        // 我们有别的触发的事件。"——主路径是 content trigger，兜底只管
        // 捞极少数漏网的，不该把自己搞成高频轮询进 OEM 省电黑名单。
        assertEquals(5L, PERIODIC_FALLBACK_HOURS)
        assertTrue("兜底不得高频化（至少 2h）", PERIODIC_FALLBACK_HOURS >= 2L)
        val src = codeOf(File(repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt"))
        assertTrue(
            "周期必须用常量，不能写死数字（防止改一处漏一处）",
            src.contains("PeriodicWorkRequestBuilder<BackupWorker>(PERIODIC_FALLBACK_HOURS"),
        )
    }

    @Test
    fun periodic_work_uses_update_so_constraints_propagate() {
        // MOB-12 回归锁：周期任务必须用 UPDATE，不能用 KEEP。
        // KEEP = "已存在就完全不动"，包括不更新约束——真机实测后果：
        // MOB-10 删掉 requiresCharging、重装 App 后，content trigger（走
        // REPLACE）已是新约束，周期任务却还是 charging=true，继续每 6h
        // 报一次 stopReason=CONSTRAINT_CHARGING(6)。
        // UPDATE 更新约束但保留下次执行时间，不像 REPLACE 重置 6h 计时。
                val src = codeOf(File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt"))
        val body = src.substringAfter("fun scheduleAutoBackup(").substringBefore("}")
        assertTrue(
            "scheduleAutoBackup 必须用 UPDATE（KEEP 会让约束变更永远进不去）",
            body.contains("ExistingPeriodicWorkPolicy.UPDATE"),
        )
        assertTrue(
            "不允许退回 KEEP",
            !body.contains("ExistingPeriodicWorkPolicy.KEEP"),
        )
    }

    @Test
    fun charging_constraint_is_gone_for_good() {
        // MOB-10 回归锁：绝不允许把 requiresCharging 加回来。
        // 用户的三星开着「保护电池」，充到上限即 NOT_CHARGING/DISCHARGING，
        // 插着墙充也一样——WorkManager 会在 job 起来的同一瞬间掐掉：
        //   auto backup cancelled by system after 30ms,
        //   stopReason=CONSTRAINT_CHARGING(6)
        // 任何有充电上限功能的机器（三星/小米/OPPO）在满电常态下都会踩，
        // 「仅充电时备份」的实际语义是「永不备份」。
                val worker = codeOf(File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt"))
        assertTrue(
            "不允许 setRequiresCharging——它在开着电池保护的设备上等于永不备份",
            !worker.contains("setRequiresCharging("),
        )
        assertTrue(
            "后台档必须设 setRequiresBatteryNotLow",
            worker.contains("setRequiresBatteryNotLow(spec.requiresBatteryNotLow)"),
        )
    }

    // ── 验收 3：本轮最多短退避重试 2 次，之后放弃 ──

    @Test
    fun retries_twice_then_gives_up() {
        // 第 1、2 次失败 → 重试；第 3 次 → 放弃（Result.failure + 通知）。
        assertTrue("第 1 次失败应重试", shouldRetryAfter(1))
        assertTrue("第 2 次失败应重试", shouldRetryAfter(2))
        assertFalse("第 3 次失败必须放弃", shouldRetryAfter(3))
        assertEquals(2, MAX_BACKUP_RETRIES)
    }

    // ── 验收 4：新相册默认策略（null 包含 / 子集不包含）──

    @Test
    fun never_scoped_means_no_new_album_badges() {
        // 从未选过范围（known == null）= 全量模式——新相册自动包含，
        // 标「新」无意义，返回空集。
        assertEquals(
            emptySet<Long>(),
            newAlbumIds(current = setOf(1L, 2L, 3L), known = null),
        )
    }

    @Test
    fun scoped_subset_marks_new_albums() {
        // 选过子集后，新出现的相册 = 当前 − 已知；默认不包含由选中集
        // 语义天然保证（新相册不在 selected 里，扫描排除）。
        assertEquals(
            setOf(3L),
            newAlbumIds(current = setOf(1L, 2L, 3L), known = setOf(1L, 2L)),
        )
        assertEquals(
            emptySet<Long>(),
            newAlbumIds(current = setOf(1L, 2L), known = setOf(1L, 2L)),
        )
    }

    // ── 验收 5：部分授权判定（API 34+ 双权限同授 = 部分）──

    @Test
    fun partial_access_detection() {
        // 真机反证：READ_MEDIA_VISUAL_USER_SELECTED 授予后不会因为后续
        // 升级到完整授权而被系统撤销——images 已授时必须判定为非部分，
        // 不管 visual_selected 是否历史遗留 true（否则用户永远卡在
        // 「已完整授权却被判部分」的死循环，2026-08-12 真机报告）。
        assertFalse(
            isPartialMediaAccess(imagesGranted = true, visualSelectedGranted = true, sdkInt = 34)
        )
        assertFalse(
            isPartialMediaAccess(imagesGranted = true, visualSelectedGranted = false, sdkInt = 34)
        )
        // 真正的部分授权：images 未授、visual_selected 已授。
        assertTrue(
            isPartialMediaAccess(imagesGranted = false, visualSelectedGranted = true, sdkInt = 34)
        )
        assertFalse(
            isPartialMediaAccess(imagesGranted = false, visualSelectedGranted = false, sdkInt = 34)
        )
        // API < 34 无此权限，恒 false。
        assertFalse(
            isPartialMediaAccess(imagesGranted = false, visualSelectedGranted = true, sdkInt = 33)
        )
    }


}
