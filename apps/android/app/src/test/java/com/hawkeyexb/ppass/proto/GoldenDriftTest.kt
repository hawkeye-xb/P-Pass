// T-050 drift check: decode the SAME insta snapshots that
// crates/proto/tests/snapshots.rs asserts against. If the Rust wire
// format and these Kotlin types ever disagree, this suite goes red on
// the same commit that changed the shape.
package com.hawkeyexb.ppass.proto

import java.io.File
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GoldenDriftTest {

    private val snapshotsDir: File by lazy {
        // Unit tests run with CWD = apps/android/app.
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "crates/proto/tests/snapshots").isDirectory) {
            dir = dir.parentFile
                ?: error("crates/proto/tests/snapshots not found above ${System.getProperty("user.dir")}")
        }
        File(dir, "crates/proto/tests/snapshots")
    }

    /** Strip the insta YAML front matter; the body is pretty JSON. */
    private fun goldenJson(name: String): JsonElement {
        val text = File(snapshotsDir, "$name.snap").readText()
        val body = text.split("---", limit = 3)[2].trim()
        return Json.parseToJsonElement(body)
    }

    /**
     * Golden ⊆ encoded: every key present in the golden JSON must appear
     * in our encoding with the same value. Our encoding may add fields
     * the golden omitted (both sides deserialise with defaults, so extra
     * defaults are wire-compatible). A golden `null` matches an absent
     * key: serde writes `null` for a plain Option, kotlinx with
     * explicitNulls=false omits it — same meaning.
     */
    private fun assertSubset(golden: JsonElement, encoded: JsonElement, path: String = "$") {
        if (golden is JsonObject) {
            assertTrue("$path: expected object, got $encoded", encoded is JsonObject)
            val enc = encoded as JsonObject
            for ((k, v) in golden) {
                val e = enc[k]
                if (e == null) {
                    assertEquals("$path.$k: missing from Kotlin encoding", JsonNull, v)
                } else {
                    assertSubset(v, e, "$path.$k")
                }
            }
        } else {
            assertEquals(path, golden, encoded)
        }
    }

    private inline fun <reified T> check(snapshot: String, serializer: KSerializer<T>) {
        val golden = goldenJson(snapshot)
        val decoded: T = ProtoJson.decodeFromJsonElement(serializer, golden)
        val encoded: JsonElement = ProtoJson.encodeToJsonElement(serializer, decoded)
        assertSubset(golden, encoded)
        // Full roundtrip stability.
        val again: T = ProtoJson.decodeFromJsonElement(serializer, encoded)
        assertEquals(snapshot, decoded, again)
    }

    @Test fun hello() = check("snapshots__hello", Hello.serializer())
    @Test fun helloJson() = check("snapshots__hello_json", Hello.serializer())
    @Test fun pairRequest() = check("snapshots__pair_request", PairRequest.serializer())
    @Test fun pairAccepted() = check("snapshots__pair_accepted", PairAccepted.serializer())
    @Test fun reqEnvelope() = check("snapshots__req_envelope", Req.serializer())
    @Test fun reqEnvelopeJson() = check("snapshots__req_envelope_json", Req.serializer())
    @Test fun respOk() = check("snapshots__resp_ok_envelope", Resp.serializer())
    @Test fun respOkJson() = check("snapshots__resp_ok_envelope_json", Resp.serializer())
    @Test fun respErr() = check("snapshots__resp_err_envelope", Resp.serializer())
    @Test fun respErrJson() = check("snapshots__resp_err_envelope_json", Resp.serializer())
    @Test fun timelineQuery() = check("snapshots__timeline_query", TimelineQuery.serializer())
    @Test fun timelinePage() = check("snapshots__timeline_page", TimelinePage.serializer())
    @Test fun thumbGet256() = check("snapshots__thumb_get_256", ThumbGet.serializer())
    @Test fun thumbGet1024() = check("snapshots__thumb_get_1024", ThumbGet.serializer())
    @Test fun blobTicketReq() = check("snapshots__blob_ticket_request", BlobTicketRequest.serializer())
    @Test fun blobTicketResp() = check("snapshots__blob_ticket_response", BlobTicketResponse.serializer())
    @Test fun backupBegin() = check("snapshots__backup_begin", BackupBegin.serializer())
    @Test fun backupManifest() = check("snapshots__backup_manifest", BackupManifest.serializer())
    @Test fun backupManifestItems() =
        check("snapshots__backup_manifest_with_items", BackupManifest.serializer())
    @Test fun backupMissing() = check("snapshots__backup_missing", BackupMissing.serializer())
    @Test fun backupCommit() = check("snapshots__backup_commit", BackupCommit.serializer())
    @Test fun backupCommitGen() =
        check("snapshots__backup_commit_with_generation", BackupCommit.serializer())
    @Test fun diagStatus() = check("snapshots__diag_status", DiagStatus.serializer())
    @Test fun uploadHeader() = check("snapshots__upload_header", UploadHeader.serializer())

    /** Every JSON-shaped snapshot must be covered — a new Rust message
     *  without a Kotlin mirror fails here, not in the field. */
    @Test
    fun everySnapshotIsCovered() {
        val covered = setOf(
            "snapshots__hello", "snapshots__hello_json",
            "snapshots__pair_request", "snapshots__pair_accepted",
            "snapshots__req_envelope", "snapshots__req_envelope_json",
            "snapshots__resp_ok_envelope", "snapshots__resp_ok_envelope_json",
            "snapshots__resp_err_envelope", "snapshots__resp_err_envelope_json",
            "snapshots__timeline_query", "snapshots__timeline_page",
            "snapshots__thumb_get_256", "snapshots__thumb_get_1024",
            "snapshots__blob_ticket_request", "snapshots__blob_ticket_response",
            "snapshots__backup_begin", "snapshots__backup_manifest",
            "snapshots__backup_manifest_with_items", "snapshots__backup_missing",
            "snapshots__backup_commit", "snapshots__backup_commit_with_generation",
            "snapshots__diag_status", "snapshots__upload_header",
        )
        val onDisk = snapshotsDir.listFiles()!!
            .map { it.name.removeSuffix(".snap") }
            // _hex snapshots are the length-prefixed frame encoding —
            // covered when T-051 ports the codec, not a JSON shape.
            .filterNot { it.endsWith("_hex") }
            .toSet()
        assertEquals("snapshot coverage drifted", onDisk, covered)
    }
}
