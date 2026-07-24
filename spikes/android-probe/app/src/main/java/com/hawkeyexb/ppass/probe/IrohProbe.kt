package com.hawkeyexb.ppass.probe

import android.util.Log
import computer.iroh.BiStream
import computer.iroh.Connection
import computer.iroh.Endpoint
import computer.iroh.EndpointAddr
import computer.iroh.EndpointId
import computer.iroh.EndpointOptions
import computer.iroh.presetN0
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * S-03: Minimal iroh probe for Android — bind, listen, dial, throughput test.
 *
 * Wire protocol: ALPN = "ppass-probe"
 * - Listener: accept → read 100MB → send ACK "OK"
 * - Dialer: connect → send 100MB → read ACK "OK"
 *
 * Results match the S-01 CLI JSON format.
 */

data class ProbeResult(
    val attempt: Int,
    val path: String,           // "lan", "direct", "relay", "unknown"
    val ipver: String,          // "v4", "v6", "?"
    val connectMs: Long,
    val throughputMbps: Double,
    val error: String? = null,
)

class IrohProbe {
    companion object {
        const val ALPN = "ppass-probe"
        private const val TAG = "IrohProbe"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var endpoint: Endpoint? = null

    fun nodeId(): String? = endpoint?.addr()?.id?.toString()
    fun ticket(): String? = endpoint?.addr()?.toTicketHex()

    /** Bind the endpoint. Safe to call multiple times. */
    suspend fun bind(): Result<String> = withContext(Dispatchers.IO) {
        try {
            if (endpoint != null) return@withContext Result.success(ticket()!!)
            val ep = Endpoint.bind(
                EndpointOptions(
                    preset = presetN0(),
                    alpns = listOf(ALPN),
                )
            )
            endpoint = ep
            val t = ep.addr().toTicketHex()
            Log.i(TAG, "Bound: ${ep.addr().id}")
            Result.success(t)
        } catch (e: Throwable) {
            Log.e(TAG, "Bind failed", e)
            Result.failure(e)
        }
    }

    /** Start accepting incoming probe connections. */
    fun startListener(onResult: (ProbeResult) -> Unit) {
        scope.launch {
            val ep = endpoint ?: return@launch
            var attempt = 0
            try {
                while (true) {
                    val incoming = ep.acceptNext() ?: break
                    attempt++
                    try {
                        val accepting = incoming.accept()
                        val alpn = accepting.alpn()
                        if (alpn?.let { String(it) } != ALPN) continue
                        val conn = accepting.connect()
                        val bi = conn.acceptBi()
                        handleIncoming(attempt, conn, bi, onResult)
                    } catch (e: Throwable) {
                        Log.w(TAG, "Accept #$attempt threw: ${e.message}")
                        onResult(ProbeResult(attempt, "error", "?", 0, 0.0, e.message))
                    }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "Accept loop: ${e.message}")
            }
        }
    }

    /** Dial a peer, transfer [payloadMegaBytes] MB, return result. */
    suspend fun dial(
        ticketHex: String,
        payloadMegaBytes: Int = 100,
    ): ProbeResult = withContext(Dispatchers.IO) {
        val ep = endpoint ?: return@withContext ProbeResult(-1, "error", "?", 0, 0.0, "not bound")
        val startTime = System.currentTimeMillis()

        try {
            val addr = EndpointAddr.fromTicketHex(ticketHex)
            val conn = ep.connect(addr, ALPN)
            val connectMs = System.currentTimeMillis() - startTime

            val (send, recv) = conn.openBi()

            // Generate random payload and send
            val payload = ByteArray(payloadMegaBytes * 1_000_000)
            kotlin.random.Random.nextBytes(payload)

            val txStart = System.nanoTime()
            send.write(payload)
            send.finish()
            val txDone = System.nanoTime()
            val txMs = (txDone - txStart) / 1_000_000.0

            // Read ACK
            val ack = ByteArray(2)
            recv.read(ack)
            recv.finish()

            // Path info from connection stats
            val paths = conn.paths()
            val pathKind = when {
                paths.any { it.isIp && !it.isRelay } -> {
                    val p = paths.first { it.isIp }
                    if (p.rttMs < 5) "lan" else "direct"
                }
                paths.any { it.isRelay } -> "relay"
                else -> "unknown"
            }
            val ipver = if (paths.any { it.remoteAddr.contains(":") }) "v6" else "v4"

            val throughputMbps = (payloadMegaBytes * 8).toDouble() / (txMs / 1000.0)

            conn.close()
            ProbeResult(-1, pathKind, ipver, connectMs, throughputMbps)
        } catch (e: Throwable) {
            Log.e(TAG, "Dial failed", e)
            ProbeResult(-1, "error", "?", 0, 0.0, e.message)
        }
    }

    private suspend fun handleIncoming(
        attempt: Int,
        conn: Connection,
        bi: BiStream,
        onResult: (ProbeResult) -> Unit,
    ) {
        val (send, recv) = bi

        val startTime = System.nanoTime()
        var total = 0L
        val buf = ByteArray(65536)
        while (true) {
            val n = recv.read(buf)
            if (n <= 0) break
            total += n
        }
        val durationNs = System.nanoTime() - startTime
        val durationMs = durationNs / 1_000_000.0
        val throughputMbps = (total * 8.0) / (durationNs.toDouble() / 1_000_000_000.0) / 1_000_000.0

        // ACK
        send.write("OK".toByteArray())
        send.finish()

        val paths = conn.paths()
        val pathKind = when {
            paths.any { it.isIp && !it.isRelay } -> {
                val p = paths.first { it.isIp }
                if (p.rttMs < 5) "lan" else "direct"
            }
            paths.any { it.isRelay } -> "relay"
            else -> "unknown"
        }
        val ipver = if (paths.any { it.remoteAddr.contains(":") }) "v6" else "v4"

        // Don't close; let the dialer close
        conn.closed().await()

        onResult(
            ProbeResult(
                attempt = attempt,
                path = pathKind,
                ipver = ipver,
                connectMs = 0,  // server side, no connect ms
                throughputMbps = throughputMbps,
                error = null,
            )
        )
    }

    fun close() {
        endpoint?.close()
        endpoint = null
    }
}
