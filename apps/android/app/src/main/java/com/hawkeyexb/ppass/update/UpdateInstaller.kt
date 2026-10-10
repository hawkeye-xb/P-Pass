// UPD-02: 安装层——PackageInstaller 会话 API。
//
// 为什么换掉 UPD-01 的 FileProvider + ACTION_VIEW：那条路把 APK 扔给系统
// 就结束了，装没装上、用户是不是点了取消，App 一无所知。会话 API 给出
// 真实回执（成功 / 失败原因 / 用户中止），状态机才能合上最后一环。
//
// 回执路径：session.commit() 的 PendingIntent 指向本包非导出的
// [UpdateInstallReceiver]——PendingIntent 以创建者（本 App）身份发送，
// 所以非导出接收器也能收到；结果经 [InstallResultBus] 送回协程。
// 系统弹「要安装这个应用吗？」时 STATUS_PENDING_USER_ACTION 把确认
// 页面 Intent 带回来，接收器直接 startActivity 拉起来。
package com.hawkeyexb.ppass.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/** 安装结果的进程内总线（接收器 → 等待中的协程）。 */
object InstallResultBus {
    sealed interface Event {
        /** 系统要用户确认——把确认页拉起来（接收器已代劳，这里只是事实）。 */
        data object UserActionRequested : Event
        data class Finished(val status: Int, val message: String?) : Event
    }

    val events = MutableSharedFlow<Event>(extraBufferCapacity = 4)
}

class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION") // else 分支用的是 33 以下的旧 API
                val confirm = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (confirm != null) {
                    context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    InstallResultBus.events.tryEmit(InstallResultBus.Event.UserActionRequested)
                } else {
                    InstallResultBus.events.tryEmit(
                        InstallResultBus.Event.Finished(
                            PackageInstaller.STATUS_FAILURE, "missing confirm intent",
                        )
                    )
                }
            }
            else -> {
                InstallResultBus.events.tryEmit(
                    InstallResultBus.Event.Finished(
                        intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999),
                        intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE),
                    )
                )
            }
        }
    }
}

object UpdateInstaller {

    sealed interface Outcome {
        /** 系统接管并确认安装完成（进程通常随即被替换，多数情况下走不到返回）。 */
        data object Success : Outcome

        /** 用户在系统确认页点了取消/返回——不是错误，但要把状态退回「待安装」。 */
        data object AbortedByUser : Outcome

        data class Failed(val status: Int, val message: String?) : Outcome

        /** 本地会话建立/写入失败，或等待系统回执超时。 */
        data class Error(val cause: String) : Outcome
    }

    /**
     * #793：本 App 是否已获准安装应用（「安装未知应用」逐来源授权，Android 8+）。
     * 没有授权时直接提交会话，系统会在确认页之前插一道「不允许安装此来源」的门；
     * 用户在那道门上取消时会话**收不到终态**——所以按官方做法先查、先请求授权。
     */
    fun canInstall(context: Context): Boolean = context.packageManager.canRequestPackageInstalls()

    /** #793：系统的「安装未知应用」授权页，直接定位到本 App。 */
    fun installPermissionIntent(context: Context): Intent =
        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** 等待系统回执的上限：含用户看确认页的时间，给足 10 分钟。 */
    private const val INSTALL_RESULT_TIMEOUT_MS = 10L * 60 * 1000

    /**
     * 把 [apk] 交给系统安装器并等待回执。调用前必须已过 [ApkVerifier]——
     * 本函数不验签，只负责安装（同签名校验由系统 PackageInstaller 兜底）。
     */
    suspend fun install(context: Context, apk: File): Outcome {
        val installer = context.packageManager.packageInstaller
        val session = try {
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            )
            installer.openSession(installer.createSession(params))
        } catch (e: Exception) {
            return Outcome.Error("open session: $e")
        }
        try {
            session.openWrite("ppass-update.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
        } catch (e: Exception) {
            runCatching { session.abandon() }
            return Outcome.Error("write apk: $e")
        }

        val callbackIntent = Intent(context, UpdateInstallReceiver::class.java)
            .setAction(ACTION_INSTALL_RESULT)
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            REQUEST_CODE_INSTALL_RESULT,
            callbackIntent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return try {
            session.commit(pendingIntent.intentSender)
            session.close()
            when (val finished = awaitFinish()) {
                null -> Outcome.Error("install result timeout")
                else -> when (finished.status) {
                    PackageInstaller.STATUS_SUCCESS -> Outcome.Success
                    PackageInstaller.STATUS_FAILURE_ABORTED -> Outcome.AbortedByUser
                    else -> Outcome.Failed(finished.status, finished.message)
                }
            }
        } catch (e: CancellationException) {
            // #793：等待回执时被取消（回到前台对账判定「这次没装」）——放掉会话，并照协程约定
            // 把取消抛回去；不许当成「安装失败」吞掉（那会把界面打成「更新没有完成」）。
            runCatching { session.abandon() }
            throw e
        } catch (e: Exception) {
            runCatching { session.abandon() }
            Outcome.Error("commit: $e")
        }
    }

    private suspend fun awaitFinish(): InstallResultBus.Event.Finished? =
        withTimeoutOrNull(INSTALL_RESULT_TIMEOUT_MS) {
            InstallResultBus.events.first { it is InstallResultBus.Event.Finished }
                as InstallResultBus.Event.Finished
        }

    internal const val ACTION_INSTALL_RESULT = "com.hawkeyexb.ppass.update.INSTALL_RESULT"
    internal const val REQUEST_CODE_INSTALL_RESULT = 2041
}
