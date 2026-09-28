// T-052: the pairing conversation, camera-free — the scanner hands us a
// QR string; this turns it into a saved Pairing or a human-readable
// failure.
//
// NET-10 (#128): submitting is not waiting. pair.request (ack_then_poll)
// answers as soon as the desktop has queued the request; the owner's
// verdict is then read by polling pair.status every 5 s, until the
// deadline the desktop itself sent back. The old shape held ONE RPC open
// until the owner clicked — but DaemonClient.call caps every round trip at
// 15 s (CONNECT_TIMEOUT_MS), so any owner slower than ~15 s turned into
// "could not reach the computer".
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.PairAccepted
import com.hawkeyexb.ppass.proto.PairRequest
import com.hawkeyexb.ppass.proto.PairStatusReply
import com.hawkeyexb.ppass.proto.PairStatusRequest
import com.hawkeyexb.ppass.proto.PairSubmitted
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Resp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.buildJsonObject
import kotlinx.coroutines.withTimeout

sealed class PairOutcome {
    data class Joined(val pairing: Pairing) : PairOutcome()
    /**
     * The pairing ended without joining; [msgKey] names the cause (diag
     * dictionary). [ownerSaidNo] = the desktop actually refused (owner
     * denied, or the code was invalid/used); false = it lapsed on its own
     * (expired, desktop restarted, desktop too old) — NET-10 keeps those
     * apart so the screen does not claim "the computer said no".
     */
    data class Refused(val msgKey: String, val ownerSaidNo: Boolean = true) : PairOutcome()
    data class Failed(val reason: String) : PairOutcome()
}

/** NET-10: msg_keys for the lapsed causes (assets/i18n, crates/diag keys.rs). */
const val ERR_PAIR_EXPIRED = "err.pair_expired"
const val ERR_PAIR_RESTARTED = "err.pair_restarted"
/** Reused as-is: "the storage computer doesn't understand this request". */
const val ERR_UNSUPPORTED = "err.unsupported"
const val ERR_NOT_AUTHORIZED = "err.not_authorized"

/** NET-10: hello capability of a desktop that serves pair.status (router.rs). */
const val PAIR_STATUS_CAPABILITY = "pair.status.v1"
/** NET-10: card-fixed polling interval. */
const val PAIR_POLL_INTERVAL_MS = 5_000L
/** A single failed status RPC is not a dead pairing — the ledger entry
 *  lives on the desktop for minutes. Give up only after this many failures
 *  in a row (any answer resets the count). */
const val PAIR_STATUS_MAX_CONSECUTIVE_FAILURES = 3
/** Only if a desktop's ack carries no ttl_ms; mirrors TOKEN_TTL_MS. */
const val PAIR_FALLBACK_TTL_MS = 600_000L

/** NET-10: the one RPC seam the pairing state machine needs —
 *  [DaemonClient.call] in production, a fake in JVM tests. */
fun interface PairRpc {
    suspend fun call(method: String, params: JsonElement): Resp
}

/** NET-10: how one pairing request ended — every cause is its own branch. */
sealed class PairVerdict {
    data class Accepted(val accepted: PairAccepted) : PairVerdict()
    /** Owner said no, or the code was rejected on submit (invalid/used). */
    data class Denied(val msgKey: String) : PairVerdict()
    /** Nobody decided within the desktop's pending window. */
    data object Expired : PairVerdict()
    /** pair.status → not_found: the desktop service restarted and lost
     *  the request. Do not resend blindly; ask for a fresh code. */
    data object DesktopRestarted : PairVerdict()
    /** The desktop does not speak pair.status (no capability in hello). */
    data object DesktopTooOld : PairVerdict()
    /** The RPCs themselves kept failing (network / computer off). */
    data class Unreachable(val reason: String) : PairVerdict()
}

/**
 * NET-10 state machine: capability check → submit → poll pair.status.
 *
 * New phone + old desktop: an old desktop has no [PAIR_STATUS_CAPABILITY]
 * in hello → [PairVerdict.DesktopTooOld] (explicit "update the computer"),
 * never a silent timeout. A revoked phone's hello is denied, so it cannot
 * check first; it submits and judges by the reply shape (request_id = new
 * desktop; a PairAccepted within the cap = old desktop answered the
 * blocking shape; no answer = [PairVerdict.Unreachable]).
 */
suspend fun awaitPairVerdict(
    rpc: PairRpc,
    token: String,
    deviceName: String,
    pollIntervalMs: Long = PAIR_POLL_INTERVAL_MS,
    maxConsecutiveFailures: Int = PAIR_STATUS_MAX_CONSECUTIVE_FAILURES,
): PairVerdict {
    val hello = try {
        rpc.call(Methods.HELLO, buildJsonObject {})
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        return PairVerdict.Unreachable(e.toString())
    }
    if (hello.ok) {
        val caps = hello.result?.let {
            runCatching { ProtoJson.decodeFromJsonElement(Hello.serializer(), it) }.getOrNull()
        }?.capabilities.orEmpty()
        if (PAIR_STATUS_CAPABILITY !in caps) return PairVerdict.DesktopTooOld
    }

    val submit = try {
        rpc.call(
            Methods.PAIR_REQUEST,
            ProtoJson.encodeToJsonElement(
                PairRequest.serializer(),
                PairRequest(token = token, deviceName = deviceName, ackThenPoll = true),
            ),
        )
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        return PairVerdict.Unreachable(e.toString())
    }
    if (!submit.ok) return PairVerdict.Denied(submit.error?.msgKey ?: ERR_NOT_AUTHORIZED)
    val result = submit.result ?: return PairVerdict.DesktopTooOld
    val submitted = runCatching {
        ProtoJson.decodeFromJsonElement(PairSubmitted.serializer(), result)
    }.getOrNull()
    if (submitted == null || submitted.requestId.isBlank()) {
        // An old desktop ignored ack_then_poll and still answered inside
        // the cap with the blocking shape: that is a real join.
        val legacy = runCatching {
            ProtoJson.decodeFromJsonElement(PairAccepted.serializer(), result)
        }.getOrNull()
        return if (legacy != null && legacy.pairingEpoch.isNotBlank()) {
            PairVerdict.Accepted(legacy)
        } else {
            PairVerdict.DesktopTooOld
        }
    }

    val ttlMs = submitted.ttlMs.takeIf { it > 0 } ?: PAIR_FALLBACK_TTL_MS
    // One poll past the deadline so the desktop's own "expired" is what
    // we report, not a guess from our clock.
    val maxPolls = (ttlMs + pollIntervalMs - 1) / pollIntervalMs + 1
    val query = ProtoJson.encodeToJsonElement(
        PairStatusRequest.serializer(),
        PairStatusRequest(requestId = submitted.requestId),
    )
    var failures = 0
    var lastFailure = ""
    var polls = 0L
    while (polls < maxPolls) {
        polls += 1
        delay(pollIntervalMs)
        val reply: PairStatusReply? = try {
            val r = rpc.call(Methods.PAIR_STATUS, query)
            if (r.ok) {
                r.result?.let { ProtoJson.decodeFromJsonElement(PairStatusReply.serializer(), it) }
            } else {
                lastFailure = "pair.status: ${r.error?.msgKey}"
                null
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            lastFailure = e.toString()
            null
        }
        if (reply == null) {
            failures += 1
            if (failures >= maxConsecutiveFailures) return PairVerdict.Unreachable(lastFailure)
            continue
        }
        failures = 0
        when (reply.state) {
            "pending" -> Unit
            "accepted" -> {
                val payload = reply.accepted
                if (payload != null && payload.pairingEpoch.isNotBlank()) {
                    return PairVerdict.Accepted(payload)
                }
                // accepted without its payload is a malformed reply —
                // counts toward the failure budget, never a half-join.
                failures += 1
                lastFailure = "pair.status: accepted without payload"
                if (failures >= maxConsecutiveFailures) return PairVerdict.Unreachable(lastFailure)
            }
            "denied" -> return PairVerdict.Denied(reply.msgKey ?: ERR_NOT_AUTHORIZED)
            "expired" -> return PairVerdict.Expired
            "not_found" -> return PairVerdict.DesktopRestarted
        }
    }
    return PairVerdict.Expired
}

/** NET-10: verdict → what the pairing screen shows (one branch per cause). */
fun PairVerdict.toOutcome(join: (PairAccepted) -> Pairing): PairOutcome = when (this) {
    is PairVerdict.Accepted -> PairOutcome.Joined(join(accepted))
    is PairVerdict.Denied -> PairOutcome.Refused(msgKey)
    PairVerdict.Expired -> PairOutcome.Refused(ERR_PAIR_EXPIRED, ownerSaidNo = false)
    PairVerdict.DesktopRestarted -> PairOutcome.Refused(ERR_PAIR_RESTARTED, ownerSaidNo = false)
    PairVerdict.DesktopTooOld -> PairOutcome.Refused(ERR_UNSUPPORTED, ownerSaidNo = false)
    is PairVerdict.Unreachable -> PairOutcome.Failed(reason)
}

/**
 * Scan result → submit → poll until the owner decides (NET-10).
 */
suspend fun pairWithQr(
    client: DaemonClient,
    qr: String,
    deviceName: String,
    invalidCodeMessage: String = "This is not a P-Pass pairing code.",
    unparseableCodeMessage: String =
        "The pairing code cannot be parsed. Update P-Pass on both the computer and phone to the latest version.",
    storageDeviceNameFallback: String = "P-Pass storage",
): PairOutcome {
    val parsed = try {
        parsePairingQr(qr)
    } catch (e: Exception) {
        return PairOutcome.Failed(invalidCodeMessage)
    }
    // H-10b: 新 QR 只有 r=（relay URL）——从 node+relay 重建可连接地址；
    // 旧 QR 的 a= 完整解析仍兼容。
    val addr: PeerAddrParts = parsed.addr ?: parsed.relayUrl?.let {
        PeerAddrParts(parsed.nodeIdHex, it, emptyList())
    } ?: return PairOutcome.Failed(
        // FIX-T3: 升级顺序地雷——旧 APK（≤0.3.0-test.2）只认 a=，新码
        // 只带 r=；a=/r= 都缺 = 配对码无法解析。明确引导升级而非静默失败。
        unparseableCodeMessage
    )
    // 存储 token：旧码存原 a= 串；新码从 node+relay 重建（backup 的
    // parsePeerAddrToken 兼容）。
    val addrToken: String = parsed.addr?.let { qr.substringAfter("&a=", "") }
        ?: parsed.relayUrl?.let { buildAddrToken(parsed.nodeIdHex, it) }
        ?: ""

    // Already a member on this storage (same phone, the computer's
    // identity/address changed)? Then no pair.request is needed — and
    // it would be REFUSED (members can't re-apply). backup.begin is
    // member-gated: an ok means we're recognised; just re-save.
    try {
        val probe = withTimeout(20_000) {
            client.call(addr, Methods.BACKUP_BEGIN, buildJsonObject {})
        }
        if (probe.ok) {
            val hello = withTimeout(20_000) {
                client.call(addr, Methods.HELLO, buildJsonObject {})
            }
            val helloInfo = hello.result?.let {
                ProtoJson.decodeFromJsonElement(Hello.serializer(), it)
            }
            val name = helloInfo?.deviceName?.takeIf { it.isNotBlank() } ?: storageDeviceNameFallback
            return PairOutcome.Joined(
                Pairing(
                    daemonNodeId = parsed.nodeIdHex,
                    daemonAddrToken = addrToken,
                    storageDeviceName = name,
                    pairedAt = System.currentTimeMillis(),
                    pairingEpoch = helloInfo?.pairingEpoch.orEmpty(),
                )
            )
        }
    } catch (_: Exception) {
        // Not reachable or not recognised — fall through to pairing.
    }

    // NET-10: each RPC is a short control-plane call (DaemonClient.call's
    // own 15 s cap); the wait for the owner lives in the polling loop.
    val verdict = awaitPairVerdict(
        rpc = { method, params -> client.call(addr, method, params) },
        token = parsed.token,
        deviceName = deviceName,
    )
    return verdict.toOutcome { accepted ->
        Pairing(
            daemonNodeId = parsed.nodeIdHex,
            daemonAddrToken = addrToken,
            storageDeviceName = accepted.storageDeviceName,
            pairedAt = System.currentTimeMillis(),
            pairingEpoch = accepted.pairingEpoch,
        )
    }
}
