// UPD-02: 更新 APK 的后台下载 Worker。
//
// 为什么是 WorkManager 而不是对话框里的协程：APK 几十 MB，用户切走/锁屏/
// 进程被杀都该续上——WorkManager 给唯一工作、约束（联网）、指数退避重试
// 和进程死亡后的续跑；HTTP Range 断点（resumePlanFor）让重试不从头来。
// 前台通知（LOW 重要性频道）是 WorkManager 对长下载的要求，也顺带让
// 「在下更新」这件事离开对话框后仍然可见。
package com.hawkeyexb.ppass.update

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.hawkeyexb.ppass.R
import java.io.File
import java.util.concurrent.TimeUnit

class UpdateDownloadWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val url = inputData.getString(KEY_URL) ?: return Result.failure()
        val version = inputData.getString(KEY_VERSION).orEmpty()
        val sha256 = inputData.getString(KEY_SHA256).orEmpty()
        val signature = inputData.getString(KEY_SIGNATURE).orEmpty()

        val apk = updateApkFile(applicationContext.cacheDir).apply { parentFile?.mkdirs() }
        val marker = completeMarkerFile(applicationContext.cacheDir)

        runCatching { setForeground(downloadNotification(received = 0, total = -1)) }

        // 完成标记在 = 上次已整包落盘（worker 重跑 / 进程死亡恢复），直接进校验。
        val download = if (marker.isFile && apk.isFile && apk.length() > 0) {
            ApkDownloadResult.Ok(apk.length())
        } else {
            marker.delete()
            var lastNotified = 0L
            downloadApk(
                url,
                apk,
                resumeFromBytes = if (apk.isFile) apk.length() else 0L,
                onProgress = { received, total ->
                    setProgressAsync(
                        workDataOf(PROGRESS_RECEIVED to received, PROGRESS_TOTAL to total)
                    )
                    // 通知节流：每 512KB 一次，别把 NotificationManager 刷爆。
                    // 非挂起回调里用 setForegroundAsync（suspend 版在这里编译不过）。
                    if (received - lastNotified >= 512 * 1024) {
                        lastNotified = received
                        runCatching {
                            setForegroundAsync(downloadNotification(received, total))
                        }
                    }
                },
            )
        }

        return when (download) {
            is ApkDownloadResult.Ok -> {
                android.util.Log.i(UPDATE_LOG_TAG, download.logLine(url))
                setProgressAsync(workDataOf(PROGRESS_VERIFYING to true))
                when (val verify = ApkVerifier.verifyDownloadedApk(apk, sha256, signature)) {
                    ApkVerifier.Result.Ok -> {
                        marker.writeText("ok")
                        Result.success(
                            workDataOf(KEY_VERSION to version, KEY_BYTES to download.bytes)
                        )
                    }
                    else -> {
                        // 校验不过 = 这份字节永远不该被装——删干净，不重试
                        // （重试拿回来的还是同一份字节），如实报 Verify 类失败。
                        android.util.Log.w(UPDATE_LOG_TAG, "apk verify FAILED for $version: $verify")
                        apk.delete()
                        marker.delete()
                        Result.failure(failureData(UpdateFailureKind.Verify))
                    }
                }
            }
            else -> {
                android.util.Log.w(UPDATE_LOG_TAG, download.logLine(url))
                val kind = failureKindOf(download)
                if (retryVerdictOf(download, runAttemptCount) == DownloadVerdict.Retry) {
                    Result.retry()
                } else {
                    apk.delete()
                    marker.delete()
                    Result.failure(failureData(kind))
                }
            }
        }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo =
        downloadNotification(received = 0, total = -1)

    private fun downloadNotification(received: Long, total: Long): ForegroundInfo {
        ensureUpdateChannel(applicationContext)
        val builder = NotificationCompat.Builder(applicationContext, UPDATE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(applicationContext.getString(R.string.notif_update_download_title))
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        if (total > 0) {
            val percent = (received * 100 / total).toInt().coerceIn(0, 100)
            builder.setProgress(100, percent, false)
                .setContentText("$percent%")
        } else {
            builder.setProgress(0, 0, true)
        }
        val notification = builder.build()
        return if (Build.VERSION.SDK_INT >= 29) {
            // SystemForegroundService 已声明 dataSync（备份前台服务同款类型），
            // 更新下载与它共用这一声明，不新增权限/类型。
            ForegroundInfo(UPDATE_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(UPDATE_NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val UNIQUE_WORK_NAME = "ppass.update.download"

        const val KEY_URL = "url"
        const val KEY_VERSION = "version"
        const val KEY_SHA256 = "sha256"
        const val KEY_SIGNATURE = "signature"
        const val KEY_BYTES = "bytes"
        const val KEY_FAILURE_KIND = "failure_kind"

        const val PROGRESS_RECEIVED = "received"
        const val PROGRESS_TOTAL = "total"
        const val PROGRESS_VERIFYING = "verifying"

        /** 下载类失败最多补 2 次（共 3 跑）——指数退避，仍失败就如实报给用户。 */
        internal const val MAX_RUN_ATTEMPTS = 3

        /** 用户确认后入队。REPLACE：重复确认 = 放弃旧的、按最新 manifest 重来。 */
        fun enqueue(context: Context, info: UpdateInfo) {
            val request = OneTimeWorkRequestBuilder<UpdateDownloadWorker>()
                .setInputData(
                    Data.Builder()
                        .putString(KEY_URL, info.url)
                        .putString(KEY_VERSION, info.version)
                        .putString(KEY_SHA256, info.sha256)
                        .putString(KEY_SIGNATURE, info.signature)
                        .build(),
                )
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork(UNIQUE_WORK_NAME, ExistingWorkPolicy.REPLACE, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_WORK_NAME)
        }
    }
}

internal const val UPDATE_CHANNEL_ID = "ppass.update"
internal const val UPDATE_NOTIFICATION_ID = 2031

/** 整包落盘标记：区分「残包可续」与「整包待验」，进程死亡恢复靠它。 */
internal fun completeMarkerFile(cacheDir: File): File =
    File(File(cacheDir, "update"), "ppass-update.apk.complete")

internal fun ensureUpdateChannel(context: Context) {
    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (manager.getNotificationChannel(UPDATE_CHANNEL_ID) == null) {
        manager.createNotificationChannel(
            NotificationChannel(
                UPDATE_CHANNEL_ID,
                context.getString(R.string.notif_channel_update),
                NotificationManager.IMPORTANCE_LOW,
            )
        )
    }
}

/** 失败结果携带失败类（controller 读它映射文案）。 */
private fun failureData(kind: UpdateFailureKind) = workDataOf(UpdateDownloadWorker.KEY_FAILURE_KIND to kind.name)

/** 更新失败的分类（UI 文案按类分句，见 [failureTextRes]）。 */
enum class UpdateFailureKind { Network, Server, Stalled, Write, Verify, Install, Unexpected }

/** ApkDownloadResult → 失败类（纯函数，JVM 可测）。Ok 不可达，归 Unexpected。 */
internal fun failureKindOf(result: ApkDownloadResult): UpdateFailureKind = when (result) {
    is ApkDownloadResult.Stalled -> UpdateFailureKind.Stalled
    is ApkDownloadResult.HttpStatus -> UpdateFailureKind.Server
    is ApkDownloadResult.ConnectionFailed -> UpdateFailureKind.Network
    is ApkDownloadResult.LocalWriteFailed -> UpdateFailureKind.Write
    is ApkDownloadResult.Unexpected, is ApkDownloadResult.Ok -> UpdateFailureKind.Unexpected
}

internal enum class DownloadVerdict { Retry, GiveUp }

/**
 * 失败该不该让 WorkManager 退避重试（纯函数，JVM 可测）：
 * 停滞/断连、5xx、429 = 值得再来一次（有次数上限）；4xx（除 429）、写盘失败、
 * 未知异常 = 重试也是同一个结果，直接给用户交代。
 */
internal fun retryVerdictOf(result: ApkDownloadResult, runAttemptCount: Int): DownloadVerdict {
    val attemptsLeft = runAttemptCount + 1 < UpdateDownloadWorker.MAX_RUN_ATTEMPTS
    return when (result) {
        is ApkDownloadResult.Stalled, is ApkDownloadResult.ConnectionFailed ->
            if (attemptsLeft) DownloadVerdict.Retry else DownloadVerdict.GiveUp
        is ApkDownloadResult.HttpStatus ->
            if (attemptsLeft && (result.code >= 500 || result.code == 429)) {
                DownloadVerdict.Retry
            } else {
                DownloadVerdict.GiveUp
            }
        else -> DownloadVerdict.GiveUp
    }
}
