// T-052: the pairing conversation, camera-free — the scanner hands us a
// QR string; this turns it into a saved Pairing or a human-readable
// failure. The pair.request response blocks until the owner clicks
// Allow on the computer (or the daemon times the request out).
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.PairAccepted
import com.hawkeyexb.ppass.proto.PairRequest
import com.hawkeyexb.ppass.proto.ProtoJson
import kotlinx.coroutines.withTimeout

sealed class PairOutcome {
    data class Joined(val pairing: Pairing) : PairOutcome()
    data class Refused(val msgKey: String) : PairOutcome()
    data class Failed(val reason: String) : PairOutcome()
}

/**
 * Scan result → pair.request → wait for the owner's Allow.
 * [waitMs] must exceed a human's reaction time generously; the QR
 * token itself lives 10 minutes.
 */
suspend fun pairWithQr(
    client: DaemonClient,
    qr: String,
    deviceName: String,
    waitMs: Long = 120_000,
): PairOutcome {
    val parsed = try {
        parsePairingQr(qr)
    } catch (e: Exception) {
        return PairOutcome.Failed("这不是 P-Pass 配对码")
    }
    val addr = parsed.addr
        ?: return PairOutcome.Failed("配对码缺少地址信息，请在电脑上重新生成")

    return try {
        val resp = withTimeout(waitMs) {
            client.call(
                addr,
                Methods.PAIR_REQUEST,
                ProtoJson.encodeToJsonElement(
                    PairRequest.serializer(),
                    PairRequest(token = parsed.token, deviceName = deviceName),
                ),
            )
        }
        if (resp.ok) {
            val accepted = ProtoJson.decodeFromJsonElement(
                PairAccepted.serializer(), resp.result!!
            )
            PairOutcome.Joined(
                Pairing(
                    daemonNodeId = parsed.nodeIdHex,
                    daemonAddrToken = "", // filled by caller with the QR's a= token
                    storageDeviceName = accepted.storageDeviceName,
                ).let {
                    val raw = qr.substringAfter("&a=", "")
                    if (raw.isNotEmpty()) it.copy(daemonAddrToken = raw) else it
                }
            )
        } else {
            PairOutcome.Refused(resp.error?.msgKey ?: "err.unknown")
        }
    } catch (e: Exception) {
        PairOutcome.Failed(e.toString())
    }
}
