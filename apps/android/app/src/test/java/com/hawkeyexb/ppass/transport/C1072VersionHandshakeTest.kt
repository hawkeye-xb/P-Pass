// #1072 acceptance 3: version compatibility is decided at the handshake. An incompatible desktop —
// one that says so (`phone_outdated` / `desktop_outdated`) or one too old to send `ver` — becomes the
// same VERSION_MISMATCH rejection for every caller (DaemonClient → Resp.versionChecked), pairing
// sends no pair.request, and the home screen's prompt follows the latest reply.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Codes
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.MIN_SUPPORTED_VER
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.proto.PROTO_VER
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.RespError
import com.hawkeyexb.ppass.proto.versionChecked
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class C1072VersionHandshakeTest {

    private fun v2(ok: Boolean = true, error: RespError? = null) =
        Resp(id = "1", ok = ok, result = if (ok) JsonPrimitive("x") else null, error = error, ver = PROTO_VER, minVer = MIN_SUPPORTED_VER)

    // ── the reply check every DaemonClient call goes through ──

    @Test
    fun `a pre-v2 desktop's successful reply becomes desktop_outdated - nobody acts on it`() {
        val old = ProtoJson.decodeFromString(Resp.serializer(), """{"id":"1","ok":true,"result":{"pairing_epoch":"e"}}""")
        val checked = old.versionChecked()
        assertEquals(false, checked.ok)
        assertNull("旧桌面的结果不许流到调用方", checked.result)
        assertEquals(Codes.VERSION_MISMATCH, checked.error?.code)
        assertEquals("desktop_outdated", checked.error?.reason)
    }

    @Test
    fun `a desktop that needs a newer phone is phone_outdated even if it answered`() {
        val checked = v2().copy(minVer = PROTO_VER + 1).versionChecked()
        assertEquals("phone_outdated", checked.error?.reason)
    }

    @Test
    fun `compatible replies and the desktop's own verdict pass through unchanged`() {
        val fine = v2()
        assertSame(fine, fine.versionChecked())
        val denied = v2(ok = false, error = RespError("NOT_AUTHORIZED", "revoked"))
        assertSame(denied, denied.versionChecked())
        val said = v2(ok = false, error = RespError("VERSION_MISMATCH", "phone_outdated"))
        assertSame(said, said.versionChecked())
    }

    @Test
    fun `the home prompt follows the latest reply`() {
        ProtocolVersionGate.observe(v2(ok = false, error = RespError("VERSION_MISMATCH", "phone_outdated")))
        assertEquals(OutdatedSide.PHONE, ProtocolVersionGate.outdated.value)
        ProtocolVersionGate.observe(ProtoJson.decodeFromString(Resp.serializer(), """{"id":"1","ok":true}""").versionChecked())
        assertEquals(OutdatedSide.DESKTOP, ProtocolVersionGate.outdated.value)
        // A compatible reply — even a rejection for another reason — clears it by itself.
        ProtocolVersionGate.observe(v2(ok = false, error = RespError("NOT_AUTHORIZED", "not_paired")))
        assertNull(ProtocolVersionGate.outdated.value)
    }

    @Test
    fun `DaemonClient routes every reply through the check`() {
        val src = java.io.File("src/main/java/com/hawkeyexb/ppass/transport/DaemonClient.kt").readText()
        val decodes = Regex("""decodePayload\(\s*Resp\.serializer\(\)""").findAll(src).count()
        val checked = Regex("""checkedReply\(\s*(com\.hawkeyexb\.ppass\.proto\.)?decodePayload\(\s*Resp\.serializer\(\)""").findAll(src).count()
        assertTrue("found no reply decode at all", decodes >= 3)
        assertEquals("every Resp decode must go through checkedReply", decodes, checked)
    }

    @Test
    fun `the home status card shows the version line - unless the media card or the red card takes the place`() {
        val full = com.hawkeyexb.ppass.backup.MediaAccess.FULL
        assertEquals(OutdatedSide.PHONE, com.hawkeyexb.ppass.ui.visibleOutdatedSide(OutdatedSide.PHONE, full, pairingLost = false))
        assertNull(com.hawkeyexb.ppass.ui.visibleOutdatedSide(OutdatedSide.PHONE, full, pairingLost = true))
        assertNull(com.hawkeyexb.ppass.ui.visibleOutdatedSide(OutdatedSide.DESKTOP, com.hawkeyexb.ppass.backup.MediaAccess.NONE, pairingLost = false))
        assertNull(com.hawkeyexb.ppass.ui.visibleOutdatedSide(null, full, pairingLost = false))
        assertTrue(com.hawkeyexb.ppass.ui.offersAppUpdate(OutdatedSide.PHONE))
        assertEquals(false, com.hawkeyexb.ppass.ui.offersAppUpdate(OutdatedSide.DESKTOP))
    }

    // ── pairing: no pair.request once the hello says incompatible ──

    private class Desk(val hello: Resp, val submit: Resp = Resp(ok = false)) : PairRpc {
        val methods = mutableListOf<String>()
        override suspend fun call(method: String, params: JsonElement): Resp {
            methods += method
            return when (method) {
                Methods.HELLO -> hello
                Methods.PAIR_REQUEST -> submit
                else -> error("unexpected $method")
            }
        }
    }

    @Test
    fun `an incompatible hello ends pairing before any pairing request is sent`() = runTest {
        for ((reason, side) in listOf("phone_outdated" to OutdatedSide.PHONE, "desktop_outdated" to OutdatedSide.DESKTOP)) {
            val desk = Desk(hello = v2(ok = false, error = RespError("VERSION_MISMATCH", reason)))
            assertEquals(PairVerdict.NeedsUpdate(side), awaitPairVerdict(desk, "t", "d"))
            assertEquals("只握手，不发配对请求", listOf(Methods.HELLO), desk.methods)
        }
    }

    @Test
    fun `a submit refused for version is an update prompt, not the computer saying no`() = runTest {
        val hello = v2().copy(
            result = ProtoJson.encodeToJsonElement(Hello.serializer(), Hello(capabilities = listOf(PAIR_STATUS_CAPABILITY))),
        )
        val desk = Desk(hello = hello, submit = v2(ok = false, error = RespError("VERSION_MISMATCH", "phone_outdated")))
        val verdict = awaitPairVerdict(desk, "t", "d")
        assertEquals(PairVerdict.NeedsUpdate(OutdatedSide.PHONE), verdict)
        val outcome = verdict.toOutcome { error("no join") }
        assertEquals(PairOutcome.NeedsUpdate(OutdatedSide.PHONE), outcome)
    }
}
