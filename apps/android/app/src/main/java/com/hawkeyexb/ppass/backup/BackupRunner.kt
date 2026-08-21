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
import kotlinx.coroutines.ensureActive
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
        // 2026-08-17：设计稿要求"正在备份 {文件名}（第 x / y 张）"——
        // 加一个文件名参数，取刚推完这个文件的 fileName（sent=0 时还
        // 没有当前文件，传空串，调用方按 sent>0 判断要不要显示文件名）。
        onProgress: (sent: Int, total: Int, fileName: String) -> Unit = { _, _, _ -> },
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
        // 2026-08-14：真实进度回调——之前这个循环对调用方完全不可见，
        // UI 只能在批次开始时钉死 Sending(0,N) 然后一路卡到批次结束才
        // 跳到 AllSafe（真机实测反馈：进度条像卡死了，一大批"突然"传完）。
        // toPush.size 才是这次真的要传的数量（manifest 去重后，可能比
        // 外层预估的 fresh.size 小）——先报一次校正总数，再逐条报进度。
        onProgress(0, toPush.size, "")
        val conn = client.connectRaw(daemon, ALPN_UPLOAD)
        try {
            toPush.forEachIndexed { i, c ->
                // UX-01: 协作取消点——用户点「暂停」（job.cancel）后，
                // 这里在下一个文件边界立即抛 CancellationException 中断
                // 当前批；未 commit，水位不推进，幂等管线安全。
                coroutineContext.ensureActive()
                pushFile(conn, c)
                onProgress(i + 1, toPush.size, c.fileName)
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

    /** DOG-01c: 漂移校准的只查不传 exist-check——用缓存 hash 集问 daemon
     *  「哪些已不在库」（只发 manifest，不 begin 不 push 不 commit）。返回
     *  missing 集合；daemon 不可达/未配对时抛错，由调用方跳过
     *  （三元组显示缓存值，不归零不崩）。
     *
     *  ⚠️ MOB-32：这里原本先发一次 `backup.BEGIN`。校准根本不需要会话
     *  （`manifest` 自己会 `entry().or_default()`），而 daemon 侧的会话是
     *  **按设备 NodeId** 索引的——于是「备份途中打开 App」= 校准把正在跑
     *  的那一轮清空，186 张照片传上来后被静默丢弃。daemon 侧已经修成
     *  「begin 不破坏活会话」（旧版 APK 打新 daemon 也安全），这里顺手把
     *  这次多余的往返也去掉。 */
    suspend fun existCheck(daemon: PeerAddrParts, hashes: Set<String>): Set<String> =
        withContext(Dispatchers.IO) {
            val manifest = BackupManifest(
                hashes = hashes.toList(),
                items = emptyList(),
                provider = null,
            )
            val resp = callOk(
                daemon, Methods.BACKUP_MANIFEST,
                ProtoJson.encodeToJsonElement(BackupManifest.serializer(), manifest),
            )
            ProtoJson.decodeFromJsonElement(
                BackupMissing.serializer(), resp.result!!
            ).hashes.toSet()
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
