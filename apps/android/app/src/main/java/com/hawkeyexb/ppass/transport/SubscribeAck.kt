// #522（MOB-119）：`timeline.subscribe` 的第一帧是应答本身，不一定是「订阅成功」。
//
// daemon 的 router 在鉴权拒绝时（设备已被撤销等）第一帧回 `{"ok":false,"error":{"code":"NOT_AUTHORIZED",...}}`
// 然后关流。旧实现「读到第一帧就算连上」，于是撤销后每轮都先打一行 `subscribe: connected`，几毫秒后才
// `ended (IrohException: null)`。这里把第一帧分成「确认」和「被拒」：只有确认才算连上，被拒抛类型化异常，
// 调用方据此写出能区分「被拒 / 未授权」的日志。
package com.hawkeyexb.ppass.transport

import java.io.IOException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** 桌面拒绝了这次订阅（第一帧就是 ok=false 的应答）。[code] 例如 `NOT_AUTHORIZED`。 */
class SubscribeRejectedException(val code: String, val msgKey: String) :
    IOException("subscribe rejected by the desktop ($code: $msgKey)")

/**
 * 第一帧是拒绝就返回对应异常，否则 null（= 订阅确认，真的连上了）。
 * 只认显式的 `ok:false`：带 `event` 的推送帧、`ok:true` 的确认都算连上。
 */
internal fun subscribeRejectionOf(firstFrame: JsonElement): SubscribeRejectedException? {
    val obj = firstFrame as? JsonObject ?: return null
    if (obj.containsKey("event")) return null
    val ok = (obj["ok"] as? JsonPrimitive)?.takeUnless { it.isString }?.content
    if (ok != "false") return null
    val error = obj["error"] as? JsonObject
    val code = (error?.get("code") as? JsonPrimitive)?.content.orEmpty()
    val msgKey = (error?.get("msg_key") as? JsonPrimitive)?.content.orEmpty()
    return SubscribeRejectedException(code, msgKey)
}

/**
 * 订阅流的读循环（与传输解耦，JVM 可测）：[nextFrame] 读下一帧，流结束 / 连接坏了由它抛出。
 * 第一帧是应答：被拒就抛 [SubscribeRejectedException]，**不调** [onConnected]；确认才调一次 [onConnected]。
 * 之后每个 `timeline.invalidated` 调 [onInvalidated]；`flow.delivered` / `flow.failed` 带 data 调 [onFlowEvent]
 * （NET-14：daemon 已按手机过滤，到这里的都是这台手机自己的事件）。没有 `event` 键的帧忽略。
 */
internal suspend fun readSubscriptionFrames(
    nextFrame: suspend () -> JsonElement,
    onConnected: suspend () -> Unit,
    onFlowEvent: suspend (String, JsonObject) -> Unit,
    onInvalidated: suspend () -> Unit,
): Nothing {
    var firstFrame = true
    while (true) {
        val payload = nextFrame()
        if (firstFrame) {
            firstFrame = false
            subscribeRejectionOf(payload)?.let { throw it }
            onConnected()
        }
        val event = ((payload as? JsonObject)?.get("event") as? JsonPrimitive)?.content
        when (event) {
            "timeline.invalidated" -> onInvalidated()
            "flow.delivered", "flow.failed" -> {
                val data = (payload as? JsonObject)?.get("data") as? JsonObject
                if (data != null) onFlowEvent(event, data)
            }
        }
    }
}
