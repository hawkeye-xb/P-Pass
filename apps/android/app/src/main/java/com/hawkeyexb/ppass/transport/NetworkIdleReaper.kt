// #434: 空闲时关掉手机进程里的 iroh endpoint。
//
// 一个绑定着的 iroh endpoint 哪怕什么都不传也在联网：每 15 s ping 一次 home relay，每 20–26 s
// 做一次 net report（向 relay 列表发探测），每 5 分钟一次完整探测。进程里有两个（控制通道
// DaemonClient + 传照片的原生 provider），以前都活到进程被杀为止。鸿蒙 4.2 真机实测：后台被
// 相册 / WorkManager 叫醒一次、判定「没有要传的」之后，这两个 endpoint 继续以约 20 MB/h 的
// 速度收发，移动网络下每天 200 MB 上下，基带一直降不下来。
//
// 规则：不在前台、引擎这一轮也结束了，再等 [graceMs]，就请调用方关掉 endpoint；下次有人要用时
// 各自懒绑定。调用方回 false（还有请求在飞 / 对端还连着）就隔一个 [graceMs] 再试。
package com.hawkeyexb.ppass.transport

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal const val NETWORK_IDLE_GRACE_MS = 30_000L

internal class NetworkIdleReaper(
    private val scope: CoroutineScope,
    /** 关掉空闲的 endpoint。返回 false = 现在不能关（有东西在用），过一会再试。 */
    private val park: suspend () -> Boolean,
    private val graceMs: Long = NETWORK_IDLE_GRACE_MS,
    private val log: (String) -> Unit = {},
) {
    private val lock = Any()
    private var foreground = false
    private var engineBusy = false
    private var pending: Job? = null

    /** App 有可见的 Activity。 */
    fun setForeground(visible: Boolean) = update { foreground = visible }

    /** Flow 引擎这一轮还没结束（检查 / 传输中）。 */
    fun setEngineBusy(busy: Boolean) = update { engineBusy = busy }

    /** 有 endpoint 刚绑上（懒绑定）：已经空闲的话重新排一次回收，别让它又一直挂着。 */
    fun onBound() = update {}

    private fun update(change: () -> Unit) = synchronized(lock) {
        change()
        if (idle()) {
            if (pending?.isActive != true) pending = scope.launch { reap() }
        } else {
            pending?.cancel()
            pending = null
        }
    }

    private fun idle() = !foreground && !engineBusy

    private suspend fun reap() {
        while (true) {
            delay(graceMs)
            if (!synchronized(lock) { idle() }) return
            if (park()) {
                log("network idle for ${graceMs}ms in background: endpoints parked")
                return
            }
            log("network idle but still in use: retrying in ${graceMs}ms")
        }
    }
}
