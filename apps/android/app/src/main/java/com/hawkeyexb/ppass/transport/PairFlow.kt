// T-052: the pairing conversation, camera-free — the scanner hands us a
// QR string; this turns it into a saved Pairing or a human-readable
// failure.
//
// NET-10 (#128): submitting is not waiting. pair.request (ack_then_poll)
// answers as soon as the desktop has queued the request; the owner's
// verdict is then read by polling pair.status every second (#1118), until the
// deadline the desktop itself sent back. The old shape held ONE RPC open
// until the owner clicked — but DaemonClient.call caps every round trip at
// 15 s (CONNECT_TIMEOUT_MS), so any owner slower than ~15 s turned into
// "could not reach the computer".
//
// #1118: pairing needs a code. After the user confirms "connect to this
// computer?", the phone invents a 6-digit code, commits to it with a PAKE
// message in pair.request (pake_a) and shows the code ONLY once the request
// was queued; the owner types it on the computer, the computer answers with
// pake_b, the phone proves it with pair.confirm and verifies the computer's
// proof before saving anything. All cryptography is the shared Rust kernel
// (PairPhone via uniffi); this file only drives the conversation.
//
// DEV-07 (#463): leaving the waiting screen (Cancel / back) cancels the
// coroutine polling here. That alone only changed the phone's screen — the
// desktop kept the request approvable for the whole pending window, and a
// later "Allow" wrote a device the phone never learned about. So on the way
// out we tell the desktop: pair.cancel(request_id).
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.ffi.PairPhone
import com.hawkeyexb.ppass.ffi.ParsedPairLink
import com.hawkeyexb.ppass.ffi.nodeFingerprint
import com.hawkeyexb.ppass.ffi.pairCodeGenerate
import com.hawkeyexb.ppass.ffi.parsePairLink
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.PairAccepted
import com.hawkeyexb.ppass.proto.PairConfirmRequest
import com.hawkeyexb.ppass.proto.PairRequest
import com.hawkeyexb.ppass.proto.PairStatusReply
import com.hawkeyexb.ppass.proto.PairStatusRequest
import com.hawkeyexb.ppass.proto.PairStatusState
import com.hawkeyexb.ppass.proto.PairSubmitted
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.proto.Reason
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.outdatedSideOf
import com.hawkeyexb.ppass.proto.reasonKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.buildJsonObject

sealed class PairOutcome {
    data class Joined(val pairing: Pairing) : PairOutcome()
    /**
     * The pairing ended without joining; [cause] names why (#1072: decided on the desktop's
     * `reason` / `pair.status` state, worded by the phone). [ownerSaidNo] = the owner clicked
     * "decline" on the computer; anything else (an invalid or used code, a lapsed request, …) is not
     * the computer saying no — NET-10 / 10-29 copy B6 keep those apart so the screen does not claim it.
     * [wireReason] = the desktop's raw reason when it maps to [PairRefusal.OTHER] (B13: the screen only
     * says "error code: generic", so the raw reason must reach the log); null otherwise.
     */
    data class Refused(val cause: PairRefusal, val wireReason: String? = null) : PairOutcome() {
        val ownerSaidNo: Boolean get() = cause == PairRefusal.DENIED
    }
    /** #1072: versions are incompatible — found at the hello, before any pairing request is sent. */
    data class NeedsUpdate(val side: OutdatedSide) : PairOutcome()
    /**
     * The pairing could not be carried out. #1264: [diagnostic] is for the log only (exception class,
     * close code, RPC reason — never on screen, tokens.json rule 10); [kind] picks the screen (10-29
     * copy B7: a scanned code that is not a P-Pass code is its own page, not "can't connect").
     */
    data class Failed(val diagnostic: String, val kind: PairFailure = PairFailure.UNREACHABLE) : PairOutcome()
}

/** 10-29 copy B7: why a pairing could not be carried out — one screen each. */
enum class PairFailure {
    /** The computer could not be reached (or anything else that went wrong on the way). */
    UNREACHABLE,
    /** What was scanned or pasted is not a P-Pass pairing code. */
    NOT_A_CODE,
    /** A P-Pass code with neither relay nor direct address (FIX-T3): only an update fixes it. */
    NO_ADDRESS,
}

/** #1072: why a pairing ended without joining (one phone-side wording each). */
enum class PairRefusal {
    /** `pair_token_invalid`: the code was wrong, used or expired on the desktop. */
    TOKEN_INVALID,
    /** `pair.status` = `denied`: the owner said no. */
    DENIED,
    /** Nobody decided within the desktop's pending window. */
    EXPIRED,
    /** `pair.status` = `not_found`: the desktop service restarted and lost the request. */
    DESKTOP_RESTARTED,
    /** #1118: `pair.status` = `failed` / `pair.confirm` → `pair_code_wrong`: the code did not match. */
    CODE_WRONG,
    /** #1118: the computer's key confirmation did not verify — nothing was saved. */
    PROOF_FAILED,
    /** #1264: the computer refused the connection itself (`not_paired` close at the handshake, before
     *  any request): its pairing window is shut — the QR code expired, was closed, or was already
     *  used. Not the owner's "no": scan a fresh code. */
    QR_EXPIRED,
    /** Any other reason, including one this build does not know. */
    OTHER,
}

/** #1072: a rejected pair.request → its cause; never looks at text. */
internal fun pairRefusalOf(reason: Reason): PairRefusal = when (reason) {
    Reason.PAIR_TOKEN_INVALID -> PairRefusal.TOKEN_INVALID
    Reason.PAIR_CODE_WRONG -> PairRefusal.CODE_WRONG
    else -> PairRefusal.OTHER
}

/** NET-10: hello capability of a desktop that serves pair.status (router.rs). */
const val PAIR_STATUS_CAPABILITY = "pair.status.v1"
/** DEV-07: hello capability of a desktop that accepts pair.cancel (router.rs). */
const val PAIR_CANCEL_CAPABILITY = "pair.cancel.v1"
/** DEV-07: how long leaving the waiting screen may spend telling the desktop.
 *  Best effort — the user has already moved on; DaemonClient's own 15 s cap
 *  is too long to hold a cancelled job open for. */
const val PAIR_CANCEL_BUDGET_MS = 5_000L
/** #1118: while the code is on screen the owner may type it any second — poll every second
 *  (owner decision; was 5 s). Used only for this step. */
const val PAIR_POLL_INTERVAL_MS = 1_000L
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
    /** Owner said no, or the code was rejected on submit (invalid/used). [wireReason]: see [PairOutcome.Refused]. */
    data class Denied(val cause: PairRefusal, val wireReason: String? = null) : PairVerdict()
    /** #1072: one side is too old for the other (hello, submit or status said so). */
    data class NeedsUpdate(val side: OutdatedSide) : PairVerdict()
    /** Nobody decided within the desktop's pending window. */
    data object Expired : PairVerdict()
    /** pair.status → not_found: the desktop service restarted and lost
     *  the request. Do not resend blindly; ask for a fresh code. */
    data object DesktopRestarted : PairVerdict()
    /** The desktop does not speak pair.status (no capability in hello). */
    data object DesktopTooOld : PairVerdict()
    /** The RPCs themselves kept failing (network / computer off). */
    data class Unreachable(val reason: String) : PairVerdict()
    /** #1118: the code typed on the computer did not match (`failed` state or `pair_code_wrong`). */
    data object CodeWrong : PairVerdict()
    /** #1118: the computer's key confirmation was missing/invalid — never save such a pairing. */
    data object ProofFailed : PairVerdict()
}

/** #1118: the phone's half of the code exchange — implemented by the uniffi `PairPhone`
 *  ([FfiPairPhone]) in production, by a fake in JVM tests. Throws on any protocol error. */
interface PairPhoneCore {
    /** The SPAKE2 message for `pair.request.pake_a` (hex). */
    fun pakeA(): String
    /** The desktop's `pake_b` → `confirm_a` (hex) for `pair.confirm`. Once only. */
    fun finish(pakeB: String): String
    /** The desktop's `confirm_b`; returns normally only if the desktop used the same code. */
    fun verify(confirmB: String)
}

/** #1118: everything user-facing or random about a pairing, injectable: the code, the PAKE session
 *  and showing the code. There is no "connect to this computer?" step: scanning is the intent to
 *  connect, and a swapped QR is caught by the code (it is only on this phone; the user types it
 *  into their own computer). */
interface PairCeremony {
    /** A fresh 6-digit code (shared Rust generator). */
    fun newCode(): String
    /** Start the PAKE session for [code] (token / node ids are the ceremony's own context). */
    fun start(code: String): PairPhoneCore
    /** Called ONLY after the request was queued ([PairSubmitted] received): show [code] with the
     *  computer it is for. [desktopName] = `hello.device_name`, or null when the hello gave none. */
    fun showCode(code: String, desktopName: String?)
}

/** #1051: how long the membership probe may take before we give up and
 *  fall back to normal pairing. */
const val MEMBER_PROBE_TIMEOUT_MS = 20_000L

/**
 * #1051: "am I already a member of this computer?" — one `hello`.
 * Member = the reply carries a non-empty `pairing_id` (the desktop sends
 * it only to a paired, non-revoked peer). Returns that [Hello], or null for
 * unpaired (no pairing id), revoked (hello denied), unparseable, timed out or
 * failed — every null means "go through normal pairing". Caller
 * cancellation still propagates.
 */
suspend fun probeMembership(
    rpc: PairRpc,
    timeoutMs: Long = MEMBER_PROBE_TIMEOUT_MS,
): Hello? {
    return try {
        val resp = withTimeoutOrNull(timeoutMs) { rpc.call(Methods.HELLO, buildJsonObject {}) }
            ?: return null
        if (!resp.ok) return null
        val hello = resp.result?.let {
            ProtoJson.decodeFromJsonElement(Hello.serializer(), it)
        } ?: return null
        hello.takeIf { !it.pairingId.isNullOrEmpty() }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }
}

/**
 * #1116 N1: the member shortcut (#1051) only for a computer this phone already finished pairing
 * with. Unknown computer ⇒ null without even asking it, so the caller goes through the code.
 */
suspend fun trustedMembership(knownDesktop: Boolean, rpc: PairRpc): Hello? =
    if (knownDesktop) probeMembership(rpc) else null

/**
 * NET-10 state machine: capability check → "connect to this computer?" (#1118) → submit with
 * the PAKE commitment → show the code → poll pair.status / answer pair.confirm.
 *
 * New phone + old desktop: an old desktop has no [PAIR_STATUS_CAPABILITY]
 * in hello → [PairVerdict.DesktopTooOld] (explicit "update the computer"),
 * never a silent timeout. A revoked phone's hello is denied, so it cannot
 * check first; it submits and judges by the reply shape (request_id = new
 * desktop; no answer = [PairVerdict.Unreachable]). #1118: a desktop that answers with the
 * old blocking [PairAccepted] never checked the code — that is [PairVerdict.DesktopTooOld],
 * not a join.
 */
suspend fun awaitPairVerdict(
    rpc: PairRpc,
    token: String,
    deviceName: String,
    ceremony: PairCeremony,
    pollIntervalMs: Long = PAIR_POLL_INTERVAL_MS,
    maxConsecutiveFailures: Int = PAIR_STATUS_MAX_CONSECUTIVE_FAILURES,
): PairVerdict {
    val hello = try {
        rpc.call(Methods.HELLO, buildJsonObject {})
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        if (pairWindowClosed(e)) return PairVerdict.Denied(PairRefusal.QR_EXPIRED)
        return PairVerdict.Unreachable(e.toString())
    }
    // DEV-07: withdraw only where the desktop says it understands it (an
    // older desktop denies the unknown method and logs a denial). A revoked
    // phone's hello is denied, so it cannot know — it tries anyway.
    var mayWithdraw = true
    var desktopName: String? = null
    // #1072: version first — an incompatible desktop gets no pairing request at all.
    if (!hello.ok) hello.error?.let { outdatedSideOf(it.reasonKind) }?.let { return PairVerdict.NeedsUpdate(it) }
    if (hello.ok) {
        val parsed = hello.result?.let {
            runCatching { ProtoJson.decodeFromJsonElement(Hello.serializer(), it) }.getOrNull()
        }
        val caps = parsed?.capabilities.orEmpty()
        if (PAIR_STATUS_CAPABILITY !in caps) return PairVerdict.DesktopTooOld
        mayWithdraw = PAIR_CANCEL_CAPABILITY in caps
        desktopName = parsed?.deviceName?.takeIf { it.isNotBlank() }
    }

    // #1118: no question after the scan — straight to the request; the code page names the computer.
    val code = ceremony.newCode()
    val phone = ceremony.start(code)

    val submit = try {
        rpc.call(
            Methods.PAIR_REQUEST,
            ProtoJson.encodeToJsonElement(
                PairRequest.serializer(),
                PairRequest(token = token, deviceName = deviceName, ackThenPoll = true, pakeA = phone.pakeA()),
            ),
        )
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        if (pairWindowClosed(e)) return PairVerdict.Denied(PairRefusal.QR_EXPIRED)
        return PairVerdict.Unreachable(e.toString())
    }
    if (!submit.ok) {
        val reason = submit.error?.reasonKind ?: Reason.UNKNOWN
        outdatedSideOf(reason)?.let { return PairVerdict.NeedsUpdate(it) }
        val cause = pairRefusalOf(reason)
        // B13: a reason the phone has no wording for keeps its raw form for the log (the caller logs it).
        val wire = submit.error?.let { "${it.code}/${it.reason}" }
        return PairVerdict.Denied(cause, wireReason = wire.takeIf { cause == PairRefusal.OTHER })
    }
    val result = submit.result ?: return PairVerdict.DesktopTooOld
    val submitted = runCatching {
        ProtoJson.decodeFromJsonElement(PairSubmitted.serializer(), result)
    }.getOrNull()
    // An old desktop ignored ack_then_poll / pake_a and answered with the blocking shape (or
    // garbage): it never verified a code, so this is no join.
    if (submitted == null || submitted.requestId.isBlank()) return PairVerdict.DesktopTooOld

    // #1118: the request is queued on the desktop — only now may the code be shown.
    ceremony.showCode(code, desktopName)

    val ttlMs = submitted.ttlMs.takeIf { it > 0 } ?: PAIR_FALLBACK_TTL_MS
    // One poll past the deadline so the desktop's own "expired" is what
    // we report, not a guess from our clock.
    val maxPolls = (ttlMs + pollIntervalMs - 1) / pollIntervalMs + 1
    val query = ProtoJson.encodeToJsonElement(
        PairStatusRequest.serializer(),
        PairStatusRequest(requestId = submitted.requestId),
    )
    try {
        return pollPairStatus(rpc, query, submitted.requestId, phone, pollIntervalMs, maxPolls, maxConsecutiveFailures)
    } catch (e: CancellationException) {
        // The user left the waiting screen. Tell the desktop before the job
        // dies, so the owner's queue row can no longer be approved. Runs
        // outside the cancellation, bounded, and never throws.
        if (mayWithdraw) {
            withContext(NonCancellable) {
                withTimeoutOrNull(PAIR_CANCEL_BUDGET_MS) {
                    try {
                        rpc.call(Methods.PAIR_CANCEL, query)
                    } catch (_: Exception) {
                        // Best effort: an unreachable desktop still ends
                        // the request at its own pending deadline.
                    }
                }
            }
        }
        throw e
    }
}

/**
 * #1219：等配对结果时，正在配对的那台电脑在握手时就用「未配对」关闭码（401 / 410）关掉连接。
 * 桌面只在「二维码开着，或这台手机自己的申请还没结束」时放行未配对的手机（#1122 准入）；
 * 申请已提交、轮询还在继续，却被拒在握手——说明桌面手里已经没有这条申请（服务重启，内存里的待办没了），
 * 与 `pair.status` 应答 NOT_FOUND 同义。[rpc] 只连这一台电脑，关闭方经 TLS 认证就是它。
 */
internal fun pairRequestGone(e: Exception): Boolean = closedAsNotPaired(e)

/**
 * #1264：还没提交申请（hello / pair.request）就被这台电脑在握手时用「未配对」关闭码拒掉——它的配对窗口
 * 已经关了：二维码过期、被关掉，或已被用掉（#1122 准入，原因只记在电脑日志里）。这不是网络问题，
 * 出路是在电脑上刷新二维码后重扫。[rpc] 只连二维码里那台电脑，关闭方经 TLS 认证就是它。
 */
internal fun pairWindowClosed(e: Exception): Boolean = closedAsNotPaired(e)

private fun closedAsNotPaired(e: Exception): Boolean =
    e is PeerClosedException && DesktopCloseCodes.meansNotPaired(e.code)

/** One reply's meaning to the poll loop: done, or keep waiting, or a malformed reply. */
private sealed class Step {
    data class Done(val verdict: PairVerdict) : Step()
    data object Continue : Step()
    data class Malformed(val why: String) : Step()
}

private suspend fun pollPairStatus(
    rpc: PairRpc,
    query: JsonElement,
    requestId: String,
    phone: PairPhoneCore,
    pollIntervalMs: Long,
    maxPolls: Long,
    maxConsecutiveFailures: Int,
): PairVerdict {
    var failures = 0
    var lastFailure = ""
    var polls = 0L
    // #1118: cA is computed once (PairPhone.finish is single-use) and re-sent verbatim until
    // the desktop's accepted reply arrives — pair.confirm is idempotent for the same cA.
    var confirmA: String? = null

    /** The meaning of any reply that carries a [PairStatusReply] (pair.status or pair.confirm). */
    fun judge(reply: PairStatusReply): Step = when (reply.state) {
        PairStatusState.PENDING -> Step.Continue
        PairStatusState.ACCEPTED -> {
            val payload = reply.accepted
            val confirmB = reply.confirmB
            when {
                payload == null || payload.pairingId.isBlank() ->
                    Step.Malformed("pair.status: accepted without payload")
                // accepted without the desktop's proof is a malformed reply — never a half-join.
                confirmB.isNullOrBlank() -> Step.Malformed("pair.status: accepted without confirm_b")
                // The desktop is accepted but we never sent cA: it skipped the code. No proof, no join.
                confirmA == null -> Step.Done(PairVerdict.ProofFailed)
                else -> Step.Done(
                    try {
                        phone.verify(confirmB)
                        PairVerdict.Accepted(payload)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        PairVerdict.ProofFailed
                    },
                )
            }
        }
        PairStatusState.DENIED -> Step.Done(PairVerdict.Denied(PairRefusal.DENIED))
        PairStatusState.EXPIRED -> Step.Done(PairVerdict.Expired)
        PairStatusState.NOT_FOUND -> Step.Done(PairVerdict.DesktopRestarted)
        PairStatusState.FAILED -> Step.Done(PairVerdict.CodeWrong)
        else -> Step.Continue
    }

    while (polls < maxPolls) {
        polls += 1
        delay(pollIntervalMs)
        val reply: PairStatusReply? = try {
            val r = rpc.call(Methods.PAIR_STATUS, query)
            if (r.ok) {
                r.result?.let { ProtoJson.decodeFromJsonElement(PairStatusReply.serializer(), it) }
            } else {
                r.error?.let { outdatedSideOf(it.reasonKind) }?.let { return PairVerdict.NeedsUpdate(it) }
                lastFailure = "pair.status rejected: ${r.error?.reason}"
                null
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (pairRequestGone(e)) return PairVerdict.DesktopRestarted
            lastFailure = e.toString()
            null
        }
        if (reply == null) {
            failures += 1
            if (failures >= maxConsecutiveFailures) return PairVerdict.Unreachable(lastFailure)
            continue
        }
        var roundFailed = false
        var step = judge(reply)

        // #1118: the owner typed the code → the desktop's pake_b is here. Finish (once), then
        // pair.confirm; resend the same cA on every later poll until it goes through.
        val pakeB = reply.pakeB
        if (step is Step.Continue && !pakeB.isNullOrBlank()) {
            val cA = confirmA ?: try {
                phone.finish(pakeB)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // A malformed pake_b spends the PAKE session; no second try is possible.
                return PairVerdict.ProofFailed
            }
            confirmA = cA
            val confirmReply: PairStatusReply? = try {
                val r = rpc.call(
                    Methods.PAIR_CONFIRM,
                    ProtoJson.encodeToJsonElement(
                        PairConfirmRequest.serializer(),
                        PairConfirmRequest(requestId = requestId, confirmA = cA),
                    ),
                )
                if (r.ok) {
                    r.result?.let { ProtoJson.decodeFromJsonElement(PairStatusReply.serializer(), it) }
                        .also { if (it == null) lastFailure = "pair.confirm: empty reply" }
                } else {
                    val reason = r.error?.reasonKind ?: Reason.UNKNOWN
                    outdatedSideOf(reason)?.let { return PairVerdict.NeedsUpdate(it) }
                    if (reason == Reason.PAIR_CODE_WRONG) return PairVerdict.CodeWrong
                    lastFailure = "pair.confirm rejected: ${r.error?.reason}"
                    null
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (pairRequestGone(e)) return PairVerdict.DesktopRestarted
                lastFailure = e.toString()
                null
            }
            if (confirmReply == null) {
                roundFailed = true
            } else {
                step = judge(confirmReply)
            }
        }

        when (step) {
            is Step.Done -> return step.verdict
            is Step.Malformed -> {
                lastFailure = step.why
                roundFailed = true
            }
            Step.Continue -> Unit
        }
        if (roundFailed) {
            failures += 1
            if (failures >= maxConsecutiveFailures) return PairVerdict.Unreachable(lastFailure)
        } else {
            failures = 0
        }
    }
    return PairVerdict.Expired
}

/** NET-10: verdict → what the pairing screen shows (one branch per cause). */
fun PairVerdict.toOutcome(join: (PairAccepted) -> Pairing): PairOutcome = when (this) {
    is PairVerdict.Accepted -> PairOutcome.Joined(join(accepted))
    is PairVerdict.Denied -> PairOutcome.Refused(cause, wireReason)
    PairVerdict.Expired -> PairOutcome.Refused(PairRefusal.EXPIRED)
    PairVerdict.DesktopRestarted -> PairOutcome.Refused(PairRefusal.DESKTOP_RESTARTED)
    // A desktop without pair.status predates the current pairing flow: the computer needs updating.
    PairVerdict.DesktopTooOld -> PairOutcome.NeedsUpdate(OutdatedSide.DESKTOP)
    is PairVerdict.NeedsUpdate -> PairOutcome.NeedsUpdate(side)
    is PairVerdict.Unreachable -> PairOutcome.Failed(reason)
    PairVerdict.CodeWrong -> PairOutcome.Refused(PairRefusal.CODE_WRONG)
    PairVerdict.ProofFailed -> PairOutcome.Refused(PairRefusal.PROOF_FAILED)
}

/**
 * NET-28 (#454): the pairing wait screen's whole job — bind the endpoint,
 * then pair. Any throw lands on [PairOutcome.Failed] carrying the
 * throwable's class and message, so "the phone's endpoint never came up"
 * ([EndpointBindTimeoutException]) and "the computer cannot be reached"
 * ([DaemonUnreachableException]) read differently in the log (#1264: never on screen).
 * Catches Throwable, not Exception: a missing native lib
 * (UnsatisfiedLinkError) must land on the trouble screen, never crash the
 * app (real-phone T-052 lesson).
 */
suspend fun bindThenPair(bind: suspend () -> Unit, pair: suspend () -> PairOutcome): PairOutcome =
    try {
        bind()
        pair()
    } catch (t: Throwable) {
        PairOutcome.Failed(t.toString())
    }

/** #1118: the computer on the code page: the name the computer reports and the human-readable
 *  identity (`AB12 CD34`) of the QR's NodeId — the same one the desktop shows under its QR code. */
data class PairDesktopIdentity(val name: String, val fingerprint: String)

/** #1118: production [PairPhoneCore] — the shared Rust kernel through uniffi. */
internal class FfiPairPhone(private val inner: PairPhone) : PairPhoneCore {
    override fun pakeA(): String = inner.pakeA()
    override fun finish(pakeB: String): String = inner.finish(pakeB)
    override fun verify(confirmB: String) = inner.verify(confirmB)
}

/** #1118: production [PairCeremony] for one scan: code and PAKE from the shared Rust kernel. */
internal class FfiPairCeremony(
    private val token: String,
    private val phoneNode: String,
    private val deskNode: String,
    private val fallbackName: String,
    private val onCode: (code: String, desktop: PairDesktopIdentity, phoneNodeId: String) -> Unit,
    /** Injectable only for tests; always applied to the QR's node (the NodeId actually dialled). */
    private val fingerprintOf: (String) -> String = ::nodeFingerprint,
) : PairCeremony {
    // The identity shown is computed HERE, by this phone, from the QR's node — never taken from
    // anything the computer says. The name is the computer's own claim: a label only (and it is
    // never logged — it may hold a real name).
    override fun newCode(): String = pairCodeGenerate()

    override fun start(code: String): PairPhoneCore =
        FfiPairPhone(PairPhone.start(code, token, phoneNode, deskNode))

    override fun showCode(code: String, desktopName: String?) =
        onCode(code, PairDesktopIdentity(desktopName ?: fallbackName, fingerprintOf(deskNode)), phoneNode)
}

/**
 * Scan result → submit → show the code with the computer's name and identity ([onCode], only
 * after the request was queued) → poll until the owner decides (NET-10, #1118). No question in
 * between. Automation logs the code in [onCode].
 */
suspend fun pairWithQr(
    client: DaemonClient,
    qr: String,
    deviceName: String,
    onCode: (code: String, desktop: PairDesktopIdentity, phoneNodeId: String) -> Unit,
    storageDeviceNameFallback: String = "P-Pass storage",
    knownDesktop: (nodeIdHex: String) -> Boolean = { false },
    /** Injectable only for tests; production is the shared Rust parser. */
    parseLink: (String) -> ParsedPairLink = ::parsePairLink,
): PairOutcome {
    // #1149: the one strict parser lives in the Rust core (`transport::parse_pair_link`, shared with
    // iOS and the dev testclient): node = 64 hex, t = the daemon's 24-hex token, relay = https://
    // plus a valid host name. A malformed code is "not a P-Pass pairing code" and nothing below
    // runs — no dial, no local write.
    val parsed = try {
        parseLink(qr)
    } catch (e: Exception) {
        return PairOutcome.Failed("not a pairing code: ${e.javaClass.simpleName}", PairFailure.NOT_A_CODE)
    }
    // The core rebuilds the dialable address from node + relay (or the legacy full `a=` address);
    // the stored token has the same JSON shape backup's `parsePeerAddrToken` reads.
    val addrToken: String = parsed.peerToken
    val addr: PeerAddrParts = try {
        parsePeerAddrToken(addrToken)
    } catch (e: Exception) {
        return PairOutcome.Failed("not a pairing code: ${e.javaClass.simpleName}", PairFailure.NOT_A_CODE)
    }
    // FIX-T3: a code with neither relay nor direct address (node + token only) cannot be dialled
    // from this phone — point at upgrading instead of failing silently.
    if (addr.relayUrl == null && addr.directAddresses.isEmpty()) {
        return PairOutcome.Failed("pairing code has no dialable address", PairFailure.NO_ADDRESS)
    }

    // Already a member on this storage (same phone, the computer's
    // address changed)? Then no pair.request is needed — and it would be
    // REFUSED (members can't re-apply). #1051: hello is the probe; the
    // desktop returns pairing_id only to a paired, non-revoked member.
    // Unpaired / revoked / unreachable → pair normally.
    //
    // #1116 N1: "you're a member" is the computer's own claim — only believe it from a computer this
    // phone has already finished pairing with (same NodeId, like SSH known_hosts). A QR pointing at
    // any other node goes through the code, otherwise a forged QR could claim membership and
    // skip the #1118 code entirely.
    val member = trustedMembership(
        knownDesktop = knownDesktop(parsed.nodeId),
        rpc = { method, params -> client.call(addr, method, params) },
    )
    if (member != null) {
        val name = member.deviceName.takeIf { it.isNotBlank() } ?: storageDeviceNameFallback
        return PairOutcome.Joined(
            Pairing(
                daemonNodeId = parsed.nodeId,
                daemonAddrToken = addrToken,
                storageDeviceName = name,
                pairedAt = System.currentTimeMillis(),
                pairingId = member.pairingId.orEmpty(),
            )
        )
    }

    // NET-10: each RPC is a short control-plane call (DaemonClient.call's
    // own 15 s cap); the wait for the owner lives in the polling loop.
    val phoneNode = client.nodeIdHex() ?: error("the phone's endpoint has no NodeId")
    val verdict = awaitPairVerdict(
        rpc = { method, params -> client.call(addr, method, params) },
        token = parsed.token,
        deviceName = deviceName,
        ceremony = FfiPairCeremony(
            token = parsed.token,
            phoneNode = phoneNode,
            deskNode = parsed.nodeId,
            fallbackName = storageDeviceNameFallback,
            onCode = onCode,
        ),
    )
    return verdict.toOutcome { accepted ->
        Pairing(
            daemonNodeId = parsed.nodeId,
            daemonAddrToken = addrToken,
            storageDeviceName = accepted.storageDeviceName,
            pairedAt = System.currentTimeMillis(),
            pairingId = accepted.pairingId,
        )
    }
}
