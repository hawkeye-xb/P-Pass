// DEV-07 (#463): leaving the waiting screen must withdraw the request on the
// desktop. Before, Cancel only changed the phone's screen; the desktop kept
// the row approvable for the whole pending window and a later "Allow" wrote a
// device the phone never learned about. A scripted PairRpc plays the desktop;
// virtual time plays the minutes.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.PairAccepted
import com.hawkeyexb.ppass.proto.PairStatusReply
import com.hawkeyexb.ppass.proto.PairStatusRequest
import com.hawkeyexb.ppass.proto.PairSubmitted
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.RespError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DEV07PairCancelTest {

    private val requestId = "r".repeat(32)

    private fun ok(v: JsonElement) = Resp(id = "x", ok = true, result = v)

    /** Scripted desktop that records every call with its virtual time. */
    private inner class Desk(
        val scope: TestScope,
        /** null = hello denied (a revoked phone). */
        val caps: List<String>? = listOf("thumbnail.v1", PAIR_STATUS_CAPABILITY, PAIR_CANCEL_CAPABILITY),
        val submit: suspend () -> Resp = { queued() },
        val status: suspend () -> Resp = { reply(PairStatusReply(state = "pending")) },
        val cancel: suspend () -> Resp = { reply(PairStatusReply(state = "expired")) },
    ) : PairRpc {
        val calls = mutableListOf<Triple<String, Long, JsonElement>>()

        override suspend fun call(method: String, params: JsonElement): Resp {
            // Like DaemonClient.call's withContext(Dispatchers.IO): a caller
            // that is already cancelled never reaches the desktop.
            yield()
            calls += Triple(method, scope.currentTime, params)
            return when (method) {
                Methods.HELLO -> if (caps == null) {
                    Resp(id = "h", ok = false, error = RespError("NOT_AUTHORIZED", "err.not_authorized"))
                } else {
                    ok(ProtoJson.encodeToJsonElement(Hello.serializer(), Hello(capabilities = caps)))
                }
                Methods.PAIR_REQUEST -> submit()
                Methods.PAIR_STATUS -> status()
                Methods.PAIR_CANCEL -> cancel()
                else -> error("unexpected $method")
            }
        }

        fun cancels() = calls.filter { it.first == Methods.PAIR_CANCEL }
    }

    private fun queued() = ok(
        ProtoJson.encodeToJsonElement(
            PairSubmitted.serializer(),
            PairSubmitted(accepted = true, requestId = requestId, ttlMs = 600_000),
        ),
    )

    private fun reply(r: PairStatusReply) =
        ok(ProtoJson.encodeToJsonElement(PairStatusReply.serializer(), r))

    private fun requestIdOf(params: JsonElement) =
        ProtoJson.decodeFromJsonElement(PairStatusRequest.serializer(), params).requestId

    /** 验收：等待中点「取消」（协程被取消）→ 桌面收到一条 pair.cancel，带的正是这次的 request_id。 */
    @Test
    fun leavingTheWaitingScreen_withdrawsTheRequestOnTheDesktop() = runTest {
        val desk = Desk(this)
        val job = launch { awaitPairVerdict(desk, token = "t", deviceName = "SM-S9210") }
        advanceTimeBy(22_000) // 22 s into the wait — the emulator repro's gap
        job.cancel()
        job.join()

        val cancels = desk.cancels()
        assertEquals(1, cancels.size)
        assertEquals(requestId, requestIdOf(cancels.single().third))
        assertEquals(22_000L, cancels.single().second)
        assertEquals("the withdrawal is the last word", Methods.PAIR_CANCEL, desk.calls.last().first)
    }

    /** 取消落在一次 pair.status 往返的半路上：同样要撤回。 */
    @Test
    fun cancellingDuringAnInFlightStatusCall_stillWithdraws() = runTest {
        val inFlight = CompletableDeferred<Unit>()
        val desk = Desk(this, status = {
            inFlight.complete(Unit)
            awaitCancellation()
        })
        val job = launch { awaitPairVerdict(desk, "t", "d") }
        inFlight.await()
        job.cancel()
        job.join()
        assertEquals(1, desk.cancels().size)
    }

    /** 撤回是尽力而为：桌面不回（断网 / 关机）时，最多占用 PAIR_CANCEL_BUDGET_MS 就放手，不把被取消的任务挂住。 */
    @Test
    fun anUnansweredWithdrawal_isBoundedByItsBudget() = runTest {
        val desk = Desk(this, cancel = { awaitCancellation() })
        val job = launch { awaitPairVerdict(desk, "t", "d") }
        advanceTimeBy(7_000)
        job.cancel()
        val cancelledAt = currentTime
        job.join()
        assertEquals(PAIR_CANCEL_BUDGET_MS, currentTime - cancelledAt)
        assertTrue(job.isCancelled)
    }

    /** 撤回 RPC 自己抛异常：吞掉，取消照常完成（不把网络错误冒成崩溃）。 */
    @Test
    fun aFailingWithdrawal_neverEscapes() = runTest {
        val desk = Desk(this, cancel = { throw DaemonUnreachableException("gone") })
        val job = launch { awaitPairVerdict(desk, "t", "d") }
        advanceTimeBy(7_000)
        job.cancel()
        job.join()
        assertTrue(job.isCancelled)
        assertEquals(1, desk.cancels().size)
    }

    /** 兼容：桌面 hello 没有 pair.cancel.v1（#468 那一版）→ 不发（旧桌面会按未知方法拒绝并记 denial）。 */
    @Test
    fun desktopWithoutTheCapability_isNeverSentAWithdrawal() = runTest {
        val desk = Desk(this, caps = listOf("thumbnail.v1", PAIR_STATUS_CAPABILITY))
        val job = launch { awaitPairVerdict(desk, "t", "d") }
        advanceTimeBy(12_000)
        job.cancel()
        job.join()
        assertTrue(desk.cancels().isEmpty())
    }

    /** 被移除过的手机 hello 被拒、查不了能力 → 仍然撤回（宁可多一条 denial，也不留幽灵设备）。 */
    @Test
    fun revokedPhone_whoseHelloIsDenied_stillWithdraws() = runTest {
        val desk = Desk(this, caps = null)
        val job = launch { awaitPairVerdict(desk, "t", "d") }
        advanceTimeBy(12_000)
        job.cancel()
        job.join()
        assertEquals(1, desk.cancels().size)
    }

    /** 提交还没拿到 request_id 就取消：无从撤回，也不乱发。 */
    @Test
    fun cancellingBeforeTheSubmitAnswers_sendsNothing() = runTest {
        val desk = Desk(this, submit = { awaitCancellation() })
        val job = launch { awaitPairVerdict(desk, "t", "d") }
        runCurrent()
        job.cancel()
        job.join()
        assertTrue(desk.cancels().isEmpty())
    }

    /** 正常收尾（允许 / 拒绝 / 过期）不发撤回——撤回只属于「人走了」。 */
    @Test
    fun aSettledVerdict_isNeverFollowedByAWithdrawal() = runTest {
        val accepted = PairAccepted(storageDeviceName = "Home PC", pairingEpoch = "e".repeat(32))
        for (terminal in listOf(
            PairStatusReply(state = "accepted", accepted = accepted),
            PairStatusReply(state = "denied", msgKey = ERR_NOT_AUTHORIZED),
            PairStatusReply(state = "expired"),
        )) {
            val desk = Desk(this, status = { reply(terminal) })
            awaitPairVerdict(desk, "t", "d")
            assertTrue("${terminal.state}: ${desk.calls.map { it.first }}", desk.cancels().isEmpty())
        }
    }
}
