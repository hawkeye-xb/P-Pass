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

const val PROTO_VER: Int = 1
const val MIN_SUPPORTED_VER: Int = 1

/** The one Json instance every wire encode/decode must go through. */
val ProtoJson: Json = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

// ── Envelope ────────────────────────────────────────

@Serializable
data class Req(
    val id: String = "",
    val method: String = "",
    val params: JsonElement = JsonNull,
    @SerialName("min_ver") val minVer: Int = MIN_SUPPORTED_VER,
)

@Serializable
data class RespError(
    val code: String = "",
    @SerialName("msg_key") val msgKey: String = "",
)

@Serializable
data class Resp(
    val id: String = "",
    val ok: Boolean = false,
    val result: JsonElement? = null,
    val error: RespError? = null,
)

// ── Hello ───────────────────────────────────────────

@Serializable
data class Hello(
    @SerialName("proto_ver") val protoVer: Int = PROTO_VER,
    val capabilities: List<String> = emptyList(),
    @SerialName("device_name") val deviceName: String = "",
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
    @SerialName("device_hint")
    val deviceHint: String? = null,
)

@Serializable
data class PairAccepted(
    @SerialName("storage_device_name") val storageDeviceName: String = "",
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
)

// ── Blob transfer ───────────────────────────────────

@Serializable
data class BlobTicketRequest(val hash: String = "")

@Serializable
data class BlobTicketResponse(val ticket: String = "")

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
data class BackupMissing(
    val hashes: List<String> = emptyList(),
)

@Serializable
data class BackupCommit(
    /** MediaStore generation watermark, persisted on success (T-053). */
    val generation: Long? = null,
)

/** Upload plane (T-054): header frame before one file's raw bytes. */
@Serializable
data class UploadHeader(
    val hash: String = "",
    val bytes: Long = 0,
    @SerialName("file_name") val fileName: String = "",
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
    const val TIMELINE_PAGE = "timeline.page"
    const val ASSET_META = "asset.meta"
    const val THUMB_GET = "thumb.get"
    const val ASSET_BLOB_TICKET = "asset.blob_ticket"
    const val BACKUP_BEGIN = "backup.begin"
    const val BACKUP_MANIFEST = "backup.manifest"
    const val BACKUP_COMMIT = "backup.commit"
    const val DIAG_STATUS = "diag.status"
    const val BACKUP_UPLOAD = "backup.upload"
}

object Codes {
    const val NOT_AUTHORIZED = "NOT_AUTHORIZED"
    const val INVALID_REQUEST = "INVALID_REQUEST"
    const val NOT_FOUND = "NOT_FOUND"
    const val STORAGE_FULL = "STORAGE_FULL"
    const val VERSION_MISMATCH = "VERSION_MISMATCH"
    const val INTERNAL = "INTERNAL"
}
