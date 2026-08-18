// M10（全页面状态稿）："备份失败时通知我"是设置页里一个真实的开关行，
// 不是系统通知权限本身（那个在 OS 层，这里管的是"P-Pass 要不要在这个
// 本地偏好上再加一道闸"）——默认开，跟设计稿的开关默认态一致。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class NotifyOnFailurePrefsData(
    val enabled: Boolean = true,
)

class NotifyOnFailurePrefs(private val dir: File) {
    private val file = File(dir, "notify_on_failure_prefs.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun enabled(): Boolean = load().enabled

    fun setEnabled(enabled: Boolean) {
        dir.mkdirs()
        val tmp = File(dir, "notify_on_failure_prefs.json.tmp")
        tmp.writeText(json.encodeToString(NotifyOnFailurePrefsData.serializer(), NotifyOnFailurePrefsData(enabled)))
        check(tmp.renameTo(file)) { "cannot persist notify_on_failure_prefs.json" }
    }

    private fun load(): NotifyOnFailurePrefsData =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(NotifyOnFailurePrefsData.serializer(), file.readText())
            }.getOrDefault(NotifyOnFailurePrefsData())
        } else {
            NotifyOnFailurePrefsData()
        }
}
