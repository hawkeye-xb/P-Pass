// T-051: the phone's ctrl-plane client — iroh-ffi endpoint + one
// request/response per bidirectional stream, length-prefixed JSON
// frames (crates/proto codec), talking to the storage daemon's router.
//
// Same shape as tools/testclient's `call`: open bi stream, send one
// frame, finish the send side, read one response frame.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Req
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.encodeFrame
import com.hawkeyexb.ppass.proto.decodePayload
import com.hawkeyexb.ppass.proto.frameLen
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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonElement
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

    /**
     * Bind the endpoint. Pass the device's persistent 32-byte secret so
     * the phone keeps ONE identity across restarts — pairing is bound to
     * the NodeId, a fresh key would demote us to a stranger.
     */
    suspend fun bind(secretKey: ByteArray? = null): Unit = withContext(Dispatchers.IO) {
        if (endpoint != null) return@withContext
        val opts = EndpointOptions(
            preset = presetN0(),
            alpns = listOf(ALPN_CTRL.toByteArray()),
        )
        if (secretKey != null) opts.secretKey = secretKey
        endpoint = Endpoint.bind(opts)
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
