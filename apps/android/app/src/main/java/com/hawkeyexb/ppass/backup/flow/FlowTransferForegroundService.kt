// NET-12: the foreground service protection REBUILD-04 deleted (see
// FlowUiProjection.kt's foregroundActionFor doc for the full root-cause
// history and real-device evidence). This class only owns the Android
// Service lifecycle; the START/STOP decision itself is the pure,
// JVM-tested foregroundActionFor.
package com.hawkeyexb.ppass.backup.flow

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.hawkeyexb.ppass.MainActivity
import com.hawkeyexb.ppass.R

/**
 * NET-12: keeps the transfer foreground service's running state in sync
 * with the durable "is a round active" ledger fact. Called from the same
 * postcondition point every Flow trigger already reaches
 * ([AndroidFlowRuntime]'s `flushAuditOutbox`), so it never depends on a
 * caller remembering to invoke it separately.
 */
internal object FlowTransferForeground {
    fun sync(context: Context, snapshot: DiscoveryLedgerSnapshot) {
        val app = context.applicationContext
        when (foregroundActionFor(snapshot)) {
            ForegroundAction.START -> {
                val intent = Intent(app, FlowTransferForegroundService::class.java)
                    .putExtra(FlowTransferForegroundService.EXTRA_TEXT, textFor(app, snapshot))
                ContextCompat.startForegroundService(app, intent)
            }
            ForegroundAction.STOP -> {
                app.stopService(Intent(app, FlowTransferForegroundService::class.java))
            }
        }
    }

    private fun textFor(context: Context, snapshot: DiscoveryLedgerSnapshot): String {
        val aggregate = flowAggregateOf(snapshot)
        val done = aggregate.confirmed.toInt()
        val total = (aggregate.confirmed + aggregate.pending).toInt()
        val currentFile = (flowUiStateOf(snapshot) as? FlowUiState.Transferring)?.fileName.orEmpty()
        return if (currentFile.isNotEmpty()) {
            context.getString(R.string.state_sending_file, currentFile, done, total)
        } else {
            context.getString(R.string.state_sending, done, total)
        }
    }
}

/**
 * MOB-08's real-device lesson still applies here: WorkManager's own FGS
 * declares `foregroundServiceType="dataSync"` in the manifest — this
 * service must match it or `startForeground(DATA_SYNC)` crashes on
 * Android 14 (T-054b crash history).
 */
class FlowTransferForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.notif_channel_transfer),
                    NotificationManager.IMPORTANCE_LOW, // silent — this is status, not an alert
                ),
            )
        }
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notif_transfer_title))
            .setContentText(text.ifEmpty { getString(R.string.notif_transfer_title) })
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setContentIntent(pi)
        return builder.build()
    }

    companion object {
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "ppass.backup.transfer"
        private const val NOTIFICATION_ID = 2026
    }
}
