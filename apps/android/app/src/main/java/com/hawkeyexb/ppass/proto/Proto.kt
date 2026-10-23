// P-Pass protocol — Kotlin mirror of crates/proto (T-050).
//
// Field-for-field port of msgs.rs / error.rs / version.rs. Drift is
// caught by GoldenDriftTest, which decodes the SAME insta snapshots the
// Rust side asserts against (crates/proto/tests/snapshots). If either
// side changes shape, one of the two suites goes red.
//
// Serde behaviours mirrored via ProtoJson:
//   #[serde(default)]              -> every field has a default value
//   unknown-field tolerance        -> ignoreUnknownKeys = true
//   skip_serializing_if = None     -> explicitNulls = false
package com.hawkeyexb.ppass.proto

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject

const val PROTO_VER: Int = 3
const val MIN_SUPPORTED_VER: Int = 3

/** #1070: a frame without `ver` / `min_ver` comes from a pre-v2 sender. */
const val V1: Int = 1

/** The one Json instance every wire encode/decode must go through. */
val ProtoJson: Json = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

// ── Envelope ────────────────────────────────────────

/** #1070: `ver` / `min_ver` = this build's [PROTO_VER] / [MIN_SUPPORTED_VER] (always encoded). */
@Serializable
data class Req(
    val id: String = "",
    val method: String = "",
    val params: JsonElement = JsonNull,
    @SerialName("min_ver") val minVer: Int = MIN_SUPPORTED_VER,
    val ver: Int = PROTO_VER,
)

/**
 * #1070 protocol v2 error: coarse [code], registered [reason] (see [Reason]), optional [params].
 * #1072: the phone decides on [reason] only; wording is the phone's own (strings.xml).
 */
@Serializable
data class RespError(
    val code: String = "",
    val reason: String = "",
    val params: JsonObject? = null,
)

/** [RespError.reason] mapped onto the registry; anything unregistered is [Reason.UNKNOWN]. */
val RespError.reasonKind: Reason get() = Reason.fromWire(reason)

/**
 * #1070: mirror of `proto::Reason` (wire strings pinned by the `reasons_registry` golden).
 * Decoding never fails on a new value — it lands on [UNKNOWN] and the raw string stays in
 * [RespError.reason].
 */
enum class Reason(val wire: String) {
    NOT_PAIRED("not_paired"),
    ROLE_FORBIDDEN("role_forbidden"),
    PAIR_TOKEN_INVALID("pair_token_invalid"),
    /** #1118: the code typed on the computer did not match the one this phone showed. */
    PAIR_CODE_WRONG("pair_code_wrong"),
    PHONE_OUTDATED("phone_outdated"),
    DESKTOP_OUTDATED("desktop_outdated"),
    UNSUPPORTED_METHOD("unsupported_method"),
    BAD_REQUEST("bad_request"),
    NOT_FOUND("not_found"),
    INTERNAL("internal"),
    BACKUP_FAILED("backup_failed"),
    STORAGE_FULL("storage_full"),
    LIBRARY_UNAVAILABLE("library_unavailable"),
    STORAGE_FAILED("storage_failed"),
    FETCH_FAILED("fetch_failed"),
    PAIRING_MISMATCH("pairing_mismatch"),
    GRANT_NOT_FOUND("grant_not_found"),
    GRANT_CONFLICT("grant_conflict"),
    CANCELLED("cancelled"),
    UNKNOWN("");

    companion object {
        fun fromWire(wire: String): Reason =
            entries.firstOrNull { it != UNKNOWN && it.wire == wire } ?: UNKNOWN
    }
}

/** #1070: `ver` / `min_ver` default to [V1] — a reply without them is from a pre-v2 desktop. */
@Serializable
data class Resp(
    val id: String = "",
    val ok: Boolean = false,
    val result: JsonElement? = null,
    val error: RespError? = null,
    val ver: Int = V1,
    @SerialName("min_ver") val minVer: Int = V1,
)

// ── Hello ───────────────────────────────────────────

@Serializable
data class Hello(
    @SerialName("proto_ver") val protoVer: Int = PROTO_VER,
    val capabilities: List<String> = emptyList(),
    @SerialName("device_name") val deviceName: String = "",
    @SerialName("pairing_id") val pairingId: String? = null,
    /** #413 契约 §5：桌面健康。旧桌面没有这个字段 → null，手机视为健康。 */
    val health: HelloHealth? = null,
)

/** #413 契约 §5：`hello` 回复里的 `health`。字段名固定。 */
@Serializable
data class HelloHealth(
    @SerialName("free_bytes") val freeBytes: Long? = null,
    @SerialName("library_writable") val libraryWritable: Boolean = true,
    @SerialName("index_ok") val indexOk: Boolean = true,
)

// ── Pair ────────────────────────────────────────────

@Serializable
data class PairRequest(
    val token: String = "",
    @SerialName("device_name") val deviceName: String = "",
    val role: String = "member",
    // DEV-01: 重装指纹（SHA-256(Build.MODEL+ANDROID_ID) 前 8 字节 hex）。
    // null = 旧客户端/设置里关了「重装识别」——序列化时省略该键，
    // 帧与 DEV-01 前逐字节一致（proto 演进铁律：旧端互解）。
    /** NET-10 (#128): true = "answer once queued, I will poll pair.status".
     *  null (never false) so a legacy frame omits the key, byte-identical
     *  to the Rust side's skip_serializing_if. */
    @SerialName("ack_then_poll") val ackThenPoll: Boolean? = null,
    /** #1118: the phone's SPAKE2 message (hex, 66 chars) — required by a v3 desktop. */
    @SerialName("pake_a") val pakeA: String? = null,
)

@Serializable
data class PairAccepted(
    @SerialName("storage_device_name") val storageDeviceName: String = "",
    @SerialName("pairing_id") val pairingId: String = "",
)

/** NET-10 (#128): pair.request reply for ackThenPoll — queued, poll [requestId]. */
@Serializable
data class PairSubmitted(
    val accepted: Boolean = false,
    @SerialName("request_id") val requestId: String = "",
    /** Polling deadline from the desktop (single source: its PENDING_TTL_MS). */
    @SerialName("ttl_ms") val ttlMs: Long = 0,
)

/** NET-10 (#128): pair.status params. */
@Serializable
data class PairStatusRequest(
    @SerialName("request_id") val requestId: String = "",
)

/** NET-10 (#128): pair.status reply — pending / accepted / denied / expired / not_found / failed (#1118). */
@Serializable
data class PairStatusReply(
    val state: String = "",
    val accepted: PairAccepted? = null,
    /** #1118: the desktop's SPAKE2 message; appears (state still `pending`) once the owner typed the code. */
    @SerialName("pake_b") val pakeB: String? = null,
    /** #1118: the desktop's key confirmation; present with `accepted`. */
    @SerialName("confirm_b") val confirmB: String? = null,
)

/** NET-10 / #1118: the `pair.status` `state` wire strings (mirror of `proto::PairStatusState`). */
object PairStatusState {
    const val PENDING = "pending"
    const val ACCEPTED = "accepted"
    const val DENIED = "denied"
    const val EXPIRED = "expired"
    /** #1118: the code confirmation did not match — the request and its token are void. */
    const val FAILED = "failed"
    const val NOT_FOUND = "not_found"
}

/** #1118: pair.confirm params — the phone's key confirmation for [requestId]. */
@Serializable
data class PairConfirmRequest(
    @SerialName("request_id") val requestId: String = "",
    @SerialName("confirm_a") val confirmA: String = "",
)

// ── Timeline ────────────────────────────────────────

@Serializable
data class TimelineQuery(
    val cursor: String? = null,
    val limit: Int = 200,
)

@Serializable
data class TimelinePage(
    val items: List<AssetMeta> = emptyList(),
    val next: String? = null,
)

@Serializable
data class AssetMeta(
    val hash: String = "",
    @SerialName("taken_at") val takenAt: Long = 0,
    @SerialName("media_type") val mediaType: String = "",
    val width: Int = 0,
    val height: Int = 0,
    val bytes: Long = 0,
    @SerialName("src_device") val srcDevice: String? = null,
)

// ── Thumbnail ───────────────────────────────────────

/** Wire format: a bare u32 (256 / 1024), same as the Rust enum. */
@Serializable(with = ThumbSizeSerializer::class)
enum class ThumbSize(val px: Int) {
    S256(256),
    S1024(1024);
}

object ThumbSizeSerializer : KSerializer<ThumbSize> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("ThumbSize", PrimitiveKind.INT)

    override fun serialize(encoder: Encoder, value: ThumbSize) =
        encoder.encodeInt(value.px)

    override fun deserialize(decoder: Decoder): ThumbSize =
        when (val v = decoder.decodeInt()) {
            256 -> ThumbSize.S256
            1024 -> ThumbSize.S1024
            else -> throw IllegalArgumentException(
                "unknown ThumbSize: $v (expected 256 or 1024)"
            )
        }
}

@Serializable
data class ThumbGet(
    val hash: String = "",
    val size: ThumbSize = ThumbSize.S256,
)

@Serializable
data class ThumbData(
    @SerialName("jpeg_base64") val jpegBase64: String = "",
    // #527（refs #428）：daemon 回占位图时带上，真图时 Rust 侧不序列化。
    // 手机端目前不消费，只做 wire 镜像，让 GoldenDriftTest 能覆盖这两个 snapshot。
    val placeholder: Boolean = false,
    @SerialName("retry_after_ms") val retryAfterMs: Long = 0,
)

// ── Blob transfer ───────────────────────────────────

@Serializable
data class BlobTicketRequest(val hash: String = "")

@Serializable
data class BlobTicketResponse(val ticket: String = "")

// ── Single-item Flow delivery ───────────────────────

/** Kotlin mirror of proto::FlowFetchRequest. */
@Serializable
data class FlowFetchRequest(
    @SerialName("queue_sequence") val queueSequence: Long = 0L,
    @SerialName("pairing_id") val pairingId: String = "",
    @SerialName("lease_token") val leaseToken: String = "",
    @SerialName("content_hash") val contentHash: String = "",
    @SerialName("file_name") val fileName: String = "",
    @SerialName("media_type") val mediaType: String = "",
    /** Native iroh-blobs ticket for this exact hash. */
    val provider: String = "",
    // DESK-12: MediaStore DATE_TAKEN (unix ms; 0 = unknown) — Desktop uses
    // this only when the file itself has no EXIF, instead of falling back
    // to its own local mtime (which for a Flow-delivered file is the
    // export/ingest moment, not the real capture moment).
    @SerialName("capture_at_ms") val captureAtMs: Long = 0L,
    /** #413 契约 §5：这张的字节数（0 = 未知）。桌面 offer 时按它预检剩余空间，放不下回 `storage_full`。 */
    @SerialName("size_bytes") val sizeBytes: Long = 0L,
)

/** #851：Kotlin mirror of proto::FlowSupersedeRequest——用原图原地替换桌面上抹过地点的旧副本。 */
@Serializable
data class FlowSupersedeRequest(
    @SerialName("pairing_id") val pairingId: String = "",
    @SerialName("old_hash") val oldHash: String = "",
    @SerialName("new_hash") val newHash: String = "",
    /** 原图（new_hash）的 iroh-blobs ticket。 */
    val provider: String = "",
)

/** #1070: Kotlin mirror of proto::FlowFailedPush (`flow.failed` push payload; `reason` replaced `code`). */
@Serializable
data class FlowFailedPush(
    @SerialName("node_id") val nodeId: String = "",
    @SerialName("queue_sequence") val queueSequence: Long = 0L,
    @SerialName("pairing_id") val pairingId: String = "",
    @SerialName("lease_token") val leaseToken: String = "",
    val reason: String = "",
)

/** #851：Kotlin mirror of proto::FlowSupersedeReply。`outcome` = `replaced` / `refused`。 */
@Serializable
data class FlowSupersedeReply(
    val outcome: String = "",
    val reason: String = "",
)

/**
 * #1072: mirror of `proto::SupersedeRefusal` (wire strings pinned against crates/proto msgs.rs by
 * GoldenDriftTest). A refusal this build does not know is [UNKNOWN]; the raw string stays in
 * [FlowSupersedeReply.reason].
 */
enum class SupersedeRefusal(val wire: String) {
    OLD_MISSING("old_missing"),
    NOT_UPLOADER("not_uploader"),
    OLD_CHANGED("old_changed"),
    UNKNOWN_FORMAT("unknown_format"),
    REGION_TOO_LARGE("region_too_large"),
    SIZE_MISMATCH("size_mismatch"),
    INCOMPLETE_RANGES("incomplete_ranges"),
    NOT_A_REDACTION("not_a_redaction"),
    HASH_MISMATCH("hash_mismatch"),
    PAIRING_MISMATCH("pairing_mismatch"),
    BAD_REQUEST("bad_request"),
    FETCH_FAILED("fetch_failed"),
    UNKNOWN("");

    companion object {
        fun fromWire(wire: String): SupersedeRefusal =
            entries.firstOrNull { it != UNKNOWN && it.wire == wire } ?: UNKNOWN
    }
}

/** Kotlin mirror of proto::FlowCompletionReceipt. */
@Serializable
data class FlowCompletionReceipt(
    @SerialName("queue_sequence") val queueSequence: Long = 0L,
    @SerialName("receipt_id") val receiptId: String = "",
    @SerialName("pairing_id") val pairingId: String = "",
    @SerialName("lease_token") val leaseToken: String = "",
    @SerialName("content_hash") val contentHash: String = "",
)

// ── NET-06: async status query + suspend/cancel by tuple (control-plane) ──

/** Kotlin mirror of proto::FlowTupleRef — identifies one exact grant
 *  tuple for `flow.status`/`flow.suspend`/`flow.cancel_tuple`. Deliberately
 *  lighter than [FlowFetchRequest]: no content_hash/provider, so it stays
 *  valid even after the phone has discarded that item's one-shot ticket
 *  (e.g. an item that already failed out to FAILED_NEEDS_USER). */
@Serializable
data class FlowTupleRef(
    @SerialName("queue_sequence") val queueSequence: Long = 0L,
    @SerialName("pairing_id") val pairingId: String = "",
    @SerialName("lease_token") val leaseToken: String = "",
)

/** Kotlin mirror of proto::FlowStatusReply. `state` is one of:
 *  "active" / "completed" / "cancelled" / "not_found". The phone polls
 *  this instead of inferring task state from an RPC round-trip timing out
 *  (NET-01/NET-06: "回声即状态" is the bug this replaces). */
@Serializable
data class FlowStatusReply(
    val state: String = "",
    val receipt: FlowCompletionReceipt? = null,
    @SerialName("task_running") val taskRunning: Boolean = false,
)

// ── Flow audit outbox delivery (AUDIT-01) ────────────

/** Kotlin mirror of proto::FlowAuditEvent — the wire shape of one durable
 *  phone-side outbox event (see backup.flow.AuditOutboxEvent, the ledger's
 *  own domain type this is built from at the delivery boundary). */
@Serializable
data class FlowAuditEvent(
    @SerialName("event_id") val eventId: String = "",
    val kind: String = "",
    @SerialName("round_id") val roundId: String? = null,
    @SerialName("occurred_at_ms") val occurredAtMs: Long = 0L,
    val payload: Map<String, String> = emptyMap(),
)

/** Kotlin mirror of proto::FlowAuditSubmit. */
@Serializable
data class FlowAuditSubmit(
    val events: List<FlowAuditEvent> = emptyList(),
)

/** Kotlin mirror of proto::FlowAuditAccepted. */
@Serializable
data class FlowAuditAccepted(
    @SerialName("event_ids") val eventIds: List<String> = emptyList(),
)

// ── Backup pipeline ─────────────────────────────────

@Serializable
data object BackupBegin

@Serializable
data class BackupItem(
    val hash: String = "",
    @SerialName("file_name") val fileName: String = "",
    @SerialName("media_type") val mediaType: String = "",
)

@Serializable
data class BackupManifest(
    val hashes: List<String> = emptyList(),
    val items: List<BackupItem> = emptyList(),
    val provider: String? = null,
)

@Serializable
data class BackupPresenceQuery(
    val hashes: List<String> = emptyList(),
)

@Serializable
data class BackupMissing(
    val hashes: List<String> = emptyList(),
)

@Serializable
data class BackupCommit(
    /** MediaStore generation watermark, persisted on success (T-053). */
    val generation: Long? = null,
)

// ── Diagnostics ─────────────────────────────────────

@Serializable
data object DiagStatusQuery

@Serializable
data class DiagStatus(
    val state: String = "",
    val detail: String? = null,
)

// ── Constants ───────────────────────────────────────

object Methods {
    const val HELLO = "hello"
    const val PAIR_REQUEST = "pair.request"
    /** NET-10 (#128): read-only verdict query for an ackThenPoll pair.request. */
    const val PAIR_STATUS = "pair.status"
    /** DEV-07 (#463): the submitting phone withdraws its own pending pair.request. */
    const val PAIR_CANCEL = "pair.cancel"
    /** #1118: the phone's key confirmation after the desktop's pake_b appeared. */
    const val PAIR_CONFIRM = "pair.confirm"
    const val TIMELINE_PAGE = "timeline.page"
    const val ASSET_META = "asset.meta"
    const val THUMB_GET = "thumb.get"
    const val ASSET_BLOB_TICKET = "asset.blob_ticket"
    const val FLOW_OFFER = "flow.offer"
    /** NET-06: read-only status query for one exact tuple. */
    const val FLOW_STATUS = "flow.status"
    /** NET-06: pause — interrupts the in-progress native fetch task
     *  WITHOUT changing the durable grant state (stays active). */
    const val FLOW_SUSPEND = "flow.suspend"
    /** NET-06: cancel by tuple identity alone — no content_hash/provider
     *  required. */
    const val FLOW_CANCEL_TUPLE = "flow.cancel_tuple"
    /** AUDIT-01: phone-side durable outbox events -> daemon v2 audit repo. */
    const val FLOW_AUDIT_SUBMIT = "flow.audit.submit"
    /** #851：用原图原地替换抹过地点的旧副本；只在 hello 宣告 [FLOW_SUPERSEDE_CAPABILITY] 时调用。 */
    const val FLOW_SUPERSEDE = "flow.supersede"
    const val BACKUP_BEGIN = "backup.begin"
    const val BACKUP_MANIFEST = "backup.manifest"
    const val BACKUP_PRESENCE = "backup.presence"
    const val BACKUP_COMMIT = "backup.commit"
    const val DIAG_STATUS = "diag.status"
    /** SYNC-04: 前台常驻订阅——见 DaemonClient.subscribeTimeline。 */
    const val TIMELINE_SUBSCRIBE = "timeline.subscribe"
}

/** #851：桌面支持 `flow.supersede`。旧桌面没有它——手机就不重读已备份的照片（否则原图会成为第二张）。 */
const val FLOW_SUPERSEDE_CAPABILITY = "flow.supersede.v1"

object Codes {
    const val NOT_AUTHORIZED = "NOT_AUTHORIZED"
    const val INVALID_REQUEST = "INVALID_REQUEST"
    const val NOT_FOUND = "NOT_FOUND"
    const val STORAGE_FULL = "STORAGE_FULL"
    const val VERSION_MISMATCH = "VERSION_MISMATCH"
    const val INTERNAL = "INTERNAL"
    /** #1070 categories. */
    const val DESKTOP_STORAGE = "DESKTOP_STORAGE"
    const val PATH_FAILED = "PATH_FAILED"
    const val FLOW_REJECTED = "FLOW_REJECTED"
}
