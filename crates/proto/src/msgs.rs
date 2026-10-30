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
/// `ver` / `min_ver` are the sender's [`crate::PROTO_VER`] /
/// [`crate::MIN_SUPPORTED_VER`] (#1070 in-band negotiation). A frame without
/// them comes from a v1 peer and decodes as `1` / `1`; a freshly built
/// `Req::default()` carries this build's numbers.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Req {
    pub id: String,
    /// Method name (e.g. `"hello"`, `"timeline.page"`).
    pub method: String,
    /// Method-specific parameters as a JSON value.
    pub params: Value,
    /// Sender's protocol version.
    #[serde(default = "v1")]
    pub ver: u16,
    /// Oldest protocol version the sender still accepts.
    #[serde(default = "v1")]
    pub min_ver: u16,
}

/// Wire default for a missing `ver` / `min_ver`: the peer predates v2.
fn v1() -> u16 {
    crate::version::V1
}

impl Default for Req {
    fn default() -> Self {
        Self {
            id: String::new(),
            method: String::new(),
            params: Value::Null,
            ver: super::PROTO_VER,
            min_ver: super::MIN_SUPPORTED_VER,
        }
    }
}

impl Req {
    /// The sender's declared versions.
    pub fn versions(&self) -> crate::Versions {
        crate::Versions {
            ver: self.ver,
            min_ver: self.min_ver,
        }
    }
}

/// Unified response envelope.
///
/// When `ok` is `true`, `result` carries the method-specific payload.
/// When `ok` is `false`, `error` carries the [`RespError`] (code / reason / params).
/// `ver` / `min_ver` follow the same rule as [`Req`]: missing = a v1 sender.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Resp {
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RespError>,
    #[serde(default = "v1")]
    pub ver: u16,
    #[serde(default = "v1")]
    pub min_ver: u16,
}

impl Default for Resp {
    fn default() -> Self {
        Self {
            id: String::new(),
            ok: false,
            result: None,
            error: None,
            ver: super::PROTO_VER,
            min_ver: super::MIN_SUPPORTED_VER,
        }
    }
}

impl Resp {
    /// Build a success response.
    pub fn ok(id: impl Into<String>, result: Value) -> Self {
        Self {
            id: id.into(),
            ok: true,
            result: Some(result),
            ..Self::default()
        }
    }

    /// Build an error response.
    pub fn err(id: impl Into<String>, error: RespError) -> Self {
        Self {
            id: id.into(),
            ok: false,
            error: Some(error),
            ..Self::default()
        }
    }

    /// The sender's declared versions.
    pub fn versions(&self) -> crate::Versions {
        crate::Versions {
            ver: self.ver,
            min_ver: self.min_ver,
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
    /// Current Flow authorization generation for this authenticated member.
    /// Omitted for unpaired peers so hello remains a zero-data handshake there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pairing_id: Option<String>,
    /// #413 §7: Desktop health, carried only on the Desktop's reply to a
    /// paired member (same zero-data rule as `pairing_id`). Omitted
    /// entirely otherwise; a phone that sees no `health` treats the Desktop
    /// as healthy (old Desktop builds never send it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub health: Option<DesktopHealth>,
}

/// #413 §7 / contract §5: what the phone checks before it asks for a
/// foreground service. Field names are a fixed W1↔W4 contract.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(default)]
pub struct DesktopHealth {
    /// Bytes an unprivileged writer can still use on the photo library's
    /// volume (`statvfs` `f_bavail` semantics). `null` = this platform could
    /// not answer — never a made-up number.
    pub free_bytes: Option<i64>,
    /// The photo library folder exists and a file can be created in it.
    pub library_writable: bool,
    /// The index database answers a query.
    pub index_ok: bool,
}

#[allow(clippy::derivable_impls)]
impl Default for Hello {
    fn default() -> Self {
        Self {
            proto_ver: super::PROTO_VER,
            capabilities: Vec::new(),
            device_name: String::new(),
            pairing_id: None,
            health: None,
        }
    }
}

// ── Pair ────────────────────────────────────────────

/// Pairing request (sent from joining device to storage owner).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct PairRequest {
    /// One-time token from the QR code (12 bytes, 24 hex chars).
    pub token: String,
    /// Human-readable device name.
    pub device_name: String,
    /// Requested role: `"member"` or `"viewer"`.
    pub role: String,
    /// NET-10 (#128): the caller will poll `pair.status` for the owner's
    /// verdict, so the daemon answers as soon as the request is queued
    /// ([`PairSubmitted`]) instead of holding this RPC open until a human
    /// clicks. #1050: this is the only shape the daemon serves — a request
    /// with `false` (or the key omitted) is refused as `phone_outdated` (#1070);
    /// the blocking reply is gone. The field stays on the wire because
    /// every supported phone (Android ≥ v0.9.0, iOS) sends `true` and both
    /// phones' golden snapshots pin it; the key is skipped when false so
    /// the `pair_request` snapshot stays identical.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ack_then_poll: bool,
    /// #1118: the phone's first SPAKE2 message (`crates/pair-pake`, 33 bytes, lowercase hex).
    /// The phone generated a 6-digit code (shown to the user only after [`PairSubmitted`]) and
    /// committed to it here; the desktop answers once the owner has typed that code. Required:
    /// a request without it is refused as `phone_outdated`. Skipped when empty so the legacy
    /// `pair_request` samples stay identical.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub pake_a: String,
}

#[allow(clippy::derivable_impls)]
impl Default for PairRequest {
    fn default() -> Self {
        Self {
            token: String::new(),
            device_name: String::new(),
            role: String::from("member"),
            ack_then_poll: false,
            pake_a: String::new(),
        }
    }
}

/// NET-10 (#128): `pair.request` reply when `ack_then_poll` is set — the
/// token was valid and the request sits in the owner's queue. The verdict
/// is read through `pair.status(request_id)`, never inferred from how long
/// this RPC took.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct PairSubmitted {
    /// Always `true` on an ok reply (a bad token is an error reply).
    pub accepted: bool,
    /// Opaque id naming this request in the daemon's pairing ledger. Only
    /// the NodeId that submitted it can query it.
    pub request_id: String,
    /// How much longer the daemon keeps this request pending for the
    /// owner — the phone's polling deadline. The daemon's
    /// `PENDING_TTL_MS` stays the single source of that number.
    pub ttl_ms: i64,
}

/// NET-10 (#128): `pair.status` params.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct PairStatusRequest {
    pub request_id: String,
}

/// NET-10 (#128): `pair.status` reply — same shape as [`FlowStatusReply`]:
/// a state plus the terminal payload when there is one.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct PairStatusReply {
    pub state: PairStatusState,
    /// Present only when `state == accepted`. Replayed identically on
    /// every query for as long as the ledger keeps the entry.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accepted: Option<PairAccepted>,
    /// #1118: the desktop's SPAKE2 answer (33 bytes, hex). Present while `state == pending` once
    /// the owner has typed the code; the phone then sends `pair.confirm`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pake_b: Option<String>,
    /// #1118: the desktop's key confirmation `cB` (32 bytes, hex), sent only after the phone's
    /// `cA` checked out. Present with `state == accepted`; the phone verifies it before saving
    /// the pairing (mutual proof that both sides used the same code).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub confirm_b: Option<String>,
}

/// #1118: `pair.confirm` params — the phone's key confirmation for one request.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct PairConfirmRequest {
    pub request_id: String,
    /// `cA` (32 bytes, hex). Checked once: a mismatch voids the request and its token
    /// (`pair_code_wrong`), and the phone must scan again.
    pub confirm_a: String,
}

/// #1070: the `pair.status` / `pair.cancel` verdict. A denial carries no
/// reason key any more — "the owner said no" is the state itself.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum PairStatusState {
    #[default]
    Pending,
    Accepted,
    Denied,
    Expired,
    /// #1118: the code confirmation did not match — the request and its token are void.
    Failed,
    /// Unknown id, another device's id, or the daemon restarted and its
    /// in-memory ledger is gone.
    NotFound,
}

/// Pairing accepted response.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct PairAccepted {
    /// Storage-side information (device name, version, etc.).
    pub storage_device_name: String,
    /// Fresh owner-approved pairing generation. New Flow delivery rejects
    /// requests whose epoch is not this currently persisted value.
    pub pairing_id: String,
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
    /// Full hex NodeId of the device that contributed this asset.
    ///
    /// `None` is the wire-compatible representation of legacy/rebuilt rows
    /// whose source identity is unavailable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub src_device: Option<String>,
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

/// Thumbnail response payload (T-033): the JPEG, base64-encoded inside
/// the ctrl-plane JSON frame. Thumbs are tens of KB — far under the
/// 16 MiB frame cap; originals go over blobs instead.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct ThumbData {
    pub jpeg_base64: String,
    /// DESK-34 (#428): `true` when `jpeg_base64` is the daemon's built-in
    /// placeholder, not the asset's pixels — the caller must not treat it
    /// as final. Skipped when `false`, so a real-thumb frame is byte-for-byte
    /// what it was before this field existed (old clients: unknown key only
    /// on placeholder answers; Android's `ProtoJson` ignores unknown keys).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub placeholder: bool,
    /// DESK-34 (#428): with `placeholder`, how long until asking again can
    /// give a different answer — the remaining negative-cache window, or the
    /// generation budget while a slow generation is still running. `0`
    /// (skipped) means "no point retrying" (unknown asset / bad hash) or,
    /// with `placeholder = false`, nothing to retry.
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub retry_after_ms: u64,
}

fn is_zero_u64(v: &u64) -> bool {
    *v == 0
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

// ── Single-item flow delivery ───────────────────────

/// Register one new-flow delivery (`flow.offer`). This is intentionally separate
/// from the legacy batch manifest/push/commit protocol: one queue item has one
/// pairing epoch, one lease, and one BLAKE3 hash.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowFetchRequest {
    pub queue_sequence: u64,
    pub pairing_id: String,
    pub lease_token: String,
    /// BLAKE3 content hash as 64 lowercase-or-uppercase hex characters.
    pub content_hash: String,
    pub file_name: String,
    pub media_type: String,
    /// Provider endpoint address token, consumed only by iroh-blobs.
    pub provider: String,
    /// DESK-12: MediaStore `DATE_TAKEN` (or EXIF fallback) as unix ms — the
    /// phone's fact about when the photo was actually taken. 0 = unknown
    /// (old client, or the phone itself never resolved a capture time);
    /// Desktop must fall back to its own EXIF/mtime probe, never to the
    /// ingest wall-clock. `#[serde(default)]` on this struct makes the field
    /// backward compatible with an older phone build that never sends it.
    pub capture_at_ms: i64,
    /// #413 §7: the item's size in bytes as the phone knows it. 0 = unknown
    /// (old client). Desktop prechecks free space with it at offer time and
    /// refuses with `storage_full` before fetching a single byte.
    pub size_bytes: i64,
    /// #1272: how this item came to be sent — the automatic backup rule, or the user picking it
    /// once in the system photo picker. Optional and never required: an old phone omits it (auto),
    /// an automatic item is not sent at all, and an old desktop ignores the key.
    #[serde(skip_serializing_if = "FlowItemSource::is_auto")]

    pub source: FlowItemSource,
}

/// #1272: the origin of one [`FlowFetchRequest`]. Unknown values decode as [`Self::Auto`] so a
/// newer phone never breaks an older desktop's offer parsing.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum FlowItemSource {
    /// The automatic backup rule (albums + time range). The default.
    #[default]
    Auto,
    /// Picked once by the user in the system photo picker; never part of the backup scope.
    Picked,
}

impl FlowItemSource {
    pub fn is_auto(&self) -> bool {
        *self == Self::Auto
    }

    /// Stable storage / wire spelling.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Picked => "picked",
        }
    }

    /// Inverse of [`Self::as_str`]; anything else is [`Self::Auto`].
    pub fn from_wire(value: &str) -> Self {
        match value {
            "picked" => Self::Picked,
            _ => Self::Auto,
        }
    }
}

impl<'de> Deserialize<'de> for FlowItemSource {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = Option::<String>::deserialize(deserializer)?;
        Ok(value.as_deref().map_or(Self::Auto, Self::from_wire))
    }
}

/// #851 `flow.supersede`: replace the Desktop's location-redacted copy of a photo (`old_hash`,
/// uploaded by this phone before it held `ACCESS_MEDIA_LOCATION`) with the original bytes
/// (`new_hash`) the phone can read now — in place, so the library still holds one photo.
///
/// The Desktop fetches only the metadata byte ranges of `new_hash` from `provider` (the phone's
/// blob ticket for it), splices them into its copy of `old_hash`, and replaces only if the result
/// hashes to `new_hash` and every changed byte was zero in the old copy (Android's redaction zeroes
/// the location bytes and keeps the length). A phone sends this only when hello advertises
/// `flow.supersede.v1`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowSupersedeRequest {
    pub pairing_id: String,
    /// BLAKE3 hex of the copy the Desktop holds (location-redacted).
    pub old_hash: String,
    /// BLAKE3 hex of the original the phone holds now.
    pub new_hash: String,
    /// The phone's iroh-blobs ticket for `new_hash`.
    pub provider: String,
}

/// Reply to [`FlowSupersedeRequest`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowSupersedeReply {
    /// `"replaced"` (now holds `new_hash`, including a replay of a finished request) or
    /// `"refused"` (nothing changed; the old copy stays).
    pub outcome: String,
    /// Why it was refused. Absent when replaced.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<SupersedeRefusal>,
}

/// #1070: why a `flow.supersede` was refused. Wire strings are unchanged
/// from the pre-v2 free-text field.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SupersedeRefusal {
    OldMissing,
    NotUploader,
    OldChanged,
    UnknownFormat,
    RegionTooLarge,
    SizeMismatch,
    IncompleteRanges,
    NotARedaction,
    HashMismatch,
    PairingMismatch,
    BadRequest,
    FetchFailed,
}

impl SupersedeRefusal {
    pub const ALL: &'static [SupersedeRefusal] = &[
        Self::OldMissing,
        Self::NotUploader,
        Self::OldChanged,
        Self::UnknownFormat,
        Self::RegionTooLarge,
        Self::SizeMismatch,
        Self::IncompleteRanges,
        Self::NotARedaction,
        Self::HashMismatch,
        Self::PairingMismatch,
        Self::BadRequest,
        Self::FetchFailed,
    ];

    /// The wire string.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OldMissing => "old_missing",
            Self::NotUploader => "not_uploader",
            Self::OldChanged => "old_changed",
            Self::UnknownFormat => "unknown_format",
            Self::RegionTooLarge => "region_too_large",
            Self::SizeMismatch => "size_mismatch",
            Self::IncompleteRanges => "incomplete_ranges",
            Self::NotARedaction => "not_a_redaction",
            Self::HashMismatch => "hash_mismatch",
            Self::PairingMismatch => "pairing_mismatch",
            Self::BadRequest => "bad_request",
            Self::FetchFailed => "fetch_failed",
        }
    }

    /// Parse a wire string (`None` for an unregistered one).
    pub fn from_wire(s: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|r| r.as_str() == s)
    }
}

/// #1070: payload of the `flow.failed` push (the item could not be stored or
/// fetched). `reason` replaces the pre-v2 `code` key.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FlowFailedPush {
    pub node_id: String,
    pub queue_sequence: i64,
    pub pairing_id: String,
    pub lease_token: String,
    pub reason: crate::Reason,
}

/// A durable Desktop acknowledgement for exactly one materialized item.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowCompletionReceipt {
    pub queue_sequence: u64,
    pub receipt_id: String,
    pub pairing_id: String,
    pub lease_token: String,
    pub content_hash: String,
}

// ── NET-06: async status query + suspend (control-plane, no bytes) ─

/// Identifies one exact grant tuple for `flow.status`/`flow.suspend`.
/// Deliberately lighter than [`FlowFetchRequest`]: it carries only the
/// fields that name a tuple, not the transfer metadata (`file_name`,
/// `media_type`, `provider`) that only `offer`/`fetch` need to start a
/// native fetch.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowTupleRef {
    pub queue_sequence: u64,
    pub pairing_id: String,
    pub lease_token: String,
}

/// `flow.status` reply. The phone polls this instead of inferring task
/// state from whether an RPC round-trip returned in time (NET-01/NET-06:
/// "回声即状态" is the bug this replaces).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowStatusReply {
    /// One of: `"active"`, `"completed"`, `"cancelled"`, `"not_found"`.
    pub state: String,
    /// Present only when `state == "completed"`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub receipt: Option<FlowCompletionReceipt>,
    /// Whether a native fetch task is currently running for this exact
    /// tuple *in this daemon process*. This is a process-local fact, not
    /// a durable one — a daemon restart clears it independently of the
    /// durable grant `state` above, which is what drives crash-recovery
    /// respawn logic (a caller sees `state == "active"` with
    /// `task_running == false` and knows to re-offer).
    pub task_running: bool,
}

// ── Flow audit outbox delivery (AUDIT-01) ───────────

/// One phone-side durable outbox event awaiting delivery to the daemon.
/// Field-for-field mirror of Android's `AuditOutboxEvent` (the ledger's
/// own domain type) — the wire shape and the durable local shape are
/// intentionally identical so nothing is lost or reshaped in transit.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowAuditEvent {
    /// The idempotency key. Generated once on the phone when the durable
    /// fact was written to the ledger outbox; never regenerated by the
    /// daemon, so retransmission after a crash or lost response is a
    /// no-op rather than a duplicate audit row.
    pub event_id: String,
    /// e.g. `flow.round.finished`, `flow.round.controlled`.
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub round_id: Option<String>,
    pub occurred_at_ms: i64,
    /// Flat string payload — matches the phone ledger's own outbox shape.
    #[serde(default)]
    pub payload: std::collections::BTreeMap<String, String>,
}

/// A batch of durable outbox events the phone is submitting for delivery.
/// Intentionally separate from `flow.offer`:
/// this channel carries no content and never blocks on native transport.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowAuditSubmit {
    pub events: Vec<FlowAuditEvent>,
}

/// Which submitted event ids the daemon durably accepted (inserted or
/// already present — both count, since `append_audit` is `INSERT OR
/// IGNORE` on event_id). The phone acknowledges exactly these ids out of
/// its local outbox; anything missing (a malformed event, or a write
/// that failed) stays queued for the next flush to retry.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct FlowAuditAccepted {
    pub event_ids: Vec<String>,
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
    /// The uploader's dialable address token (transport::PeerAddr string).
    /// The storage side pulls missing blobs from here — self-declared, so
    /// the transfer never depends on address observation or discovery
    /// services (真机冒烟教训). Optional for wire compatibility.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
}

/// Read-only presence check for one bounded page of confirmed content hashes.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct BackupPresenceQuery {
    pub hashes: Vec<String>,
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
/// `state` is one of the canonical states: `ONLINE_DIRECT`, `PAIRING`.
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
    /// NET-10 (#128): read-only verdict query for one `pair.request`
    /// submitted with `ack_then_poll`. Control-plane, answers at once.
    pub const PAIR_STATUS: &str = "pair.status";
    /// DEV-07 (#463): the submitting phone withdraws its own pending
    /// `pair.request` (params [`PairStatusRequest`], reply
    /// [`PairStatusReply`] with the state after the withdrawal). Without
    /// it the owner's later "Allow" still wrote a device row the phone had
    /// already walked away from. Control-plane, answers at once.
    pub const PAIR_CANCEL: &str = "pair.cancel";
    /// #1118: the phone's key confirmation (params [`PairConfirmRequest`], reply
    /// [`PairStatusReply`]: `accepted` + `confirm_b` on success; error `pair_code_wrong` on a
    /// mismatch, after which the request is void). Idempotent for the same `confirm_a`.
    pub const PAIR_CONFIRM: &str = "pair.confirm";
    pub const TIMELINE_PAGE: &str = "timeline.page";
    pub const ASSET_META: &str = "asset.meta";
    pub const THUMB_GET: &str = "thumb.get";
    pub const ASSET_BLOB_TICKET: &str = "asset.blob_ticket";
    /// REBUILD-02: creates the Desktop-side current item grant. It carries no
    /// content and is not part of the frozen batch backup protocol.
    pub const FLOW_OFFER: &str = "flow.offer";
    /// NET-06: read-only status query for one exact tuple. Any network
    /// condition must answer within a short control-plane timeout — it
    /// never waits on the data plane. Replaces "RPC timed out" as a
    /// failure signal (NET-01's root cause).
    pub const FLOW_STATUS: &str = "flow.status";
    /// NET-06: pause semantics — interrupts the in-progress native fetch
    /// task for this exact tuple WITHOUT changing the durable grant state
    /// (stays `active`). Distinct from `flow.cancel_tuple` (which marks the
    /// grant `cancelled` and lets partial bytes fall out of GC
    /// protection): suspend keeps the partial protected so a later
    /// `flow.offer` on the same tuple resumes instead of restarting.
    pub const FLOW_SUSPEND: &str = "flow.suspend";
    /// NET-06: cancel by tuple identity alone (queue_sequence +
    /// pairing_id + lease_token). A phone that already gave up on an
    /// item after exhausting its local retry budget has discarded that
    /// item's one-shot provider ticket, so it cannot rebuild a full
    /// `FlowFetchRequest` (which additionally requires `content_hash` and
    /// `provider` to match the stored row exactly). This method looks up
    /// the stored grant by tuple first (same as `flow.status`/
    /// `flow.suspend`) and cancels using the daemon's own recollection of
    /// content_hash/provider, so the phone never needs to supply them.
    /// #1050: the older full-request `flow.cancel` is retired; this is the
    /// only cancel.
    pub const FLOW_CANCEL_TUPLE: &str = "flow.cancel_tuple";
    /// AUDIT-01: phone-side durable outbox events → daemon v2 audit
    /// repository. Carries no data-plane content and is authorized the
    /// same as the other Flow methods (member+); the daemon appends each
    /// event via its existing event_id idempotency key and returns which
    /// ids landed so the phone can safely drop them from its outbox.
    pub const FLOW_AUDIT_SUBMIT: &str = "flow.audit.submit";
    /// #851: replace a location-redacted copy with its original, in place
    /// ([`super::FlowSupersedeRequest`] → [`super::FlowSupersedeReply`]). Member+ like every
    /// `flow.*` method. Gated on the `flow.supersede.v1` capability.
    pub const FLOW_SUPERSEDE: &str = "flow.supersede";
    pub const BACKUP_BEGIN: &str = "backup.begin";
    pub const BACKUP_MANIFEST: &str = "backup.manifest";
    pub const BACKUP_PRESENCE: &str = "backup.presence";
    pub const BACKUP_COMMIT: &str = "backup.commit";
    pub const DIAG_STATUS: &str = "diag.status";
    /// UX-06: a paired device revokes ITSELF (unilateral stop, product
    /// file §二双端共通「任一端可单方停止」). The daemon marks the
    /// caller revoked; hello is then denied, and a fresh owner-issued
    /// token can rejoin (same rejoin door as owner revoke, T-041).
    pub const DEVICE_UNPAIR: &str = "device.unpair";
    /// SYNC-03: QUIC 平面订阅入口——照抄本地 IPC 已跑通的
    /// `events.subscribe`（IPC-02）。应答后连接不 finish，转入推送态，
    /// 只推 `timeline.invalidated`（不带数据，取数据仍走独立鉴权请求）。
    pub const TIMELINE_SUBSCRIBE: &str = "timeline.subscribe";
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
            ver: 2,
            min_ver: 2,
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
        let resp = Resp::err("abc-123", RespError::new(crate::Reason::NotFound));
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
            pairing_id: None,
            health: None,
        }
    );

    /// #413 §5 W1↔W4 契约：`hello` 回复的 `health` 字段名、`free_bytes` 取不到时
    /// 是 JSON `null`（不是省略），这三点手机侧逐字依赖——钉死字面量。
    #[test]
    fn hello_health_serializes_with_the_contract_field_names_and_a_null_free_bytes() {
        let hello = Hello {
            health: Some(DesktopHealth {
                free_bytes: None,
                library_writable: true,
                index_ok: false,
            }),
            ..Hello::default()
        };
        let value = serde_json::to_value(&hello).unwrap();
        assert_eq!(
            value["health"],
            serde_json::json!({"free_bytes": null, "library_writable": true, "index_ok": false})
        );
        let known = DesktopHealth {
            free_bytes: Some(6_000_000_000),
            library_writable: true,
            index_ok: true,
        };
        assert_eq!(
            serde_json::to_value(known).unwrap(),
            serde_json::json!({"free_bytes": 6_000_000_000i64, "library_writable": true, "index_ok": true})
        );
    }

    /// 没有 health 的 hello（未配对节点、手机自己发的 hello、老桌面）不带这个键，
    /// 旧的 hello 快照因此一字不变。
    #[test]
    fn hello_without_health_omits_the_key_and_old_frames_still_parse() {
        let value = serde_json::to_value(Hello::default()).unwrap();
        assert!(value.get("health").is_none(), "{value}");
        let old: Hello =
            serde_json::from_str(r#"{"proto_ver":1,"capabilities":[],"device_name":"d"}"#).unwrap();
        assert_eq!(old.health, None);
    }

    /// `size_bytes` 缺省（老手机）= 0 = 未知。
    #[test]
    fn flow_fetch_request_size_bytes_defaults_to_unknown_for_old_phones() {
        let old: FlowFetchRequest =
            serde_json::from_str(r#"{"queue_sequence":7,"pairing_id":"e"}"#).unwrap();
        assert_eq!(old.size_bytes, 0);
        let value = serde_json::to_value(FlowFetchRequest {
            size_bytes: 42,
            ..FlowFetchRequest::default()
        })
        .unwrap();
        assert_eq!(value["size_bytes"], 42);
    }

    roundtrip_test!(
        pair_request_roundtrip,
        PairRequest,
        PairRequest {
            token: "abcd1234".into(),
            device_name: "Mom's Phone".into(),
            role: "member".into(),
            ack_then_poll: false,
            pake_a: String::new(),
        }
    );

    /// NET-10: the opt-in flag is omitted when false, so a legacy frame is
    /// byte-identical, and an old frame (no key) parses as legacy.
    #[test]
    fn pair_request_ack_then_poll_is_omitted_when_false_and_defaults_off() {
        let legacy = serde_json::to_value(PairRequest::default()).unwrap();
        assert!(legacy.get("ack_then_poll").is_none(), "{legacy}");
        let old: PairRequest =
            serde_json::from_str(r#"{"token":"t","device_name":"d","role":"member"}"#).unwrap();
        assert!(!old.ack_then_poll);
        let new = serde_json::to_value(PairRequest {
            ack_then_poll: true,
            ..PairRequest::default()
        })
        .unwrap();
        assert_eq!(new["ack_then_poll"], true);
    }

    roundtrip_test!(
        pair_submitted_roundtrip,
        PairSubmitted,
        PairSubmitted {
            accepted: true,
            request_id: "ab".repeat(16),
            ttl_ms: 600_000,
        }
    );

    roundtrip_test!(
        pair_status_reply_accepted_roundtrip,
        PairStatusReply,
        PairStatusReply {
            state: PairStatusState::Accepted,
            accepted: Some(PairAccepted {
                storage_device_name: "Home PC".into(),
                pairing_id: "epoch-1".into(),
            }),
            ..Default::default()
        }
    );

    /// NET-10: pending carries no payload; #1070: no state carries a reason key.
    #[test]
    fn pair_status_reply_pending_has_only_state() {
        let v = serde_json::to_value(PairStatusReply {
            state: PairStatusState::Pending,
            ..PairStatusReply::default()
        })
        .unwrap();
        assert_eq!(v, serde_json::json!({"state": "pending"}));
        for (state, wire) in [
            (PairStatusState::Accepted, "accepted"),
            (PairStatusState::Denied, "denied"),
            (PairStatusState::Expired, "expired"),
            (PairStatusState::Failed, "failed"),
            (PairStatusState::NotFound, "not_found"),
        ] {
            assert_eq!(serde_json::to_value(state).unwrap(), wire);
        }
    }

    /// #1070: the supersede refusal enum keeps the pre-v2 wire strings.
    #[test]
    fn supersede_refusal_wire_strings_are_stable() {
        for r in SupersedeRefusal::ALL {
            assert_eq!(serde_json::to_value(r).unwrap(), r.as_str());
            assert_eq!(SupersedeRefusal::from_wire(r.as_str()), Some(*r));
        }
        assert_eq!(SupersedeRefusal::ALL.len(), 12);
        let replaced = serde_json::to_value(FlowSupersedeReply {
            outcome: "replaced".into(),
            reason: None,
        })
        .unwrap();
        assert_eq!(replaced, serde_json::json!({"outcome": "replaced"}));
    }

    /// #1070: envelope defaults — built = this build's numbers, decoded
    /// without the keys = a v1 peer.
    #[test]
    fn envelope_versions_default_to_local_when_built_and_v1_when_missing() {
        let built = Req::default();
        assert_eq!(
            (built.ver, built.min_ver),
            (crate::PROTO_VER, crate::MIN_SUPPORTED_VER)
        );
        let v1: Req =
            serde_json::from_str(r#"{"id":"1","method":"hello","params":{},"min_ver":1}"#).unwrap();
        assert_eq!((v1.ver, v1.min_ver), (1, 1));
        let bare: Req = serde_json::from_str(r#"{"id":"1","method":"hello"}"#).unwrap();
        assert_eq!((bare.ver, bare.min_ver), (1, 1));
        let resp = Resp::ok("1", Value::Null);
        assert_eq!(
            (resp.ver, resp.min_ver),
            (crate::PROTO_VER, crate::MIN_SUPPORTED_VER)
        );
        let old: Resp = serde_json::from_str(r#"{"id":"1","ok":true}"#).unwrap();
        assert_eq!((old.ver, old.min_ver), (1, 1));
    }

    /// #1272: `source` is optional on the wire. An old phone never sends it → auto; an automatic
    /// item omits it (old desktops see exactly the frame they always saw); a value this build
    /// does not know degrades to auto instead of failing the whole offer.
    #[test]
    fn flow_fetch_request_source_is_optional_and_forward_compatible() {
        let old: FlowFetchRequest = serde_json::from_str(r#"{"queue_sequence":7}"#).unwrap();
        assert_eq!(old.source, FlowItemSource::Auto);

        let auto = serde_json::to_string(&FlowFetchRequest::default()).unwrap();
        assert!(!auto.contains("source"), "auto must not be sent: {auto}");

        let picked = FlowFetchRequest {
            source: FlowItemSource::Picked,
            ..Default::default()
        };
        let wire = serde_json::to_string(&picked).unwrap();
        assert!(wire.contains(r#""source":"picked""#), "{wire}");
        let back: FlowFetchRequest = serde_json::from_str(&wire).unwrap();
        assert_eq!(back.source, FlowItemSource::Picked);

        let future: FlowFetchRequest =
            serde_json::from_str(r#"{"queue_sequence":7,"source":"shared_from_app"}"#).unwrap();
        assert_eq!(future.source, FlowItemSource::Auto);
        assert_eq!(future.queue_sequence, 7);
    }

    /// DEV-02: 老版本手机仍会发 `device_hint`（DEV-01b 只藏了设置页那行
    /// UI，pref 默认开）。`PairRequest` 没有 `deny_unknown_fields`，所以
    /// 那个字段现在被静默忽略——删掉指纹不能让老手机配不上对。
    #[test]
    fn a_frame_from_an_old_client_still_parses_with_the_hint_ignored() {
        let json = r#"{"token":"abcd1234","device_name":"Mom's Phone","role":"member","device_hint":"a1b2c3d4e5f60718"}"#;
        let parsed: PairRequest = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.token, "abcd1234");
        assert_eq!(parsed.device_name, "Mom's Phone");
        assert_eq!(parsed.role, "member");
        // 再序列化回去不带这个键——它已经不在结构里了。
        let re = serde_json::to_string(&parsed).unwrap();
        assert!(!re.contains("device_hint"), "hint 不该复活：{re}");
    }

    roundtrip_test!(
        pair_accepted_roundtrip,
        PairAccepted,
        PairAccepted {
            storage_device_name: "Home PC".into(),
            pairing_id: "epoch-1".into(),
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
                src_device: Some(
                    "0101010101010101010101010101010101010101010101010101010101010101".into()
                ),
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
            src_device: Some("a1b2c3d4".into()),
        }
    );

    #[test]
    fn asset_meta_source_roundtrip_and_old_frame_defaults_to_none() {
        let current = AssetMeta {
            hash: "abcdef1234567890".into(),
            taken_at: 1690000000,
            media_type: "photo".into(),
            width: 4032,
            height: 3024,
            bytes: 3_500_000,
            src_device: Some("a1b2c3d4".into()),
        };
        let json = serde_json::to_string(&current).unwrap();
        assert!(json.contains("\"src_device\":\"a1b2c3d4\""));
        assert_eq!(serde_json::from_str::<AssetMeta>(&json).unwrap(), current);

        let old = r#"{"hash":"abcdef1234567890","taken_at":1690000000,"media_type":"photo","width":4032,"height":3024,"bytes":3500000}"#;
        assert_eq!(
            serde_json::from_str::<AssetMeta>(old).unwrap().src_device,
            None
        );
    }

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
            provider: Some("addr-token".into()),
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
        flow_fetch_request_roundtrip,
        FlowFetchRequest,
        FlowFetchRequest {
            queue_sequence: 7,
            pairing_id: "epoch-1".into(),
            lease_token: "lease-7".into(),
            content_hash: "ab".repeat(32),
            file_name: "IMG_0007.jpg".into(),
            media_type: "image/jpeg".into(),
            provider: "peer-address".into(),
            capture_at_ms: 1_700_000_000_000,
            size_bytes: 3_000_000,
            source: FlowItemSource::Picked,
        }
    );

    roundtrip_test!(
        flow_completion_receipt_roundtrip,
        FlowCompletionReceipt,
        FlowCompletionReceipt {
            queue_sequence: 7,
            receipt_id: "receipt-7".into(),
            pairing_id: "epoch-1".into(),
            lease_token: "lease-7".into(),
            content_hash: "ab".repeat(32),
        }
    );

    roundtrip_test!(
        flow_tuple_ref_roundtrip,
        FlowTupleRef,
        FlowTupleRef {
            queue_sequence: 7,
            pairing_id: "epoch-1".into(),
            lease_token: "lease-7".into(),
        }
    );

    roundtrip_test!(
        flow_status_reply_active_roundtrip,
        FlowStatusReply,
        FlowStatusReply {
            state: "active".into(),
            receipt: None,
            task_running: true,
        }
    );

    roundtrip_test!(
        flow_status_reply_completed_roundtrip,
        FlowStatusReply,
        FlowStatusReply {
            state: "completed".into(),
            receipt: Some(FlowCompletionReceipt {
                queue_sequence: 7,
                receipt_id: "receipt-7".into(),
                pairing_id: "epoch-1".into(),
                lease_token: "lease-7".into(),
                content_hash: "ab".repeat(32),
            }),
            task_running: false,
        }
    );

    roundtrip_test!(
        flow_audit_submit_roundtrip,
        FlowAuditSubmit,
        FlowAuditSubmit {
            events: vec![FlowAuditEvent {
                event_id: "outbox-event-1".into(),
                kind: "flow.round.finished".into(),
                round_id: Some("round-1".into()),
                occurred_at_ms: 1_700_000_000_000,
                payload: std::collections::BTreeMap::from([(
                    "confirmed".to_string(),
                    "3".to_string(),
                )]),
            }],
        }
    );

    #[test]
    fn flow_audit_event_old_frame_without_round_id_parses_as_none() {
        let json =
            r#"{"event_id":"e1","kind":"flow.scope.changed","occurred_at_ms":1,"payload":{}}"#;
        let parsed: FlowAuditEvent = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.round_id, None);
    }

    roundtrip_test!(
        flow_audit_accepted_roundtrip,
        FlowAuditAccepted,
        FlowAuditAccepted {
            event_ids: vec!["outbox-event-1".into(), "outbox-event-2".into()],
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
        // #1070: a frame without version keys is a v1 peer.
        assert_eq!(req.min_ver, crate::version::V1);
        assert_eq!(req.ver, crate::version::V1);
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
