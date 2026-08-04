// T-054: the phone-side backup pipeline —
// scan → hash → begin/manifest → push each missing file → commit →
// persist watermark. Fully idempotent: rerunning after any failure
// converges (dedup drops what already arrived).
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.proto.BackupCommit
import com.hawkeyexb.ppass.proto.BackupItem
import com.hawkeyexb.ppass.proto.BackupManifest
import com.hawkeyexb.ppass.proto.BackupMissing
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Req
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.UploadHeader
import com.hawkeyexb.ppass.proto.decodePayload
import com.hawkeyexb.ppass.proto.encodeFrame
import com.hawkeyexb.ppass.proto.frameLen
import com.hawkeyexb.ppass.transport.ALPN_CTRL
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.PeerAddrParts
import computer.iroh.Connection
import java.io.InputStream
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

const val ALPN_UPLOAD = "ppf/upload/1"
private const val CHUNK = 256 * 1024

/** One backup candidate: content + identity, source-agnostic
 *  (MediaStore URIs on the phone, plain files in tests). */
data class Candidate(
    val hash: String,
    val fileName: String,
    val mediaType: String,
    val bytes: Long,
    /** Re-openable content source. */
    val open: () -> InputStream,
)

data class BackupReport(
    val offered: Int,
    val pushed: Int,
    val ingested: Int,
    val duplicates: Int,
    /** DOG-01b: manifest 回 missing 的 hash 集合（校准确认缓存用——
     *  只查不传语义的产物，非新协议动词）。 */
    val missing: Set<String>,
)

class BackupRunner(private val client: DaemonClient) {

    /**
     * Run one backup batch against [daemon]. Returns the daemon-confirmed
     * report. Throws on transport errors — caller retries; the pipeline
     * is idempotent end to end.
     */
    suspend fun run(
        daemon: PeerAddrParts,
        candidates: List<Candidate>,
        generation: Long?,
    ): BackupReport = withContext(Dispatchers.IO) {
        // begin + manifest on the ctrl plane.
        callOk(daemon, Methods.BACKUP_BEGIN, buildJsonObject {})
        val manifest = BackupManifest(
            hashes = candidates.map { it.hash },
            items = candidates.map {
                BackupItem(hash = it.hash, fileName = it.fileName, mediaType = it.mediaType)
            },
            provider = null, // the phone pushes; it never serves blobs
        )
        val missingResp = callOk(
            daemon, Methods.BACKUP_MANIFEST,
            ProtoJson.encodeToJsonElement(BackupManifest.serializer(), manifest),
        )
        val missing = ProtoJson.decodeFromJsonElement(
            BackupMissing.serializer(), missingResp.result!!
        ).hashes.toSet()

        // Push every missing file over the upload plane, one stream each.
        val toPush = candidates.filter { it.hash in missing }
        val conn = client.connectRaw(daemon, ALPN_UPLOAD)
        try {
            for (c in toPush) {
                pushFile(conn, c)
            }
        } finally {
            conn.close(0L, ByteArray(0))
        }

        // Commit — the daemon ingests from its local store, no dial-back.
        val commitResp = callOk(
            daemon, Methods.BACKUP_COMMIT,
            ProtoJson.encodeToJsonElement(
                BackupCommit.serializer(), BackupCommit(generation = generation)
            ),
        )
        val result = commitResp.result as? kotlinx.serialization.json.JsonObject
        fun field(name: String): Int =
            (result?.get(name) as? kotlinx.serialization.json.JsonPrimitive)
                ?.content?.toIntOrNull() ?: 0
        val ingested = field("ingested")
        val duplicates = field("duplicates")

        BackupReport(
            offered = candidates.size,
            pushed = toPush.size,
            ingested = ingested,
            duplicates = duplicates,
            missing = missing,
        )
    }

    private suspend fun pushFile(conn: Connection, c: Candidate) {
        val bi = conn.openBi()
        val send = bi.send()
        val recv = bi.recv()
        val header = Req(
            id = UUID.randomUUID().toString(),
            method = Methods.BACKUP_UPLOAD,
            params = ProtoJson.encodeToJsonElement(
                UploadHeader.serializer(),
                UploadHeader(hash = c.hash, bytes = c.bytes, fileName = c.fileName),
            ),
        )
        send.writeAll(encodeFrame(Req.serializer(), header))
        c.open().use { input ->
            val buf = ByteArray(CHUNK)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                send.writeAll(if (n == buf.size) buf else buf.copyOf(n))
            }
        }
        send.finish()
        val respHeader = recv.readExact(4u)
        val len = frameLen(respHeader)
        val resp = decodePayload(Resp.serializer(), recv.readExact(len.toUInt()))
        check(resp.ok) { "upload ${c.fileName} rejected: ${resp.error?.msgKey}" }
    }

    private suspend fun callOk(
        daemon: PeerAddrParts,
        method: String,
        params: kotlinx.serialization.json.JsonElement,
    ): Resp {
        val resp = client.call(daemon, method, params)
        check(resp.ok) { "$method failed: ${resp.error?.msgKey}" }
        return resp
    }
}
