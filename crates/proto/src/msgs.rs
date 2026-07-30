//! P-Pass protocol — wire message types.
//!
//! Every struct carries `#[serde(default)]` so that deserialisation
//! is forward-compatible: missing fields from newer peers fall back
//! to the Rust `Default` for that type.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::RespError;

// ── Envelope ────────────────────────────────────────

/// Unified request envelope.
///
/// `id` is a client-generated UUID v4 string for request/response correlation.
/// `params` is method-specific; its shape is validated by the method handler.
/// `min_ver` lets the sender declare the oldest protocol version it accepts
/// in the response (defaults to `PROTO_VER` when omitted).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Req {
    pub id: String,
    /// Method name (e.g. `"hello"`, `"timeline.page"`).
    pub method: String,
    /// Method-specific parameters as a JSON value.
    pub params: Value,
    /// Minimum protocol version the sender expects in the response.
    /// Defaults to `MIN_SUPPORTED_VER` (most conservative: assume oldest peer).
    pub min_ver: u16,
}

#[allow(clippy::derivable_impls)]
impl Default for Req {
    fn default() -> Self {
        Self {
            id: String::new(),
            method: String::new(),
            params: Value::Null,
            min_ver: super::MIN_SUPPORTED_VER,
        }
    }
}

/// Unified response envelope.
///
/// When `ok` is `true`, `result` carries the method-specific payload.
/// When `ok` is `false`, `error` carries the error code and localisation key.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct Resp {
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RespError>,
}

impl Resp {
    /// Build a success response.
    pub fn ok(id: impl Into<String>, result: Value) -> Self {
        Self {
            id: id.into(),
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    /// Build an error response.
    pub fn err(id: impl Into<String>, error: RespError) -> Self {
        Self {
            id: id.into(),
            ok: false,
            result: None,
            error: Some(error),
        }
    }
}

// ── Hello ───────────────────────────────────────────

/// Sent by the connecting peer immediately after ALPN handshake.
/// Both sides exchange Hello to negotiate capabilities.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Hello {
    /// Protocol version the sender is speaking.
    pub proto_ver: u16,
    /// Capability strings (e.g. `"thumbnail.v1"`, `"video.range.v1"`).
    pub capabilities: Vec<String>,
    /// Human-readable device name for UI display.
    pub device_name: String,
}

#[allow(clippy::derivable_impls)]
impl Default for Hello {
    fn default() -> Self {
        Self {
            proto_ver: super::PROTO_VER,
            capabilities: Vec::new(),
            device_name: String::new(),
        }
    }
}

// ── Pair ────────────────────────────────────────────

/// Pairing request (sent from joining device to storage owner).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct PairRequest {
    /// One-time token from the QR code (32B hex).
    pub token: String,
    /// Human-readable device name.
    pub device_name: String,
    /// Requested role: `"member"` or `"viewer"`.
    pub role: String,
}

#[allow(clippy::derivable_impls)]
impl Default for PairRequest {
    fn default() -> Self {
        Self {
            token: String::new(),
            device_name: String::new(),
            role: String::from("member"),
        }
    }
}

/// Pairing accepted response.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct PairAccepted {
    /// Storage-side information (device name, version, etc.).
    pub storage_device_name: String,
}

// ── Timeline ────────────────────────────────────────

/// Query a page of the asset timeline.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct TimelineQuery {
    /// Opaque cursor for the next page (omitted for first page).
    pub cursor: Option<String>,
    /// Maximum number of items to return.
    pub limit: u32,
}

#[allow(clippy::derivable_impls)]
impl Default for TimelineQuery {
    fn default() -> Self {
        Self {
            cursor: None,
            limit: 200,
        }
    }
}

/// A page of timeline results.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct TimelinePage {
    pub items: Vec<AssetMeta>,
    /// Opaque cursor for the next page, or `None` if this is the last page.
    pub next: Option<String>,
}

// ── Asset ───────────────────────────────────────────

/// Metadata for a single asset (photo or video).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct AssetMeta {
    /// BLAKE3 content hash (hex-encoded, 64 chars).
    pub hash: String,
    /// Unix timestamp from EXIF (seconds).
    pub taken_at: i64,
    /// Media type: `"photo"` or `"video"`.
    pub media_type: String,
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
    /// File size in bytes.
    pub bytes: u64,
}

// ── Thumbnail ───────────────────────────────────────

/// Preset thumbnail sizes.
/// Serialised as a u32 integer (e.g. 256, 1024) — not a string.
/// This is the final wire format; chosen before any peer implementation exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ThumbSize {
    /// 256 px thumbnail for grid display.
    #[default]
    S256 = 256,
    /// 1024 px preview for detail view.
    S1024 = 1024,
}

impl serde::Serialize for ThumbSize {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        (*self as u32).serialize(serializer)
    }
}

impl<'de> serde::Deserialize<'de> for ThumbSize {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let val = u32::deserialize(deserializer)?;
        match val {
            256 => Ok(ThumbSize::S256),
            1024 => Ok(ThumbSize::S1024),
            other => Err(serde::de::Error::custom(format!(
                "unknown ThumbSize: {} (expected 256 or 1024)",
                other
            ))),
        }
    }
}

/// Request a thumbnail for a given asset.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct ThumbGet {
    /// BLAKE3 hash of the asset.
    pub hash: String,
    /// Requested thumbnail size.
    pub size: ThumbSize,
}

// ── Blob transfer ───────────────────────────────────

/// Request a blob transfer ticket (i.e. a BLAKE3 hash).
/// The ticket is used with iroh-blobs to start the content transfer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct BlobTicketRequest {
    pub hash: String,
}

/// Blob ticket response.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct BlobTicketResponse {
    /// iroh-blobs ticket string for initiating the transfer.
    pub ticket: String,
}

// ── Backup pipeline ─────────────────────────────────

/// Initiate a backup session. The client signals begin, then sends a
/// manifest of candidate hashes; the storage side responds with the list
/// of hashes it does not yet have (BackupMissing).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct BackupBegin {}

/// Send a list of candidate hashes for dedup check.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct BackupManifest {
    /// Candidate BLAKE3 hashes the client wants to upload.
    pub hashes: Vec<String>,
    /// Per-file metadata (T-032) — ingest needs a file name and MIME type
    /// per hash. Optional and skipped when empty so pre-T-032 frames are
    /// byte-identical (protocol evolution, not a breaking change).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub items: Vec<BackupItem>,
}

/// One file the client offers in a backup manifest (T-032).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct BackupItem {
    /// BLAKE3 content hash, 64 hex chars.
    pub hash: String,
    /// Uploader-side file name, e.g. `IMG_1234.HEIC`.
    pub file_name: String,
    /// MIME type, e.g. `image/heic`.
    pub media_type: String,
}

/// Response: which hashes the storage side does NOT yet have.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct BackupMissing {
    pub hashes: Vec<String>,
}

/// Commit a backup batch — the client confirms that all missing
/// blobs from this batch are available for transfer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct BackupCommit {
    /// Client-side incremental-scan watermark to persist on success
    /// (MediaStore generation on Android). Skipped when absent so
    /// pre-T-032 frames are byte-identical.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generation: Option<i64>,
}

// ── Diagnostics ─────────────────────────────────────

/// Request a diagnostic status snapshot.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct DiagStatusQuery {}

/// Diagnostic status response.
///
/// `state` is one of the canonical states:
/// `ONLINE_DIRECT`, `ONLINE_RELAY`, `STORAGE_OFFLINE`, `PAIRING`,
/// `DISK_FULL`, `INDEXING`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct DiagStatus {
    /// Canonical state machine value.
    pub state: String,
    /// Optional human-readable detail (e.g. `"free: 1.2 GB"`, `"last_seen: 2026-07-25T23:11:03Z"`).
    pub detail: Option<String>,
}

// ── Method name constants ───────────────────────────

/// Well-known method names used in `Req.method`.
pub mod methods {
    pub const HELLO: &str = "hello";
    pub const PAIR_REQUEST: &str = "pair.request";
    pub const TIMELINE_PAGE: &str = "timeline.page";
    pub const ASSET_META: &str = "asset.meta";
    pub const THUMB_GET: &str = "thumb.get";
    pub const ASSET_BLOB_TICKET: &str = "asset.blob_ticket";
    pub const BACKUP_BEGIN: &str = "backup.begin";
    pub const BACKUP_MANIFEST: &str = "backup.manifest";
    pub const BACKUP_COMMIT: &str = "backup.commit";
    pub const DIAG_STATUS: &str = "diag.status";
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Envelope roundtrip ──────────────────────────

    #[test]
    fn req_roundtrip() {
        let req = Req {
            id: "abc-123".into(),
            method: "hello".into(),
            params: serde_json::json!({"proto_ver": 1}),
            min_ver: 1,
        };
        let json = serde_json::to_string(&req).unwrap();
        let back: Req = serde_json::from_str(&json).unwrap();
        assert_eq!(req, back);
    }

    #[test]
    fn resp_ok_roundtrip() {
        let resp = Resp::ok("abc-123", serde_json::json!({"state": "online"}));
        let json = serde_json::to_string(&resp).unwrap();
        let back: Resp = serde_json::from_str(&json).unwrap();
        assert_eq!(resp, back);
    }

    #[test]
    fn resp_err_roundtrip() {
        let resp = Resp::err("abc-123", RespError::new("NOT_FOUND", "err.not_found"));
        let json = serde_json::to_string(&resp).unwrap();
        let back: Resp = serde_json::from_str(&json).unwrap();
        assert_eq!(resp, back);
    }

    // ── Message roundtrips ──────────────────────────

    macro_rules! roundtrip_test {
        ($name:ident, $ty:ty, $val:expr) => {
            #[test]
            fn $name() {
                let val: $ty = $val;
                let json = serde_json::to_string(&val).unwrap();
                let back: $ty = serde_json::from_str(&json).unwrap();
                assert_eq!(val, back);
            }
        };
    }

    roundtrip_test!(
        hello_roundtrip,
        Hello,
        Hello {
            proto_ver: 1,
            capabilities: vec!["thumbnail.v1".into()],
            device_name: "Salamira's Phone".into(),
        }
    );

    roundtrip_test!(
        pair_request_roundtrip,
        PairRequest,
        PairRequest {
            token: "abcd1234".into(),
            device_name: "Mom's Phone".into(),
            role: "member".into(),
        }
    );

    roundtrip_test!(
        pair_accepted_roundtrip,
        PairAccepted,
        PairAccepted {
            storage_device_name: "Home PC".into(),
        }
    );

    roundtrip_test!(
        timeline_query_roundtrip,
        TimelineQuery,
        TimelineQuery {
            cursor: Some("opaque-cursor".into()),
            limit: 50,
        }
    );

    roundtrip_test!(
        timeline_page_roundtrip,
        TimelinePage,
        TimelinePage {
            items: vec![AssetMeta {
                hash: "abcdef1234567890".into(),
                taken_at: 1690000000,
                media_type: "photo".into(),
                width: 4032,
                height: 3024,
                bytes: 3_500_000,
            }],
            next: Some("next-cursor".into()),
        }
    );

    roundtrip_test!(
        asset_meta_roundtrip,
        AssetMeta,
        AssetMeta {
            hash: "abcdef1234567890".into(),
            taken_at: 1690000000,
            media_type: "video".into(),
            width: 1920,
            height: 1080,
            bytes: 50_000_000,
        }
    );

    roundtrip_test!(
        thumb_get_roundtrip,
        ThumbGet,
        ThumbGet {
            hash: "abcdef1234567890".into(),
            size: ThumbSize::S1024,
        }
    );

    roundtrip_test!(
        blob_ticket_req_roundtrip,
        BlobTicketRequest,
        BlobTicketRequest {
            hash: "abcdef1234567890".into(),
        }
    );

    roundtrip_test!(
        blob_ticket_resp_roundtrip,
        BlobTicketResponse,
        BlobTicketResponse {
            ticket: "blob_ticket_here".into(),
        }
    );

    roundtrip_test!(
        backup_manifest_roundtrip,
        BackupManifest,
        BackupManifest {
            hashes: vec!["hash1".into(), "hash2".into()],
            items: vec![BackupItem {
                hash: "hash1".into(),
                file_name: "IMG_1.jpg".into(),
                media_type: "image/jpeg".into(),
            }],
        }
    );

    roundtrip_test!(
        backup_missing_roundtrip,
        BackupMissing,
        BackupMissing {
            hashes: vec!["hash1".into()],
        }
    );

    roundtrip_test!(
        diag_status_roundtrip,
        DiagStatus,
        DiagStatus {
            state: "ONLINE_DIRECT".into(),
            detail: Some("last seen just now".into()),
        }
    );

    // ── Unknown field tolerance ─────────────────────

    #[test]
    fn unknown_field_tolerant() {
        // Extra unknown fields in JSON should NOT cause deserialisation errors.
        let json = r#"{
            "hash": "abc123",
            "size": 256,
            "extra_thing": 42,
            "future_field": "value"
        }"#;
        let tg: ThumbGet = serde_json::from_str(json).unwrap();
        assert_eq!(tg.hash, "abc123");
        assert_eq!(tg.size, ThumbSize::S256);
    }

    #[test]
    fn unknown_field_in_envelope() {
        // Envelope with extra fields still works.
        let json = r#"{
            "id": "u-1",
            "method": "hello",
            "params": {},
            "min_ver": 1,
            "x_custom": null
        }"#;
        let req: Req = serde_json::from_str(json).unwrap();
        assert_eq!(req.id, "u-1");
        assert_eq!(req.method, "hello");
    }

    // ── Default-value tolerance ─────────────────────

    #[test]
    fn partial_fields_defaults() {
        // Missing fields should fall back to Default.
        let json = r#"{"hash": "abc123"}"#;
        let tg: ThumbGet = serde_json::from_str(json).unwrap();
        assert_eq!(tg.hash, "abc123");
        // size absent → check that default is S256
        let default_s256: ThumbSize = Default::default();
        assert_eq!(tg.size, default_s256);
    }

    #[test]
    fn empty_object_defaults() {
        // Completely empty object should work for types with all default fields.
        let json = "{}";
        let req: Req = serde_json::from_str(json).unwrap();
        assert_eq!(req.id, "");
        assert_eq!(req.method, "");
        assert_eq!(req.params, Value::Null);
        assert_eq!(req.min_ver, super::super::MIN_SUPPORTED_VER);
    }

    #[test]
    fn thumb_size_serialisation() {
        assert_eq!(serde_json::to_string(&ThumbSize::S256).unwrap(), "256");
        assert_eq!(serde_json::to_string(&ThumbSize::S1024).unwrap(), "1024");
        let s: ThumbSize = serde_json::from_str("256").unwrap();
        assert_eq!(s, ThumbSize::S256);
        let s1024: ThumbSize = serde_json::from_str("1024").unwrap();
        assert_eq!(s1024, ThumbSize::S1024);
    }
}
