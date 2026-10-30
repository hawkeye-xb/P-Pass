// T-051 / #1124: the phone's ctrl-plane client. Since #1124 it is a thin Kotlin
// wrapper around the shared Rust transport core (`crates/transport/src/mobile_ffi.rs`,
// uniffi `CtrlClient`) — the same implementation iOS uses. One request/response per
// connection, length-prefixed JSON frames (crates/proto codec) — all in Rust.
//
// The wrapper keeps what is Android's own: lazy bind with the persistent identity and
// the idle reaper (#434), the NET-28 bind deadline, coroutine cancellation, the #1072
// version check on every reply, and turning FFI errors into the exceptions the rest of
// the app already handles.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.ffi.CtrlClient
import com.hawkeyexb.ppass.ffi.CtrlClientInterface
import com.hawkeyexb.ppass.ffi.CtrlConfig
import com.hawkeyexb.ppass.ffi.FetchCancel
import com.hawkeyexb.ppass.ffi.FetchProgress
import com.hawkeyexb.ppass.ffi.FfiException
import com.hawkeyexb.ppass.ffi.StreamListener
import com.hawkeyexb.ppass.proto.BlobTicketRequest
import com.hawkeyexb.ppass.proto.BlobTicketResponse
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.versionChecked
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

const val ALPN_CTRL = "ppf/ctrl/1"

/** UX-11: every control call (connect + request + reply) is bounded so a dead peer always
 *  surfaces as a real failure instead of an infinite spinner. Enforced inside Rust. */
private const val CONNECT_TIMEOUT_MS = 15_000L

/** NET-09 (#116): fetching an original fails once no payload byte has arrived for this long;
 *  a slow but moving transfer is never cut. Passed to the shared Rust `fetch_blob`. */
internal const val ORIGINAL_BYTE_STALL_MS = 60_000L

/** Deliberately NOT a CancellationException — it must flow through
 *  existing `catch (t: Throwable)` blocks as a genuine failure.
 *  BackupUiStateHolder's `if (t is CancellationException) throw t` guard
 *  exists to preserve "tap again = pause" semantics; a timeout wearing
 *  a CancellationException costume would vanish there silently instead
 *  of surfacing as the Trouble state. */
class DaemonUnreachableException(message: String) : IOException(message)

/**
 * NET-28 (#454): upper bound on binding the endpoint. Bind does no network round trip
 * (relay / net-report run after it, in the background); the slowest legitimate bind on
 * Android is bounded by netdev's netlink dumps — about 8 s. 15 s clears that with margin and
 * equals [CONNECT_TIMEOUT_MS], so the pairing wait screen gives up no later than one connect
 * budget after the tap. The `bindMs=` line from [DaemonClient]'s bindLog is how that is
 * checked on a real device.
 */
internal const val BIND_TIMEOUT_MS = 15_000L

/**
 * The phone's own endpoint did not come up in time — a local problem on the phone,
 * deliberately NOT a [DaemonUnreachableException] ("the computer cannot be reached"): the two
 * point troubleshooting in opposite directions. Not a CancellationException either, for the
 * reason given on [DaemonUnreachableException].
 */
class EndpointBindTimeoutException(timeoutMs: Long) :
    IOException("phone network endpoint did not start within ${timeoutMs}ms (local, not the computer)")

/** Any other failure the shared transport core reported (network, stream, codec). */
class TransportFailureException(message: String) : IOException(message)

/** The original that came back is not the one asked for (content hash mismatch). */
class OriginalHashMismatchException(expected: String, actual: String) :
    IOException("original $expected came back as $actual")

/** More bytes arrived than the computer said the original has; the fetch was stopped. */
class OriginalExceedsDeclaredSizeException(declared: Long, got: Long) :
    IOException("original grew past its declared $declared bytes (got $got); fetch stopped")

/**
 * Stops a fetch as soon as the received byte count passes [declared]. [onBytes] gets the
 * cumulative count (iroh-blobs `payload_bytes_read`); [abort] runs at most once.
 * `declared <= 0` means the size is unknown and nothing is enforced here — callers that
 * need a bound refuse to start without one.
 */
internal class DeclaredSizeGuard(private val declared: Long, private val abort: () -> Unit) {
    @Volatile var exceededAt: Long = -1
        private set

    fun onBytes(got: Long) {
        if (declared > 0 && got > declared && exceededAt < 0) {
            exceededAt = got
            abort()
        }
    }
}

private fun bindCtrlPlane(secretKey: ByteArray?): CtrlClientInterface =
    CtrlClient.bind(CtrlConfig(secretKey, emptyList(), false, BIND_TIMEOUT_MS.toULong()))

/** FFI error → the exception the app already understands. */
internal fun mapFfi(e: FfiException, what: String): IOException = when (e) {
    is FfiException.Timeout -> DaemonUnreachableException("$what: no response from the computer within ${CONNECT_TIMEOUT_MS}ms")
    is FfiException.PeerClosed -> PeerClosedException(e.nodeId, e.code.toLong())
    else -> TransportFailureException("$what: ${e.message}")
}

/**
 * One endpoint per app process. Bind once (or lazily with [secretKey]), then `call` against a
 * peer. All methods are IO-dispatched — safe to call from any coroutine.
 */
class DaemonClient internal constructor(
    private val bindTimeoutMs: Long,
    private val openPlane: suspend (secretKey: ByteArray?) -> CtrlClientInterface,
    private val bindLog: (String) -> Unit,
    /** #434: the device's persistent identity. When set, every method binds on demand, so the
     *  endpoint can be closed while idle ([closeIfIdle]) and come back on the next use. */
    private val secretKey: (() -> ByteArray)? = null,
) {
    /** [bindLog] receives one line per bind attempt (duration, outcome) —
     *  NET-28 asks for real-device bind timings to be observable. */
    constructor(bindLog: (String) -> Unit = {}, secretKey: (() -> ByteArray)? = null) :
        this(BIND_TIMEOUT_MS, { key -> bindCtrlPlane(key) }, bindLog, secretKey)

    /** #434: called after every successful bind (the idle reaper re-arms on it). */
    @Volatile var onBound: () -> Unit = {}

    /**
     * #1124: a connection of this client — any call, probe, subscription or original fetch —
     * was closed by the peer with an application close code. `nodeId` is the authenticated
     * closer. The app decides (recorded desktop + 401 / 410 ⇒ rejected-cleanup, everything else
     * ⇒ unreachable); see [desktopRejectionForClose].
     */
    @Volatile var onPeerClosed: (nodeId: String, code: Long) -> Unit = { _, _ -> }

    private val closeListener = peerCloseListener { nodeId, code -> this.onPeerClosed(nodeId, code) }

    /** #434: requests / streams / downloads currently using the endpoint. */
    private val inFlight = java.util.concurrent.atomic.AtomicInteger(0)

    private suspend fun <T> using(block: suspend (CtrlClientInterface) -> T): T {
        inFlight.incrementAndGet()
        try {
            return block(requirePlane())
        } finally {
            inFlight.decrementAndGet()
        }
    }

    /** The bound plane; binds it first when [secretKey] is known (#434 lazy bind). */
    private suspend fun requirePlane(): CtrlClientInterface {
        plane?.let { return it }
        val key = secretKey ?: error("bind() first")
        bind(key())
        return plane ?: error("bind() first")
    }

    private val bindScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val bound = BoundedSingleFlight<CtrlClientInterface>(
        timeoutMs = bindTimeoutMs,
        scope = bindScope,
        // A bind that finishes after close(): nobody owns it, release it.
        discard = { late -> runCatching { late.shutdown() } },
    )
    private val plane: CtrlClientInterface? get() = bound.current()

    /**
     * Bind the endpoint. Pass the device's persistent 32-byte secret so the phone keeps ONE
     * identity across restarts — pairing is bound to the NodeId, a fresh key would demote us to
     * a stranger.
     *
     * NET-28: bounded by [BIND_TIMEOUT_MS]; a hung bind throws [EndpointBindTimeoutException]
     * instead of waiting forever. The hung attempt is not restarted by the next call — that call
     * waits on the same attempt again, and adopts it if it ever finishes (see
     * [BoundedSingleFlight]).
     */
    suspend fun bind(secretKey: ByteArray? = null) {
        bound.get(
            start = {
                val started = System.nanoTime()
                fun ms() = (System.nanoTime() - started) / 1_000_000
                try {
                    withContext(Dispatchers.IO) { openPlane(secretKey) }.also {
                        it.setPeerCloseListener(closeListener)
                        bindLog("bind ok bindMs=${ms()}")
                        runCatching { lastNodeIdHex = it.nodeId() }
                        runCatching { onBound() }
                    }
                } catch (t: Throwable) {
                    bindLog("bind failed bindMs=${ms()} error=$t")
                    throw t
                }
            },
            onTimeout = { waited ->
                bindLog("bind timeout: still running after ${waited}ms")
                EndpointBindTimeoutException(waited)
            },
        )
    }

    /** #434: the id survives [closeIfIdle] — it comes from the persistent key, not the socket. */
    fun nodeIdHex(): String? = plane?.let { runCatching { it.nodeId() }.getOrNull() }?.also { lastNodeIdHex = it } ?: lastNodeIdHex

    @Volatile private var lastNodeIdHex: String? = null

    /**
     * #1072: every reply goes through here. An incompatible desktop — one that refused us as
     * outdated, or one too old to send `ver` at all — becomes a `VERSION_MISMATCH` rejection, so
     * no caller ever acts on a pre-v2 reply; the verdict also feeds [ProtocolVersionGate].
     */
    private fun checkedReply(reply: Resp): Resp =
        reply.versionChecked().also(ProtocolVersionGate::observe)

    private fun decodeReply(json: String): Resp =
        checkedReply(ProtoJson.decodeFromString(Resp.serializer(), json))

    /**
     * One request/response round trip on a connection of its own (the daemon serves one
     * connection's streams one after another; a shared connection would queue requests).
     * [timeoutMs]: the whole round trip; default 15 s. #851 `flow.supersede` waits for the
     * desktop to pull, splice and fingerprint, so it is widened there.
     */
    suspend fun call(peer: PeerAddrParts, method: String, params: JsonElement, timeoutMs: Long = CONNECT_TIMEOUT_MS): Resp =
        withContext(Dispatchers.IO) { using { p ->
            val reply = try {
                p.call(peer.toToken(), method, params.toString(), timeoutMs.toULong())
            } catch (e: FfiException) {
                throw mapFfi(e, method)
            }
            decodeReply(reply)
        } }

    /**
     * DIAG-A：与 [call] 同一次往返、同一个 [CONNECT_TIMEOUT_MS] 上限，但逐阶段记下发生了什么，
     * 成败都调一次 [report]。只给可达性探测用——状态轮询也走它会把日志刷爆。逐阶段记录由共享
     * Rust 核心给出（`CtrlClient::call_traced`）：本端 home relay、`online()` 何时返回、连接与回复
     * 耗时、连上后选中的路径、失败时的错误类别 / 关闭码与 iroh 手里的对端地址。
     */
    suspend fun callTraced(
        peer: PeerAddrParts,
        method: String,
        params: JsonElement,
        report: (CallTrace) -> Unit,
    ): Resp = withContext(Dispatchers.IO) { using { p ->
        val t = try {
            p.callTraced(peer.toToken(), method, params.toString(), CONNECT_TIMEOUT_MS.toULong())
        } catch (e: FfiException) {
            throw mapFfi(e, method)
        }
        val failure: IOException? = when (t.errorKind) {
            null -> null
            "timeout" -> DaemonUnreachableException("$method: no response from the computer within ${CONNECT_TIMEOUT_MS}ms")
            "peer_closed" -> PeerClosedException(t.closedBy.orEmpty(), (t.closeCode ?: 0uL).toLong())
            else -> TransportFailureException("$method: ${t.errorMessage}")
        }
        report(
            CallTrace(
                method = method,
                tokenRelay = peer.relayUrl,
                tokenDirectAddrs = peer.directAddresses,
                homeRelayAtStart = t.homeRelayAtStart,
                onlineAfterMs = t.onlineAfterMs?.toLong(),
                connectMs = t.connectMs?.toLong(),
                roundTripMs = t.roundTripMs?.toLong(),
                totalMs = t.totalMs.toLong(),
                path = t.pathKind?.let { kind ->
                    PathVerdict(PathKind.entries.first { it.wire == kind }, t.pathRemoteIp, t.pathRttMs.toLong())
                },
                pathCount = t.pathCount.toInt(),
                errorClass = failure?.javaClass?.simpleName,
                errorKind = t.errorKind?.let { k -> t.closeCode?.let { "$k:$it" } ?: k },
                errorMessage = t.errorMessage,
                peerKnownAddr = if (failure == null) null else KnownAddr(t.peerKnownRelay, t.peerKnownDirect),
            ),
        )
        if (failure != null) throw failure
        decodeReply(checkNotNull(t.replyJson) { "$method: trace without reply or error" })
    } }

    /**
     * NET-06: read-only status query for one exact tuple — a short control-plane RPC that never
     * blocks on the data plane and always answers within [CONNECT_TIMEOUT_MS], on any network
     * condition.
     */
    suspend fun flowStatus(peer: PeerAddrParts, tuple: FlowTupleRef): FlowStatusReply {
        val resp = call(peer, Methods.FLOW_STATUS, ProtoJson.encodeToJsonElement(FlowTupleRef.serializer(), tuple))
        check(resp.ok) { "flow.status rejected: ${resp.error?.reason}" }
        return ProtoJson.decodeFromJsonElement(FlowStatusReply.serializer(), resp.result ?: error("flow.status: empty result"))
    }

    /**
     * NET-06: pause — interrupts the daemon's in-progress native fetch task for this exact tuple
     * WITHOUT changing the durable grant state. Best-effort per the card's principle 1
     * (意图先行，不等回声): callers swallow exceptions from this call.
     */
    suspend fun flowSuspend(peer: PeerAddrParts, tuple: FlowTupleRef) {
        val resp = call(peer, Methods.FLOW_SUSPEND, ProtoJson.encodeToJsonElement(FlowTupleRef.serializer(), tuple))
        check(resp.ok) { "flow.suspend rejected: ${resp.error?.reason}" }
    }

    /**
     * NET-06: cancel by tuple identity alone — no content_hash/provider needed. Best-effort,
     * same as [flowSuspend]: callers swallow exceptions.
     */
    suspend fun flowCancelTuple(peer: PeerAddrParts, tuple: FlowTupleRef) {
        val resp = call(peer, Methods.FLOW_CANCEL_TUPLE, ProtoJson.encodeToJsonElement(FlowTupleRef.serializer(), tuple))
        check(resp.ok) { "flow.cancel_tuple rejected: ${resp.error?.reason}" }
    }

    /**
     * SYNC-04: 前台常驻订阅——发一次 `timeline.subscribe`，之后只管读直到这条流结束（对端主动关闭 /
     * 连接坏了 / 协程被取消）。收到第一个帧（订阅确认本身）就调用一次 [onConnected]；每收到一次
     * `timeline.invalidated` 推送就调用 [onInvalidated]。
     *
     * 流由共享 Rust 核心读（`CtrlClient::open_stream`），帧经通道交回协程。对端结束 / 连接出错都以
     * 异常结束本次订阅（调用方按断线退避重连处理，不用区分）；连接被对端用应用关闭码关掉时，
     * 关闭监听（[onPeerClosed]）先于这里收到消息（#1124）。协程取消 ⇒ 取消这条流。
     */
    suspend fun subscribeTimeline(
        peer: PeerAddrParts,
        onConnected: suspend () -> Unit = {},
        onFlowEvent: suspend (String, JsonObject) -> Unit = { _, _ -> },
        onInvalidated: suspend () -> Unit,
    ): Unit = withContext(Dispatchers.IO) { using { p ->
        val frames = Channel<Result<JsonElement>>(Channel.UNLIMITED)
        val listener = object : StreamListener {
            override fun onFrame(json: String) {
                frames.trySend(runCatching { ProtoJson.parseToJsonElement(json) })
            }
            override fun onClosed(error: String?) {
                frames.trySend(Result.failure(TransportFailureException("${Methods.TIMELINE_SUBSCRIBE} ended: ${error ?: "finished by the computer"}")))
                frames.close()
            }
        }
        val handle = try {
            p.openStream(peer.toToken(), Methods.TIMELINE_SUBSCRIBE, "{}", CONNECT_TIMEOUT_MS.toULong(), listener)
        } catch (e: FfiException) {
            throw mapFfi(e, Methods.TIMELINE_SUBSCRIBE)
        }
        try {
            readSubscriptionFrames(
                nextFrame = { frames.receive().getOrThrow() },
                onConnected = onConnected,
                onFlowEvent = onFlowEvent,
                onInvalidated = onInvalidated,
            )
        } finally {
            handle.cancel()
        }
    } }

    /** UX-06: unilateral stop — ask the daemon to revoke THIS device.
     *  #565: [pairingId] names the pairing being ended (blank = legacy pairing without one); the
     *  daemon only revokes while that pairing is still current. Sent once on disconnect
     *  ([sendUnpairNoticeOnce]); the reply is only logged (#956). */
    suspend fun unpair(peer: PeerAddrParts, pairingId: String): Resp = withContext(Dispatchers.IO) {
        call(peer, "device.unpair", unpairParams(pairingId))
    }

    /**
     * Fetch an asset's original bytes to [dest] — the same path as iOS (#1124): ask the desktop
     * for an `asset.blob_ticket`, then pull that blob with the shared Rust `fetch_blob`
     * (iroh-blobs verifies every chunk against the content hash; nothing partial is left at
     * [dest] on failure). The returned content hash must equal [hash].
     * Returns the byte count. [onProgress] gets (received, [expectedBytes]).
     * NET-09 (#116): no total-duration limit; fails once no payload byte arrives for
     * [ORIGINAL_BYTE_STALL_MS]. Coroutine cancellation aborts the fetch.
     */
    suspend fun downloadAsset(
        peer: PeerAddrParts,
        hash: String,
        dest: java.io.File,
        expectedBytes: Long = 0,
        onProgress: (Long, Long) -> Unit = { _, _ -> },
    ): Long = withContext(Dispatchers.IO) { using { p ->
        val resp = call(
            peer, Methods.ASSET_BLOB_TICKET,
            ProtoJson.encodeToJsonElement(BlobTicketRequest.serializer(), BlobTicketRequest(hash)),
        )
        check(resp.ok) { "asset.blob_ticket $hash rejected: ${resp.error?.reason}" }
        val ticket = ProtoJson.decodeFromJsonElement(BlobTicketResponse.serializer(), checkNotNull(resp.result)).ticket
        val scratch = java.io.File(dest.absoluteFile.parentFile, ".fetch").apply { mkdirs() }
        val cancel = FetchCancel()
        val guard = DeclaredSizeGuard(expectedBytes) { cancel.cancel() }
        val progress = object : FetchProgress {
            override fun onBytes(bytes: ULong) {
                guard.onBytes(bytes.toLong())
                onProgress(bytes.toLong(), expectedBytes)
            }
        }
        val got = try {
            suspendCancellableCoroutine { cont ->
                cont.invokeOnCancellation { cancel.cancel() }
                try {
                    cont.resume(p.fetchBlob(ticket, scratch.path, dest.path, ORIGINAL_BYTE_STALL_MS.toULong(), progress, cancel))
                } catch (e: FfiException) {
                    val over = guard.exceededAt
                    cont.resumeWithException(
                        if (over >= 0) OriginalExceedsDeclaredSizeException(expectedBytes, over)
                        else mapFfi(e, "fetch original $hash"),
                    )
                }
            }
        } finally {
            cancel.destroy()
        }
        // The abort can lose the race with the last chunk; the result is refused either way.
        if (guard.exceededAt >= 0) {
            dest.delete()
            throw OriginalExceedsDeclaredSizeException(expectedBytes, guard.exceededAt)
        }
        if (!got.equals(hash, ignoreCase = true)) {
            dest.delete()
            throw OriginalHashMismatchException(hash, got)
        }
        dest.length()
    } }

    /**
     * #434: close the endpoint if nothing is using it, so an idle process stops pinging relays.
     * Returns false (and keeps it) while a request, stream or download is in flight. Only
     * meaningful with [secretKey] set — the next use binds again.
     */
    suspend fun closeIfIdle(): Boolean = withContext(Dispatchers.IO) {
        if (inFlight.get() != 0) return@withContext false
        if (plane == null) return@withContext true
        bound.reset()?.let { p ->
            runCatching { lastNodeIdHex = p.nodeId() }
            runCatching { p.shutdown() }
            bindLog("endpoint closed while idle")
        }
        true
    }

    suspend fun close(): Unit = withContext(Dispatchers.IO) {
        bound.reset()?.shutdown()
    }
}
