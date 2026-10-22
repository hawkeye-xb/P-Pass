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

    /**
     * #1039：没有用户操作在等结果的写盘（进程回到前台的对账、首页存量补记、启动时定老用户），或 iOS 对位处只记日志的
     * （完成页「问过通知」、快速重连按意图恢复）——失败只记日志、不提示，返回 false；调用方照常往下走。
     */
    fun quiet(what: String, value: Any?, op: () -> Unit): Boolean =
        try {
            op()
            PLog.i(TAG, "settings: saved $what=$value")
            true
        } catch (e: Exception) {
            PLog.w(TAG, "settings: write failed ($what)", e)
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

/**
 * #1039（对位 iOS #969 `LivePairing.saveFailure`）：配对文件写盘。成功返回 null；失败记日志、返回原因（给配对失败页的细节行），
 * 不抛——写盘成功才算配对成功，调用方据此进失败页，而不是进一个重启即丢的「已配对」。
 */
internal fun savePairingOrError(save: () -> Unit): String? =
    try {
        save()
        null
    } catch (e: Exception) {
        PLog.w("PPassPair", "pair: cannot persist pairing.json", e)
        e.message ?: e.javaClass.simpleName
    }
