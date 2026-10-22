// #1118: the pairing-code state machine, driven through the real [awaitPairVerdict] with a scripted
// desktop and a fake PAKE core (the native kernel is covered by the live-daemon tests). Virtual time
// plays the owner's minutes.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.PairAccepted
import com.hawkeyexb.ppass.proto.PairConfirmRequest
import com.hawkeyexb.ppass.proto.PairRequest
import com.hawkeyexb.ppass.proto.PairStatusReply
import com.hawkeyexb.ppass.proto.PairStatusState
import com.hawkeyexb.ppass.proto.PairSubmitted
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.RespError
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairCodeFlowTest {

    private val requestId = "r".repeat(32)
    private val accepted = PairAccepted(storageDeviceName = "Home PC", pairingId = "e".repeat(32))
    private val pakeB = "bb".repeat(33)
    private val confirmB = "cb".repeat(32)

    private fun ok(v: JsonElement) = Resp(id = "x", ok = true, result = v)
    private fun reply(r: PairStatusReply) = ok(ProtoJson.encodeToJsonElement(PairStatusReply.serializer(), r))
    private fun pending() = PairStatusReply(state = PairStatusState.PENDING)
    private fun pendingWithPakeB() = PairStatusReply(state = PairStatusState.PENDING, pakeB = pakeB)
    private fun acceptedWithProof() =
        PairStatusReply(state = PairStatusState.ACCEPTED, accepted = accepted, confirmB = confirmB)

    /** Scripted desktop; every RPC lands in [log] (shared with the ceremony) and [statusTimes]. */
    private class Desk(
        val scope: TestScope,
        val log: MutableList<String>,
        val helloName: String? = "Studio Mac",
        val submit: () -> Resp,
        val status: (n: Int, atMs: Long) -> Resp,
        val confirm: (n: Int, req: PairConfirmRequest) -> Resp,
    ) : PairRpc {
        val statusTimes = mutableListOf<Long>()
        val confirms = mutableListOf<PairConfirmRequest>()
        var submitted: PairRequest? = null
        private fun ok(v: JsonElement) = Resp(id = "x", ok = true, result = v)

        override suspend fun call(method: String, params: JsonElement): Resp {
            log += "rpc:$method"
            return when (method) {
                Methods.HELLO -> Resp(
                    id = "h", ok = true,
                    result = ProtoJson.encodeToJsonElement(
                        Hello.serializer(),
                        Hello(
                            capabilities = listOf(PAIR_STATUS_CAPABILITY, PAIR_CANCEL_CAPABILITY),
                            deviceName = helloName.orEmpty(),
                        ),
                    ),
                )
                Methods.PAIR_REQUEST -> {
                    submitted = ProtoJson.decodeFromJsonElement(PairRequest.serializer(), params)
                    submit()
                }
                Methods.PAIR_STATUS -> {
                    statusTimes += scope.currentTime
                    status(statusTimes.size, scope.currentTime)
                }
                Methods.PAIR_CONFIRM -> {
                    val req = ProtoJson.decodeFromJsonElement(PairConfirmRequest.serializer(), params)
                    confirms += req
                    confirm(confirms.size, req)
                }
                Methods.PAIR_CANCEL -> ok(ProtoJson.encodeToJsonElement(PairStatusReply.serializer(), PairStatusReply(state = PairStatusState.EXPIRED)))
                else -> error("unexpected $method")
            }
        }
    }

    private fun queued() = ok(
        ProtoJson.encodeToJsonElement(
            PairSubmitted.serializer(),
            PairSubmitted(accepted = true, requestId = requestId, ttlMs = 600_000),
        ),
    )

    private fun TestScope.desk(
        log: MutableList<String>,
        helloName: String? = "Studio Mac",
        submit: () -> Resp = { queued() },
        status: (Int, Long) -> Resp = { _, _ -> reply(pending()) },
        confirm: (Int, PairConfirmRequest) -> Resp = { _, _ -> reply(acceptedWithProof()) },
    ) = Desk(this, log, helloName, submit, status, confirm)

    private fun codeWrongError() = Resp(id = "c", ok = false, error = RespError("NOT_AUTHORIZED", "pair_code_wrong"))

    // ── 1. a refused submit never shows the code ──

    @Test
    fun refusedSubmit_neverShowsTheCode() = runTest {
        val log = mutableListOf<String>()
        val ceremony = FakeCeremony(events = log)
        val desk = desk(log, submit = { Resp(id = "s", ok = false, error = RespError("NOT_AUTHORIZED", "pair_token_invalid")) })
        assertEquals(PairVerdict.Denied(PairRefusal.TOKEN_INVALID), awaitPairVerdict(desk, "t", "d", ceremony))
        assertTrue("code leaked after a refused submit: $log", log.none { it.startsWith("showCode") })
        assertTrue(desk.statusTimes.isEmpty())
    }

    @Test
    fun theCodeAppearsOnlyAfterTheSubmitWasAnswered_andBeforeTheFirstPoll() = runTest {
        val log = mutableListOf<String>()
        val ceremony = FakeCeremony(events = log)
        val desk = desk(log, status = { _, _ -> reply(PairStatusReply(state = PairStatusState.DENIED)) })
        awaitPairVerdict(desk, "t", "d", ceremony)
        assertEquals(
            listOf(
                "rpc:hello", "confirmDesktop", "newCode", "start:123456",
                "rpc:pair.request", "showCode:123456", "rpc:pair.status",
            ),
            log,
        )
        assertEquals("pake_a goes out in the request", ceremony.phone.pakeA, desk.submitted!!.pakeA)
        assertEquals(true, desk.submitted!!.ackThenPoll)
    }

    @Test
    fun aSubmitThatNeverAnswered_neverShowsTheCode() = runTest {
        val log = mutableListOf<String>()
        val ceremony = FakeCeremony(events = log)
        val desk = desk(log, submit = { throw DaemonUnreachableException("gone") })
        assertTrue(awaitPairVerdict(desk, "t", "d", ceremony) is PairVerdict.Unreachable)
        assertTrue(log.none { it.startsWith("showCode") })
    }

    // ── 2. pake_b gates finish and pair.confirm ──

    @Test
    fun finishAndConfirm_happenOnlyOnceTheDesktopsPakeBAppears() = runTest {
        val log = mutableListOf<String>()
        val phone = FakePairPhone()
        val desk = desk(log, status = { n, _ -> reply(if (n <= 5) pending() else pendingWithPakeB()) })
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(phone = phone, events = log))
        assertEquals(PairVerdict.Accepted(accepted), verdict)
        assertEquals(6, desk.statusTimes.size)
        // Nothing was finished or confirmed during the five pending polls: the first pair.confirm
        // comes right after the sixth status reply.
        assertEquals(
            listOf("rpc:pair.status", "rpc:pair.confirm"),
            log.subList(log.lastIndexOf("rpc:pair.status") , log.size),
        )
        assertEquals(1, log.count { it == "rpc:pair.confirm" })
        assertEquals(listOf("finish:$pakeB", "verify:$confirmB"), phone.calls)
        assertEquals(PairConfirmRequest(requestId = requestId, confirmA = phone.confirmA), desk.confirms.single())
    }

    @Test
    fun pendingWithoutPakeB_neverFinishesOrConfirms() = runTest {
        val log = mutableListOf<String>()
        val phone = FakePairPhone()
        val desk = desk(log, status = { n, _ -> reply(if (n < 30) pending() else PairStatusReply(state = PairStatusState.EXPIRED)) })
        assertEquals(PairVerdict.Expired, awaitPairVerdict(desk, "t", "d", FakeCeremony(phone = phone, events = log)))
        assertTrue(phone.calls.isEmpty())
        assertTrue(desk.confirms.isEmpty())
    }

    // ── 3. a desktop proof that does not verify is never saved ──

    @Test
    fun confirmBThatFailsVerification_isNotAJoin() = runTest {
        val log = mutableListOf<String>()
        val phone = FakePairPhone(verifyOk = false)
        val desk = desk(log, status = { _, _ -> reply(pendingWithPakeB()) })
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(phone = phone, events = log))
        assertEquals(PairVerdict.ProofFailed, verdict)
        val outcome = verdict.toOutcome { error("a pairing must not be built from an unverified desktop") }
        assertEquals(PairOutcome.Refused(PairRefusal.PROOF_FAILED), outcome)
        assertEquals("verify was actually asked", "verify:$confirmB", phone.calls.last())
    }

    @Test
    fun acceptedViaStatusWithBadProof_isNotAJoin() = runTest {
        // pair.confirm's reply was lost; the status poll then reports accepted with a bad cB.
        val log = mutableListOf<String>()
        val phone = FakePairPhone(verifyOk = false)
        val desk = desk(
            log,
            status = { n, _ -> reply(if (n == 1) pendingWithPakeB() else acceptedWithProof()) },
            confirm = { _, _ -> throw DaemonUnreachableException("reply lost") },
        )
        assertEquals(PairVerdict.ProofFailed, awaitPairVerdict(desk, "t", "d", FakeCeremony(phone = phone, events = log)))
    }

    @Test
    fun aMalformedPakeB_endsTheSession_andSendsNoConfirm() = runTest {
        val log = mutableListOf<String>()
        val desk = desk(log, status = { _, _ -> reply(pendingWithPakeB()) })
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(phone = FakePairPhone(finishFails = true), events = log))
        assertEquals(PairVerdict.ProofFailed, verdict)
        assertTrue(desk.confirms.isEmpty())
    }

    // ── 4. wrong code lands on "the code did not match" ──

    @Test
    fun pairCodeWrongOnConfirm_isCodeWrong() = runTest {
        val log = mutableListOf<String>()
        val desk = desk(log, status = { _, _ -> reply(pendingWithPakeB()) }, confirm = { _, _ -> codeWrongError() })
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(events = log))
        assertEquals(PairVerdict.CodeWrong, verdict)
        assertEquals(PairOutcome.Refused(PairRefusal.CODE_WRONG), verdict.toOutcome { error("no join") })
    }

    @Test
    fun failedState_isCodeWrong() = runTest {
        val log = mutableListOf<String>()
        val desk = desk(log, status = { n, _ -> reply(if (n < 3) pending() else PairStatusReply(state = PairStatusState.FAILED)) })
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(events = log))
        assertEquals(PairVerdict.CodeWrong, verdict)
        assertEquals(PairOutcome.Refused(PairRefusal.CODE_WRONG), verdict.toOutcome { error("no join") })
    }

    @Test
    fun pairCodeWrongErrorReason_mapsToItsOwnRefusal() {
        assertEquals(PairRefusal.CODE_WRONG, pairRefusalOf(com.hawkeyexb.ppass.proto.Reason.PAIR_CODE_WRONG))
        assertEquals(
            com.hawkeyexb.ppass.R.string.pair_refused_detail_code_wrong,
            com.hawkeyexb.ppass.ui.pairRefusalDetailRes(PairRefusal.CODE_WRONG),
        )
        assertEquals(
            com.hawkeyexb.ppass.R.string.pair_desktop_proof_failed,
            com.hawkeyexb.ppass.ui.pairRefusalDetailRes(PairRefusal.PROOF_FAILED),
        )
    }

    // ── 5. polling is one second, from the first poll on ──

    @Test
    fun pollingIntervalIsOneSecond() = runTest {
        val log = mutableListOf<String>()
        val desk = desk(log, status = { n, _ -> reply(if (n < 4) pending() else PairStatusReply(state = PairStatusState.DENIED)) })
        awaitPairVerdict(desk, "t", "d", FakeCeremony(events = log))
        assertEquals(1_000L, PAIR_POLL_INTERVAL_MS)
        assertEquals(listOf(1_000L, 2_000L, 3_000L, 4_000L), desk.statusTimes)
    }

    // ── 6. accepted without the desktop's proof is not a join ──

    @Test
    fun acceptedWithoutConfirmB_isNeverAJoin() = runTest {
        val log = mutableListOf<String>()
        val phone = FakePairPhone()
        val desk = desk(
            log,
            status = { n, _ ->
                reply(if (n == 1) pendingWithPakeB() else PairStatusReply(state = PairStatusState.ACCEPTED, accepted = accepted))
            },
            confirm = { _, _ -> throw DaemonUnreachableException("reply lost") },
        )
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(phone = phone, events = log))
        assertTrue("accepted without confirm_b must not join: $verdict", verdict is PairVerdict.Unreachable)
        assertTrue("never verified anything", phone.calls.none { it.startsWith("verify") })
    }

    @Test
    fun confirmReplyAcceptedWithoutConfirmB_isNeverAJoin() = runTest {
        val log = mutableListOf<String>()
        val desk = desk(
            log,
            status = { _, _ -> reply(pendingWithPakeB()) },
            confirm = { _, _ -> reply(PairStatusReply(state = PairStatusState.ACCEPTED, accepted = accepted)) },
        )
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(events = log))
        assertTrue("$verdict", verdict is PairVerdict.Unreachable)
    }

    @Test
    fun acceptedBeforeAnyPakeB_isNoJoin_theCodeWasSkipped() = runTest {
        val log = mutableListOf<String>()
        val desk = desk(log, status = { _, _ -> reply(acceptedWithProof()) })
        val phone = FakePairPhone()
        assertEquals(PairVerdict.ProofFailed, awaitPairVerdict(desk, "t", "d", FakeCeremony(phone = phone, events = log)))
        assertTrue("verify must not even be asked without a finished exchange", phone.calls.isEmpty())
    }

    // ── confirm retries: same cA, counted against the failure budget ──

    @Test
    fun aLostConfirm_isResentWithTheSameConfirmA_andFinishRunsOnce() = runTest {
        val log = mutableListOf<String>()
        val phone = FakePairPhone()
        val desk = desk(
            log,
            status = { _, _ -> reply(pendingWithPakeB()) },
            confirm = { n, _ -> if (n == 1) throw DaemonUnreachableException("blip") else reply(acceptedWithProof()) },
        )
        assertEquals(PairVerdict.Accepted(accepted), awaitPairVerdict(desk, "t", "d", FakeCeremony(phone = phone, events = log)))
        assertEquals(2, desk.confirms.size)
        assertEquals(desk.confirms[0], desk.confirms[1])
        assertEquals(1, phone.calls.count { it.startsWith("finish") })
    }

    @Test
    fun confirmFailuresCountAgainstTheBudget_evenThoughStatusKeepsAnswering() = runTest {
        val log = mutableListOf<String>()
        val desk = desk(
            log,
            status = { _, _ -> reply(pendingWithPakeB()) },
            confirm = { _, _ -> Resp(id = "c", ok = false, error = RespError("INTERNAL", "internal")) },
        )
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(events = log))
        assertTrue("$verdict", verdict is PairVerdict.Unreachable)
        assertEquals(PAIR_STATUS_MAX_CONSECUTIVE_FAILURES, desk.confirms.size)
    }

    // ── the "connect to this computer?" step ──

    @Test
    fun decliningTheComputer_sendsNoPairRequest_andIsNotAFailure() = runTest {
        val log = mutableListOf<String>()
        val desk = desk(log)
        val verdict = awaitPairVerdict(desk, "t", "d", FakeCeremony(connect = false, events = log))
        assertEquals(PairVerdict.Cancelled, verdict)
        assertEquals(PairOutcome.Cancelled, verdict.toOutcome { error("no join") })
        assertEquals(listOf("rpc:hello", "confirmDesktop"), log)
    }

    @Test
    fun theComputersNameComesFromTheHello_andFallsBackWhenAbsent() = runTest {
        val log = mutableListOf<String>()
        val named = FakeCeremony(events = log)
        awaitPairVerdict(desk(log, status = { _, _ -> reply(PairStatusReply(state = PairStatusState.DENIED)) }), "t", "d", named)
        assertEquals("Studio Mac", named.desktopNameSeen)

        val unnamed = FakeCeremony(events = mutableListOf())
        awaitPairVerdict(
            desk(mutableListOf(), helloName = "", status = { _, _ -> reply(PairStatusReply(state = PairStatusState.DENIED)) }),
            "t", "d", unnamed,
        )
        assertNull("blank name → null, the caller uses its fallback", unnamed.desktopNameSeen)
        assertFalse(unnamed.events.isEmpty())
    }

    // ── the identity on the "connect?" page comes from the QR's node, never from the computer ──

    @Test
    fun theShownIdentity_isComputedFromTheQrNode_notFromAnythingTheComputerSays() = runTest {
        val qrNode = "ab".repeat(32)
        var shown: PairDesktopIdentity? = null
        val ceremony = FfiPairCeremony(
            token = "t", phoneNode = "cd".repeat(32), deskNode = qrNode, fallbackName = "fallback",
            confirm = { shown = it; false },
            onCode = { _, _ -> error("no code expected") },
            fingerprintOf = { node -> "FP<$node>" },
        )
        // The computer claims a name that looks like a fingerprint.
        val log = mutableListOf<String>()
        val desk = desk(log, helloName = "AAAA BBBB")
        assertEquals(PairVerdict.Cancelled, awaitPairVerdict(desk, "t", "d", ceremony))
        assertEquals(PairDesktopIdentity(name = "AAAA BBBB", fingerprint = "FP<$qrNode>"), shown)
        assertTrue(shown!!.fingerprint != "AAAA BBBB")
    }
}
