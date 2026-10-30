// #1263：首页「开启后台备份」卡片。onboarding 里不再问后台备份（新用户默认关），首页一直挂一张卡，
// 直到用户开启或手动关掉。这里只记「手动关掉了」；开没开看 AutoBackupPrefs 的意图。
// filesDir JSON，tmp+rename，损坏当没关过（卡片再出现一次，偏「让用户知道有这个选项」的一侧）。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class BackgroundBackupOfferState(val dismissed: Boolean = false)

class BackgroundBackupOfferStore(private val dir: File) {
    private val file = File(dir, FILE_NAME)
    private val json = Json { ignoreUnknownKeys = true }

    fun dismissed(): Boolean =
        if (file.isFile) {
            runCatching { json.decodeFromString(BackgroundBackupOfferState.serializer(), file.readText()).dismissed }.getOrDefault(false)
        } else {
            false
        }

    fun dismiss() {
        dir.mkdirs()
        val tmp = File(dir, "$FILE_NAME.tmp")
        tmp.writeText(json.encodeToString(BackgroundBackupOfferState.serializer(), BackgroundBackupOfferState(dismissed = true)))
        check(tmp.renameTo(file)) { "cannot persist $FILE_NAME" }
    }

    companion object {
        const val FILE_NAME = "background_backup_offer.json"
    }
}

/**
 * 卡片显示的判据（纯函数）：后台备份是「关」态，且没被手动关掉。卡片申请白名单被拒时不写意图，仍是「关」，卡片留着。
 * 从设置页开关打开、被拒的（意图是开、等系统授权）由「允许系统后台运行」那张提示接手。
 */
fun showBackgroundBackupOffer(state: BackgroundBackupState, dismissed: Boolean): Boolean =
    state == BackgroundBackupState.OffByUser && !dismissed
