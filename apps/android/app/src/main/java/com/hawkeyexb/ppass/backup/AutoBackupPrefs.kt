// MOB-65: 自动备份开关只拥有「是否允许自动唤醒」这一条策略事实；当前轮的
// 暂停/继续仍完全由 Flow ledger 的 ConsumerGate 拥有。
// filesDir JSON，tmp+rename 崩溃安全，损坏回默认（自动备份开启）。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

@Serializable
data class AutoBackupPrefsData(
    val autoEnabled: Boolean = true,
)

/** Policy store for automatic producer wakes. Distinct from Flow's round gate. */
class AutoBackupPrefs(private val dir: File) {
    private val file = File(dir, "auto_backup_prefs.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun enabled(): Boolean = load().autoEnabled

    fun setEnabled(enabled: Boolean) {
        dir.mkdirs()
        val tmp = File(dir, "auto_backup_prefs.json.tmp")
        tmp.writeText(json.encodeToString(AutoBackupPrefsData.serializer(), AutoBackupPrefsData(enabled)))
        check(tmp.renameTo(file)) { "cannot persist auto_backup_prefs.json" }
    }

    private fun load(): AutoBackupPrefsData =
        if (file.isFile) {
            runCatching {
                val fields = json.parseToJsonElement(file.readText()).jsonObject
                val enabled = fields["autoEnabled"]?.jsonPrimitive?.booleanOrNull
                    ?: fields["paused"]?.jsonPrimitive?.booleanOrNull?.not()
                    ?: true
                AutoBackupPrefsData(autoEnabled = enabled)
            }.getOrDefault(AutoBackupPrefsData())
        } else {
            AutoBackupPrefsData()
        }
}
