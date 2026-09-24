// NET-12 → ARCH-13 (#417, 吸收 #414): 传输前台服务 + PARTIAL_WAKE_LOCK，生命周期 = 循环的生命周期。
//
// 判据从「账本里还有待传项」改成「循环正在跑」：只有 [FlowEngine] 在检查全部通过之后调 [AndroidForegroundLease.acquire]
// 一次，循环退出时 release。#414 的两条根因在这里各自被结构性地堵死：
//  1. 被拒后无限递归：被拒只记原因（FlowControl.fgsBlock，给 UI 说人话）然后返回 false；没有任何「被拒 → 暂停 →
//     同步前台 → 再申请」的回路——暂停路径根本不认识这个类的 acquire。
//  2. 超时后又调 startForegroundService：onTimeout 只记原因、通知引擎停循环、stopSelf。同一轮里不会再申请。
// #413：受阻原因**不再是闸门**——以前记下之后要等 App 回前台才清，后台备份一次被拒就停到用户打开 App。
// 现在下一次触发照常申请；成功拿到就清掉原因。
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
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.hawkeyexb.ppass.MainActivity
import com.hawkeyexb.ppass.R
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * MOB-101: `ForegroundServiceStartNotAllowedException` is matched by NAME, never by type — the class
 * only exists from API 31.
 */
internal fun isForegroundStartRefusal(failure: Throwable): Boolean =
    failure.javaClass.simpleName == "ForegroundServiceStartNotAllowedException"

/** MOB-101: only the system's own "Time limit already exhausted …" message proves the budget reading. */
internal fun isSystemBudgetExhausted(failure: Throwable): Boolean =
    isForegroundStartRefusal(failure) && (failure.message ?: "").contains("Time limit")

internal fun fgsBlockReasonOf(failure: Throwable): FgsBlockReason =
    if (isSystemBudgetExhausted(failure)) FgsBlockReason.BUDGET_EXHAUSTED else FgsBlockReason.START_REFUSED

/** 进程内：服务与租约之间的交接。 */
internal object FlowForegroundHandoff {
    /** acquire 在等的那个结论；服务在 onStartCommand 里完成它。 */
    @Volatile var verdict: CompletableDeferred<Boolean>? = null

    /** 服务当前是否真的在前台。 */
    @Volatile var held: Boolean = false

    /** 服务被系统 onTimeout 收走时回调引擎（停循环，不重启）。 */
    @Volatile var onLost: ((FgsBlockReason) -> Unit)? = null

    /** 受阻事实的写入口（服务在 onStartCommand / onTimeout 里用）。 */
    @Volatile var control: FlowControl? = null

    @Volatile var latestText: String = ""
}

class AndroidForegroundLease(
    context: Context,
    private val control: FlowControl,
    private val verdictTimeoutMs: Long = VERDICT_TIMEOUT_MS,
) : ForegroundLease {
    private val app = context.applicationContext
    private val wakeLock: PowerManager.WakeLock =
        (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ppass:flow-loop")
            .apply { setReferenceCounted(false) }

    @Volatile private var lastRenewAt = 0L

    override suspend fun acquire(): Boolean {
        FlowForegroundHandoff.control = control
        val verdict = CompletableDeferred<Boolean>()
        FlowForegroundHandoff.verdict = verdict
        val intent = Intent(app, FlowTransferForegroundService::class.java)
        try {
            ContextCompat.startForegroundService(app, intent)
        } catch (refusal: IllegalStateException) {
            if (!isForegroundStartRefusal(refusal)) throw refusal
            control.recordFgsBlock(fgsBlockReasonOf(refusal))
            Log.w(TAG, "foreground: startForegroundService refused (${fgsBlockReasonOf(refusal)}); waiting for the next trigger")
            FlowForegroundHandoff.verdict = null
            return false
        }
        val granted = withTimeoutOrNull(verdictTimeoutMs) { verdict.await() } ?: false
        if (!granted) {
            // 不在这里 stopService：服务可能还没走到 startForeground，这时把它带下去正是 #414 的崩溃
            // （Bringing down service while still waiting for start foreground）。迟到的 onStartCommand
            // 看到没人在等，会自己 startForeground + 立刻 stopSelf 了结义务。
            Log.w(TAG, "foreground: no verdict within ${verdictTimeoutMs}ms; treating as refused")
            FlowForegroundHandoff.verdict = null
            return false
        }
        wakeLock.acquire(WAKE_LOCK_TIMEOUT_MS)
        lastRenewAt = System.currentTimeMillis()
        control.clearFgsBlock()
        Log.i(TAG, "foreground: held (FGS + PARTIAL_WAKE_LOCK ${WAKE_LOCK_TIMEOUT_MS}ms)")
        return true
    }

    override fun isHeld(): Boolean = FlowForegroundHandoff.held

    override fun renew() {
        val now = System.currentTimeMillis()
        if (now - lastRenewAt < RENEW_THROTTLE_MS) return
        lastRenewAt = now
        // 非引用计数：再 acquire 一次就是把超时往后推。
        if (FlowForegroundHandoff.held) wakeLock.acquire(WAKE_LOCK_TIMEOUT_MS)
    }

    override fun update(status: LoopStatus) {
        if (!FlowForegroundHandoff.held) return
        runCatching {
            app.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildTransferNotification(app, status))
        }
    }

    override fun release() {
        runCatching { if (wakeLock.isHeld) wakeLock.release() }
        FlowForegroundHandoff.verdict = null
        if (FlowForegroundHandoff.held) {
            FlowForegroundHandoff.held = false
            app.stopService(Intent(app, FlowTransferForegroundService::class.java))
        }
        Log.i(TAG, "foreground: released")
    }

    companion object {
        private const val TAG = "PPassFlow"

        /** 系统给 startForegroundService 的宽限大约 5 秒；超过就当被拒。 */
        const val VERDICT_TIMEOUT_MS = 6_000L

        /** 必须长于 3 分钟的字节停滞窗口；有进度就续期。 */
        const val WAKE_LOCK_TIMEOUT_MS = 10 * 60 * 1000L
        private const val RENEW_THROTTLE_MS = 30_000L
    }
}

internal const val NOTIFICATION_ID = 2026
private const val CHANNEL_ID = "ppass.backup.transfer"

internal fun buildTransferNotification(context: Context, status: LoopStatus): Notification {
    val nm = context.getSystemService(NotificationManager::class.java)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.notif_channel_transfer), NotificationManager.IMPORTANCE_LOW),
        )
    }
    val open = Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }
    val pi = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val current = status.current
    val builder = NotificationCompat.Builder(context, CHANNEL_ID)
        .setContentTitle(context.getString(R.string.notif_transfer_title))
        .setContentText(current?.fileName?.takeIf { it.isNotBlank() } ?: context.getString(R.string.notif_transfer_title))
        .setSmallIcon(R.drawable.ic_notification)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setContentIntent(pi)
    // #418「FGS 常驻通知：显示传输进度条」——用当前这一张的字节进度，不用「已确认 / 总数」：
    //  - 通知与循环同生共死，它要回答的是「现在有没有在传、传到哪了」；大库里一张照片只占总数的
    //    万分之几，「已确认 / 总数」的进度条几分钟都不动，看起来像卡死；
    //  - 首页进度条也是这一张的字节进度（同一个函数 [transferPermilleOf]），两处说的是同一件事；
    //  - 「已确认 / 总数」要读 order 表 + MediaStore 计数，这条路径每个进度回调都会走，不该碰数据库。
    val permille = transferPermilleOf(current)
    if (permille != null) {
        builder.setProgress(1000, permille, false)
    } else if (current != null) {
        builder.setProgress(0, 0, true)
    }
    return builder.build()
}

/**
 * MOB-08's real-device lesson still applies: WorkManager's own FGS declares
 * `foregroundServiceType="dataSync"` in the manifest — this service must match it.
 */
class FlowTransferForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val waiting = FlowForegroundHandoff.verdict?.takeIf { it.isActive }
        val notification = buildTransferNotification(this, LoopStatus(LoopPhase.RUNNING))
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (refusal: IllegalStateException) {
            if (!isForegroundStartRefusal(refusal)) throw refusal
            FlowForegroundHandoff.control?.recordFgsBlock(fgsBlockReasonOf(refusal))
            Log.w("PPassFlow", "foreground: startForeground refused (${fgsBlockReasonOf(refusal)}); recorded")
            FlowForegroundHandoff.held = false
            waiting?.complete(false)
            stopSelf()
            return START_NOT_STICKY
        }
        if (waiting == null) {
            // 没人在等（acquire 已超时放弃，或循环已结束）：义务已了结，立刻下来。
            FlowForegroundHandoff.held = false
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        FlowForegroundHandoff.held = true
        waiting.complete(true)
        return START_NOT_STICKY
    }

    /**
     * Android 15：dataSync 额度在服务运行中耗尽时系统调这里，并要求几秒内下来。
     * #414：只停止、只记录，这一轮**不再调用 startForegroundService**（#413：下一次触发照常再申请）。
     */
    @androidx.annotation.RequiresApi(35)
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w("PPassFlow", "foreground: onTimeout (dataSync budget); stopping this round, the next trigger may try again")
        FlowForegroundHandoff.held = false
        FlowForegroundHandoff.control?.recordFgsBlock(FgsBlockReason.BUDGET_EXHAUSTED)
        runCatching { FlowForegroundHandoff.onLost?.invoke(FgsBlockReason.BUDGET_EXHAUSTED) }
        stopForegroundCompat()
        stopSelf()
    }

    override fun onDestroy() {
        FlowForegroundHandoff.held = false
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        }
    }
}

/** UI-19 / MOB-101：暂停理由的人话（受阻事实 → 文案资源）。null = 没有可解释的。 */
fun fgsBlockNoticeRes(reason: FgsBlockReason?): Int? = when (reason) {
    FgsBlockReason.BUDGET_EXHAUSTED -> R.string.state_background_budget_paused
    FgsBlockReason.START_REFUSED -> R.string.state_background_protection_unknown
    null -> null
}
