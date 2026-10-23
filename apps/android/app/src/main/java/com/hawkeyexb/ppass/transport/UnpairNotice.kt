// 用户主动断开（UX-06）时告诉电脑「这次配对我结束了」：清配对前尽力发一次，收到就收到，没收到就算了。
//
// 主动断开是单向行为（#956 关闭裁决，2026-10-22）：本地配对凭据清掉的那一刻断开就完成了，不留发件箱、
// 不在之后的任何时机（回前台 / 网络恢复 / 重启）重发。电脑上残留的设备行归电脑端管理（最近活动、手动移除）。
// 配对期间的被动断开（断网、电脑重启）才需要恢复机制，与这里无关。
//
// 撤掉的是 #565 的发件箱（WorkManager 一次性投递、指数退避、7 天期限）。保留的一半：通知带上要结束的那次
// 配对 id，电脑只在配对 id 一致时吊销——迟到的通知不会误删新配对，对单次发送同样成立。
package com.hawkeyexb.ppass.transport

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.hawkeyexb.ppass.proto.Resp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** 断开通知的等待上限（iOS `UnpairNotice.timeoutMs` 同值）。 */
internal const val UNPAIR_NOTICE_TIMEOUT_MS = 5_000L

/** device.unpair 的参数：带上要结束的那次配对的配对 id（没有就不带）。 */
internal fun unpairParams(pairingId: String): JsonObject = buildJsonObject {
    if (pairingId.isNotBlank()) put("pairing_id", pairingId)
}

/**
 * 发一次，最多等 [UNPAIR_NOTICE_TIMEOUT_MS]。连不上 / 超时 = null，被拒原样返回；除外层取消外不抛。
 * 结局只用来写日志，不决定任何后续动作。
 */
internal suspend fun sendUnpairNoticeOnce(send: suspend () -> Resp): Resp? =
    withTimeoutOrNull(UNPAIR_NOTICE_TIMEOUT_MS) {
        try {
            send()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        }
    }

/**
 * 断开的固定次序：先尽力通知一次，再无条件清本地。通知失败、超时、所在协程被取消（界面被关掉）都不跳过清理。
 */
internal suspend fun disconnectAfterUnpairNotice(notify: suspend () -> Unit, clearLocal: suspend () -> Unit) {
    try {
        notify()
    } finally {
        withContext(NonCancellable) { clearLocal() }
    }
}

/**
 * 老版本（#565）为每台电脑排过一条 `ppass.unpair-notice.<daemonNodeId>` 一次性任务，输入里存着电脑地址。
 * WorkManager 默认把 Worker 的全限定类名加成 tag，按它一次撤掉全部（断开之后已拿不到 daemonNodeId，按名撤不了）。
 */
internal const val LEGACY_UNPAIR_NOTICE_TAG = "com.hawkeyexb.ppass.transport.UnpairNoticeWorker"

fun cancelLegacyUnpairNotices(context: Context) {
    WorkManager.getInstance(context).cancelAllWorkByTag(LEGACY_UNPAIR_NOTICE_TAG)
}

/**
 * 墓碑：类名必须留着——WorkManager 可能在 [cancelLegacyUnpairNotices] 之前就拉起老任务（它先于
 * Application.onCreate 初始化）。拉起来也不联网，直接结束、不重试。
 */
class UnpairNoticeWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result = Result.failure()
}
