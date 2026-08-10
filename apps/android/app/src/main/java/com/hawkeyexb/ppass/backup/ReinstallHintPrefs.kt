// DEV-01: 「重装识别」开关的持久化状态。默认开（产品默认：重装后
// 重扫一次码时，电脑端认出旧设备、默认「替换旧的」不留僵尸行）。
// 关掉 = 不发 device_hint，行为回到 DEV-01 前（重装后出新设备行）。
// filesDir JSON，tmp+rename 崩溃安全，损坏回默认（true=开）。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class ReinstallHintPrefsData(
    val enabled: Boolean = true,
)

class ReinstallHintPrefs(private val dir: File) {
    private val file = File(dir, "reinstall_hint_prefs.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun enabled(): Boolean = load().enabled

    fun setEnabled(enabled: Boolean) {
        dir.mkdirs()
        val tmp = File(dir, "reinstall_hint_prefs.json.tmp")
        tmp.writeText(json.encodeToString(ReinstallHintPrefsData.serializer(), ReinstallHintPrefsData(enabled)))
        check(tmp.renameTo(file)) { "cannot persist reinstall_hint_prefs.json" }
    }

    private fun load(): ReinstallHintPrefsData =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(ReinstallHintPrefsData.serializer(), file.readText())
            }.getOrDefault(ReinstallHintPrefsData())
        } else {
            ReinstallHintPrefsData()
        }
}
