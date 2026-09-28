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

import com.hawkeyexb.ppass.backup.isPairingLostText
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.Resp
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
    // UI-10 item 4: SentinelStore had `recordReachable`/`recordUnreachable`
    // but no production caller anywhere in the app — the home/photos "失联
    // N 天" field was frozen data, never updated. This heartbeat is the
    // natural, already-scheduled connectivity signal (30s while foreground);
    // wiring its outcome here is the fix, not a new mechanism.
    private val sentinel: com.hawkeyexb.ppass.backup.SentinelStore? = null,
    // #439: 桌面可达（hello 成功）时通知备份引擎——引擎只在「等待中（桌面不可达）」时才会据此叫醒循环。
    private val onReachable: (() -> Unit)? = null,
    // #466: 桌面已移除这台手机（hello 被拒为 not_paired/not_authorized）——交给红卡，按这次配对的 epoch 记。
    private val onPairingLost: ((epoch: String, failure: Throwable) -> Unit)? = null,
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
        // hello 无业务参数；结果写回 SentinelStore（UI-10：这是唯一实际
        // 跑着的连通性检测，之前静默丢弃结果导致「失联天数」恒定不更新）。
        applyHeartbeatOutcome(
            sentinel,
            runCatching { client.call(peer, Methods.HELLO, buildJsonObject {}) },
            onPairingLost = onPairingLost?.let { cb -> { failure: Throwable -> cb(pairing.pairingEpoch, failure) } },
            onReachable = onReachable,
        )
    }

    companion object {
        /** 30s 轻心跳——daemon 侧 2 分钟窗口能容 4 拍，锁屏瞬间不误判离线。 */
        const val HEARTBEAT_MS = 30_000L
    }
}

/** UI-10: the pure outcome→SentinelStore mapping, split out of [ForegroundHeartbeat.beat]
 *  so it is testable without a real network call (`DaemonClient` is concrete,
 *  not fakeable). `null` sentinel (default constructor arg) is a no-op —
 *  covers any caller that hasn't been updated to pass one. */
internal fun applyHeartbeatOutcome(
    sentinel: com.hawkeyexb.ppass.backup.SentinelStore?,
    outcome: Result<*>,
    // 放在 onReachable 前面：既有调用方用尾随 lambda 传 onReachable，不能被新参数截走。
    onPairingLost: ((Throwable) -> Unit)? = null,
    onReachable: (() -> Unit)? = null,
) {
    outcome
        .onSuccess { value ->
            // #466: `DaemonClient.call` 被拒时不抛，回 ok=false 的 Resp——原来这里把「你已被移除」也当成可达。
            val rejectedKey = (value as? Resp)?.takeIf { !it.ok }?.error?.msgKey
            if (rejectedKey != null && isPairingLostText(rejectedKey)) {
                onPairingLost?.invoke(IllegalStateException("hello: $rejectedKey"))
                return
            }
            sentinel?.recordReachable()
            onReachable?.invoke()
        }
        .onFailure { sentinel?.recordUnreachable() }
}
