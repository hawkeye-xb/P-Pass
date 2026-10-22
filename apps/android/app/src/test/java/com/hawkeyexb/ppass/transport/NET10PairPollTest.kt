// NET-10 (#128): the phone-side pairing state machine — submit ≠ wait.
// A scripted PairRpc plays the desktop; kotlinx-coroutines-test virtual
// time plays the owner's minutes, so the 1 s cadence and the desktop-sent
// deadline are asserted exactly, without sleeping.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.proto.PairAccepted
import com.hawkeyexb.ppass.proto.PairConfirmRequest
import com.hawkeyexb.ppass.proto.PairRequest
import com.hawkeyexb.ppass.proto.PairStatusReply
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
import org.junit.Assert.assertTrue
import org.junit.Test

private fun ok(v: JsonElement) = Resp(id = "x", ok = true, result = v)

class NET10PairPollTest {

    private val pid = "e".repeat(32)
    private val accepted = PairAccepted(storageDeviceName = "Home PC", pairingId = pid)

    /** Scripted desktop. [status] answers one pair.status call given the
     *  virtual time it arrived at; throwing = the RPC itself failed. */
    private class FakeDesk(
        val scope: TestScope,
        val caps: List<String>? = listOf("thumbnail.v1", PAIR_STATUS_CAPABILITY),
        val submit: () -> Resp,
        val status: (atMs: Long) -> PairStatusReply,
        /** #1118: the desktop's answer to pair.confirm (default: the code matched → accepted + cB). */
        val confirm: (PairConfirmRequest) -> Resp = { ok(ProtoJson.encodeToJsonElement(PairStatusReply.serializer(), PairStatusReply(state = "accepted", accepted = PairAccepted("Home PC", "e".repeat(32)), confirmB = "cb".repeat(32)))) },
    ) : PairRpc {
        val calls = mutableListOf<Pair<String, Long>>()
        var submitParams: JsonElement? = null

        override suspend fun call(method: String, params: JsonElement): Resp {
            calls += method to scope.currentTime
            return when (method) {
                Methods.HELLO -> if (caps == null) {
                    Resp(id = "h", ok = false, error = RespError("NOT_AUTHORIZED", "not_paired"))
                } else {
                    ok(ProtoJson.encodeToJsonElement(Hello.serializer(), Hello(capabilities = caps)))
                }
                Methods.PAIR_REQUEST -> {
                    submitParams = params
                    submit()
                }
                Methods.PAIR_STATUS -> ok(
                    ProtoJson.encodeToJsonElement(PairStatusReply.serializer(), status(scope.currentTime)),
                )
                Methods.PAIR_CONFIRM -> confirm(
                    ProtoJson.decodeFromJsonElement(PairConfirmRequest.serializer(), params),
                )
                else -> error("unexpected $method")
            }
        }

        fun statusTimes() = calls.filter { it.first == Methods.PAIR_STATUS }.map { it.second }
    }

    private fun queued(ttlMs: Long = 600_000) = ok(
        ProtoJson.encodeToJsonElement(
            PairSubmitted.serializer(),
            PairSubmitted(accepted = true, requestId = "r".repeat(32), ttlMs = ttlMs),
        ),
    )
    private fun pending() = PairStatusReply(state = "pending")
    /** #1118: the owner has typed the code — the desktop's pake_b is out. */
    private fun pendingWithPakeB() = PairStatusReply(state = "pending", pakeB = "bb".repeat(33))

    /** 验收：主人隔 60 s 才输码 → 经 1 s 轮询走到 pake_b → pair.confirm → accepted，全程无失败。 */
    @Test
    fun slowOwner_60s_isReachedThroughOneSecondPolls() = runTest {
        val desk = FakeDesk(this, submit = { queued() }, status = { at ->
            if (at < 60_000) pending() else pendingWithPakeB()
        })
        val v = awaitPairVerdict(desk, token = "t", deviceName = "SM-S9210", ceremony = FakeCeremony())
        assertEquals(PairVerdict.Accepted(accepted), v)
        val times = desk.statusTimes()
        assertEquals((1..60).map { it * 1_000L }, times)
        val req = ProtoJson.decodeFromJsonElement(PairRequest.serializer(), desk.submitParams!!)
        assertEquals(true, req.ackThenPoll)
        assertEquals("t", req.token)
    }

    /** 死因 1：主人拒绝 → Denied(DENIED)，下一次轮询即出结果（#1072：v2 的 denied 不带任何文案 key）。 */
    @Test
    fun ownerDeny_isItsOwnBranch() = runTest {
        val desk = FakeDesk(this, submit = { queued() }, status = { at ->
            if (at < 10_000) pending() else PairStatusReply(state = "denied")
        })
        assertEquals(PairVerdict.Denied(PairRefusal.DENIED), awaitPairVerdict(desk, "t", "d", FakeCeremony()))
        assertEquals((1..10).map { it * 1_000L }, desk.statusTimes())
    }

    /** 死因 2：没人点 → 桌面报 expired。 */
    @Test
    fun desktopExpired_isItsOwnBranch() = runTest {
        val desk = FakeDesk(this, submit = { queued() }, status = { PairStatusReply(state = "expired") })
        assertEquals(PairVerdict.Expired, awaitPairVerdict(desk, "t", "d", FakeCeremony()))
    }

    /** 死因 3：桌面重启 → not_found → DesktopRestarted，不盲重发（只提交过一次）。 */
    @Test
    fun desktopRestart_notFound_isItsOwnBranch_andNeverResubmits() = runTest {
        val desk = FakeDesk(this, submit = { queued() }, status = { at ->
            if (at < 15_000) pending() else PairStatusReply(state = "not_found")
        })
        assertEquals(PairVerdict.DesktopRestarted, awaitPairVerdict(desk, "t", "d", FakeCeremony()))
        assertEquals(1, desk.calls.count { it.first == Methods.PAIR_REQUEST })
    }

    /** 死因 4：status RPC 自身连续失败（15 s 控制档超时）→ Unreachable。 */
    @Test
    fun statusRpcKeepsFailing_isNetworkFailure() = runTest {
        val desk = FakeDesk(this, submit = { queued() }, status = {
            throw DaemonUnreachableException("pair.status: no response from the computer within 15000ms")
        })
        val v = awaitPairVerdict(desk, "t", "d", FakeCeremony())
        assertTrue("$v", v is PairVerdict.Unreachable)
        assertTrue((v as PairVerdict.Unreachable).reason.contains("pair.status"))
        assertEquals(PAIR_STATUS_MAX_CONSECUTIVE_FAILURES, desk.statusTimes().size)
    }

    /** 单次抖动不等于配对死了：失败后一次成功回答即清零，照常走到 accepted。 */
    @Test
    fun oneFailedPoll_doesNotKillAMinuteLongWait() = runTest {
        var n = 0
        val desk = FakeDesk(this, submit = { queued() }, status = {
            n += 1
            when {
                n % 2 == 0 && n < 8 -> throw DaemonUnreachableException("blip")
                n < 9 -> pending()
                else -> pendingWithPakeB()
            }
        })
        assertEquals(PairVerdict.Accepted(accepted), awaitPairVerdict(desk, "t", "d", FakeCeremony()))
    }

    /** 上限单一来源：轮询截止取桌面回的 ttl_ms，不是手机自己的常数。 */
    @Test
    fun pollingDeadline_comesFromTheDesktopTtl() = runTest {
        val desk = FakeDesk(this, submit = { queued(ttlMs = 20_000) }, status = { pending() })
        assertEquals(PairVerdict.Expired, awaitPairVerdict(desk, "t", "d", FakeCeremony()))
        // 20 s / 1 s = 20 polls, +1 to read the desktop's own verdict.
        assertEquals((1..21).map { it * 1_000L }, desk.statusTimes())
    }

    /** 新手机 + 旧桌面：hello 没有 pair.status.v1 → 明确「桌面过旧」，且不提交（不消耗 token）。 */
    @Test
    fun oldDesktop_withoutCapability_isDesktopTooOld_andTokenIsNotSpent() = runTest {
        val desk = FakeDesk(this, caps = listOf("thumbnail.v1"), submit = { error("must not submit") }, status = { error("no") })
        assertEquals(PairVerdict.DesktopTooOld, awaitPairVerdict(desk, "t", "d", FakeCeremony()))
        assertEquals(listOf(Methods.HELLO), desk.calls.map { it.first })
    }

    /** token 无效/已用：提交即拒，不进入轮询。 */
    @Test
    fun badToken_isRefusedOnSubmit_withoutPolling() = runTest {
        val desk = FakeDesk(
            this,
            submit = { Resp(id = "s", ok = false, error = RespError("NOT_AUTHORIZED", "pair_token_invalid")) },
            status = { error("no poll") },
        )
        assertEquals(PairVerdict.Denied(PairRefusal.TOKEN_INVALID), awaitPairVerdict(desk, "t", "d", FakeCeremony()))
        assertTrue(desk.statusTimes().isEmpty())
    }

    /** 被移除过的手机：hello 被拒（查不了能力）→ 仍提交，按应答形状判断，照常轮询。 */
    @Test
    fun revokedPhone_whoseHelloIsDenied_stillSubmitsAndPolls() = runTest {
        val desk = FakeDesk(this, caps = null, submit = { queued() }, status = { pendingWithPakeB() })
        assertEquals(PairVerdict.Accepted(accepted), awaitPairVerdict(desk, "t", "d", FakeCeremony()))
    }

    /** #1118：旧桌面按旧同步形状回了 PairAccepted——它没验过验证码，不算加入，按「桌面过旧」处理。 */
    @Test
    fun legacyBlockingReply_neverCheckedACode_isNotAJoin() = runTest {
        val desk = FakeDesk(this, caps = null, submit = {
            ok(ProtoJson.encodeToJsonElement(PairAccepted.serializer(), accepted))
        }, status = { error("no poll") })
        assertEquals(PairVerdict.DesktopTooOld, awaitPairVerdict(desk, "t", "d", FakeCeremony()))
    }

    /** 屏幕映射：每个死因一条独立出口；自行失效的不说「电脑拒绝了」；桌面太旧走「需要更新电脑端」（#1072）。 */
    @Test
    fun everyCause_mapsToItsOwnScreen() {
        val join = { a: PairAccepted -> Pairing("n", "t", a.storageDeviceName, 1L, a.pairingId) }
        val joined = PairVerdict.Accepted(accepted).toOutcome(join)
        assertTrue(joined is PairOutcome.Joined)
        for (cause in listOf(PairRefusal.DENIED, PairRefusal.TOKEN_INVALID)) {
            val o = PairVerdict.Denied(cause).toOutcome(join) as PairOutcome.Refused
            assertEquals(cause, o.cause)
            assertTrue("$cause is the computer saying no", o.ownerSaidNo)
        }
        val lapsed = listOf(
            PairVerdict.Expired to PairRefusal.EXPIRED,
            PairVerdict.DesktopRestarted to PairRefusal.DESKTOP_RESTARTED,
        )
        for ((verdict, cause) in lapsed) {
            val o = verdict.toOutcome(join) as PairOutcome.Refused
            assertEquals(cause, o.cause)
            assertFalse("$cause lapsed on its own", o.ownerSaidNo)
        }
        assertEquals(PairOutcome.NeedsUpdate(OutdatedSide.DESKTOP), PairVerdict.DesktopTooOld.toOutcome(join))
        assertEquals(PairOutcome.NeedsUpdate(OutdatedSide.PHONE), PairVerdict.NeedsUpdate(OutdatedSide.PHONE).toOutcome(join))
        assertTrue(PairVerdict.Unreachable("x").toOutcome(join) is PairOutcome.Failed)
        // #1118: a wrong code / a missing desktop proof is a refusal the desktop owner did not choose.
        for ((verdict, cause) in listOf(
            PairVerdict.CodeWrong to PairRefusal.CODE_WRONG,
            PairVerdict.ProofFailed to PairRefusal.PROOF_FAILED,
        )) {
            val o = verdict.toOutcome(join) as PairOutcome.Refused
            assertEquals(cause, o.cause)
            assertFalse(o.ownerSaidNo)
        }
        assertEquals(PairOutcome.Cancelled, PairVerdict.Cancelled.toOutcome(join))
    }
}
