// UX-03: 自动备份极简设置——「仅充电」「仅 WiFi」两开关，写 WorkManager
// 约束（BackupWorker 的 Constraints 由 BackupSettings 决定，改开关即
// rescheduleAutoBackup 按新约束重建周期任务）。
// filesDir JSON（WatermarkStore 同款：tmp+rename 崩溃安全，损坏读默认）。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 极简设置快照。默认值 = 产品默认：插电 + WiFi 才跑。 */
@Serializable
data class BackupSettingsState(
    val chargeOnly: Boolean = true,
    val wifiOnly: Boolean = true,
)

class BackupSettings(private val dir: File) {
    private val file = File(dir, "backup-settings.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): BackupSettingsState =
        if (file.isFile) {
            try {
                json.decodeFromString(BackupSettingsState.serializer(), file.readText())
            } catch (_: Exception) {
                BackupSettingsState() // 损坏则回默认（不崩）
            }
        } else BackupSettingsState()

    /** 幂等保存：tmp + rename 崩溃安全。 */
    fun save(chargeOnly: Boolean, wifiOnly: Boolean) {
        dir.mkdirs()
        val tmp = File(dir, "backup-settings.json.tmp")
        tmp.writeText(
            json.encodeToString(
                BackupSettingsState.serializer(),
                BackupSettingsState(chargeOnly = chargeOnly, wifiOnly = wifiOnly),
            )
        )
        check(tmp.renameTo(file)) { "cannot persist backup settings" }
    }
}
