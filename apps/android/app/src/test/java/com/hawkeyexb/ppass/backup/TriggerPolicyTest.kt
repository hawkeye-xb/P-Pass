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
    fun charging_constraint_is_gone_for_good() {
        // MOB-10 回归锁：绝不允许把 requiresCharging 加回来。
        // 用户的三星开着「保护电池」，充到上限即 NOT_CHARGING/DISCHARGING，
        // 插着墙充也一样——WorkManager 会在 job 起来的同一瞬间掐掉：
        //   auto backup cancelled by system after 30ms,
        //   stopReason=CONSTRAINT_CHARGING(6)
        // 任何有充电上限功能的机器（三星/小米/OPPO）在满电常态下都会踩，
        // 「仅充电时备份」的实际语义是「永不备份」。
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        val worker = File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt",
        ).readText()
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

    // ── 验收 2：content trigger 的 Constraints 含 update/max delay + 去重 ──

    @Test
    fun content_trigger_constraints_carry_burst_aggregation_delays() {
        // 连拍聚合的机制证据：update delay（防抖窗口）+ max delay（封顶）
        // 是硬常量，且 request 能正常构建（接线 smoke）。
        // MOB-11：节奏从 2min/15min 收到 1s/30s——单张拍完 ~1s 就发起。
        assertEquals(1L * 1000, CONTENT_UPDATE_DELAY_MS)
        assertEquals(30L * 1000, CONTENT_MAX_DELAY_MS)
        // MOB-11 回归锁：update delay 是尾沿防抖，持续不断的 MediaStore
        // 写入（截图/IM 收图/其它 App 批量写）会让 1s 静默窗口永远等不到，
        // 此时只有 max delay 这个从第一次变化起算的强制闸能救。它必须留在
        // 与 update delay 同数量级的秒级，不能退回分钟级。
        // （注意：有限连拍不会触到 max delay——连拍结束后 1s 就走。）
        assertTrue(
            "max delay 必须秒级封顶持续 churn（不得超过 update delay 的 60 倍）",
            CONTENT_MAX_DELAY_MS <= CONTENT_UPDATE_DELAY_MS * 60,
        )
        // ⚠️ 无法从 WorkSpec 读回 delay：mockable android.jar 的
        // Build.VERSION.SDK_INT=0，Constraints.build() 的 SDK≥24 门把
        // delay 强制 -1、triggers 清空（JVM 侧不可观察）——接线证据走
        // 文件级反证（下个测试）+ 真机连拍验收（卡面验收 8：连拍 20 张
        // 只触发一次备份，观察 WorkManager 日志）。
        val request = buildContentTriggerRequest(
            BackupSettingsState(),
            triggerUris = emptyList(),
        )
        assertTrue("request 必须能构建（接线 smoke）", request.workSpec.id.isNotBlank())
    }

    @Test
    fun content_trigger_wires_delays_in_constraints_builder() {
        // 文件级反证（DOG-01d 同款手法）：work-runtime 2.10 的 content
        // trigger delay 接线在 Constraints.Builder（addContentUriTrigger /
        // setTriggerContentUpdateDelay / setTriggerContentMaxDelay），
        // 不在 WorkRequest.Builder 上。JVM 无法从 WorkSpec 读回 delay，
        // 用源码级断言锁死接线——把 update delay 去掉 → 本测试必红。
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        val src = File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt",
        ).readText()
        assertTrue(
            "update delay 必须接线（连拍聚合安静窗口）",
            src.contains("setTriggerContentUpdateDelay(CONTENT_UPDATE_DELAY_MS"),
        )
        assertTrue(
            "max delay 必须接线（持续变化兜底）",
            src.contains("setTriggerContentMaxDelay(CONTENT_MAX_DELAY_MS"),
        )
        assertTrue(
            "必须监听 MediaStore 两集合",
            src.contains("MediaStore.Images.Media.EXTERNAL_CONTENT_URI") &&
                src.contains("MediaStore.Video.Media.EXTERNAL_CONTENT_URI"),
        )
        // MOB-08 回归锁：forDescendants 必须为 true。MediaProvider 的
        // notifyChange 发的是带行 id 的 item URI，精确匹配（false）永远
        // 收不到——这正是「content trigger 从未触发」的根因，改回 false
        // 本测试必红。
        assertTrue(
            "content trigger 必须 forDescendants=true（否则收不到 item URI 通知）",
            src.contains("addContentUriTrigger(it, true)"),
        )
        assertTrue(
            "不允许退回 forDescendants=false",
            !src.contains("addContentUriTrigger(it, false)"),
        )
    }

    // ── MOB-08：content trigger 跑完必须重挂 ──

    @Test
    fun content_trigger_rearms_after_every_run() {
        // 根因回归锁：content trigger 是 OneTimeWork，触发跑完监听就没了。
        // 只在 App 启动/改设置时挂 = 后台自动同步只在开过 App 那一次有效。
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        val src = File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt",
        ).readText()
        assertTrue(
            "每轮备份结束必须排一次重挂",
            src.contains("enqueueContentTriggerRearm(ctx)"),
        )
        assertTrue(
            "重挂中转必须用独立 unique name（同名 REPLACE 会取消正在跑的自己）",
            CONTENT_REARM_WORK_NAME != CONTENT_TRIGGER_WORK_NAME &&
                CONTENT_REARM_WORK_NAME != BACKUP_WORK_NAME &&
                CONTENT_REARM_WORK_NAME != CATCHUP_WORK_NAME,
        )
        assertTrue(
            "重挂前必须确认上一轮已终态（否则 REPLACE 掉正在传照片的 worker）",
            src.contains("getWorkInfosForUniqueWork(CONTENT_TRIGGER_WORK_NAME)") &&
                src.contains("all { it.state.isFinished }"),
        )
        assertTrue(
            "取消路径上的收尾必须 NonCancellable（否则 client.close() 跑不到）",
            src.contains("withContext(NonCancellable)"),
        )
    }

    @Test
    fun pause_cancels_rearm_channel_too() {
        // UX-06 回归：暂停后如果 rearm 还在路上，监听会被悄悄装回去。
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        val src = File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt",
        ).readText()
        val pauseBody = src.substringAfter("fun pauseAutoBackup(").substringBefore("fun resumeAutoBackup(")
        assertTrue(
            "暂停必须取消重挂中转",
            pauseBody.contains("cancelUniqueWork(CONTENT_REARM_WORK_NAME)"),
        )
    }

    @Test
    fun content_trigger_uses_unique_replace_dedup() {
        // unique work + REPLACE = 同一波 MediaStore 变化只跑一次
        // （连拍 20 张不叠加 20 个任务）。
        assertNotEquals("content trigger 独立 unique 名", BACKUP_WORK_NAME, CONTENT_TRIGGER_WORK_NAME)
        assertEquals(ExistingWorkPolicy.REPLACE, CONTENT_TRIGGER_POLICY)
    }

}
