// MOB-02（2026-08-11 用户定稿）：备份触发模型重构的纯逻辑层——
// 两档运行条件、失败重试裁决、新相册策略、部分授权判定。
// 全部纯函数、零 Android 框架依赖，JVM 单测直接可测（卡面验收 1/3/4/5）。
package com.hawkeyexb.ppass.backup

/** 备份触发档位。
 *
 *  MOB-19（2026-08-20 用户定稿）：备份只有**一条**管线，触发方式五种——
 *  ①改完范围返回 ②新照片落库 ③周期兜底 ④App 进前台 ⑤用户手点「立即备份」。
 *  前四种是机器自己决定要跑，第五种是人决定要跑。档位区别只在**条件检测**。 */
enum class BackupTier {
    /** 事件①④：人在操作但不是直接下令（打开 App / 改完范围返回）。 */
    USER_PRESENT,

    /** 事件②③：机器自己决定（新照片 / 周期兜底）。 */
    BACKGROUND,

    /** 事件⑤：用户手点「立即备份」。**不过任何条件检测。**
     *
     *  用户原话（2026-08-20）："ABCDE 种触发方式都会过 Wi-Fi 电量的监测，
     *  那手动能不能在检测-发起之间，直接人工点击-发起？"
     *
     *  理由：人已经在场、亲手点的，这一下就是**当场的明确指令**，压过
     *  「仅 Wi-Fi 时备份」这条**给自动备份定的规则**。点了不动是反直觉的
     *  ——尤其这个入口在设置页深处，定位是狗粮/排障用。 */
    MANUAL,
}

/** WorkManager Constraints 的纯数据描述（可测，不依赖 androidx.work）。 */
data class BackupConstraintsSpec(
    /** MOB-10: 取代原来的 requiresCharging，见 [constraintsFor] 注释。 */
    val requiresBatteryNotLow: Boolean,
    val requiresUnmetered: Boolean,
)

/**
 * MOB-02 卡面 §四：两档条件。
 * - 用户在场档（事件①选完范围返回 / ④App 进前台）：只查 Wi-Fi 要求。
 * - 后台档（事件②新照片落库 / ③周期兜底）：加一条「电量不低」。
 *
 * ## MOB-10（2026-08-19 用户定稿）：「仅充电」整个删掉，换成「电量不低」
 *
 * 原来后台档带 `requiresCharging = settings.chargeOnly`（默认 true）。
 * 真机上这条约束是坏的——用户的三星开着「保护电池」
 * （`settings get global protect_battery = 2`），电量充到上限后系统状态
 * 就变成 `NOT_CHARGING`/`DISCHARGING`，**插着墙充也一样**。于是：
 * JobScheduler 认为 CHARGING 满足、放行 job，WorkManager 自己的
 * `BatteryChargingTracker` 认为没在充电，在 job 起来的同一瞬间掐掉：
 *
 * ```
 * W PPassBackup: auto backup cancelled by system after 30ms,
 *                stopReason=CONSTRAINT_CHARGING(6)
 * ```
 *
 * 任何有充电上限功能的机器（三星/小米/OPPO 都有）在满电常态下都会踩，
 * 「仅充电时备份」实际语义变成「永不备份」。而本项目是局域网 P2P 传
 * 照片，几十秒的事，能耗根本不是瓶颈——为这点能耗牺牲可靠性不划算。
 *
 * `setRequiresBatteryNotLow` 判的是「电量不低」，**不受充电状态影响**，
 * 才是「别在快没电时折腾」的真实意图；「必须正在充电」只是它的一个
 * 坏代理。用户在场档不设这条（人在操作，用户自己说了算）。
 *
 * 反证：把后台档的 `requiresBatteryNotLow` 改成 false，或把用户在场档
 * 改成 true → TriggerPolicyTest 必红。
 */
fun constraintsFor(tier: BackupTier, settings: BackupSettingsState): BackupConstraintsSpec =
    when (tier) {
        // MOB-19: 手动 = 零约束。这是唯一一档**不读 settings** 的，
        // 因为「仅 Wi-Fi」是给自动备份定的规则，不是给当场指令定的。
        BackupTier.MANUAL -> BackupConstraintsSpec(
            requiresBatteryNotLow = false,
            requiresUnmetered = false,
        )
        BackupTier.USER_PRESENT -> BackupConstraintsSpec(
            requiresBatteryNotLow = false,
            requiresUnmetered = settings.wifiOnly,
        )
        BackupTier.BACKGROUND -> BackupConstraintsSpec(
            requiresBatteryNotLow = true,
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
