// #565: 「我断开了这次配对」的可靠送达（发件箱模式）。
//
// 本质：一端的状态变化要让另一端最终知道，而另一端可能不在线。原来断开时只
// 发一次 device.unpair（5 s 超时、失败静默），电脑不在线就永远停在「已配对」。
//
// 标准做法：
//  - 发件箱：先把通知持久记下，再投递，对方确认（或已不认这次配对）才算完；
//    Android 上「有网就投、失败退避、跨重启保留」的标准载体就是 WorkManager
//    的唯一任务（网络约束 + 指数退避）。断开时先入队、再清本地配对。
//  - 条件更新：手机身份在断开后保留，重新配对同一台电脑后迟到的旧通知不许
//    吊销新配对——通知带上它要结束的 pairing_epoch，daemon 只在纪元一致时吊销。
//
// 为什么不复用 AUDIT-01 的 audit_outbox：那张表换桌面时清空、派发器属于断开
// 时就停掉的 Flow runtime——同一模式，独立载体。
package com.hawkeyexb.ppass.transport

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.hawkeyexb.ppass.PPassApplication
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.proto.Resp
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** daemon `codes::NOT_AUTHORIZED`：已吊销 / 从未配对的设备调 device.unpair 的答复。 */
internal const val UNPAIR_ALREADY_GONE_CODE = "NOT_AUTHORIZED"

/**
 * 投递期限：7 天。家里的电脑一周内总会开机；过了期限仍送不到就放弃，此后由
 * 电脑端设备行的「最后在线」如实反映这台手机很久没出现——不无限重试。
 */
internal const val UNPAIR_NOTICE_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000

internal enum class UnpairDelivery { Done, Retry }

/**
 * 一次投递的结局（纯函数，按结构化错误码判，不看文案）：
 *  - ok = 电脑确认（或那次配对早已被新配对取代，daemon 答 ok 但不吊销）；
 *  - NOT_AUTHORIZED = 电脑已经不认这台手机（已吊销 / 没有这行）——所有角色都
 *    允许断开自己（authz.rs self_unpair），所以对 device.unpair 它只可能是这个意思；
 *  - 其余（连不上 = null、INTERNAL 等）= 稍后再投。
 */
internal fun unpairDeliveryOf(reply: Resp?): UnpairDelivery = when {
    reply == null -> UnpairDelivery.Retry
    reply.ok -> UnpairDelivery.Done
    reply.error?.code == UNPAIR_ALREADY_GONE_CODE -> UnpairDelivery.Done
    else -> UnpairDelivery.Retry
}

internal fun unpairNoticeExpired(createdAtMs: Long, nowMs: Long): Boolean =
    nowMs - createdAtMs > UNPAIR_NOTICE_MAX_AGE_MS

/** device.unpair 的参数：带上要结束的那次配对的纪元（旧配对没有纪元就不带，daemon 走旧语义）。 */
internal fun unpairParams(pairingEpoch: String): JsonObject = buildJsonObject {
    if (pairingEpoch.isNotBlank()) put("pairing_epoch", pairingEpoch)
}

object UnpairNotice {
    private const val WORK_PREFIX = "ppass.unpair-notice."
    internal const val KEY_ADDR_TOKEN = "addr_token"
    internal const val KEY_PAIRING_EPOCH = "pairing_epoch"
    internal const val KEY_CREATED_AT = "created_at"

    /** 每台电脑一条：断开 A、配 B、再断开 B，两条通知互不顶替。 */
    fun workName(daemonNodeId: String): String = WORK_PREFIX + daemonNodeId

    /**
     * 断开时**先**调用（再清本地配对）：通知自带地址与纪元，不依赖之后会被清掉的 pairing.json。
     * 入队与「清本地」之间进程死亡，留下的是一条待投通知，而不是一次丢失的断开。
     */
    fun enqueue(context: Context, pairing: Pairing, nowMs: Long = System.currentTimeMillis()) {
        val request = OneTimeWorkRequestBuilder<UnpairNoticeWorker>()
            .setInputData(
                Data.Builder()
                    .putString(KEY_ADDR_TOKEN, pairing.daemonAddrToken)
                    .putString(KEY_PAIRING_EPOCH, pairing.pairingEpoch)
                    .putLong(KEY_CREATED_AT, nowMs)
                    .build(),
            )
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context)
            .enqueueUniqueWork(workName(pairing.daemonNodeId), ExistingWorkPolicy.REPLACE, request)
    }

    /**
     * 重新配对这台电脑成功后撤掉还没送到的旧通知。不是安全所必需（daemon 按纪元
     * 判，旧通知送到也不会吊销新配对），是不再白跑——也照顾没有纪元的旧配对 / 旧版 daemon。
     */
    fun cancel(context: Context, daemonNodeId: String) {
        WorkManager.getInstance(context).cancelUniqueWork(workName(daemonNodeId))
    }
}

class UnpairNoticeWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val token = inputData.getString(UnpairNotice.KEY_ADDR_TOKEN) ?: return Result.failure()
        val epoch = inputData.getString(UnpairNotice.KEY_PAIRING_EPOCH).orEmpty()
        val createdAt = inputData.getLong(UnpairNotice.KEY_CREATED_AT, 0L)
        val peer = runCatching { parsePeerAddrToken(token) }.getOrNull() ?: return Result.failure()
        val client = (applicationContext as PPassApplication).daemonClient
        val reply = runCatching { withTimeout(30_000) { client.unpair(peer, epoch) } }.getOrNull()
        return when (unpairDeliveryOf(reply)) {
            UnpairDelivery.Done -> Result.success()
            UnpairDelivery.Retry ->
                if (unpairNoticeExpired(createdAt, System.currentTimeMillis())) {
                    PLog.w(
                        "PPassUnpair",
                        "#565: gave up telling the desktop about the disconnect after ${UNPAIR_NOTICE_MAX_AGE_MS / 86_400_000} days",
                    )
                    Result.failure()
                } else {
                    Result.retry()
                }
        }
    }
}
