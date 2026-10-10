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
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.log.PLog
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

        // #719: 产物按身份分目录——不同版本的两个 Worker 永远不碰同一个文件。
        val artifacts = updateArtifactsOf(
            applicationContext.cacheDir,
            downloadIdentityOf(version, url, sha256),
        )

        runCatching { setForeground(downloadNotification(received = 0, total = -1)) }

        var lastNotified = 0L
        val settled = runUpdateDownload(
            artifacts = artifacts,
            runAttemptCount = runAttemptCount,
            onStaleCleared = {
                PLog.i(UPDATE_LOG_TAG, "stale update artifacts cleared before downloading $version")
            },
            fetch = { resumeFromBytes ->
                downloadApk(
                    url,
                    artifacts.apk,
                    resumeFromBytes = resumeFromBytes,
                    isStopped = { isStopped },
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
            },
            onDownloaded = { download ->
                if (download is ApkDownloadResult.Ok) {
                    PLog.i(UPDATE_LOG_TAG, download.logLine(url))
                    setProgressAsync(workDataOf(PROGRESS_VERIFYING to true))
                } else {
                    PLog.w(UPDATE_LOG_TAG, download.logLine(url))
                }
            },
            verify = { file ->
                ApkVerifier.verifyDownloadedApk(file, sha256, signature).also {
                    if (it != ApkVerifier.Result.Ok) {
                        PLog.w(UPDATE_LOG_TAG, "apk verify FAILED for $version: $it")
                    }
                }
            },
        )
        return when (settled) {
            is DownloadSettlement.Verified ->
                Result.success(workDataOf(KEY_VERSION to version, KEY_BYTES to settled.bytes))
            DownloadSettlement.RetryKeepingPartial -> Result.retry()
            is DownloadSettlement.Failed -> Result.failure(failureData(settled.kind))
            // 被停的 Worker 的返回值 WorkManager 不采用（状态已是 CANCELLED）；照约定退出即可。
            DownloadSettlement.Stopped -> Result.failure()
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

        /**
         * #719: 造一个下载请求。入队与「待办绑定哪个请求」由 [UpdateUiController] 决定：
         * 它先把 `request.id` 写进待办、再 [enqueue]，界面只观察这一个 id。
         */
        fun request(info: UpdateInfo): OneTimeWorkRequest =
            OneTimeWorkRequestBuilder<UpdateDownloadWorker>()
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

        /**
         * REPLACE：同一时刻只有一条更新线。被顶替的旧 Worker 按约定停手（[downloadApk]
         * 的 isStopped），它的产物在自己的目录里，碰不到新 Worker 的文件。
         * 「同一份更新再点一次」不会走到这里（controller 判定为无事可做）。
         */
        fun enqueue(context: Context, request: OneTimeWorkRequest) {
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

/** 所有更新产物的根目录：必须在 file_paths.xml 的 `update/` 下（见 UpdateApkFileProviderPathTest）。 */
internal fun updateRootDir(cacheDir: File): File = File(cacheDir, "update")

/**
 * #719: 一份更新的产物——放在以其身份（[downloadIdentityOf]）命名的目录里。
 * 身份就是路径：同一份更新的残包天然可续（UPD-19），不同的天然互不相干，
 * 不再需要身份旁路文件与「认领」。
 */
internal class UpdateArtifacts(val dir: File) {
    val apk: File get() = File(dir, "ppass-update.apk")

    /** 整包落盘标记：区分「残包可续」与「整包待验」，进程死亡恢复靠它。 */
    val marker: File get() = File(dir, "ppass-update.apk.complete")
}

internal fun updateArtifactsOf(cacheDir: File, identity: String): UpdateArtifacts =
    UpdateArtifacts(File(updateRootDir(cacheDir), artifactKeyOf(identity)))

/** 身份 → 目录名：SHA-256 前 16 个十六进制字符（身份里有 URL，不能直接当文件名）。 */
internal fun artifactKeyOf(identity: String): String =
    java.security.MessageDigest.getInstance("SHA-256")
        .digest(identity.toByteArray())
        .joinToString("") { "%02x".format(it) }
        .take(16)

internal fun PendingUpdate.artifacts(cacheDir: File): UpdateArtifacts =
    updateArtifactsOf(cacheDir, downloadIdentityOf(version, url, sha256))

/**
 * 删掉 [keep] 以外的所有更新产物（含 #719 之前平铺在 `update/` 下的旧文件）。
 * 由当前这条更新线的 Worker 开跑时调用：别的身份都是过期的更新线。返回是否删了东西。
 */
internal fun clearOtherUpdateArtifacts(keep: UpdateArtifacts): Boolean {
    val others = keep.dir.parentFile?.listFiles()?.filter { it != keep.dir }.orEmpty()
    others.forEach { it.deleteRecursively() }
    return others.isNotEmpty()
}

/** 放弃全部更新产物（安装完成 / 升级回执 / 用户放弃这条更新线）——唯一的整体清理入口。 */
internal fun discardUpdateArtifacts(cacheDir: File) {
    updateRootDir(cacheDir).deleteRecursively()
}

/**
 * 一份更新包的身份：version + url + sha256。只用 version 不够——同版本号重发
 * 包（换了字节）时 url / sha256 会变，旧残包同样不能续。
 */
internal fun downloadIdentityOf(version: String, url: String, sha256: String): String =
    "$version\n$url\n$sha256"

/**
 * 一跑下载的完整流程（Worker 的 doWork 只负责把 Android 侧的副作用——日志、
 * 进度、通知——以回调接进来；文件与判定全在这里，JVM 可测）：
 *  1. [clearOtherUpdateArtifacts]：别的身份的产物是过期更新线，清掉（#719）；
 *  2. 完成标记在 = 上次已整包落盘（worker 重跑 / 进程死亡恢复），直接进校验；
 *     否则以残包长度为断点调 [fetch]（残包不在 = 0，即完整下载）；
 *  3. [settleDownload]：校验 / 重试 / 清理。
 */
internal fun runUpdateDownload(
    artifacts: UpdateArtifacts,
    runAttemptCount: Int,
    fetch: (resumeFromBytes: Long) -> ApkDownloadResult,
    verify: (File) -> ApkVerifier.Result,
    onStaleCleared: () -> Unit = {},
    onDownloaded: (ApkDownloadResult) -> Unit = {},
): DownloadSettlement {
    val apk = artifacts.apk
    val marker = artifacts.marker
    if (clearOtherUpdateArtifacts(artifacts)) onStaleCleared()
    artifacts.dir.mkdirs()
    val download = if (marker.isFile && apk.isFile && apk.length() > 0) {
        ApkDownloadResult.Ok(apk.length())
    } else {
        marker.delete()
        fetch(if (apk.isFile) apk.length() else 0L)
    }
    onDownloaded(download)
    return settleDownload(download, apk, marker, runAttemptCount, verify)
}

/** 一次下载跑完之后的落定结果（[settleDownload] 的返回值）。 */
internal sealed interface DownloadSettlement {
    /** 整包落盘且校验通过，完成标记已写。 */
    data class Verified(val bytes: Long) : DownloadSettlement
    /** 瞬时失败且还有重试次数：残包留着，下一跑带 Range 续传。 */
    data object RetryKeepingPartial : DownloadSettlement
    /** 不再重试：残包与标记已删，[kind] 交给 UI 选文案。 */
    data class Failed(val kind: UpdateFailureKind) : DownloadSettlement
    /** #719: Worker 已被停止：什么都不动，产物留给它的主人（下一跑或清理入口）。 */
    data object Stopped : DownloadSettlement
}

/**
 * 下载结果 + 校验 + 重试次数 → 落定（JVM 可测，[verify] 可注入）。文件副作用
 * 全在这里：校验通过写完成标记；校验不过 = 这份字节永远不该被装——删干净，
 * 不重试（重试拿回来的还是同一份字节）；下载失败按 [retryVerdictOf] 分流——
 * 重试则保留残包（UPD-19），放弃则删干净。
 */
internal fun settleDownload(
    download: ApkDownloadResult,
    apk: File,
    marker: File,
    runAttemptCount: Int,
    verify: (File) -> ApkVerifier.Result,
): DownloadSettlement = when (download) {
    is ApkDownloadResult.Stopped -> DownloadSettlement.Stopped
    is ApkDownloadResult.Ok ->
        if (verify(apk) == ApkVerifier.Result.Ok) {
            marker.writeText("ok")
            DownloadSettlement.Verified(download.bytes)
        } else {
            apk.delete()
            marker.delete()
            DownloadSettlement.Failed(UpdateFailureKind.Verify)
        }
    else ->
        if (retryVerdictOf(download, runAttemptCount) == DownloadVerdict.Retry) {
            DownloadSettlement.RetryKeepingPartial
        } else {
            apk.delete()
            marker.delete()
            DownloadSettlement.Failed(failureKindOf(download))
        }
}

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
    is ApkDownloadResult.Unexpected, is ApkDownloadResult.Ok,
    is ApkDownloadResult.Stopped -> UpdateFailureKind.Unexpected
}

internal enum class DownloadVerdict { Retry, GiveUp }

/**
 * 失败该不该让 WorkManager 退避重试（纯函数，JVM 可测）：
 * 停滞/断连、5xx、429 = 值得再来一次（有次数上限）；4xx（除 429）、写盘失败、
 * 未知异常 = 重试也是同一个结果，直接给用户交代。
 */
internal fun retryVerdictOf(result: ApkDownloadResult, runAttemptCount: Int): DownloadVerdict {
    val attemptsLeft = runAttemptCount + 1 < UpdateDownloadWorker.MAX_RUN_ATTEMPTS
    // 「值不值得重试」与「残包值不值得留」是同一个判定（UPD-19），共用一个谓词。
    return if (attemptsLeft && isTransientDownloadFailure(result)) {
        DownloadVerdict.Retry
    } else {
        DownloadVerdict.GiveUp
    }
}
