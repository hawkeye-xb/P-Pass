// PRES-01: 前台轻心跳——App 在前台期间每 ~30s 向存储端发一次 hello。
//
// 为什么复用 hello 而不加协议动词：hello 是唯一对成员/未配对都放行的
// 零数据方法（能力握手），daemon 侧已在 hello 落点刷新 last_seen + 记
// device.connected 审计（10 分钟去重）。新加轻方法要动 authz + 双端
// 协议，收益为零。
//
// 耗电红线：只在 ON_RESUME ~ ON_STOP 之间心跳；退后台/锁屏即停，绝不
// 常驻。失败静默——daemon 不在线（手机没网/电脑关机）只是跳过这一拍，
// 不重试不告警，等下一拍。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Methods
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject

class ForegroundHeartbeat(
    private val client: DaemonClient,
    private val pairings: PairingStore,
    private val scope: CoroutineScope,
) {
    private var job: Job? = null
    private var active = false

    /** 前台开始：立即拍一拍（进入 App 马上在线），然后每 30s 一拍。 */
    fun start() {
        if (active) return
        active = true
        job = scope.launch {
            beat()
            while (isActive && active) {
                delay(HEARTBEAT_MS)
                beat()
            }
        }
    }

    /** 退后台/锁屏：停循环，取消挂起中的 delay。 */
    fun stop() {
        active = false
        job?.cancel()
        job = null
    }

    private suspend fun beat() {
        val pairing = pairings.load() ?: return // 未配对：无存储端可拍
        val peer = try {
            parsePeerAddrToken(pairing.daemonAddrToken)
        } catch (_: Exception) {
            return // token 损坏：静默跳过，配对流程会重建
        }
        // hello 无业务参数；失败（断网/存储端关机）静默，下一拍再说。
        runCatching { client.call(peer, Methods.HELLO, buildJsonObject {}) }
    }

    companion object {
        /** 30s 轻心跳——daemon 侧 2 分钟窗口能容 4 拍，锁屏瞬间不误判离线。 */
        const val HEARTBEAT_MS = 30_000L
    }
}
