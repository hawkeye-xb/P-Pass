// #1272：「自动备份」规则开关（以后哪些照片自动送到电脑）。与 [AutoBackupPrefs]（「App 关着也传」= 后台唤醒）是两件事：
// 规则关着时引擎不做自动备份这一支（只剩手选）；规则开着，后台唤醒才有意义。
// 没存过值时按当前真实状态初始化一次并落盘：已有全部照片权限且已选过备份范围 ⇒ 开，否则 ⇒ 关
// （读现状，不是升级迁移）。之后以存下的偏好为准；权限被收回时偏好不动，界面显示成单独状态。
package com.hawkeyexb.ppass.backup

import android.content.Context
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
private data class AutoBackupRuleData(val enabled: Boolean = false)

class AutoBackupRulePrefs(private val dir: File, private val initial: () -> Boolean = { false }) {
    private val file = File(dir, FILE_NAME)
    private val json = Json { ignoreUnknownKeys = true }

    fun enabled(): Boolean = synchronized(LOCK) {
        if (file.isFile) {
            runCatching { json.decodeFromString(AutoBackupRuleData.serializer(), file.readText()).enabled }.getOrDefault(false)
        } else {
            initial().also { save(it) }
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

/** 没存过值时的初值：全部照片权限 + 已选过备份范围。 */
fun autoBackupRulePrefs(context: Context): AutoBackupRulePrefs {
    val app = context.applicationContext
    return AutoBackupRulePrefs(
        app.filesDir,
        initial = { currentMediaAccess(app) == MediaAccess.FULL && BackupScopeStore(app).selectedBucketIds() != null },
    )
}
