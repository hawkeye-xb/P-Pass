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
    fun user_present_ignores_charging_requirement() {
        // 卡面 §四事件①④：人在操作，充电要求无意义——即使设置要求充电，
        // 用户在场档也不查充电。
        val spec = constraintsFor(
            BackupTier.USER_PRESENT,
            BackupSettingsState(chargeOnly = true, wifiOnly = true),
        )
        assertFalse("用户在场档必须豁免充电要求", spec.requiresCharging)
        assertTrue("用户在场档仍查 Wi-Fi", spec.requiresUnmetered)
    }

    @Test
    fun user_present_wifi_requirement_follows_setting() {
        val wifiOn = constraintsFor(
            BackupTier.USER_PRESENT,
            BackupSettingsState(chargeOnly = true, wifiOnly = true),
        )
        assertTrue(wifiOn.requiresUnmetered)
        val wifiOff = constraintsFor(
            BackupTier.USER_PRESENT,
            BackupSettingsState(chargeOnly = true, wifiOnly = false),
        )
        assertFalse("关闭需要 Wi-Fi 后用户在场档也不查", wifiOff.requiresUnmetered)
    }

    @Test
    fun background_checks_both_requirements() {
        // 卡面 §四事件②③：后台档条件全查（充电 + Wi-Fi 都按设置来）。
        val bothOn = constraintsFor(
            BackupTier.BACKGROUND,
            BackupSettingsState(chargeOnly = true, wifiOnly = true),
        )
        assertTrue(bothOn.requiresCharging)
        assertTrue(bothOn.requiresUnmetered)

        val bothOff = constraintsFor(
            BackupTier.BACKGROUND,
            BackupSettingsState(chargeOnly = false, wifiOnly = false),
        )
        assertFalse(bothOff.requiresCharging)
        assertFalse(bothOff.requiresUnmetered)
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
        // API 34+ 上「部分照片」授权 = READ_MEDIA_IMAGES 与
        // READ_MEDIA_VISUAL_USER_SELECTED 同时已授。
        assertTrue(
            isPartialMediaAccess(imagesGranted = true, visualSelectedGranted = true, sdkInt = 34)
        )
        // 完整授权只给 images（不给 visual_selected）→ 不是部分。
        assertFalse(
            isPartialMediaAccess(imagesGranted = true, visualSelectedGranted = false, sdkInt = 34)
        )
        assertFalse(
            isPartialMediaAccess(imagesGranted = false, visualSelectedGranted = true, sdkInt = 34)
        )
        // API < 34 无此权限，恒 false。
        assertFalse(
            isPartialMediaAccess(imagesGranted = true, visualSelectedGranted = true, sdkInt = 33)
        )
    }

    // ── 验收 2：content trigger 的 Constraints 含 update/max delay + 去重 ──

    @Test
    fun content_trigger_constraints_carry_burst_aggregation_delays() {
        // 连拍聚合的机制证据：update delay（安静窗口 ~2min）+ max delay
        // （~15min 兜底）是硬常量，且 request 能正常构建（接线 smoke）。
        assertEquals(2L * 60 * 1000, CONTENT_UPDATE_DELAY_MS)
        assertEquals(15L * 60 * 1000, CONTENT_MAX_DELAY_MS)
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
    }

    @Test
    fun content_trigger_uses_unique_replace_dedup() {
        // unique work + REPLACE = 同一波 MediaStore 变化只跑一次
        // （连拍 20 张不叠加 20 个任务）。
        assertNotEquals("content trigger 独立 unique 名", BACKUP_WORK_NAME, CONTENT_TRIGGER_WORK_NAME)
        assertEquals(ExistingWorkPolicy.REPLACE, CONTENT_TRIGGER_POLICY)
    }

    // ── 验收 6：四种条件组合各有合成句（裁决纯函数映射）──

    @Test
    fun policy_sentence_maps_all_four_combinations() {
        // 映射函数在 ui 包（policySentenceKey 需要 R 常量）；
        // 这里验证两档开关与合成句的对应关系通过「不歧义」断言：
        // 四种组合必须映射到四个不同结果。
        val keys = setOf(
            com.hawkeyexb.ppass.ui.policySentenceKey(chargeOnly = true, wifiOnly = true),
            com.hawkeyexb.ppass.ui.policySentenceKey(chargeOnly = true, wifiOnly = false),
            com.hawkeyexb.ppass.ui.policySentenceKey(chargeOnly = false, wifiOnly = true),
            com.hawkeyexb.ppass.ui.policySentenceKey(chargeOnly = false, wifiOnly = false),
        )
        assertEquals("四种组合必须四句不同文案，不留歧义", 4, keys.size)
    }
}
