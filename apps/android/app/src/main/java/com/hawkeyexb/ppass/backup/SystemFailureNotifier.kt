// MOB-67: the Android side of the failure notification — UX-02's behavior,
// re-hosted on the Flow core after REBUILD-04 deleted it from BackupWorker.
// Channel id and notification id are deliberately the historical values
// (`ppass.backup.failed`, 2027): users who already tuned the channel keep
// their settings, and the fixed id means a second terminal failure updates
// the existing notification instead of stacking a second buzz.
package com.hawkeyexb.ppass.backup

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.hawkeyexb.ppass.MainActivity
import com.hawkeyexb.ppass.R

class SystemFailureNotifier(
    private val context: Context,
    private val prefs: NotifyOnFailurePrefs,
) : FailureNotifier {
    override fun enabled(): Boolean = prefs.enabled()

    override fun postFailure(failedItems: Int) {
        // #413 §8：有通知权限才发（API 33+ 的运行时权限，以及用户在系统设置里关掉的通知）。
        if (!canPostNotifications(context)) return
        val nm = context.getSystemService(NotificationManager::class.java)
        ensureAttentionChannel(context, nm)
        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            context,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, FAIL_CHANNEL_ID)
            .setContentTitle(context.getString(R.string.notif_backup_failed_title))
            .setContentText(context.resources.getQuantityString(R.plurals.notif_backup_failed_body, failedItems, failedItems))
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify(FAIL_NOTIFICATION_ID, notification)
    }

    private companion object {
        const val FAIL_NOTIFICATION_ID = 2027
    }
}

/**
 * 历史渠道 id 不变（`ppass.backup.failed`）：用户调过的渠道设置保留；同 id 再建一次只更新显示名。
 * #130 起这条渠道承载「需要你处理」的确定事件（[SystemDefinitiveEventNotifier]），显示名随之改。
 */
internal const val FAIL_CHANNEL_ID = "ppass.backup.failed"

private fun ensureAttentionChannel(context: Context, nm: NotificationManager) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        nm.createNotificationChannel(
            NotificationChannel(
                FAIL_CHANNEL_ID,
                context.getString(R.string.notif_channel_backup_failed),
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
    }
}

/** #130 第 1 层：每类确定事件一个 id（避开 FGS 的 2026 与失败通知的 2027），也各用一个 requestCode。 */
internal fun definitiveNotificationIdOf(event: DefinitiveEvent): Int = when (event) {
    DefinitiveEvent.PAIRING_LOST -> 2028
    DefinitiveEvent.MEDIA_ACCESS_REVOKED -> 2029
    DefinitiveEvent.BACKGROUND_STOPPED -> 2030
}

/**
 * #130 第 1 层的 Android 发送端。点开直达处理入口：
 * - 配对失效 → 打开 App（默认照片页就是失联红卡，上面是「重新扫码连接」）。不替用户清配对。
 * - 相册权限 → 系统的应用详情页（改相册权限的地方）。
 * - 后台被停 → 打开 App，由提示条的「去处理」接手（MOB-28：用户点了才恢复，不从通知直接重挂）。
 */
class SystemDefinitiveEventNotifier(
    private val context: Context,
    private val prefs: NotifyOnFailurePrefs,
) : DefinitiveEventNotifier {
    override fun enabled(): Boolean = prefs.enabled() && canPostNotifications(context)

    override fun post(notice: DefinitiveNotice) {
        if (!canPostNotifications(context)) return
        val nm = context.getSystemService(NotificationManager::class.java)
        ensureAttentionChannel(context, nm)
        val (title, body) = when (notice) {
            DefinitiveNotice.PairingLost ->
                R.string.pairing_lost_title to R.string.notif_pairing_lost_body
            is DefinitiveNotice.MediaAccessRevoked ->
                if (notice.now == MediaAccess.NONE) {
                    R.string.no_media_access_title to R.string.notif_media_none_body
                } else {
                    R.string.partial_access_title to R.string.notif_media_partial_body
                }
            is DefinitiveNotice.BackgroundStopped ->
                if (notice.batteryOnly) {
                    R.string.notif_battery_reenabled_title to R.string.notif_battery_reenabled_body
                } else {
                    R.string.notif_background_stopped_title to R.string.notif_background_stopped_body
                }
        }
        val target = when (notice.event) {
            DefinitiveEvent.MEDIA_ACCESS_REVOKED -> Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            DefinitiveEvent.PAIRING_LOST, DefinitiveEvent.BACKGROUND_STOPPED ->
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
        }
        val id = definitiveNotificationIdOf(notice.event)
        val pi = PendingIntent.getActivity(
            context,
            id,
            target,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val bodyText = context.getString(body)
        val notification = NotificationCompat.Builder(context, FAIL_CHANNEL_ID)
            .setContentTitle(context.getString(title))
            .setContentText(bodyText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(bodyText))
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify(id, notification)
    }

    override fun cancel(event: DefinitiveEvent) {
        NotificationManagerCompat.from(context).cancel(definitiveNotificationIdOf(event))
    }
}

/**
 * #413 §8：这台手机此刻能不能发通知——API 33+ 要 POST_NOTIFICATIONS 运行时权限（更早的版本装完就有），
 * 而且用户没在系统设置里关掉本 App 的通知。发任何非 FGS 通知前都先问它。
 */
fun canPostNotifications(context: Context): Boolean {
    val granted = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    return granted && NotificationManagerCompat.from(context).areNotificationsEnabled()
}
