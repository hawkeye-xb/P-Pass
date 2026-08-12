// MOB-02（2026-08-11 用户定稿）：备份触发模型重构的纯逻辑层——
// 两档运行条件、失败重试裁决、新相册策略、部分授权判定。
// 全部纯函数、零 Android 框架依赖，JVM 单测直接可测（卡面验收 1/3/4/5）。
package com.hawkeyexb.ppass.backup

/** 备份触发档位：用户在场（人在操作，充电要求无意义）/ 后台（条件全查）。 */
enum class BackupTier { USER_PRESENT, BACKGROUND }

/** WorkManager Constraints 的纯数据描述（可测，不依赖 androidx.work）。 */
data class BackupConstraintsSpec(
    val requiresCharging: Boolean,
    val requiresUnmetered: Boolean,
)

/**
 * MOB-02 卡面 §四：两档条件。
 * - 用户在场档（事件①选完范围返回 / ④App 进前台）：只查 Wi-Fi 要求，
 *   不查充电——人在操作，充电要求无意义。
 * - 后台档（事件②新照片落库 / ③周期兜底）：条件全查。
 *
 * 反证：把用户在场档的充电豁免去掉 → TriggerPolicyTest 必红（验收 1）。
 */
fun constraintsFor(tier: BackupTier, settings: BackupSettingsState): BackupConstraintsSpec =
    when (tier) {
        BackupTier.USER_PRESENT -> BackupConstraintsSpec(
            requiresCharging = false,
            requiresUnmetered = settings.wifiOnly,
        )
        BackupTier.BACKGROUND -> BackupConstraintsSpec(
            requiresCharging = settings.chargeOnly,
            requiresUnmetered = settings.wifiOnly,
        )
    }

/**
 * MOB-02 卡面 §五：本轮最多短退避重试 2 次（扛网络瞬断），之后放弃本轮——
 * 捞回责任交给下一个触发事件（②③④天然就是重试）。
 * [consecutiveFailures] = 连续失败次数（BackupAttemptStore 落盘）。
 * 第 1、2 次失败 → 重试；第 3 次 → 放弃（Result.failure + 失败通知）。
 * 反证：把 update delay 去掉 → 验收 2 必红（此函数不受影响，见 TriggerPolicyTest）。
 */
const val MAX_BACKUP_RETRIES = 2

fun shouldRetryAfter(consecutiveFailures: Int): Boolean =
    consecutiveFailures <= MAX_BACKUP_RETRIES

/**
 * MOB-02 卡面 §六：新相册策略。
 * - 从未设置范围（known == null）→ 维持全量语义，无「新」徽标
 *   （全量模式下新相册自动包含，标新无意义）。
 * - 选过子集 → 新相册 = 当前全部 − 已知，BucketScreen 标「新」；
 *   默认不包含由选中集语义天然保证（新相册不在 selected 里，扫不到）。
 */
fun newAlbumIds(current: Set<Long>, known: Set<Long>?): Set<Long> =
    if (known == null) emptySet() else current - known

/**
 * MOB-02 卡面 §二：部分授权判定（消灭 0/0 死局）。
 * API 34+ 上「部分照片」授权 = READ_MEDIA_IMAGES 未授、
 * READ_MEDIA_VISUAL_USER_SELECTED 已授。
 * 真机反证（2026-08-12 用户报告）：READ_MEDIA_VISUAL_USER_SELECTED 一旦
 * 授予过，之后去系统设置升级到「允许所有照片」也不会被系统撤销——
 * 旧版用 `imagesGranted && visualSelectedGranted` 判 partial，导致完整
 * 授权后仍被误判成部分授权，永远进不了相册列表。imagesGranted 本身就是
 * 完整授权的充分条件，与 visualSelected 是否历史遗留无关。
 * API < 34 无此权限（partial 恒 false）。
 */
fun isPartialMediaAccess(
    imagesGranted: Boolean,
    visualSelectedGranted: Boolean,
    sdkInt: Int,
): Boolean = sdkInt >= 34 && !imagesGranted && visualSelectedGranted
