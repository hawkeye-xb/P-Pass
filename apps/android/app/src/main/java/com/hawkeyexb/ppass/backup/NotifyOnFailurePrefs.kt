// M10（全页面状态稿）："需要处理时通知我"是设置页里一个真实的开关行，
// 不是系统通知权限本身（那个在 OS 层，这里管的是"P-Pass 要不要在这个
// 本地偏好上再加一道闸"）。
// #130：类名沿用历史，语义已是「需要处理时通知我」——闸控 DefinitiveEventNotices 的三类确定事件；
// 单张失败通知仍不发（#418），这个开关不管它。
// #1262：默认**关**——onboarding 不再申请通知权限，用户在设置里打开开关时才申请。
// 老用户升级保持原状态：进程启动时文件不存在就落一次盘（[initIfAbsent]），之后只认文件。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class NotifyOnFailurePrefsData(
    val enabled: Boolean = false,
    /** #1262：从设置开关发起过系统通知申请。用来分辨「系统不会再弹」（问过且不再给解释机会）→ 去系统设置。 */
    val systemAsked: Boolean = false,
)

class NotifyOnFailurePrefs(private val dir: File) {
    private val file = File(dir, FILE_NAME)
    private val json = Json { ignoreUnknownKeys = true }

    fun enabled(): Boolean = load().enabled

    fun systemAsked(): Boolean = load().systemAsked

    fun setEnabled(enabled: Boolean) = save(load().copy(enabled = enabled))

    /** 发起系统申请之前调用。 */
    fun markSystemAsked() = save(load().copy(systemAsked = true))

    /**
     * #1262：第一次运行这一版时定下开关的起始值。文件已存在就什么都不做（幂等）——用户动过开关、
     * 或上一版 onboarding 问过通知，状态都在文件里，原样保留。
     *
     * 文件不存在时：老用户（已有配对 / 走完过 onboarding）写 true——上一版的默认值就是开，升级不许
     * 悄悄变成关；新装用户写 false。**无条件**落盘：之后新装用户配对成功、重启，不会因为「有配对」
     * 被误判成老用户。
     */
    fun initIfAbsent(existingUser: Boolean) {
        if (file.isFile) return
        save(NotifyOnFailurePrefsData(enabled = existingUser))
    }

    private fun save(data: NotifyOnFailurePrefsData) {
        dir.mkdirs()
        val tmp = File(dir, "$FILE_NAME.tmp")
        tmp.writeText(json.encodeToString(NotifyOnFailurePrefsData.serializer(), data))
        check(tmp.renameTo(file)) { "cannot persist $FILE_NAME" }
    }

    private fun load(): NotifyOnFailurePrefsData =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(NotifyOnFailurePrefsData.serializer(), file.readText())
            }.getOrDefault(NotifyOnFailurePrefsData())
        } else {
            NotifyOnFailurePrefsData()
        }

    companion object {
        const val FILE_NAME = "notify_on_failure_prefs.json"
    }
}

/**
 * #1262：设置里打开「通知」开关时该做什么（纯函数，判据本体）。
 * - 已授权（含 Android 12 及以下，没有运行时权限）→ 直接打开；
 * - 没问过，或系统还肯再弹（给了解释机会）→ 弹系统框，结果写回开关；
 * - 问过且系统不会再弹 → 去系统设置页。
 */
enum class NotifyEnableAction { ENABLE, REQUEST, OPEN_SETTINGS }

fun notifyEnableAction(granted: Boolean, askedBefore: Boolean, systemWillShowRationale: Boolean): NotifyEnableAction = when {
    granted -> NotifyEnableAction.ENABLE
    !askedBefore || systemWillShowRationale -> NotifyEnableAction.REQUEST
    else -> NotifyEnableAction.OPEN_SETTINGS
}
