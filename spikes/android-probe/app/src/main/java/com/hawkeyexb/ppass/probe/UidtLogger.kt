package com.hawkeyexb.ppass.probe

import android.content.Context
import android.os.BatteryManager
import android.os.PowerManager
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * S-04: Simple file-based logger for UIDT transfer runs.
 *
 * Writes one JSON line per transfer to app internal storage.
 * Also writes lifecycle events (job_started, job_stopped, job_cancelled)
 * so we can reconstruct what happened during lock screen.
 */
object UidtLogger {

    private const val TAG = "UidtLogger"
    private const val FILENAME = "uidt_log.jsonl"

    private var logFile: File? = null
    private var startSystemMs: Long = 0
    private var context: Context? = null

    fun init(ctx: Context) {
        context = ctx.applicationContext
        logFile = File(ctx.filesDir, FILENAME)
    }

    fun startSession() {
        startSystemMs = System.currentTimeMillis()
        append("job_started", mapOf(
            "timestamp" to isoNow(),
            "system_elapsed_ms" to android.os.SystemClock.elapsedRealtime(),
        ))
        Log.i(TAG, "Session started, log: ${logFile?.absolutePath}")
    }

    fun logResult(result: ProbeResult, ctx: Context) {
        append("transfer", mapOf(
            "attempt" to result.attempt,
            "path" to result.path,
            "ipver" to result.ipver,
            "connect_ms" to result.connectMs,
            "throughput_mbps" to result.throughputMbps,
            "error" to (result.error ?: ""),
            "elapsed_s" to ((System.currentTimeMillis() - startSystemMs) / 1000),
            "timestamp" to isoNow(),
        ) + deviceState(ctx))
    }

    fun stop(reason: String) {
        append("job_stopped", mapOf(
            "reason" to reason,
            "total_elapsed_s" to ((System.currentTimeMillis() - startSystemMs) / 1000),
            "timestamp" to isoNow(),
        ))
    }

    fun readLogAsText(ctx: Context): String {
        val file = File(ctx.filesDir, FILENAME)
        return if (file.exists()) file.readText() else "(no log)"
    }

    // -- internals --

    private fun append(type: String, fields: Map<String, Any?>) {
        val all = mutableMapOf<String, Any?>(
            "type" to type,
        )
        all.putAll(fields)

        val json = buildJsonLine(all)
        try {
            logFile?.appendText(json + "\n")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write log: ${e.message}")
        }
    }

    private fun buildJsonLine(map: Map<String, Any?>): String {
        return map.entries.joinToString(",", "{", "}") { (k, v) ->
            val valStr = when (v) {
                null -> "null"
                is String -> "\"${v.replace("\"", "\\\"")}\""
                is Number -> v.toString()
                else -> "\"$v\""
            }
            "\"$k\":$valStr"
        }
    }

    private fun deviceState(ctx: Context): Map<String, Any> {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        return mapOf(
            "screen_on" to pm.isInteractive,
            "charging" to (bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_STATUS)
                == BatteryManager.BATTERY_STATUS_CHARGING),
        )
    }

    private fun isoNow(): String {
        return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())
    }
}
