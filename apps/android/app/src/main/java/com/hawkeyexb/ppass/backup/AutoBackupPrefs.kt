// UX-06: 全局「暂停自动备份」开关的持久化状态。暂停 = 取消周期任务
// （WorkManager cancel）+ 落盘 paused=true；恢复 = 重新 schedule。
// filesDir JSON，tmp+rename 崩溃安全，损坏回默认（false=未暂停）。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class AutoBackupPrefsData(
    val paused: Boolean = false,
)

/** Pause-state store for auto backup. Distinct file from BackupSettings
 *  (UX-03, charge/wifi switches) — merged by review. */
class AutoBackupPrefs(private val dir: File) {
    private val file = File(dir, "auto_backup_prefs.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun paused(): Boolean = load().paused

    fun setPaused(paused: Boolean) {
        dir.mkdirs()
        val tmp = File(dir, "auto_backup_prefs.json.tmp")
        tmp.writeText(json.encodeToString(AutoBackupPrefsData.serializer(), AutoBackupPrefsData(paused)))
        check(tmp.renameTo(file)) { "cannot persist auto_backup_prefs.json" }
    }

    private fun load(): AutoBackupPrefsData =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(AutoBackupPrefsData.serializer(), file.readText())
            }.getOrDefault(AutoBackupPrefsData())
        } else {
            AutoBackupPrefsData()
        }
}
