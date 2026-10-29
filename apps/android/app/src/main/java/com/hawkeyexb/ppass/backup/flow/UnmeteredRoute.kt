// #1220：「仅 Wi‑Fi」的判据与流量走向——看「有没有不计流量的网」，并把流量固定到它上面。
package com.hawkeyexb.ppass.backup.flow

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import com.hawkeyexb.ppass.log.PLog

/** 一张网此刻的事实（纯数据，选路判据只看这些）。 */
internal data class NetFacts<N>(
    val network: N,
    val unmetered: Boolean,
    val internet: Boolean,
    val vpn: Boolean,
)

/** 这一刻流量该怎么走。 */
internal sealed interface RouteChoice<out N> {
    /** 跟系统默认网络走，不绑定：没开「仅 Wi‑Fi」、默认网络本身就不计流量、或默认网络是 VPN（不绕开用户的 VPN）。 */
    object Default : RouteChoice<Nothing>

    /** 默认网络计流量，但另有一张不计流量的网——流量固定到它上面。 */
    data class Pin<N>(val network: N) : RouteChoice<N>

    /** 「仅 Wi‑Fi」下没有任何不计流量的网：不连桌面。 */
    object NoUnmetered : RouteChoice<Nothing>
}

/**
 * 选路判据（纯函数）。Wi‑Fi 测不到外网时，系统把默认网络切到移动数据，Wi‑Fi 仍连着、局域网仍通——
 * 「仅 Wi‑Fi」问的是「有没有不计流量的网可用」，不是「默认网络是不是 Wi‑Fi」。
 */
internal fun <N> chooseRoute(wifiOnly: Boolean, active: NetFacts<N>?, all: List<NetFacts<N>>): RouteChoice<N> {
    if (!wifiOnly) return RouteChoice.Default
    if (active != null && (active.vpn || active.unmetered)) return RouteChoice.Default
    val candidate = all.firstOrNull { it.unmetered && it.internet && !it.vpn } ?: return RouteChoice.NoUnmetered
    return RouteChoice.Pin(candidate.network)
}

/** 「仅 Wi‑Fi」的条件是否满足：与 [chooseRoute] 同一个判据。 */
internal fun <N> hasUnmetered(active: NetFacts<N>?, all: List<NetFacts<N>>): Boolean =
    chooseRoute(wifiOnly = true, active = active, all = all) != RouteChoice.NoUnmetered

private fun facts(cm: ConnectivityManager, network: Network): NetFacts<Network>? {
    val caps = cm.getNetworkCapabilities(network) ?: return null
    return NetFacts(
        network = network,
        unmetered = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
        internet = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
        vpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
    )
}

/** 此刻的默认网络与全部网络。要的是检查那一刻的同步答案，所以用 `allNetworks` 而不是异步回调。 */
@Suppress("DEPRECATION")
internal fun networkSnapshot(cm: ConnectivityManager): Pair<NetFacts<Network>?, List<NetFacts<Network>>> =
    cm.activeNetwork?.let { facts(cm, it) } to cm.allNetworks.mapNotNull { facts(cm, it) }

/** 有没有不计流量的网可用（「仅 Wi‑Fi」的条件）。 */
internal fun isOnUnmetered(context: Context): Boolean {
    val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
    val (active, all) = networkSnapshot(cm)
    return hasUnmetered(active, all)
}

/**
 * Android 实现：按 [chooseRoute] 把**整个进程**绑到不计流量的网上（`bindProcessToNetwork`，原生 iroh 的套接字
 * 也跟着走），不再需要时解绑。绑定会一直保持到判据变化（关掉「仅 Wi‑Fi」、Wi‑Fi 断开、默认网络回到不计流量）——
 * 一轮收尾时的审计上报、看时间线也都走 Wi‑Fi，不会在轮与轮之间漏到移动数据上。
 *
 * 换了线路后 [onRebound]：让传输端点重建套接字（新套接字才吃到新的绑定）。
 */
internal class UnmeteredNetworkRoute(
    context: Context,
    private val wifiOnly: () -> Boolean,
    private val onRebound: suspend () -> Unit,
) : NetworkRoute {
    private val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override suspend fun ensure(): Boolean {
        val (active, all) = networkSnapshot(cm)
        val bound = cm.boundNetworkForProcess
        return when (val choice = chooseRoute(wifiOnly(), active, all)) {
            RouteChoice.Default -> {
                if (bound != null) rebind(null, "default network carries the traffic again")
                true
            }
            RouteChoice.NoUnmetered -> {
                if (bound != null) rebind(null, "no unmetered network left")
                false
            }
            is RouteChoice.Pin -> {
                if (bound == choice.network) return true
                if (!cm.bindProcessToNetwork(choice.network) || cm.boundNetworkForProcess != choice.network) {
                    PLog.w(TAG, "route: binding to unmetered network ${choice.network} refused; staying off metered networks")
                    return false
                }
                PLog.i(TAG, "route: default network is metered; traffic pinned to unmetered network ${choice.network}")
                onRebound()
                true
            }
        }
    }

    /** 被绑定的那张网断了（它不是默认网络，默认网络回调看不到）。 */
    fun isBound(network: Network): Boolean = cm.boundNetworkForProcess == network

    private suspend fun rebind(network: Network?, why: String) {
        cm.bindProcessToNetwork(network)
        PLog.i(TAG, "route: unbound ($why)")
        onRebound()
    }

    private companion object {
        const val TAG = "PPassFlow"
    }
}
