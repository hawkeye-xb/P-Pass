// T-051: the phone's ctrl-plane client — iroh-ffi endpoint + one
// request/response per bidirectional stream, length-prefixed JSON
// frames (crates/proto codec), talking to the storage daemon's router.
//
// Same shape as tools/testclient's `call`: open bi stream, send one
// frame, finish the send side, read one response frame.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.Req
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.encodeFrame
import com.hawkeyexb.ppass.proto.decodePayload
import com.hawkeyexb.ppass.proto.frameLen
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.ProtoJson
import computer.iroh.Connection
import computer.iroh.Endpoint
import computer.iroh.EndpointAddr
import computer.iroh.EndpointId
import computer.iroh.EndpointOptions
import computer.iroh.presetN0
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

const val ALPN_CTRL = "ppf/ctrl/1"

/** UX-11: iroh's `connect()` has no built-in timeout — against a truly
 *  dead peer (daemon stopped / computer off) it can hang forever. Real
 *  report: Photos tab stuck on "正在读取" indefinitely with zero error,
 *  because nothing ever threw. Every `call()` (and the raw connect used
 *  by uploads/downloads) is bounded so a dead peer always surfaces as a
 *  real failure instead of an infinite spinner. */
private const val CONNECT_TIMEOUT_MS = 15_000L

/** Deliberately NOT a CancellationException — it must flow through
 *  existing `catch (t: Throwable)` blocks as a genuine failure.
 *  BackupUiStateHolder's `if (t is CancellationException) throw t` guard
 *  exists to preserve "tap again = pause" semantics; a timeout wearing
 *  a CancellationException costume would vanish there silently instead
 *  of surfacing as the Trouble state. */
class DaemonUnreachableException(message: String) : IOException(message)

private suspend fun Endpoint.connectBounded(addr: EndpointAddr, alpn: ByteArray): Connection =
    try {
        withTimeout(CONNECT_TIMEOUT_MS) { connect(addr, alpn) }
    } catch (_: TimeoutCancellationException) {
        throw DaemonUnreachableException(
            "could not reach the computer within ${CONNECT_TIMEOUT_MS}ms"
        )
    }

/**
 * One endpoint per app process. Bind once, then `call` against a peer
 * added via [addPeerFromToken]. All methods are IO-dispatched — safe to
 * call from any coroutine.
 */
class DaemonClient {
    private var endpoint: Endpoint? = null
    private val bindLock = Mutex()

    /**
     * Bind the endpoint. Pass the device's persistent 32-byte secret so
     * the phone keeps ONE identity across restarts — pairing is bound to
     * the NodeId, a fresh key would demote us to a stranger.
     */
    suspend fun bind(secretKey: ByteArray? = null): Unit = withContext(Dispatchers.IO) {
        bindLock.withLock {
            if (endpoint != null) return@withLock
            val opts = EndpointOptions(
                preset = presetN0(),
                alpns = listOf(ALPN_CTRL.toByteArray()),
            )
            if (secretKey != null) opts.secretKey = secretKey
            endpoint = Endpoint.bind(opts)
        }
    }

    fun nodeIdHex(): String? = endpoint?.addr()?.id()?.toString()

    /**
     * Register the storage daemon's address (from a pairing QR's `a=`
     * token or a saved address) and return its EndpointId for `call`.
     */
    suspend fun addPeerFromToken(token: String): EndpointId = withContext(Dispatchers.IO) {
        val parts = parsePeerAddrToken(token)
        endpointIdOf(parts)
    }

    fun endpointIdOf(parts: PeerAddrParts): EndpointId =
        EndpointId.fromString(parts.idHex)

    /**
     * One request/response round trip on a fresh bi stream.
     * The peer address must carry enough to dial (relay and/or direct).
     */
    suspend fun call(peer: PeerAddrParts, method: String, params: JsonElement): Resp =
        withContext(Dispatchers.IO) {
            val ep = endpoint ?: error("bind() first")
            // relayUrl is nullable in the ffi — an empty string fails
            // URL parsing ("Failed to parse relay URL", found live).
            val addr = EndpointAddr(
                EndpointId.fromString(peer.idHex),
                peer.relayUrl,
                peer.directAddresses,
            )
            // UX-11: bound the whole round trip, not just connect — a
            // peer that accepts the connection but never answers must
            // also time out, not just one that's fully unreachable.
            try {
                withTimeout(CONNECT_TIMEOUT_MS) {
                    val conn = ep.connect(addr, ALPN_CTRL.toByteArray())
                    try {
                        val bi = conn.openBi()
                        val send = bi.send()
                        val recv = bi.recv()

                        val req = Req(
                            id = UUID.randomUUID().toString(),
                            method = method,
                            params = params,
                        )
                        send.writeAll(encodeFrame(Req.serializer(), req))
                        send.finish()

                        val header = recv.readExact(4u)
                        val len = frameLen(header)
                        val payload = recv.readExact(len.toUInt())
                        decodePayload(Resp.serializer(), payload)
                    } finally {
                        conn.close(0L, ByteArray(0))
                    }
                }
            } catch (_: TimeoutCancellationException) {
                throw DaemonUnreachableException(
                    "$method: no response from the computer within ${CONNECT_TIMEOUT_MS}ms"
                )
            }
        }

    /**
     * DIAG-A：与 [call] 同一次往返、同一个 [CONNECT_TIMEOUT_MS] 上限，但逐阶段记下发生了什么，
     * 成败都调一次 [report]。只给可达性探测用——状态轮询也走它会把日志刷爆。
     *
     * 记的东西（全部来自 iroh-ffi 公开 API，不猜）：开始时本端有没有 home relay（`addr().relayUrl()`）、
     * 本端 `online()` 在这次调用期间何时返回、`connect()` 耗时、收到回复的耗时、连上后选中的路径
     * （`Connection.paths()` → lan / direct / relay，口径同 conninfo.rs）；失败时的异常类型、
     * `IrohException.kind()` / `debugMessage()` 原文，以及 iroh 此刻手里的对端地址（`remoteAddr`）。
     */
    suspend fun callTraced(
        peer: PeerAddrParts,
        method: String,
        params: JsonElement,
        report: (CallTrace) -> Unit,
    ): Resp = withContext(Dispatchers.IO) {
        val ep = endpoint ?: error("bind() first")
        val started = System.nanoTime()
        fun sinceStart() = (System.nanoTime() - started) / 1_000_000
        val homeRelayAtStart = runCatching { ep.addr().relayUrl() }.getOrNull()?.takeIf { it.isNotBlank() }
        val onlineAfter = java.util.concurrent.atomic.AtomicLong(-1)
        var connectMs: Long? = null
        var roundTripMs: Long? = null
        var path: PathVerdict? = null
        var pathCount = 0
        var failure: Throwable? = null
        val addr = EndpointAddr(EndpointId.fromString(peer.idHex), peer.relayUrl, peer.directAddresses)
        try {
            coroutineScope {
                val onlineWatch = launch {
                    runCatching { ep.online() }.onSuccess { onlineAfter.set(sinceStart()) }
                }
                try {
                    withTimeout(CONNECT_TIMEOUT_MS) {
                        val conn = ep.connect(addr, ALPN_CTRL.toByteArray())
                        connectMs = sinceStart()
                        try {
                            runCatching {
                                val snapshots = conn.paths()
                                pathCount = snapshots.size
                                path = classifyPaths(
                                    snapshots.map { PathFacts(it.isSelected, it.isRelay, it.remoteAddr, it.rttMs.toLong()) },
                                )
                            }
                            val bi = conn.openBi()
                            val send = bi.send()
                            val recv = bi.recv()
                            val req = Req(id = UUID.randomUUID().toString(), method = method, params = params)
                            send.writeAll(encodeFrame(Req.serializer(), req))
                            send.finish()
                            val header = recv.readExact(4u)
                            val payload = recv.readExact(frameLen(header).toUInt())
                            decodePayload(Resp.serializer(), payload).also { roundTripMs = sinceStart() }
                        } finally {
                            conn.close(0L, ByteArray(0))
                        }
                    }
                } finally {
                    onlineWatch.cancel()
                }
            }
        } catch (_: TimeoutCancellationException) {
            DaemonUnreachableException("$method: no response from the computer within ${CONNECT_TIMEOUT_MS}ms")
                .also { failure = it }
                .let { throw it }
        } catch (t: Throwable) {
            failure = t
            throw t
        } finally {
            val f = failure
            val iroh = f as? computer.iroh.IrohException
            val peerKnown = if (f == null) {
                null
            } else {
                runCatching {
                    withTimeoutOrNull(1_000) { ep.remoteAddr(EndpointId.fromString(peer.idHex)) }
                        ?.let { known -> "relay=${known.relayUrl() ?: "-"} direct=${known.directAddresses()}" }
                }.getOrNull()
            }
            report(
                CallTrace(
                    method = method,
                    tokenRelay = peer.relayUrl,
                    tokenDirectAddrs = peer.directAddresses,
                    homeRelayAtStart = homeRelayAtStart,
                    onlineAfterMs = onlineAfter.get().takeIf { it >= 0 },
                    connectMs = connectMs,
                    roundTripMs = roundTripMs,
                    totalMs = sinceStart(),
                    path = path,
                    pathCount = pathCount,
                    errorClass = f?.javaClass?.simpleName,
                    errorKind = iroh?.let { runCatching { it.kind().name }.getOrNull() },
                    errorMessage = f?.let { e ->
                        iroh?.let { runCatching { it.debugMessage() }.getOrNull() } ?: e.message
                    },
                    peerKnownAddr = peerKnown,
                ),
            )
        }
    }

    /**
     * NET-06: read-only status query for one exact tuple — a short
     * control-plane RPC that never blocks on the data plane and always
     * answers within [CONNECT_TIMEOUT_MS], on any network condition. This
     * is what NativeFlowDeliveryPort polls instead of inferring the
     * transfer's outcome from whether a long `flow.fetch` round trip
     * returned in time (NET-01's root cause).
     */
    suspend fun flowStatus(peer: PeerAddrParts, tuple: FlowTupleRef): FlowStatusReply {
        val resp = call(peer, Methods.FLOW_STATUS, ProtoJson.encodeToJsonElement(FlowTupleRef.serializer(), tuple))
        check(resp.ok) { "flow.status: ${resp.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(FlowStatusReply.serializer(), resp.result ?: error("flow.status: empty result"))
    }

    /**
     * NET-06: pause — interrupts the daemon's in-progress native fetch
     * task for this exact tuple WITHOUT changing the durable grant state
     * (stays active, so a later offer resumes instead of restarting).
     * Best-effort per the card's principle 1 (意图先行，不等回声): a
     * failure here must not block the phone's own local pause — callers
     * swallow exceptions from this call.
     */
    suspend fun flowSuspend(peer: PeerAddrParts, tuple: FlowTupleRef) {
        val resp = call(peer, Methods.FLOW_SUSPEND, ProtoJson.encodeToJsonElement(FlowTupleRef.serializer(), tuple))
        check(resp.ok) { "flow.suspend: ${resp.error?.msgKey}" }
    }

    /**
     * NET-06: cancel by tuple identity alone — no content_hash/provider
     * needed, unlike [call]-based `flow.cancel`. This is what
     * CancellationRoundController must use for an item that already
     * exhausted its retry budget and discarded its one-shot provider
     * ticket, where a full `flow.cancel` request can no longer be built.
     * Best-effort, same as [flowSuspend]: callers swallow exceptions —
     * cancellation is a local state change first, the daemon notification
     * is a courtesy (卡片原则 1).
     */
    suspend fun flowCancelTuple(peer: PeerAddrParts, tuple: FlowTupleRef) {
        val resp = call(peer, Methods.FLOW_CANCEL_TUPLE, ProtoJson.encodeToJsonElement(FlowTupleRef.serializer(), tuple))
        check(resp.ok) { "flow.cancel_tuple: ${resp.error?.msgKey}" }
    }

    /**
     * SYNC-04: 前台常驻订阅——发一次 `timeline.subscribe`，之后只管读
     * 直到这条流结束（对端主动关闭 / 连接坏了 / 协程被取消）。收到第
     * 一个帧（订阅确认本身）就调用一次 [onConnected]——调用方拿它区分
     * "正在重连"和"已经连上，安静等事件"两种状态，不然重连期间界面
     * 全程没有任何提示（真机验收发现的缺口：原设计只在退避耗尽之后
     * 才亮提示，中间过程完全沉默）。每收到一次 `timeline.invalidated`
     * 推送（包括订阅建立那一刻的"当前态"那一次，§③）就调用
     * [onInvalidated]。
     *
     * 正常返回（对端 `finish` 了发送方向）和抛异常（真正的连接错误）
     * 对调用方是同一个意思：这次订阅结束了，按断线退避重连处理，不用
     * 区分对待。发送方向在发完订阅请求后立即半关闭——取数据永远走
     * 独立鉴权的普通 `call`，这条流从头到尾不传照片内容（决策档案
     * §⑦）。
     */
    suspend fun subscribeTimeline(
        peer: PeerAddrParts,
        onConnected: suspend () -> Unit = {},
        onFlowEvent: suspend (String, JsonObject) -> Unit = { _, _ -> },
        onInvalidated: suspend () -> Unit,
    ): Unit = withContext(Dispatchers.IO) {
        val ep = endpoint ?: error("bind() first")
        val addr = EndpointAddr(
            EndpointId.fromString(peer.idHex),
            peer.relayUrl,
            peer.directAddresses,
        )
        val conn = ep.connectBounded(addr, ALPN_CTRL.toByteArray())
        try {
            val bi = conn.openBi()
            val send = bi.send()
            val recv = bi.recv()
            val req = Req(
                id = UUID.randomUUID().toString(),
                method = Methods.TIMELINE_SUBSCRIBE,
                params = buildJsonObject {},
            )
            send.writeAll(encodeFrame(Req.serializer(), req))
            send.finish()

            var firstFrame = true
            while (true) {
                currentCoroutineContext().ensureActive()
                val header = recv.readExact(4u)
                val len = frameLen(header)
                val payload = decodePayload(JsonElement.serializer(), recv.readExact(len.toUInt()))
                if (firstFrame) {
                    firstFrame = false
                    onConnected() // 读到第一个帧（订阅确认）= 这次真的连上了
                }
                val event = (payload as? JsonObject)?.get("event")
                    ?.let { (it as? JsonPrimitive)?.content }
                when (event) {
                    "timeline.invalidated" -> onInvalidated()
                    // NET-14: flow.delivered/flow.failed — the daemon already
                    // filters these to only the phone they name (router.rs),
                    // so every frame that arrives here on this connection is
                    // already this phone's own event; no further filtering
                    // by node_id is needed at this layer.
                    "flow.delivered", "flow.failed" -> {
                        val data = (payload as? JsonObject)?.get("data") as? JsonObject
                        if (data != null) onFlowEvent(event, data)
                    }
                }
                // 没有 "event" 键的帧是订阅确认本身（{"ok":true,...}）——忽略。
            }
        } finally {
            conn.close(0L, ByteArray(0))
        }
    }

    /** UX-06: unilateral stop — ask the daemon to revoke THIS device.
     *  Success means hello is denied from now on; a fresh owner-issued
     *  token can rejoin. Returns true when the daemon confirmed. */
    suspend fun unpair(peer: PeerAddrParts): Boolean = withContext(Dispatchers.IO) {
        val resp = call(peer, "device.unpair", buildJsonObject {})
        resp.ok
    }

    /** Open a raw connection on any ALPN (upload plane reuses it for
     *  many streams — one per file). Caller closes. */
    suspend fun connectRaw(peer: PeerAddrParts, alpn: String): Connection =
        withContext(Dispatchers.IO) {
            val ep = endpoint ?: error("bind() first")
            val addr = EndpointAddr(
                EndpointId.fromString(peer.idHex),
                peer.relayUrl,
                peer.directAddresses,
            )
            // UX-11: bound connection establishment only — the session
            // itself (upload/download streams) legitimately runs long,
            // only the "can we even reach it" step is time-boxed.
            ep.connectBounded(addr, alpn.toByteArray())
        }

    /**
     * Download an asset's original bytes to [dest] over ppf/download/1.
     * Returns total bytes. [onProgress] gets (received, total).
     */
    suspend fun downloadAsset(
        peer: PeerAddrParts,
        hash: String,
        dest: java.io.File,
        onProgress: (Long, Long) -> Unit = { _, _ -> },
    ): Long = withContext(Dispatchers.IO) {
        val conn = connectRaw(peer, "ppf/download/1")
        try {
            val bi = conn.openBi()
            val send = bi.send()
            val recv = bi.recv()
            val req = Req(
                id = java.util.UUID.randomUUID().toString(),
                method = "asset.download",
                params = kotlinx.serialization.json.buildJsonObject {
                    put("hash", kotlinx.serialization.json.JsonPrimitive(hash))
                },
            )
            send.writeAll(com.hawkeyexb.ppass.proto.encodeFrame(Req.serializer(), req))
            send.finish()

            val header = recv.readExact(4u)
            val len = com.hawkeyexb.ppass.proto.frameLen(header)
            val resp = com.hawkeyexb.ppass.proto.decodePayload(
                Resp.serializer(), recv.readExact(len.toUInt())
            )
            check(resp.ok) { "download $hash: ${resp.error?.msgKey}" }
            val total = (resp.result as? kotlinx.serialization.json.JsonObject)
                ?.get("bytes")?.let {
                    (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toLongOrNull()
                } ?: -1L

            var received = 0L
            dest.outputStream().use { out ->
                while (received < total || total < 0) {
                    val want = if (total > 0) {
                        minOf(256L * 1024, total - received).toUInt()
                    } else 256u * 1024u
                    val chunk = try {
                        recv.readExact(want)
                    } catch (_: Throwable) {
                        break // sender finished early
                    }
                    if (chunk.isEmpty()) break
                    out.write(chunk)
                    received += chunk.size
                    onProgress(received, total)
                }
            }
            received
        } finally {
            conn.close(0L, ByteArray(0))
        }
    }

    suspend fun close(): Unit = withContext(Dispatchers.IO) {
        endpoint?.close()
        endpoint = null
    }
}
