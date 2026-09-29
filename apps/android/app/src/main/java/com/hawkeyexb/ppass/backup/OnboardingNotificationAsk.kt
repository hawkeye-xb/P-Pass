// #130（#515 后续，用户拍板 B）：Android 13+ 在 onboarding 里**只问一次** POST_NOTIFICATIONS。
//
// - 时机：配对成功、选完相册之后的完成页（Screen.Started），用户点任一按钮时先问通知、再走原来的动作；
//   问之前完成页上用一句话讲清用途（只在三类确定事件时提醒，见 DefinitiveEventNotices.kt）。
// - 只问一次：发起申请**之前**先落盘 `asked`，之后任何路径（重启、后台、再走一次 onboarding）都不再问；
//   拒绝后只能从设置里的「通知」开关进入申请（原有行为）。
// - 老用户升级不问：本文件第一次被创建时（MainActivity 首次组合），若本机已有配对或已走完过 onboarding
//   （OnboardedDesktopsStore），直接记成「不问」。靠落盘标记，不靠版本号。
// - Android 12 及以下没有运行时权限，不问；开关按原默认（NotifyOnFailurePrefs 默认开）。
// - 结果同步到开关：授予 → NotifyOnFailurePrefs 开；拒绝 → 关。设置页开关显示的是
//   `prefs.enabled() && 已授权`，两者不会矛盾。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class OnboardingNotificationAskState(
    /** true = 已经问过，或老用户升级上来不该问——两种情况都不再问。 */
    val asked: Boolean = false,
    /** 只做留痕：这次「不问」是因为老用户升级。 */
    val skippedAsExistingUser: Boolean = false,
)

/** API 33（Android 13）起 POST_NOTIFICATIONS 才是运行时权限。 */
const val POST_NOTIFICATIONS_MIN_SDK = 33

class OnboardingNotificationAsk(private val dir: File) {
    private val file = File(dir, "onboarding_notification_ask.json")
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * 第一次运行这一版时定下这台机器是不是老用户。文件已存在就什么都不做（幂等），
     * 所以新装用户这一刻写下 asked=false，之后配对成功也不会被误判成老用户。
     */
    fun initIfAbsent(existingUser: Boolean) {
        if (file.isFile) return
        save(OnboardingNotificationAskState(asked = existingUser, skippedAsExistingUser = existingUser))
    }

    /** 完成页该不该问。文件缺失（没初始化过）按「不问」——宁可少问，不许多问。 */
    fun shouldAsk(sdkInt: Int, alreadyGranted: Boolean): Boolean {
        if (sdkInt < POST_NOTIFICATIONS_MIN_SDK || alreadyGranted) return false
        val state = load() ?: return false
        return !state.asked
    }

    /** 发起系统申请之前调用：先落盘，申请中途进程被杀也不会再问。 */
    fun markAsked() {
        save((load() ?: OnboardingNotificationAskState()).copy(asked = true))
    }

    /** 系统弹窗结果：开关跟着授权结果走。 */
    fun onResult(granted: Boolean, prefs: NotifyOnFailurePrefs) {
        prefs.setEnabled(granted)
    }

    internal fun load(): OnboardingNotificationAskState? =
        if (file.isFile) {
            runCatching { json.decodeFromString(OnboardingNotificationAskState.serializer(), file.readText()) }
                .getOrDefault(OnboardingNotificationAskState(asked = true))
        } else {
            null
        }

    private fun save(state: OnboardingNotificationAskState) {
        dir.mkdirs()
        val tmp = File(dir, "onboarding_notification_ask.json.tmp")
        tmp.writeText(json.encodeToString(OnboardingNotificationAskState.serializer(), state))
        check(tmp.renameTo(file)) { "cannot persist onboarding_notification_ask.json" }
    }
}
