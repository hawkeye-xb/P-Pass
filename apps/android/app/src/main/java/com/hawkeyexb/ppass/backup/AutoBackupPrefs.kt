// MOB-65: 自动备份开关只拥有「是否允许自动唤醒」这一条策略事实；当前轮的
// 暂停/继续仍完全由 Flow ledger 的 ConsumerGate 拥有。
// filesDir JSON，tmp+rename 崩溃安全，损坏回默认（自动备份开启）。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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

    fun setEnabled(enabled: Boolean) = synchronized(LOCK) {
        save(load().copy(autoEnabled = enabled))
    }

    fun setRequested(requested: Boolean) = synchronized(LOCK) {
        save(load().copy(userRequested = requested))
    }

    companion object {
        /**
         * #540：进程启动线程（`reconcileWatchOnProcessStart`）与主线程（`ON_RESUME`）都会写这份文件；
         * 两个写者共用一个 `.tmp`，不串行化的话后到的 rename 找不到 tmp，`check` 直接抛。
         */
        private val LOCK = Any()

        private val _revision = MutableStateFlow(0L)

        /**
         * #540：每落盘一次加一。界面据此重读 [enabled]——生产者状态可能由别的线程（进程启动对账）
         * 改掉，只在界面自己的回调里刷新会漏，漏了就是「开关开、状态行写自动进行、实际 0 个任务」。
         */
        val revision: StateFlow<Long> = _revision.asStateFlow()
    }

    private fun save(data: AutoBackupPrefsData) {
        dir.mkdirs()
        val tmp = File(dir, "auto_backup_prefs.json.tmp")
        tmp.writeText(json.encodeToString(AutoBackupPrefsData.serializer(), data))
        check(tmp.renameTo(file)) { "cannot persist auto_backup_prefs.json" }
        _revision.value = _revision.value + 1
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
