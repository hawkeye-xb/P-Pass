// #1051: the "am I already a member of this computer?" probe is hello, not
// backup.begin. Member = hello comes back with a non-empty pairing_id.
// Unpaired / revoked / unreachable all mean "go through normal pairing".
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.RespError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class Card1051MemberProbeTest {

    private class Desk(val reply: suspend () -> Resp) : PairRpc {
        val methods = mutableListOf<String>()
        override suspend fun call(method: String, params: JsonElement): Resp {
            methods += method
            return reply()
        }
    }

    private fun helloOk(pid: String?, name: String = "Home PC") = Resp(
        id = "h",
        ok = true,
        result = ProtoJson.encodeToJsonElement(
            Hello.serializer(),
            Hello(capabilities = listOf("thumbnail.v1"), deviceName = name, pairingId = pid),
        ),
    )

    @Test
    fun memberHelloWithPairingIdIsRecognised() = runTest {
        val desk = Desk { helloOk("e".repeat(32)) }
        val hello = probeMembership(desk)
        assertNotNull(hello)
        assertEquals("e".repeat(32), hello!!.pairingId)
        assertEquals("Home PC", hello.deviceName)
        // Only hello — never backup.begin (that is the whole point of #1051).
        assertEquals(listOf(Methods.HELLO), desk.methods)
    }

    /**
     * #1116 N1: a computer this phone never paired with claims "you're a member" — the claim is
     * ignored and the computer is not even asked, so pairing goes through the #1118 code. Red if the
     * gate is dropped (the forged member reply would be returned).
     */
    @Test
    fun unknownComputerClaimingMembershipIsNotTrusted() = runTest {
        val forged = Desk { helloOk("f".repeat(32), name = "Forged PC") }
        assertNull(trustedMembership(knownDesktop = false, rpc = forged))
        assertTrue("an unknown computer must not be probed", forged.methods.isEmpty())

        val known = Desk { helloOk("e".repeat(32)) }
        assertEquals("e".repeat(32), trustedMembership(knownDesktop = true, rpc = known)!!.pairingId)
    }

    @Test
    fun unpairedHelloWithoutPairingIdIsNotAMember() = runTest {
        for (pid in listOf(null, "")) {
            assertNull(probeMembership(Desk { helloOk(pid) }))
        }
    }

    @Test
    fun revokedHelloDeniedIsNotAMember() = runTest {
        val denied = Resp(id = "h", ok = false, error = RespError("NOT_AUTHORIZED", "err.not_authorized"))
        val desk = Desk { denied }
        assertNull(probeMembership(desk))
        assertEquals(listOf(Methods.HELLO), desk.methods)
    }

    @Test
    fun unreachableFallsBackToPairing() = runTest {
        assertNull(probeMembership(Desk { throw java.io.IOException("no route") }))
    }

    @Test
    fun garbageResultFallsBackToPairing() = runTest {
        val bad = Resp(id = "h", ok = true, result = ProtoJson.parseToJsonElement("""["x"]"""))
        assertNull(probeMembership(Desk { bad }))
    }

    @Test
    fun timeoutFallsBackToPairing() = runTest {
        val never = CompletableDeferred<Resp>()
        val job = async { probeMembership(Desk { never.await() }, timeoutMs = 20_000) }
        advanceTimeBy(20_001)
        assertNull(job.await())
    }

    @Test
    fun callerCancellationStillPropagates() = runTest {
        val never = CompletableDeferred<Resp>()
        val job = async { probeMembership(Desk { never.await() }) }
        advanceTimeBy(1)
        job.cancel()
        try {
            job.await()
            fail("expected cancellation")
        } catch (e: CancellationException) {
            assertTrue(true)
        }
    }
}
