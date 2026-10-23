// T-050 drift check: decode the SAME insta snapshots that
// crates/proto/tests/snapshots.rs asserts against. If the Rust wire
// format and these Kotlin types ever disagree, this suite goes red on
// the same commit that changed the shape.
package com.hawkeyexb.ppass.proto

import java.io.File
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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
    @Test fun pairRequestAckThenPoll() =
        check("snapshots__pair_request_ack_then_poll", PairRequest.serializer())
    @Test fun pairSubmitted() = check("snapshots__pair_submitted", PairSubmitted.serializer())
    @Test fun pairStatusRequest() =
        check("snapshots__pair_status_request", PairStatusRequest.serializer())
    @Test fun pairStatusReplyAccepted() =
        check("snapshots__pair_status_reply_accepted", PairStatusReply.serializer())
    // #1118: code exchange — the new fields and the `failed` state.
    @Test fun pairRequestPake() = check("snapshots__pair_request_pake", PairRequest.serializer())
    @Test fun pairStatusReplyPakeB() =
        check("snapshots__pair_status_reply_pake_b", PairStatusReply.serializer())
    @Test fun pairConfirmRequest() =
        check("snapshots__pair_confirm_request", PairConfirmRequest.serializer())
    @Test fun pairStatusReplyConfirmed() =
        check("snapshots__pair_status_reply_confirmed", PairStatusReply.serializer())
    @Test fun pairStatusReplyFailed() =
        check("snapshots__pair_status_reply_failed", PairStatusReply.serializer())
    @Test fun pairStatusReplyDenied() =
        check("snapshots__pair_status_reply_denied", PairStatusReply.serializer())
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
    @Test fun thumbDataReal() = check("snapshots__thumb_data_real", ThumbData.serializer())
    @Test fun thumbDataPlaceholder() =
        check("snapshots__thumb_data_placeholder", ThumbData.serializer())
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
    @Test fun flowSupersedeRequest() = check("snapshots__flow_supersede_request", FlowSupersedeRequest.serializer())
    @Test fun flowSupersedeReplaced() = check("snapshots__flow_supersede_reply_replaced", FlowSupersedeReply.serializer())
    @Test fun flowSupersedeRefused() = check("snapshots__flow_supersede_reply_refused", FlowSupersedeReply.serializer())

    // #890：Flow 逐张交付补齐的 golden（iOS PPassCore 读同一批文件）。
    @Test fun helloPairedWithHealth() = check("snapshots__hello_paired_with_health", Hello.serializer())
    @Test fun helloHealthFreeBytesUnknown() = check("snapshots__hello_health_free_bytes_unknown", Hello.serializer())
    @Test fun flowFetchRequest() = check("snapshots__flow_fetch_request", FlowFetchRequest.serializer())
    @Test fun flowTupleRef() = check("snapshots__flow_tuple_ref", FlowTupleRef.serializer())
    @Test fun flowCompletionReceipt() = check("snapshots__flow_completion_receipt", FlowCompletionReceipt.serializer())
    @Test fun flowStatusCompleted() = check("snapshots__flow_status_reply_completed", FlowStatusReply.serializer())
    @Test fun flowStatusActive() = check("snapshots__flow_status_reply_active", FlowStatusReply.serializer())
    @Test fun flowAuditSubmit() = check("snapshots__flow_audit_submit", FlowAuditSubmit.serializer())
    @Test fun flowAuditAccepted() = check("snapshots__flow_audit_accepted", FlowAuditAccepted.serializer())
    @Test fun backupPresenceQuery() = check("snapshots__backup_presence_query", BackupPresenceQuery.serializer())

    // ── #1070 protocol v2 ──────────────────────────
    @Test fun respErrWithParams() = check("snapshots__resp_err_with_params", Resp.serializer())
    /**
     * #1072: the v1 shim's `msg_key` exists only for pre-v2 phones; this phone dropped the field and
     * must still read the shimmed refusal as "phone outdated" (never as a pairing or item verdict).
     */
    @Test fun respErrV1ShimFlow() = checkShim("snapshots__resp_err_v1_shim_flow")
    @Test fun respErrV1ShimPair() = checkShim("snapshots__resp_err_v1_shim_pair")

    private fun checkShim(name: String) {
        val golden = goldenJson(name) as JsonObject
        val decoded = ProtoJson.decodeFromJsonElement(Resp.serializer(), golden)
        assertEquals(Reason.PHONE_OUTDATED, decoded.error!!.reasonKind)
        assertEquals(OutdatedSide.PHONE, decoded.outdatedSide())
        val withoutShim = JsonObject(golden + ("error" to JsonObject((golden["error"] as JsonObject) - "msg_key")))
        assertSubset(withoutShim, ProtoJson.encodeToJsonElement(Resp.serializer(), decoded))
    }
    @Test fun flowFailedPush() = check("snapshots__flow_failed_push", FlowFailedPush.serializer())
    /** The registry golden is a JSON array; [assertSubset] compares objects, so go per element. */
    @Test
    fun reasonsRegistry() {
        val golden = goldenJson("snapshots__reasons_registry") as kotlinx.serialization.json.JsonArray
        for (element in golden) {
            val decoded = ProtoJson.decodeFromJsonElement(RespError.serializer(), element)
            assertSubset(element, ProtoJson.encodeToJsonElement(RespError.serializer(), decoded))
        }
    }

    /** Every Rust reason is a known Kotlin [Reason]; nothing Kotlin knows is missing from Rust. */
    @Test
    fun reasonRegistryMatchesRust() {
        val rust = ProtoJson.decodeFromJsonElement(
            ListSerializer(RespError.serializer()),
            goldenJson("snapshots__reasons_registry"),
        )
        for (e in rust) {
            assertNotEquals("unmapped Rust reason ${e.reason}", Reason.UNKNOWN, e.reasonKind)
            assertEquals(e.reason, e.reasonKind.wire)
        }
        assertEquals(
            Reason.entries.filter { it != Reason.UNKNOWN }.map { it.wire }.toSet(),
            rust.map { it.reason }.toSet(),
        )
    }

    /** #1122 / #1124: the Kotlin close-code registry is the Rust one, row for row. */
    @Test
    fun closeCodesRegistryMatchesRust() {
        val rust = (goldenJson("snapshots__close_codes_registry") as kotlinx.serialization.json.JsonArray).map {
            val o = it as kotlinx.serialization.json.JsonObject
            (o["code"] as kotlinx.serialization.json.JsonPrimitive).content.toLong() to
                (o["reason"] as kotlinx.serialization.json.JsonPrimitive).content
        }
        assertEquals(rust, com.hawkeyexb.ppass.transport.DesktopCloseCodes.registry)
    }

    /** #1072: the Kotlin SupersedeRefusal mirrors every `proto::SupersedeRefusal::as_str` wire string. */
    @Test
    fun supersedeRefusalsMatchRust() {
        val msgs = File(snapshotsDir.parentFile.parentFile, "src/msgs.rs").readText()
        val body = msgs.substringAfter("impl SupersedeRefusal {").substringAfter("fn as_str").substringBefore("}\n    }")
        val rust = Regex("""Self::\w+ => "([a-z_]+)"""").findAll(body).map { it.groupValues[1] }.toSet()
        assertEquals(12, rust.size)
        assertEquals(rust, SupersedeRefusal.entries.filter { it != SupersedeRefusal.UNKNOWN }.map { it.wire }.toSet())
        assertEquals(SupersedeRefusal.UNKNOWN, SupersedeRefusal.fromWire("never_registered"))
    }

    /** Acceptance 4: an unknown reason decodes, keeps its string, and maps to UNKNOWN. */
    @Test
    fun unknownReasonDecodesAndKeepsItsString() {
        val resp = ProtoJson.decodeFromString(
            Resp.serializer(),
            """{"id":"1","ok":false,"error":{"code":"FUTURE","reason":"from_the_future","params":{"n":1}},"ver":3,"min_ver":2}""",
        )
        val error = resp.error!!
        assertEquals("from_the_future", error.reason)
        assertEquals(Reason.UNKNOWN, error.reasonKind)
        assertEquals(3, resp.ver)
    }

    /** #1070 envelope: a reply without version keys is a v1 desktop; a built request carries v2. */
    @Test
    fun envelopeVersionDefaults() {
        val old = ProtoJson.decodeFromString(Resp.serializer(), """{"id":"1","ok":true}""")
        assertEquals(V1, old.ver)
        assertEquals(V1, old.minVer)
        val wire = ProtoJson.encodeToJsonElement(Req.serializer(), Req(id = "1", method = "hello")) as JsonObject
        assertEquals(PROTO_VER.toString(), wire["ver"].toString())
        assertEquals(MIN_SUPPORTED_VER.toString(), wire["min_ver"].toString())
    }

    /** Every JSON-shaped snapshot must be covered — a new Rust message
     *  without a Kotlin mirror fails here, not in the field. */
    @Test
    fun everySnapshotIsCovered() {
        val covered = setOf(
            "snapshots__hello", "snapshots__hello_json",
            "snapshots__pair_request", "snapshots__pair_accepted",
            "snapshots__pair_request_ack_then_poll", "snapshots__pair_submitted",
            "snapshots__pair_status_request", "snapshots__pair_status_reply_accepted",
            "snapshots__pair_status_reply_denied",
            "snapshots__pair_request_pake", "snapshots__pair_status_reply_pake_b",
            "snapshots__pair_confirm_request", "snapshots__pair_status_reply_confirmed",
            "snapshots__pair_status_reply_failed",
            "snapshots__req_envelope", "snapshots__req_envelope_json",
            "snapshots__resp_ok_envelope", "snapshots__resp_ok_envelope_json",
            "snapshots__resp_err_envelope", "snapshots__resp_err_envelope_json",
            "snapshots__timeline_query", "snapshots__timeline_page",
            "snapshots__thumb_get_256", "snapshots__thumb_get_1024",
            "snapshots__thumb_data_real", "snapshots__thumb_data_placeholder",
            "snapshots__blob_ticket_request", "snapshots__blob_ticket_response",
            "snapshots__backup_begin", "snapshots__backup_manifest",
            "snapshots__backup_manifest_with_items", "snapshots__backup_missing",
            "snapshots__backup_commit", "snapshots__backup_commit_with_generation",
            "snapshots__diag_status",
            "snapshots__flow_supersede_request", "snapshots__flow_supersede_reply_replaced",
            "snapshots__flow_supersede_reply_refused",
            "snapshots__hello_paired_with_health", "snapshots__hello_health_free_bytes_unknown",
            "snapshots__flow_fetch_request", "snapshots__flow_tuple_ref",
            "snapshots__flow_completion_receipt",
            "snapshots__flow_status_reply_completed", "snapshots__flow_status_reply_active",
            "snapshots__flow_audit_submit", "snapshots__flow_audit_accepted",
            "snapshots__backup_presence_query",
            "snapshots__resp_err_with_params",
            "snapshots__resp_err_v1_shim_flow", "snapshots__resp_err_v1_shim_pair",
            "snapshots__flow_failed_push", "snapshots__reasons_registry",
            "snapshots__close_codes_registry",
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
