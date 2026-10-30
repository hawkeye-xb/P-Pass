// #1272：「自动备份」规则开关（以后哪些照片自动送到电脑）。与 [AutoBackupPrefs]（「App 关着也传」= 后台唤醒）是两件事：
// 规则关着时引擎不做自动备份这一支（只剩手选）；规则开着，后台唤醒才有意义。
// 老用户升级：没有这份文件时按「已有备份范围」推出初值并落盘（有范围 = 自动备份已开）。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
private data class AutoBackupRuleData(val enabled: Boolean = false)

class AutoBackupRulePrefs(private val dir: File, private val hasScope: () -> Boolean = { false }) {
    private val file = File(dir, FILE_NAME)
    private val json = Json { ignoreUnknownKeys = true }

    fun enabled(): Boolean = synchronized(LOCK) {
        if (file.isFile) {
            runCatching { json.decodeFromString(AutoBackupRuleData.serializer(), file.readText()).enabled }.getOrDefault(false)
        } else {
            hasScope().also { save(it) }
        }
    }

    fun set(enabled: Boolean) = synchronized(LOCK) { save(enabled) }

    private fun save(enabled: Boolean) {
        dir.mkdirs()
        val tmp = File(dir, "$FILE_NAME.tmp")
        tmp.writeText(json.encodeToString(AutoBackupRuleData.serializer(), AutoBackupRuleData(enabled)))
        check(tmp.renameTo(file)) { "cannot persist $FILE_NAME" }
    }

    companion object {
        const val FILE_NAME = "auto_backup_rule.json"
        private val LOCK = Any()
    }
}
