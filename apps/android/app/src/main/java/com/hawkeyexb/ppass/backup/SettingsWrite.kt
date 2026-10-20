// #1020（对位 iOS #971 `AppModel.settingWriteFailed`）：设置写盘的 UI 边界。
//
// 各偏好 store（BackupSettings / AutoBackupPrefs / NotifyOnFailurePrefs / BackupScopeStore）写失败一律抛出——
// Worker、进程启动对账这些后台写者靠抛出暴露问题，store 里不吞。界面这一侧统一经过这里：
// 成功记一行日志（真机取证用）；失败记日志、给一过性提示（UI-12 的 Snackbar），调用方随后从盘上重读显示值。
// 不在这里改界面状态：显示值永远等于盘上的值，由调用方重读，不靠「写之前先改、失败再改回」。
package com.hawkeyexb.ppass.backup

import androidx.annotation.StringRes
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.log.PLog

internal class SettingsWriter(private val notify: (Int) -> Unit) {

    /**
     * 执行一次写盘。[what] 是日志里的设置名（`settings: saved wifiOnly=false` / `settings: write failed (wifiOnly)`）。
     * 成功返回 true；失败记日志、提示 [failedText]、返回 false——失败之后的副作用（重排任务、叫醒引擎）调用方不要做。
     */
    fun write(what: String, value: Any?, @StringRes failedText: Int = R.string.setting_save_failed, op: () -> Unit): Boolean =
        try {
            op()
            PLog.i(TAG, "settings: saved $what=$value")
            true
        } catch (e: Exception) {
            PLog.w(TAG, "settings: write failed ($what)", e)
            notify(failedText)
            false
        }

    /** 写 [value]，然后返回盘上的真实值（[load]）——成功时就是 [value]，失败时是原来的值。界面拿返回值显示。 */
    fun <T> persist(what: String, value: T, save: (T) -> Unit, load: () -> T): T {
        write(what, value) { save(value) }
        return load()
    }

    private companion object {
        const val TAG = "PPassSettings"
    }
}
