// #851: ask the Desktop to replace its location-redacted copy with the original, in place.
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.FlowSupersedeReply
import com.hawkeyexb.ppass.proto.FlowSupersedeRequest
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.PeerAddrParts

/**
 * 桌面要按块拉原图的元数据区间、拼接、算两遍指纹（大视频几秒），15 s 的默认往返上限不够；
 * 超过这个数按「暂时不可达」处理，下一轮再试（桌面对重放的同一请求直接回成功）。
 */
internal const val SUPERSEDE_TIMEOUT_MS = 120_000L

internal fun supersedeOutcomeOf(reply: FlowSupersedeReply): SupersedeOutcome = when (reply.outcome) {
    "replaced" -> SupersedeOutcome.Replaced
    "refused" -> SupersedeOutcome.Refused(reply.reason.ifBlank { "unspecified" })
    else -> error("flow.supersede: unknown outcome '${reply.outcome}'")
}

class RemoteSupersede(private val client: DaemonClient) {
    internal suspend fun supersede(peer: PeerAddrParts, request: FlowSupersedeRequest): SupersedeOutcome {
        val response = client.call(
            peer,
            Methods.FLOW_SUPERSEDE,
            ProtoJson.encodeToJsonElement(FlowSupersedeRequest.serializer(), request),
            timeoutMs = SUPERSEDE_TIMEOUT_MS,
        )
        check(response.ok) { "flow.supersede rejected: ${response.error?.reason}" }
        return supersedeOutcomeOf(ProtoJson.decodeFromJsonElement(FlowSupersedeReply.serializer(), response.result!!))
    }
}
