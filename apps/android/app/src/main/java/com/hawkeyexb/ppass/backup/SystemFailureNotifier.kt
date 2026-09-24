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
import android.os.Build
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    FAIL_CHANNEL_ID,
                    context.getString(R.string.notif_channel_backup_failed),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
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
        const val FAIL_CHANNEL_ID = "ppass.backup.failed"
        const val FAIL_NOTIFICATION_ID = 2027
    }
}

/**
 * #413 §8：这台手机此刻能不能发通知——API 33+ 要 POST_NOTIFICATIONS 运行时权限（更早的版本装完就有），
 * 而且用户没在系统设置里关掉本 App 的通知。发任何非 FGS 通知前都先问它；设置页「备份失败时通知我」也读它。
 */
fun canPostNotifications(context: Context): Boolean {
    val granted = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    return granted && NotificationManagerCompat.from(context).areNotificationsEnabled()
}
