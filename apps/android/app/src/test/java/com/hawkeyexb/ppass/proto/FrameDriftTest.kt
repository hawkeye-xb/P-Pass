// T-051 frame-codec drift check: the *_hex insta snapshots are the
// byte-exact frames the Rust codec produced. Decoding them proves the
// header layout; re-encoding proves our JSON bytes fit the same framing.
package com.hawkeyexb.ppass.proto

import java.io.File
import kotlinx.serialization.KSerializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class FrameDriftTest {

    private val snapshotsDir: File by lazy {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "crates/proto/tests/snapshots").isDirectory) {
            dir = dir.parentFile ?: error("snapshots dir not found")
        }
        File(dir, "crates/proto/tests/snapshots")
    }

    private fun goldenHex(name: String): ByteArray {
        val text = File(snapshotsDir, "$name.snap").readText()
        val body = text.split("---", limit = 3)[2].trim()
        return body.split(Regex("\\s+")).map { it.toInt(16).toByte() }.toByteArray()
    }

    private fun <T> check(snapshot: String, serializer: KSerializer<T>) {
        val frame = goldenHex(snapshot)
        // Header sanity: declared length + 4 == total frame bytes.
        assertEquals(snapshot, frame.size - 4, frameLen(frame))
        // The Rust-encoded frame decodes into our types...
        val decoded: T = decodeFrame(serializer, frame)
        // ...and our own frame of that value round-trips.
        val ours = encodeFrame(serializer, decoded)
        assertEquals(snapshot, decoded, decodeFrame(serializer, ours))
    }

    @Test fun helloFrame() = check("snapshots__hello_hex", Hello.serializer())
    @Test fun reqFrame() = check("snapshots__req_envelope_hex", Req.serializer())
    @Test fun respOkFrame() = check("snapshots__resp_ok_envelope_hex", Resp.serializer())
    @Test fun respErrFrame() = check("snapshots__resp_err_envelope_hex", Resp.serializer())

    @Test
    fun oversizedFrameIsRejected() {
        val header = byteArrayOf(0, 0, 0, 0x7F) // ~2 GB little-endian
        assertThrows(CodecException::class.java) { frameLen(header) }
    }
}
