// Onboarding「系统权限」步骤（配对成功后插入的三步 onboarding 第一步）：
// 读取照片必需（不给不能继续）；通知 + 忽略电池优化可跳过，「点一个弹
// 一次」——跳过后本机不再重复弹系统对话框/设置页，直到用户自己在设置页
// 主动点「去补授权」。持久化跟 AutoBackupPrefs/BackupSettings 同款套路：
// filesDir JSON，tmp+rename 崩溃安全，损坏/缺失回默认。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class OnboardingAskState(
    val notificationAsked: Boolean = false,
    val batteryAsked: Boolean = false,
)

class OnboardingPermissionsStore(private val dir: File) {
    private val file = File(dir, "onboarding-ask-state.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): OnboardingAskState =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(OnboardingAskState.serializer(), file.readText())
            }.getOrDefault(OnboardingAskState())
        } else {
            OnboardingAskState()
        }

    fun markNotificationAsked() = save(load().copy(notificationAsked = true))
    fun markBatteryAsked() = save(load().copy(batteryAsked = true))

    private fun save(state: OnboardingAskState) {
        dir.mkdirs()
        val tmp = File(dir, "onboarding-ask-state.json.tmp")
        tmp.writeText(json.encodeToString(OnboardingAskState.serializer(), state))
        check(tmp.renameTo(file)) { "cannot persist onboarding-ask-state.json" }
    }
}

/** 读取照片必需——不给就不能往下走（网格/大图/备份全部依赖它）。 */
fun onboardingCanContinue(photoGranted: Boolean): Boolean = photoGranted

/**
 * 通知这一项是否应该在「系统权限」步骤里出现可点的系统权限入口
 * （纯函数，JVM 可测）。三个条件都满足才需要：①API 33+ 才有运行时
 * 通知权限（更低版本装的时候就默认给了，弹了也没有系统对话框）；
 * ②当前确实还没被授予；③这轮 onboarding 里还没问过一次（问过就不
 * 重复弹，跳过/允许都算问过——避免用户点了「跳过」，下次进这个页面
 * 又弹一次系统对话框，体验上像「跳过没生效」）。
 */
fun shouldOfferNotificationPermission(
    sdkInt: Int,
    granted: Boolean,
    alreadyAsked: Boolean,
): Boolean = sdkInt >= 26 /* minSdk */ && sdkInt >= 33 && !granted && !alreadyAsked

/** 忽略电池优化这一项是否应该出现可点入口——同款判定，无 API 版本门槛
 *  （PowerManager.isIgnoringBatteryOptimizations 从 API 23 起就有）。 */
fun shouldOfferBatteryWhitelist(whitelisted: Boolean, alreadyAsked: Boolean): Boolean =
    !whitelisted && !alreadyAsked
