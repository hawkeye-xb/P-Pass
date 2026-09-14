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
    /** Actual producer state. It may be false while the user still wants it on. */
    val autoEnabled: Boolean = false,
    /** Explicit user intent; old files fall back to their former active value. */
    val userRequested: Boolean? = null,
)

/** Policy store for automatic producer wakes. Distinct from Flow's round gate. */
class AutoBackupPrefs(private val dir: File) {
    private val file = File(dir, "auto_backup_prefs.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun enabled(): Boolean = load().autoEnabled

    fun requested(): Boolean = load().userRequested ?: load().autoEnabled

    fun setEnabled(enabled: Boolean) {
        save(load().copy(autoEnabled = enabled))
    }

    fun setRequested(requested: Boolean) {
        save(load().copy(userRequested = requested))
    }

    private fun save(data: AutoBackupPrefsData) {
        dir.mkdirs()
        val tmp = File(dir, "auto_backup_prefs.json.tmp")
        tmp.writeText(json.encodeToString(AutoBackupPrefsData.serializer(), data))
        check(tmp.renameTo(file)) { "cannot persist auto_backup_prefs.json" }
    }

    private fun load(): AutoBackupPrefsData =
        if (file.isFile) {
            runCatching {
                val fields = json.parseToJsonElement(file.readText()).jsonObject
                val enabled = fields["autoEnabled"]?.jsonPrimitive?.booleanOrNull
                    ?: fields["paused"]?.jsonPrimitive?.booleanOrNull?.not()
                    ?: false
                val requested = fields["userRequested"]?.jsonPrimitive?.booleanOrNull
                AutoBackupPrefsData(autoEnabled = enabled, userRequested = requested)
            }.getOrDefault(AutoBackupPrefsData())
        } else {
            AutoBackupPrefsData()
        }
}
