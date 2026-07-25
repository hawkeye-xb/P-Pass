package com.hawkeyexb.ppass.probe

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobParameters
import android.app.job.JobService
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * S-04: User-Initiated Data Transfer JobService.
 *
 * Scheduled from the probe UI with a remote ticket.
 * Binds its own iroh endpoint and dials 100 MB × 20 loops in the background,
 * showing a foreground notification with progress.
 */
class UidtTransferService : JobService() {

    companion object {
        const val TAG = "UidtService"
        const val CHANNEL_ID = "uidt_transfer"
        const val NOTIFICATION_ID = 7001
        const val EXTRA_TICKET = "ticket"
        const val ITERATIONS = 20
        const val PAYLOAD_MB = 100
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var jobParams: JobParameters? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartJob(params: JobParameters?): Boolean {
        if (params == null) return false
        jobParams = params
        val ticket = params.extras.getString(EXTRA_TICKET)
        if (ticket.isNullOrBlank()) {
            Log.w(TAG, "No ticket in extras, finishing job")
            return false
        }

        Log.i(TAG, "UIDT job started, $ITERATIONS × ${PAYLOAD_MB}MB")

        startForeground(
            NOTIFICATION_ID,
            buildProgressNotification(0, "Starting…")
        )

        scope.launch {
            runUidtTransfer(ticket, params)
        }

        return true // work continues on background thread
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        Log.w(TAG, "Job stopped by system")
        scope.cancel()
        return true // reschedule
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
    }

    // ── transfer loop ────────────────────────────────────────────

    private suspend fun runUidtTransfer(ticket: String, params: JobParameters) {
        val probe = IrohProbe()
        val results = mutableListOf<ProbeResult>()
        val startTime = System.currentTimeMillis()

        try {
            probe.bind().getOrThrow()
            Log.i(TAG, "UIDT endpoint bound: ${probe.nodeId()}")

            for (i in 1..ITERATIONS) {
                // Check cancellation
                if (scope.coroutineContext.isActive.not()) {
                    Log.i(TAG, "UIDT cancelled at iteration $i")
                    break
                }

                val progressPct = ((i - 1) * 100) / ITERATIONS
                updateForegroundNotification(
                    progressPct,
                    "Transfer $i / $ITERATIONS"
                )

                Log.d(TAG, "UIDT transfer $i/$ITERATIONS starting")
                val result = probe.dial(ticket, payloadMegaBytes = PAYLOAD_MB)
                val labeled = result.copy(attempt = i)
                results.add(labeled)

                if (labeled.error != null) {
                    Log.w(TAG, "UIDT transfer $i failed: ${labeled.error}")
                } else {
                    Log.i(TAG, "UIDT transfer $i ok: path=${labeled.path} throughput=${"%.0f".format(labeled.throughputMbps)}Mbps")
                }
            }

            showResultsNotification(results, startTime)
        } catch (e: Exception) {
            Log.e(TAG, "UIDT fatal error", e)
            showErrorNotification(e.message ?: "Unknown error")
        } finally {
            probe.shutdown()
            jobFinished(params, false)
            Log.i(TAG, "UIDT job finished")
        }
    }

    // ── notification helpers ─────────────────────────────────────

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "UIDT Transfers",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Background transfer progress"
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(channel)
    }

    private fun buildProgressNotification(progressPct: Int, text: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("UIDT Transfer Running")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_upload)
            .setOngoing(true)
            .setProgress(100, progressPct, false)
            .setContentIntent(openIntent)
            .build()
    }

    private fun updateForegroundNotification(progressPct: Int, text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val n = buildProgressNotification(progressPct, text)
        nm.notify(NOTIFICATION_ID, n)
    }

    private fun showResultsNotification(
        results: List<ProbeResult>,
        startTimeMs: Long,
    ) {
        val elapsed = (System.currentTimeMillis() - startTimeMs) / 1_000
        val success = results.count { it.error == null }
        val fail = results.count { it.error != null }
        val avgMbps = results
            .filter { it.error == null && it.throughputMbps > 0 }
            .map { it.throughputMbps }
            .let { if (it.isEmpty()) 0.0 else it.sum() / it.size }

        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val n = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("UIDT Transfer Complete")
            .setContentText("$success/$ITERATIONS ok, ${"%.0f".format(avgMbps)} Mbps avg · ${elapsed}s")
            .setStyle(
                Notification.BigTextStyle()
                    .bigText(
                        "Success: $success  Fail: $fail\n" +
                        "Avg throughput: ${"%.0f".format(avgMbps)} Mbps\n" +
                        "Total elapsed: ${elapsed}s"
                    )
            )
            .setSmallIcon(android.R.drawable.ic_menu_upload)
            .setOngoing(false)
            .setAutoCancel(true)
            .setContentIntent(openIntent)
            .build()

        nm.notify(NOTIFICATION_ID, n)
    }

    private fun showErrorNotification(message: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val n = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("UIDT Transfer Failed")
            .setContentText(message)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIFICATION_ID, n)
    }
}
