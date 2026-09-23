// MOB-15/16/18: 后台备份的进程级入口。
//
// 背景（真机时间线，用户 2026-08-19 报"kill 掉 app 之后拍照要等好几分钟"）：
//   10:39:50  用户从最近任务划掉 App，进程被杀
//   10:40:07~09 用户拍照 → 通知落在「进程被杀 → job 重排」的窗口里，无人接收
//   10:40:18  系统拉起进程执行 SystemJobService（**进程活了**）
//   10:44:30  直到下一个触发事件到来，才把这批一起传完
//
// 用户的原话点破了要害："我肯定是需要 kill app 的啊，配置好了谁整天看你
// 这个同步备份用的 app？"——所以「打开 App 时补跑」不能算解决方案，用户
// 根本不会打开。补捞必须发生在**进程因任何原因被拉起**的时候。
//
// #417 在这里另挂两个进程级触发：
// - 网络变化回调（ConnectivityManager）：立刻探测一次，并让 iroh `Endpoint::network_change()` 重探路径。
// - App 进入前台（任一 Activity resumed）：清 FGS 受阻事实（前台重置 dataSync 额度，#411），跑慢路径 + 循环。
package com.hawkeyexb.ppass

import android.app.Activity
import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.onFlowAppForeground
import com.hawkeyexb.ppass.backup.flow.onFlowNetworkChanged
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.reconcileWatchOnProcessStart
import com.hawkeyexb.ppass.transport.DaemonClient
import kotlin.concurrent.thread

class PPassApplication : Application() {
    /** One iroh Endpoint for every foreground and Flow delivery connection in this process. */
    val daemonClient = DaemonClient()

    @Volatile private var lastNetworkSignature: String? = null

    override fun onCreate() {
        super.onCreate()
        thread(name = "ppass-boot-check") {
            requestFlowWake(this, TriggerReason.PROCESS_START)
            runCatching {
                reconcileWatchOnProcessStart(
                    this, System.currentTimeMillis(), SystemClock.elapsedRealtime(),
                )
            }.onFailure { error ->
                Log.w("PPassLegacyWatch", "legacy watch reconciliation failed; Flow continues", error)
            }
        }
        registerNetworkCallback()
        registerActivityLifecycleCallbacks(ForegroundWatcher())
    }

    private fun registerNetworkCallback() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        runCatching {
            cm.registerDefaultNetworkCallback(
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) = changed("available:$network")

                    override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                        // 能力回调会成串到达（信号强度等）；只有「网络 + 是否计流量」变了才算一次网络变化。
                        changed("caps:$network:${caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)}")
                    }

                    override fun onLost(network: Network) = changed("lost:$network")
                },
            )
        }.onFailure { Log.w("PPassFlow", "network callback registration failed", it) }
    }

    private fun changed(signature: String) {
        if (signature == lastNetworkSignature) return
        lastNetworkSignature = signature
        onFlowNetworkChanged(this)
    }

    /** 第一个 Activity resumed = App 进入前台。 */
    private inner class ForegroundWatcher : ActivityLifecycleCallbacks {
        private var resumed = 0

        override fun onActivityResumed(activity: Activity) {
            if (resumed++ == 0) onFlowAppForeground(this@PPassApplication)
        }

        override fun onActivityPaused(activity: Activity) {
            resumed = (resumed - 1).coerceAtLeast(0)
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }
}
