//! UniFFI binding shared by both phones (IOS-06 #313, #1124): the iOS app links
//! it as one static library inside one XCFramework (Swift bindings), Android
//! loads the same exports from `libtransport.so` (Kotlin bindings). Built only
//! with the `mobile-ffi` feature, by `tools/build-ios-transport-xcframework.sh`
//! and `tools/build-android-iroh-blobs-bridge.sh`.
//!
//! Five surfaces, none of which either phone re-implements:
//! - [`Provider`]: the same one-lease iroh-blobs provider kernel the Android
//!   JNI binding wraps ([`crate::provider::BlobsProvider`]; Android still uses
//!   the JNI wrapper until #1126).
//! - BLAKE3: [`blake3_hex`], [`blake3_file_hex`], [`Blake3Hasher`].
//! - `crates/proto` framing: [`encode_frame_json`] / [`decode_frame_json`]
//!   (Swift only handles JSON), plus a typed `crates/proto` decode of `FlowFetchRequest`
//!   ([`ProtoFlowFetchRequest`]) that tests use to check Swift's JSON field for field.
//! - [`parse_pair_link`]: the `ppf://pair?...` link the desktop shows as a QR.
//! - [`CtrlClient`]: the control-plane client (`ppf/ctrl/1`) plus the original
//!   fetch, so neither app needs iroh-ffi's own bindings — two Rust libraries in
//!   one app means two copies of std and clashing symbols, and two clients mean
//!   two protocol behaviours (#1124).
//!
//! The control client and the provider deliberately do NOT share one
//! endpoint: the control endpoint carries the paired identity key (pairing
//! and authz are bound to that NodeId), while the provider binds an
//! ephemeral key per endpoint generation and replaces/parks it on its own
//! schedule (NET-29 #467, #434). Android splits them the same way.
//!
//! All calls block the calling thread (each object owns a tokio runtime);
//! call them off the main thread. The one exception is
//! [`CtrlClient::open_stream`], which returns at once and reports through a
//! listener.

use std::fs::File;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::provider::{ActiveTransferStatus, BlobsProvider, ImportFallback, ServeError};
use crate::{IrohTransport, PeerAddr, TransportConfig, TransportError, ALPN_CTRL};

/// NET-28: the Android control client gives an endpoint bind 15s before it
/// reports a bind timeout (`DaemonClient.BIND_TIMEOUT_MS`).
pub const DEFAULT_BIND_TIMEOUT_MS: u64 = 15_000;
/// UX-11: one control call (connect + request + reply) gets 15s
/// (`DaemonClient.CONNECT_TIMEOUT_MS`).
pub const DEFAULT_CALL_TIMEOUT_MS: u64 = 15_000;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    /// A caller-supplied value could not be parsed (hash, NodeId, token, JSON).
    #[error("invalid argument: {msg}")]
    InvalidArgument { msg: String },
    /// Serving a held import whose referenced original is gone or changed.
    #[error("referenced source {fault}")]
    SourceFault { fault: String },
    /// Serving content that was never imported (or already released).
    #[error("not imported: {hash}")]
    NotImported { hash: String },
    /// Bind or call exceeded its deadline.
    #[error("timeout: {msg}")]
    Timeout { msg: String },
    /// Network / store / codec failure.
    #[error("transport: {msg}")]
    Transport { msg: String },
    /// #1122：对端（经 TLS 认证）用应用关闭码关掉了连接。`node_id` 是关闭帧的
    /// 来源（64 位 hex），Swift 侧只在它等于记录的那台电脑、且
    /// `close_code_means_not_paired(code)` 时按「未配对」清理。
    #[error("closed by {node_id} with code {code}")]
    PeerClosed { node_id: String, code: u64 },
}

/// #1122：这个关闭码是不是「未配对」（401 / 410，唯一定义在 proto::close_codes）。
#[uniffi::export]
pub fn close_code_means_not_paired(code: u64) -> bool {
    proto::close_codes::means_not_paired(code)
}

impl From<TransportError> for FfiError {
    fn from(error: TransportError) -> Self {
        match error {
            TransportError::PeerClosed { peer, code } => FfiError::PeerClosed {
                node_id: peer.to_string(),
                code,
            },
            error => FfiError::Transport {
                msg: error.to_string(),
            },
        }
    }
}

impl From<proto::codec::CodecError> for FfiError {
    fn from(error: proto::codec::CodecError) -> Self {
        FfiError::InvalidArgument {
            msg: error.to_string(),
        }
    }
}

fn invalid(msg: impl std::fmt::Display) -> FfiError {
    FfiError::InvalidArgument {
        msg: msg.to_string(),
    }
}

fn parse_hash(hex: &str) -> Result<[u8; 32], FfiError> {
    let hash: iroh_blobs::Hash = hex
        .parse()
        .map_err(|error| invalid(format!("content hash {hex:?}: {error}")))?;
    Ok(*hash.as_bytes())
}

fn hex32(bytes: &[u8; 32]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ── Pairing code (#1118) ────────────────────────────

fn unhex(s: &str, what: &str) -> Result<Vec<u8>, FfiError> {
    let s = s.trim();
    if !s.len().is_multiple_of(2) {
        return Err(invalid(format!("{what}: odd hex length")));
    }
    (0..s.len())
        .step_by(2)
        .map(|i| {
            s.get(i..i + 2)
                .and_then(|b| u8::from_str_radix(b, 16).ok())
                .ok_or_else(|| invalid(format!("{what}: not hex")))
        })
        .collect()
}

fn node32(s: &str, what: &str) -> Result<[u8; 32], FfiError> {
    <[u8; 32]>::try_from(unhex(s, what)?.as_slice())
        .map_err(|_| invalid(format!("{what}: not 32 bytes")))
}

impl From<pair_pake::PakeError> for FfiError {
    fn from(error: pair_pake::PakeError) -> Self {
        match error {
            pair_pake::PakeError::BadCode | pair_pake::PakeError::BadMessage => {
                FfiError::InvalidArgument {
                    msg: error.to_string(),
                }
            }
            pair_pake::PakeError::ConfirmMismatch | pair_pake::PakeError::Random => {
                FfiError::Transport {
                    msg: error.to_string(),
                }
            }
        }
    }
}

/// #1118: a fresh, uniformly random 6-digit pairing code (the phone shows it; the owner types it
/// on the desktop).
#[uniffi::export]
pub fn pair_code_generate() -> Result<String, FfiError> {
    Ok(pair_pake::generate_code()?)
}

/// #1118: the human-readable identity of a NodeId (`AB12 CD34`) — what the phone shows for the
/// computer it is about to pair with, and what the desktop shows for itself.
#[uniffi::export]
pub fn node_fingerprint(node_id: String) -> String {
    pair_pake::node_fingerprint(&node_id)
}

enum PhoneStage {
    Started(Box<pair_pake::PhoneStart>),
    Confirming(pair_pake::PhoneConfirm),
    Spent,
}

/// #1118: the phone's half of the pairing code exchange (SPAKE2 + key confirmation, the same
/// kernel the desktop runs). Order is enforced: [`Self::finish`] once (with the desktop's
/// `pake_b`) yields `cA`; [`Self::verify`] then checks the desktop's `cB`.
#[derive(uniffi::Object)]
pub struct PairPhone {
    pake_a: String,
    stage: Mutex<PhoneStage>,
}

#[uniffi::export]
impl PairPhone {
    /// `code` is the 6-digit code this phone shows, `token` the QR's one-time token (hex),
    /// `phone_node` / `desk_node` the two NodeIds (64 hex).
    #[uniffi::constructor]
    pub fn start(
        code: String,
        token: String,
        phone_node: String,
        desk_node: String,
    ) -> Result<Arc<Self>, FfiError> {
        let (start, msg_a) = pair_pake::PhoneStart::start(
            &code,
            &unhex(&token, "token")?,
            node32(&phone_node, "phone node id")?,
            node32(&desk_node, "desktop node id")?,
        )?;
        Ok(Arc::new(Self {
            pake_a: hex_lower(&msg_a),
            stage: Mutex::new(PhoneStage::Started(Box::new(start))),
        }))
    }

    /// The SPAKE2 message for `pair.request.pake_a` (hex).
    pub fn pake_a(&self) -> String {
        self.pake_a.clone()
    }

    /// The desktop answered (`pair.status.pake_b`): returns `cA` (hex) for `pair.confirm`.
    pub fn finish(&self, pake_b: String) -> Result<String, FfiError> {
        let msg_b = unhex(&pake_b, "pake_b")?;
        let mut stage = self.stage.lock().expect("pair stage lock");
        if !matches!(*stage, PhoneStage::Started(_)) {
            return Err(invalid("finish called twice"));
        }
        let PhoneStage::Started(start) = std::mem::replace(&mut *stage, PhoneStage::Spent) else {
            unreachable!("checked above");
        };
        // A malformed answer spends the session: the phone must not try a second `pake_b`.
        let (check, confirm_a) = start.finish(&msg_b)?;
        *stage = PhoneStage::Confirming(check);
        Ok(hex_lower(&confirm_a))
    }

    /// The desktop's `cB` (hex, from the accepted reply): `Ok` only if the desktop used the same
    /// code — then the pairing may be saved.
    pub fn verify(&self, confirm_b: String) -> Result<(), FfiError> {
        let stage = self.stage.lock().expect("pair stage lock");
        let PhoneStage::Confirming(check) = &*stage else {
            return Err(invalid("verify before finish"));
        };
        Ok(check.verify(&unhex(&confirm_b, "confirm_b")?)?)
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ── BLAKE3 ──────────────────────────────────────────

/// BLAKE3 of [data] as 64 lowercase hex characters.
#[uniffi::export]
pub fn blake3_hex(data: Vec<u8>) -> String {
    blake3::hash(&data).to_hex().to_string()
}

/// BLAKE3 of the file at [path], streamed (no full read into memory).
#[uniffi::export]
pub fn blake3_file_hex(path: String) -> Result<String, FfiError> {
    let mut file = File::open(&path).map_err(|error| FfiError::Transport {
        msg: format!("open {path:?}: {error}"),
    })?;
    let mut hasher = blake3::Hasher::new();
    std::io::copy(&mut file, &mut hasher).map_err(|error| FfiError::Transport {
        msg: format!("read {path:?}: {error}"),
    })?;
    Ok(hasher.finalize().to_hex().to_string())
}

/// Incremental BLAKE3 for bytes that arrive in pieces (e.g. a
/// `PHAssetResourceManager` data callback).
#[derive(uniffi::Object)]
pub struct Blake3Hasher(Mutex<blake3::Hasher>);

#[uniffi::export]
impl Blake3Hasher {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(blake3::Hasher::new())))
    }

    pub fn update(&self, data: Vec<u8>) {
        self.0.lock().expect("blake3 hasher lock").update(&data);
    }

    /// Hash of everything fed so far; the hasher stays usable.
    pub fn finalize_hex(&self) -> String {
        self.0
            .lock()
            .expect("blake3 hasher lock")
            .finalize()
            .to_hex()
            .to_string()
    }
}

// ── crates/proto framing ────────────────────────────

/// The protocol version this library speaks (`proto::PROTO_VER`).
#[uniffi::export]
pub fn proto_version() -> u16 {
    proto::PROTO_VER
}

/// One length-prefixed frame (`proto::codec`, u32 LE + JSON) around [json].
#[uniffi::export]
pub fn encode_frame_json(json: String) -> Result<Vec<u8>, FfiError> {
    let value: serde_json::Value = serde_json::from_str(&json).map_err(invalid)?;
    Ok(proto::codec::encode(&value)?)
}

/// The JSON payload of one complete frame (header included).
#[uniffi::export]
pub fn decode_frame_json(frame: Vec<u8>) -> Result<String, FfiError> {
    let value: serde_json::Value = proto::codec::decode(&frame)?;
    serde_json::to_string(&value).map_err(invalid)
}

/// Mirror of [`proto::FlowFetchRequest`] for the FFI boundary. Named
/// `Proto…` so it never shadows the app's own Swift `FlowFetchRequest`
/// (PPassCore's Codable type, #890) when both modules are imported. Conversions
/// in both directions destructure every field, so a field added to the
/// proto struct fails to compile here instead of silently dropping.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ProtoFlowFetchRequest {
    pub queue_sequence: u64,
    pub pairing_id: String,
    pub lease_token: String,
    pub content_hash: String,
    pub file_name: String,
    pub media_type: String,
    pub provider: String,
    pub capture_at_ms: i64,
    pub size_bytes: i64,
    /// #1272: `"auto"` or `"picked"` ([`proto::FlowItemSource`] spelling; anything else is auto).
    pub source: String,
}

impl From<ProtoFlowFetchRequest> for proto::FlowFetchRequest {
    fn from(value: ProtoFlowFetchRequest) -> Self {
        let ProtoFlowFetchRequest {
            queue_sequence,
            pairing_id,
            lease_token,
            content_hash,
            file_name,
            media_type,
            provider,
            capture_at_ms,
            size_bytes,
            source,
        } = value;
        proto::FlowFetchRequest {
            queue_sequence,
            pairing_id,
            lease_token,
            content_hash,
            file_name,
            media_type,
            provider,
            capture_at_ms,
            size_bytes,
            source: proto::FlowItemSource::from_wire(&source),
        }
    }
}

impl From<proto::FlowFetchRequest> for ProtoFlowFetchRequest {
    fn from(value: proto::FlowFetchRequest) -> Self {
        let proto::FlowFetchRequest {
            queue_sequence,
            pairing_id,
            lease_token,
            content_hash,
            file_name,
            media_type,
            provider,
            capture_at_ms,
            size_bytes,
            source,
        } = value;
        ProtoFlowFetchRequest {
            queue_sequence,
            pairing_id,
            lease_token,
            content_hash,
            file_name,
            media_type,
            provider,
            capture_at_ms,
            size_bytes,
            source: source.as_str().into(),
        }
    }
}

/// [request] as one `proto::codec` frame, serialized by `crates/proto`.
#[uniffi::export]
pub fn encode_flow_fetch_request(request: ProtoFlowFetchRequest) -> Result<Vec<u8>, FfiError> {
    Ok(proto::codec::encode(&proto::FlowFetchRequest::from(
        request,
    ))?)
}

/// One frame decoded by `crates/proto` as a `FlowFetchRequest`.
#[uniffi::export]
pub fn decode_flow_fetch_request(frame: Vec<u8>) -> Result<ProtoFlowFetchRequest, FfiError> {
    Ok(proto::codec::decode::<proto::FlowFetchRequest>(&frame)?.into())
}

// ── Pairing link ────────────────────────────────────

/// A `ppf://pair?...` link, parsed by [`crate::parse_pair_link`] (the same
/// parser the dev testclient uses; the daemon pairing contract test parses
/// the daemon own links with it).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ParsedPairLink {
    /// The storage end NodeId (64 hex).
    pub node_id: String,
    /// One-time token for `pair.request` (`PairRequest.token`).
    pub token: String,
    /// PeerAddr token for [`CtrlClient::call`]: node + relay (current
    /// links), the full legacy address, or node only (address lookup).
    pub peer_token: String,
    /// Relay URL carried by the link, if any.
    pub relay_url: Option<String>,
}

/// Parses a pairing link (QR content / pasted text).
#[uniffi::export]
pub fn parse_pair_link(link: String) -> Result<ParsedPairLink, FfiError> {
    let link = crate::parse_pair_link(&link).map_err(invalid)?;
    Ok(ParsedPairLink {
        node_id: link.node_id.to_string(),
        token: link.token,
        relay_url: link.peer_addr.relay_url(),
        peer_token: link.peer_addr.to_string(),
    })
}

// ── Provider ────────────────────────────────────────

/// Result of [`Provider::import_file`].
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MediaImport {
    pub hash: String,
    pub size: u64,
    pub by_reference: bool,
    /// `ImportFallback::as_str()` (same vocabulary as the Android wire).
    pub fallback: Option<String>,
    pub detail: Option<String>,
}

/// [`ActiveTransferStatus`] across the FFI boundary; durations in ms.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum TransferStatus {
    NoLease,
    Completed {
        hash: String,
    },
    Aborted {
        hash: String,
    },
    InProgress {
        connected: bool,
        idle_for_ms: Option<u64>,
        bytes_sent: Option<u64>,
        byte_idle_for_ms: Option<u64>,
    },
}

impl From<ActiveTransferStatus> for TransferStatus {
    fn from(status: ActiveTransferStatus) -> Self {
        let ms = |d: Option<Duration>| d.map(|d| d.as_millis() as u64);
        match status {
            ActiveTransferStatus::NoLease => TransferStatus::NoLease,
            ActiveTransferStatus::Completed { hash } => {
                TransferStatus::Completed { hash: hex32(&hash) }
            }
            ActiveTransferStatus::Aborted { hash } => {
                TransferStatus::Aborted { hash: hex32(&hash) }
            }
            ActiveTransferStatus::InProgress {
                connected,
                idle_for,
                bytes_sent,
                byte_idle_for,
            } => TransferStatus::InProgress {
                connected,
                idle_for_ms: ms(idle_for),
                bytes_sent,
                byte_idle_for_ms: ms(byte_idle_for),
            },
        }
    }
}

impl From<crate::provider::MediaImport> for MediaImport {
    fn from(import: crate::provider::MediaImport) -> Self {
        MediaImport {
            hash: hex32(&import.hash),
            size: import.size,
            by_reference: import.by_reference,
            fallback: import
                .fallback
                .map(ImportFallback::as_str)
                .map(str::to_owned),
            detail: import.detail,
        }
    }
}

/// Owned duplicate of a caller-owned descriptor (the caller closes its own).
fn duplicate_fd(fd: i32) -> Result<File, FfiError> {
    use std::os::fd::FromRawFd;
    // SAFETY: `dup` only reads the descriptor number; a bad one returns -1.
    let duplicated = unsafe { libc::dup(fd) };
    if duplicated < 0 {
        return Err(FfiError::Transport {
            msg: format!(
                "duplicate source descriptor: {}",
                std::io::Error::last_os_error()
            ),
        });
    }
    // SAFETY: `dup` returned a fresh descriptor that nothing else owns.
    Ok(unsafe { File::from_raw_fd(duplicated) })
}

/// The one-lease iroh-blobs provider (one long-lived endpoint, one lease at
/// a time, `TempTag`-protected against the 60s GC). Same kernel as Android.
#[derive(uniffi::Object)]
pub struct Provider {
    inner: BlobsProvider,
}

#[uniffi::export]
impl Provider {
    /// Opens (or creates) the provider store under [root].
    #[uniffi::constructor]
    pub fn new(root: String) -> Result<Arc<Self>, FfiError> {
        Ok(Arc::new(Self {
            inner: BlobsProvider::new(root)?,
        }))
    }

    /// Same as [`Self::new`] but with a GC pass every [gc_interval_ms]
    /// instead of every 60s. For tests and diagnostics (IOS-07 #334).
    #[uniffi::constructor]
    pub fn with_gc_interval(root: String, gc_interval_ms: u64) -> Result<Arc<Self>, FfiError> {
        if gc_interval_ms == 0 {
            return Err(invalid("gc_interval_ms must be > 0"));
        }
        Ok(Arc::new(Self {
            inner: BlobsProvider::with_gc_interval(root, Duration::from_millis(gc_interval_ms))?,
        }))
    }

    /// Whether the store still holds [hash] completely (BLOB-03 / IOS-07:
    /// observe what GC kept).
    pub fn has_blob(&self, hash: String) -> Result<bool, FfiError> {
        Ok(self.inner.has_blob(parse_hash(&hash)?))
    }

    /// The paired desktop's NodeId (64 hex) as the only peer allowed to pull;
    /// `nil` / empty refuses everyone. A malformed id refuses everyone and
    /// errors (same contract as the Android binding, #547).
    pub fn set_allowed_peer(&self, node_id: Option<String>) -> Result<(), FfiError> {
        let text = node_id.unwrap_or_default();
        if text.trim().is_empty() {
            self.inner.set_allowed_peer(None);
            return Ok(());
        }
        match text.parse::<crate::NodeId>() {
            Ok(peer) => {
                self.inner.set_allowed_peer(Some(peer));
                Ok(())
            }
            Err(error) => {
                self.inner.set_allowed_peer(None);
                Err(invalid(format!("paired desktop node id: {error}")))
            }
        }
    }

    /// Imports the file at [path] (copied into the provider store) and holds
    /// it until [`Self::release`]. Returns its BLAKE3 hash.
    pub fn import_file(&self, path: String) -> Result<MediaImport, FfiError> {
        let source = File::open(PathBuf::from(&path)).map_err(|error| FfiError::Transport {
            msg: format!("open {path:?}: {error}"),
        })?;
        Ok(self.inner.import_media(None, source)?.into())
    }

    /// #413 / #1126 (Android): imports one original from the ContentResolver descriptor [fd],
    /// by reference to [path] (the MediaStore `_data` path) when it is the same file, else by
    /// copy (`path` = `nil` always copies). The descriptor is duplicated first: the caller keeps
    /// ownership of [fd] and may close it as soon as this returns.
    pub fn import_media(&self, path: Option<String>, fd: i32) -> Result<MediaImport, FfiError> {
        let source = duplicate_fd(fd)?;
        let path = path.map(PathBuf::from);
        Ok(self.inner.import_media(path.as_deref(), source)?.into())
    }

    /// #1126: register (or clear with `nil`) the [`PeerCloseListener`] for this provider's
    /// incoming connections: the paired desktop closing one with an application code (410 when
    /// it removed this phone) is reported as (desktop NodeId, code) — the same listener and the
    /// same "forget the pairing" judgement as [`CtrlClient`]'s. Code 0 (an ordinary close) and
    /// local closes are not reported. Called on a thread of its own, never the runtime's.
    pub fn set_peer_close_listener(&self, listener: Option<Arc<dyn PeerCloseListener>>) {
        self.inner.set_peer_close_hook(listener.map(|listener| {
            Arc::new(move |peer: crate::NodeId, code: u64| {
                listener.on_peer_closed(peer.to_string(), code)
            }) as crate::provider::PeerClosedHook
        }));
    }

    /// Serves a held import as the current lease; returns its ticket.
    pub fn serve(&self, hash: String) -> Result<String, FfiError> {
        let content_hash = parse_hash(&hash)?;
        self.inner.serve(content_hash).map_err(|error| match error {
            ServeError::Source(fault) => FfiError::SourceFault {
                fault: fault.as_str().to_owned(),
            },
            ServeError::NotImported(hash) => FfiError::NotImported { hash },
            ServeError::Transport(error) => error.into(),
        })
    }

    /// Drops the hold on an imported content. Idempotent.
    pub fn release(&self, hash: String) -> Result<(), FfiError> {
        self.inner.release(parse_hash(&hash)?);
        Ok(())
    }

    pub fn stop_active_fetch(&self) {
        self.inner.stop_active_fetch();
    }

    /// BLOB-03: let the served blob go to the next GC pass, endpoint kept.
    pub fn release_retention(&self) {
        self.inner.release_retention();
    }

    pub fn revoke(&self) {
        self.inner.revoke();
    }

    pub fn transfer_status(&self) -> TransferStatus {
        self.inner.transfer_status().into()
    }

    /// `"missing"` / `"changed"` when the lease's referenced original no
    /// longer matches; `nil` otherwise.
    pub fn source_fault(&self) -> Option<String> {
        self.inner.source_fault().map(|f| f.as_str().to_owned())
    }

    /// #417: forward a network-change notification to the endpoint.
    pub fn network_change(&self) {
        self.inner.network_change();
    }

    /// #434: bind the endpoint ahead of the first serve of a round.
    pub fn prewarm(&self) -> Result<(), FfiError> {
        Ok(self.inner.prewarm()?)
    }

    /// #434: close the endpoint while idle; `false` = a peer is connected.
    pub fn park(&self) -> bool {
        self.inner.park()
    }

    /// NodeId (64 hex) of the current provider endpoint (binds it if needed).
    pub fn endpoint_node_id(&self) -> Result<String, FfiError> {
        Ok(self.inner.endpoint_node_id()?.to_string())
    }

    /// Ends the current lease (same as the Android `nativeClose`). Named `shutdown`, not
    /// `close`: Kotlin's generated class already has `AutoCloseable.close()` (#1124).
    pub fn shutdown(&self) {
        self.inner.revoke();
    }
}

// ── Control-plane client ────────────────────────────

/// How [`CtrlClient::bind`] builds its endpoint.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CtrlConfig {
    /// The paired identity key (32 bytes). `nil` = fresh ephemeral key
    /// (enough for `hello` / `pair.*`; pairing binds the NodeId, so a real
    /// app must persist and pass its key).
    pub secret_key: Option<Vec<u8>>,
    /// Custom relays; empty = n0 defaults (when `offline` is false).
    pub relay_urls: Vec<String>,
    /// No relays and no address lookup: only addresses inside the peer
    /// token are dialed (tests, LAN-only).
    pub offline: bool,
    /// Bind deadline; 0 = [`DEFAULT_BIND_TIMEOUT_MS`].
    pub bind_timeout_ms: u64,
}

/// Receives the payload bytes that have arrived so far during [`CtrlClient::fetch_blob`].
#[uniffi::export(with_foreign)]
pub trait FetchProgress: Send + Sync {
    fn on_bytes(&self, bytes: u64);
}

/// 取回取消句柄：Swift 侧每次 [`CtrlClient::fetch_blob`] 新建一个，任务被取消时调 [`FetchCancel::cancel`]，
/// 阻塞中的取回随即以 `Transport("cancelled")` 返回（临时仓库照常清理）。取消是粘性的：
/// 先于 fetch 开始调用也生效。
#[derive(uniffi::Object)]
pub struct FetchCancel {
    token: tokio_util::sync::CancellationToken,
}

#[uniffi::export]
impl FetchCancel {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            token: tokio_util::sync::CancellationToken::new(),
        })
    }

    pub fn cancel(&self) {
        self.token.cancel();
    }
}

/// Receives what [`CtrlClient::open_stream`] reads (#963). Called from a
/// runtime thread; implementations must be thread-safe.
#[uniffi::export(with_foreign)]
pub trait StreamListener: Send + Sync {
    /// One frame from the daemon, as JSON text.
    fn on_frame(&self, json: String);
    /// The stream is over (called exactly once): `None` = the daemon finished
    /// it, otherwise why it ended.
    fn on_closed(&self, error: Option<String>);
}

/// Stops one [`CtrlClient::open_stream`]; idempotent, sticky.
#[derive(uniffi::Object)]
pub struct StreamHandle {
    token: tokio_util::sync::CancellationToken,
}

#[uniffi::export]
impl StreamHandle {
    pub fn cancel(&self) {
        self.token.cancel();
    }
}

/// Closes a stream's dedicated connection however the read loop ends
/// (finished, failed, cancelled, dropped).
struct CloseConn(iroh::endpoint::Connection);

impl Drop for CloseConn {
    fn drop(&mut self) {
        self.0.close(0u32.into(), b"stream closed");
    }
}

/// Guarantees `on_closed` fires once, even if the read task is dropped
/// without finishing (runtime shut down with the client).
struct CloseOnce(Option<Arc<dyn StreamListener>>);

impl CloseOnce {
    fn fire(&mut self, error: Option<String>) {
        if let Some(listener) = self.0.take() {
            listener.on_closed(error);
        }
    }
}

impl Drop for CloseOnce {
    fn drop(&mut self) {
        self.fire(Some("control client closed".to_owned()));
    }
}

/// #1124：这个客户端上任何一条连接（请求、订阅流、取原图、探测）被对端用应用关闭码关掉时
/// 回调一次，`node_id` 是关闭帧的来源（64 位 hex，取自经 TLS 认证的连接对端）。两端各注册
/// 一个监听：关闭方是配对记录里的那台电脑、且 [`close_code_means_not_paired`] ⇒ 被拒即清理；
/// 其余一律当连不上。回调在 runtime 线程上，实现必须线程安全、不阻塞。
#[uniffi::export(with_foreign)]
pub trait PeerCloseListener: Send + Sync {
    fn on_peer_closed(&self, node_id: String, code: u64);
}

type CloseListenerSlot = Arc<Mutex<Option<Arc<dyn PeerCloseListener>>>>;

fn notify_peer_closed(slot: &CloseListenerSlot, error: &FfiError) {
    if let FfiError::PeerClosed { node_id, code } = error {
        let listener = slot.lock().expect("close listener lock").clone();
        if let Some(listener) = listener {
            listener.on_peer_closed(node_id.clone(), *code);
        }
    }
}

/// [`CtrlClient::call_traced`] 的逐阶段记录（DIAG-A 可达性探测，原 Android `callTraced`）。
/// 时间都是从调用开始算的毫秒；没走到那一步就是 `None`。成功时 `reply_json` 是完整 `Resp`
/// 信封；失败时 `error_kind` ∈ `timeout` / `peer_closed` / `connect` / `transport` /
/// `codec`，`peer_closed` 另带关闭方与关闭码。
#[derive(Debug, Clone, uniffi::Record)]
pub struct CallTrace {
    pub reply_json: Option<String>,
    pub error_kind: Option<String>,
    pub error_message: Option<String>,
    pub closed_by: Option<String>,
    pub close_code: Option<u64>,
    /// 开始时本端的 home relay（还没有 = `None`）。
    pub home_relay_at_start: Option<String>,
    /// 本端 `online()`（拿到 relay、能打洞）在这次调用期间何时返回。
    pub online_after_ms: Option<u64>,
    pub connect_ms: Option<u64>,
    pub round_trip_ms: Option<u64>,
    pub total_ms: u64,
    /// 连上后选中的路径：`lan` / `direct` / `relay` / `none`（连接上没有路径）。
    pub path_kind: Option<String>,
    pub path_remote_ip: Option<String>,
    pub path_rtt_ms: u64,
    pub path_count: u32,
    /// 失败时 iroh 手里这台对端的地址（relay 与直连），供判断「地址不对」还是「网不通」。
    pub peer_known_relay: Option<String>,
    pub peer_known_direct: Vec<String>,
}

/// Minimal `ppf/ctrl/1` client: one request frame, one reply frame per call,
/// `crates/proto` framing, JSON in and out. Every call and every stream gets a
/// connection of its own (like HTTP without keep-alive), so requests never
/// queue behind each other on the daemon's per-connection serial serve loop.
#[derive(uniffi::Object)]
pub struct CtrlClient {
    runtime: tokio::runtime::Runtime,
    transport: Mutex<Option<Arc<IrohTransport>>>,
    next_id: AtomicU64,
    close_listener: CloseListenerSlot,
}

fn ms_or(value: u64, default: u64) -> Duration {
    Duration::from_millis(if value == 0 { default } else { value })
}

#[uniffi::export]
impl CtrlClient {
    #[uniffi::constructor]
    pub fn bind(config: CtrlConfig) -> Result<Arc<Self>, FfiError> {
        let secret_key = match config.secret_key {
            None => None,
            Some(bytes) => Some(
                <[u8; 32]>::try_from(bytes.as_slice())
                    .map_err(|_| invalid(format!("secret key is {} bytes, not 32", bytes.len())))?,
            ),
        };
        let alpns = vec![ALPN_CTRL.to_owned()];
        let mut cfg = if config.offline {
            TransportConfig::loopback(alpns)
        } else {
            TransportConfig::from_endpoints(config.relay_urls, alpns)
        };
        cfg.secret_key = secret_key;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|error| FfiError::Transport {
                msg: format!("tokio runtime: {error}"),
            })?;
        let deadline = ms_or(config.bind_timeout_ms, DEFAULT_BIND_TIMEOUT_MS);
        let transport = runtime
            .block_on(async { tokio::time::timeout(deadline, IrohTransport::bind(cfg)).await })
            .map_err(|_| FfiError::Timeout {
                msg: format!("endpoint bind exceeded {} ms", deadline.as_millis()),
            })??;
        Ok(Arc::new(Self {
            runtime,
            transport: Mutex::new(Some(Arc::new(transport))),
            next_id: AtomicU64::new(1),
            close_listener: Arc::new(Mutex::new(None)),
        }))
    }

    /// #1124：注册（或用 `None` 撤掉）[`PeerCloseListener`]。之后这个客户端上每一次被对端用
    /// 应用关闭码关掉的连接都会回调——请求、订阅流、取原图、探测，一条不漏。
    pub fn set_peer_close_listener(&self, listener: Option<Arc<dyn PeerCloseListener>>) {
        *self.close_listener.lock().expect("close listener lock") = listener;
    }

    /// This endpoint's NodeId (64 hex).
    pub fn node_id(&self) -> Result<String, FfiError> {
        Ok(self.live()?.node_id().to_string())
    }

    /// 取回原图：按 `asset.blob_ticket` 返回的 iroh-blobs [ticket] 从配对电脑拉一个 blob，
    /// 校验后导出到 [dest_path]（目录须已存在）。用控制端点（配对身份）出站连 blobs ALPN，
    /// 电脑侧的 PeerGate 只放行已配对节点。blob 仓库建在 [scratch_dir] 下一个临时子目录里，
    /// 用完即删——手机是减负端，不留长期原图缓存（Android 同一红线）。
    /// [stall_ms]：连续这么久没收到任何数据字节就判失败（0 = 20s），慢但在动的传输不会被掐；
    /// [progress] 收到已到达的数据字节数。[cancel] 触发后取回立即中止并返回 `Transport("cancelled")`，
    /// 半截的 [dest_path] 一并删除。返回内容 BLAKE3（64 hex）。
    pub fn fetch_blob(
        &self,
        ticket: String,
        scratch_dir: String,
        dest_path: String,
        stall_ms: u64,
        progress: Option<Arc<dyn FetchProgress>>,
        cancel: Option<Arc<FetchCancel>>,
    ) -> Result<String, FfiError> {
        let transport = self.live()?;
        let stall = ms_or(stall_ms, 20_000);
        let store_dir = PathBuf::from(&scratch_dir).join(format!("fetch-{}", self.request_id()));
        let dest = PathBuf::from(&dest_path);
        let result = self.runtime.block_on(async {
            let blobs = crate::Blobs::open(&transport, &store_dir).await?;
            let pull = blobs.pull_observed(ticket.trim(), &dest, stall, |bytes| {
                if let Some(cb) = &progress {
                    cb.on_bytes(bytes);
                }
            });
            let pulled = match &cancel {
                Some(c) => tokio::select! {
                    biased;
                    _ = c.token.cancelled() => Err(FfiError::Transport { msg: "cancelled".into() }),
                    r = pull => r.map_err(FfiError::from),
                },
                None => pull.await.map_err(FfiError::from),
            };
            blobs.close().await;
            pulled
        });
        let _ = std::fs::remove_dir_all(&store_dir);
        if let Err(error) = &result {
            let _ = std::fs::remove_file(&dest); // 失败 / 取消不留半截文件
            notify_peer_closed(&self.close_listener, error);
        }
        Ok(hex32(&result?))
    }

    /// Sends `{id, method, params}` to the daemon named by [peer_token] (the
    /// PeerAddr token: base64url JSON of the iroh endpoint address) and returns
    /// the daemon's whole `Resp` envelope as JSON (`ok` / `result` / `error`).
    /// [timeout_ms] bounds connect + request + reply; 0 =
    /// [`DEFAULT_CALL_TIMEOUT_MS`].
    pub fn call(
        &self,
        peer_token: String,
        method: String,
        params_json: String,
        timeout_ms: u64,
    ) -> Result<String, FfiError> {
        let result = self.call_inner(peer_token, method, params_json, timeout_ms);
        if let Err(error) = &result {
            notify_peer_closed(&self.close_listener, error);
        }
        result
    }

    /// DIAG-A：与 [`Self::call`] 同一次往返、同一个上限，但逐阶段记下发生了什么（见
    /// [`CallTrace`]）。网络层的失败也装在记录里返回；只有参数不合法才是 `Err`。只给可达性
    /// 探测用——状态轮询也走它会把日志刷爆。
    pub fn call_traced(
        &self,
        peer_token: String,
        method: String,
        params_json: String,
        timeout_ms: u64,
    ) -> Result<CallTrace, FfiError> {
        let transport = self.live()?;
        let addr = PeerAddr::from_str(peer_token.trim())
            .map_err(|error| invalid(format!("peer token: {error}")))?;
        let request = self.request(method, &params_json)?;
        let frame = proto::codec::encode(&request)?;
        let deadline = ms_or(timeout_ms, DEFAULT_CALL_TIMEOUT_MS);
        let trace = self
            .runtime
            .block_on(traced_round_trip(transport, addr, request, frame, deadline));
        if let (Some(node_id), Some(code)) = (&trace.closed_by, trace.close_code) {
            notify_peer_closed(
                &self.close_listener,
                &FfiError::PeerClosed {
                    node_id: node_id.clone(),
                    code,
                },
            );
        }
        Ok(trace)
    }

    /// Streaming call (`timeline.subscribe`, #963): sends one `{id, method, params}`
    /// frame to the daemon named by [peer_token], half-closes the send side, then
    /// hands every frame the daemon pushes to [listener] as JSON text — the first
    /// one is the daemon's `Resp` (ack or rejection), the rest are pushed events.
    /// Same shape as Android's `DaemonClient.subscribeTimeline`: it waits on the
    /// stream, it never polls.
    ///
    /// Returns at once; the read loop runs on this client's runtime. The returned
    /// handle's `cancel()` stops it. [`StreamListener::on_closed`] is called
    /// exactly once whatever happens: `None` = the daemon finished the stream,
    /// otherwise the reason (connect failure / timeout, broken stream,
    /// `"cancelled"`, client closed). [connect_timeout_ms] bounds connect + send
    /// only (0 = [`DEFAULT_CALL_TIMEOUT_MS`]); an open stream has no deadline.
    pub fn open_stream(
        &self,
        peer_token: String,
        method: String,
        params_json: String,
        connect_timeout_ms: u64,
        listener: Arc<dyn StreamListener>,
    ) -> Result<Arc<StreamHandle>, FfiError> {
        let transport = self.live()?;
        let addr = PeerAddr::from_str(peer_token.trim())
            .map_err(|error| invalid(format!("peer token: {error}")))?;
        let request = self.request(method, &params_json)?;
        let frame = proto::codec::encode(&request)?;
        let deadline = ms_or(connect_timeout_ms, DEFAULT_CALL_TIMEOUT_MS);
        let handle = Arc::new(StreamHandle {
            token: tokio_util::sync::CancellationToken::new(),
        });
        let token = handle.token.clone();
        let close = CloseOnce(Some(listener.clone()));
        let closes = Arc::clone(&self.close_listener);
        self.runtime.spawn(async move {
            let mut close = close;
            // #1124：连接或读流被对端用应用关闭码关掉 ⇒ 先报给关闭监听，再把原因交给 on_closed。
            let failed = |error: TransportError| {
                let error = FfiError::from(error);
                notify_peer_closed(&closes, &error);
                error.to_string()
            };
            let run = async {
                // 独占一条连接（不进连接缓存）：daemon 同一条连接上的流是排队处理的，
                // 订阅挂在共享连接上会把之后的 offer / status 全堵住。
                let (conn, mut stream) = tokio::time::timeout(deadline, async {
                    let peer = transport.add_peer(addr);
                    let (conn, mut stream) = transport.connect_dedicated(peer, ALPN_CTRL).await?;
                    stream.send_frame(&frame).await?;
                    stream.finish()?;
                    Ok::<_, TransportError>((conn, stream))
                })
                .await
                .map_err(|_| {
                    format!(
                        "{} connect exceeded {} ms",
                        request.method,
                        deadline.as_millis()
                    )
                })?
                .map_err(failed)?;
                let _close = CloseConn(conn);
                loop {
                    match stream.recv_frame().await.map_err(failed)? {
                        None => return Ok(()),
                        Some(frame) => {
                            let json: serde_json::Value =
                                proto::codec::decode(&frame).map_err(|e| e.to_string())?;
                            listener.on_frame(json.to_string());
                        }
                    }
                }
            };
            let outcome: Result<(), String> = tokio::select! {
                biased;
                _ = token.cancelled() => Err("cancelled".to_owned()),
                r = run => r,
            };
            close.fire(outcome.err());
        });
        Ok(handle)
    }

    /// Closes the endpoint. Later calls fail; idempotent. Named `shutdown`, not `close`:
    /// Kotlin's generated class already has `AutoCloseable.close()` (#1124).
    pub fn shutdown(&self) {
        let transport = self.transport.lock().expect("ctrl transport lock").take();
        if let Some(transport) = transport {
            self.runtime.block_on(transport.close());
        }
    }
}

/// [`CtrlClient::call_traced`] 的本体：与 `call` 同一次独占连接的往返，边走边记。
async fn traced_round_trip(
    transport: Arc<IrohTransport>,
    addr: PeerAddr,
    request: proto::Req,
    frame: Vec<u8>,
    deadline: Duration,
) -> CallTrace {
    let started = std::time::Instant::now();
    let since = move || u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    let mut trace = CallTrace {
        reply_json: None,
        error_kind: None,
        error_message: None,
        closed_by: None,
        close_code: None,
        home_relay_at_start: transport.local_addr().relay_url(),
        online_after_ms: None,
        connect_ms: None,
        round_trip_ms: None,
        total_ms: 0,
        path_kind: None,
        path_remote_ip: None,
        path_rtt_ms: 0,
        path_count: 0,
        peer_known_relay: None,
        peer_known_direct: Vec::new(),
    };
    let online_after = Arc::new(AtomicU64::new(u64::MAX));
    let watch = {
        let transport = Arc::clone(&transport);
        let online_after = Arc::clone(&online_after);
        tokio::spawn(async move {
            if transport.wait_online(deadline).await {
                online_after.store(since(), Ordering::Relaxed);
            }
        })
    };
    let peer_id = addr.node_id();
    let outcome = tokio::time::timeout(deadline, async {
        let peer = transport.add_peer(addr);
        let (conn, mut stream) = transport.connect_dedicated(peer, ALPN_CTRL).await?;
        trace.connect_ms = Some(since());
        let facts = crate::iroh_impl::path_facts(&conn);
        trace.path_count = u32::try_from(facts.len()).unwrap_or(u32::MAX);
        let info = crate::conninfo::classify(&facts);
        trace.path_kind = Some(info.path.map_or("none", |p| p.as_str()).to_owned());
        trace.path_rtt_ms = info.rtt_ms;
        trace.path_remote_ip = facts
            .iter()
            .find(|f| f.selected)
            .or_else(|| facts.first())
            .and_then(|f| f.remote_ip)
            .map(|ip| ip.to_string());
        let _close = CloseConn(conn);
        stream.send_frame(&frame).await?;
        stream.finish()?;
        stream.recv_frame().await
    })
    .await;
    watch.abort();
    let online = online_after.load(Ordering::Relaxed);
    trace.online_after_ms = (online != u64::MAX).then_some(online);
    let fail = |trace: &mut CallTrace, kind: &str, message: String| {
        trace.error_kind = Some(kind.to_owned());
        trace.error_message = Some(message);
    };
    match outcome {
        Err(_) => fail(
            &mut trace,
            "timeout",
            format!("{} exceeded {} ms", request.method, deadline.as_millis()),
        ),
        Ok(Err(TransportError::PeerClosed { peer, code })) => {
            trace.closed_by = Some(peer.to_string());
            trace.close_code = Some(code);
            fail(
                &mut trace,
                "peer_closed",
                format!("closed by {peer} with code {code}"),
            );
        }
        Ok(Err(error @ TransportError::Connect { .. })) => {
            fail(&mut trace, "connect", error.to_string())
        }
        Ok(Err(error)) => fail(&mut trace, "transport", error.to_string()),
        Ok(Ok(None)) => fail(
            &mut trace,
            "transport",
            format!(
                "{}: daemon closed the stream without a reply",
                request.method
            ),
        ),
        Ok(Ok(Some(reply))) => match proto::codec::decode::<proto::Resp>(&reply) {
            Err(error) => fail(&mut trace, "codec", error.to_string()),
            Ok(resp) if resp.id != request.id => fail(
                &mut trace,
                "transport",
                format!(
                    "reply id {:?} does not match request {:?}",
                    resp.id, request.id
                ),
            ),
            Ok(resp) => match serde_json::to_string(&resp) {
                Ok(json) => {
                    trace.round_trip_ms = Some(since());
                    trace.reply_json = Some(json);
                }
                Err(error) => fail(&mut trace, "codec", error.to_string()),
            },
        },
    }
    if trace.error_kind.is_some() {
        // 失败时 iroh 手里这台对端的地址：地址本身不对，还是地址对但不通。
        if let Ok(id) = crate::iroh_impl::endpoint_id(peer_id) {
            let known =
                tokio::time::timeout(Duration::from_secs(1), transport.endpoint().remote_info(id))
                    .await
                    .ok()
                    .flatten();
            if let Some(info) = known {
                for a in info.addrs() {
                    match a.addr() {
                        iroh::TransportAddr::Relay(url) => {
                            trace
                                .peer_known_relay
                                .get_or_insert_with(|| url.to_string());
                        }
                        iroh::TransportAddr::Ip(sa) => trace.peer_known_direct.push(sa.to_string()),
                        _ => {}
                    }
                }
            }
        }
    }
    trace.total_ms = since();
    trace
}

impl CtrlClient {
    fn call_inner(
        &self,
        peer_token: String,
        method: String,
        params_json: String,
        timeout_ms: u64,
    ) -> Result<String, FfiError> {
        let transport = self.live()?;
        let addr = PeerAddr::from_str(peer_token.trim())
            .map_err(|error| invalid(format!("peer token: {error}")))?;
        let request = self.request(method, &params_json)?;
        let frame = proto::codec::encode(&request)?;
        let deadline = ms_or(timeout_ms, DEFAULT_CALL_TIMEOUT_MS);
        let reply = self.runtime.block_on(async {
            tokio::time::timeout(deadline, async {
                // 一次请求一条连接，回复到手即关（同 Android `DaemonClient.call`）：daemon 在
                // 同一条连接上串行服务流，共用连接会让请求互相排队，一个慢请求就堵住其余所有。
                let peer = transport.add_peer(addr);
                let (conn, mut stream) = transport.connect_dedicated(peer, ALPN_CTRL).await?;
                let _close = CloseConn(conn);
                stream.send_frame(&frame).await?;
                stream.finish()?;
                stream.recv_frame().await
            })
            .await
        });
        let reply = reply
            .map_err(|_| FfiError::Timeout {
                msg: format!("{} exceeded {} ms", request.method, deadline.as_millis()),
            })??
            .ok_or_else(|| FfiError::Transport {
                msg: format!(
                    "{}: daemon closed the stream without a reply",
                    request.method
                ),
            })?;
        let resp: proto::Resp = proto::codec::decode(&reply)?;
        if resp.id != request.id {
            return Err(FfiError::Transport {
                msg: format!(
                    "reply id {:?} does not match request {:?}",
                    resp.id, request.id
                ),
            });
        }
        serde_json::to_string(&resp).map_err(|error| FfiError::Transport {
            msg: error.to_string(),
        })
    }

    /// `{id, method, params}`：空参数 = `{}`；参数不是合法 JSON ⇒ 参数错误。
    fn request(&self, method: String, params_json: &str) -> Result<proto::Req, FfiError> {
        let params: serde_json::Value = if params_json.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(params_json)
                .map_err(|error| invalid(format!("params: {error}")))?
        };
        Ok(proto::Req {
            id: self.request_id(),
            method,
            params,
            ..proto::Req::default()
        })
    }

    fn live(&self) -> Result<Arc<IrohTransport>, FfiError> {
        self.transport
            .lock()
            .expect("ctrl transport lock")
            .clone()
            .ok_or_else(|| FfiError::Transport {
                msg: "control client is closed".into(),
            })
    }

    /// Unique per process: wall-clock nanos + a counter (the daemon only
    /// echoes it back; it is never interpreted).
    fn request_id(&self) -> String {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let n = self.next_id.fetch_add(1, Ordering::Relaxed);
        format!("ffi-{nanos:x}-{n}")
    }
}

impl Drop for CtrlClient {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #1126（Android 原 JNI 的契约）：`import_media` 先 dup 描述符——调用方的 fd 调用后照样有效、
    /// 由调用方自己关；导入的内容就是那个文件的内容。
    #[test]
    fn import_media_duplicates_the_callers_descriptor() {
        use std::os::fd::AsRawFd;
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("IMG_1126.jpg");
        std::fs::write(&src, b"an original behind a content descriptor").unwrap();
        let provider = Provider::new(dir.path().join("p").display().to_string()).unwrap();
        let file = std::fs::File::open(&src).unwrap();
        let fd = file.as_raw_fd();
        let import = provider.import_media(None, fd).unwrap();
        assert_eq!(
            import.hash,
            hex32(blake3::hash(b"an original behind a content descriptor").as_bytes())
        );
        assert!(!import.by_reference, "no path: copied");
        // SAFETY: only queries the descriptor's flags.
        assert_ne!(
            unsafe { libc::fcntl(fd, libc::F_GETFD) },
            -1,
            "the caller's fd is still open"
        );
        drop(file);
        assert!(
            provider.import_media(None, -1).is_err(),
            "a bad descriptor is an error"
        );
        provider.shutdown();
    }
    use crate::Transport;
    use futures_core::Stream;
    use std::pin::Pin;

    /// Minimal `StreamExt::next` stand-in (same as tests/loopback.rs).
    async fn next<S: Stream + Unpin>(s: &mut S) -> Option<S::Item> {
        std::future::poll_fn(|cx| Pin::new(&mut *s).poll_next(cx)).await
    }

    fn sample() -> ProtoFlowFetchRequest {
        ProtoFlowFetchRequest {
            queue_sequence: 42,
            pairing_id: "epoch-7".into(),
            lease_token: "lease-abc".into(),
            content_hash: "ab".repeat(32),
            file_name: "IMG_0001.HEIC".into(),
            media_type: "image/heic".into(),
            provider: "provider-token".into(),
            capture_at_ms: 1_790_243_013_123,
            size_bytes: 532_102,
            source: "picked".into(),
        }
    }

    #[test]
    fn flow_fetch_request_round_trips_through_proto() {
        let frame = encode_flow_fetch_request(sample()).unwrap();
        let decoded: proto::FlowFetchRequest = proto::codec::decode(&frame).unwrap();
        assert_eq!(ProtoFlowFetchRequest::from(decoded), sample());
        assert_eq!(decode_flow_fetch_request(frame).unwrap(), sample());
    }

    #[test]
    fn frame_json_matches_proto_codec() {
        let frame = encode_frame_json(r#"{"method":"hello","params":{}}"#.into()).unwrap();
        let value: serde_json::Value = proto::codec::decode(&frame).unwrap();
        assert_eq!(value["method"], "hello");
        let back: serde_json::Value =
            serde_json::from_str(&decode_frame_json(frame).unwrap()).unwrap();
        assert_eq!(back, value);
        assert!(decode_frame_json(vec![1, 0]).is_err());
    }

    #[test]
    fn pair_link_exports_a_dialable_peer_token() {
        let node = crate::node_id_from_secret_key(&[7; 32]).to_string();
        let parsed = parse_pair_link(format!(
            "ppf://pair?node={node}&t=0123456789abcdef01234567&r=https://relay.example"
        ))
        .unwrap();
        assert_eq!(parsed.node_id, node);
        assert_eq!(parsed.token, "0123456789abcdef01234567");
        let addr: PeerAddr = parsed.peer_token.parse().unwrap();
        assert_eq!(addr.node_id().to_string(), node);
        assert!(parsed
            .relay_url
            .unwrap()
            .starts_with("https://relay.example"));
        assert!(matches!(
            parse_pair_link("ppf://pair?node=nope".into()),
            Err(FfiError::InvalidArgument { .. })
        ));
    }

    #[test]
    fn blake3_matches_known_answer() {
        assert_eq!(
            blake3_hex(b"hello".to_vec()),
            "ea8f163db38682925e4491c5e58d4bb3506ef8c14eb78a86e908c5624a67200f"
        );
        let hasher = Blake3Hasher::new();
        hasher.update(b"hel".to_vec());
        hasher.update(b"lo".to_vec());
        assert_eq!(hasher.finalize_hex(), blake3_hex(b"hello".to_vec()));
    }

    /// Loopback daemon stand-in: answers every ctrl request with
    /// `Resp::ok(id, {"echo": method})`.
    #[test]
    fn ctrl_client_round_trips_one_request() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let server = rt
            .block_on(IrohTransport::bind(TransportConfig::loopback(vec![
                ALPN_CTRL.to_owned(),
            ])))
            .unwrap();
        let token = server.local_addr().to_string();
        let server = Arc::new(server);
        let accept = server.clone();
        rt.spawn(async move {
            let mut incoming = Box::pin(accept.listen().await);
            while let Some(conn) = next(&mut incoming).await {
                tokio::spawn(async move {
                    while let Ok(mut stream) = conn.accept_bi().await {
                        let Ok(Some(frame)) = stream.recv_frame().await else {
                            return;
                        };
                        let req: proto::Req = proto::codec::decode(&frame).unwrap();
                        let resp =
                            proto::Resp::ok(req.id, serde_json::json!({ "echo": req.method }));
                        let _ = stream
                            .send_frame(&proto::codec::encode(&resp).unwrap())
                            .await;
                        let _ = stream.finish();
                    }
                });
            }
        });

        let client = CtrlClient::bind(CtrlConfig {
            secret_key: None,
            relay_urls: Vec::new(),
            offline: true,
            bind_timeout_ms: 0,
        })
        .unwrap();
        let reply = client
            .call(token.clone(), "hello".into(), "{}".into(), 5_000)
            .unwrap();
        let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["result"]["echo"], "hello");

        assert!(matches!(
            client.call("not-a-token".into(), "hello".into(), String::new(), 1_000),
            Err(FfiError::InvalidArgument { .. })
        ));
        client.shutdown();
        assert!(client
            .call(token, "hello".into(), String::new(), 1_000)
            .is_err());
    }

    /// 2026-10-15 对齐：高频少字节的请求互不排队。服务端和 daemon 一样按连接串行服务流；
    /// 一个慢请求挂着时，另一个线程发的请求必须照样很快回来（每次请求独立连接）。
    #[test]
    fn concurrent_calls_do_not_queue_behind_a_slow_one() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let server = rt
            .block_on(IrohTransport::bind(TransportConfig::loopback(vec![
                ALPN_CTRL.to_owned(),
            ])))
            .unwrap();
        let token = server.local_addr().to_string();
        let server = Arc::new(server);
        let accept = server.clone();
        rt.spawn(async move {
            let mut incoming = Box::pin(accept.listen().await);
            while let Some(conn) = next(&mut incoming).await {
                tokio::spawn(async move {
                    while let Ok(mut stream) = conn.accept_bi().await {
                        let Ok(Some(frame)) = stream.recv_frame().await else {
                            return;
                        };
                        let req: proto::Req = proto::codec::decode(&frame).unwrap();
                        if req.method == "slow" {
                            tokio::time::sleep(Duration::from_secs(3)).await;
                        }
                        let resp =
                            proto::Resp::ok(req.id, serde_json::json!({ "echo": req.method }));
                        let _ = stream
                            .send_frame(&proto::codec::encode(&resp).unwrap())
                            .await;
                        let _ = stream.finish();
                    }
                });
            }
        });

        let client = CtrlClient::bind(CtrlConfig {
            secret_key: None,
            relay_urls: Vec::new(),
            offline: true,
            bind_timeout_ms: 0,
        })
        .unwrap();
        // 先打一次，让连接（若有缓存）建好。
        client
            .call(token.clone(), "hello".into(), String::new(), 5_000)
            .unwrap();
        std::thread::scope(|scope| {
            let slow = scope.spawn(|| {
                client
                    .call(token.clone(), "slow".into(), String::new(), 10_000)
                    .unwrap()
            });
            std::thread::sleep(Duration::from_millis(300)); // 慢请求已在服务端挂着
            let started = std::time::Instant::now();
            client
                .call(token.clone(), "hello".into(), String::new(), 10_000)
                .unwrap();
            let waited = started.elapsed();
            assert!(
                waited < Duration::from_millis(1_500),
                "a quick call queued behind a slow one for {waited:?}"
            );
            slow.join().unwrap();
        });
        client.shutdown();
    }

    /// Records what a stream delivered; `closed` carries the single on_closed.
    struct Recorder {
        frames: Mutex<Vec<serde_json::Value>>,
        closed: std::sync::mpsc::SyncSender<Option<String>>,
    }

    impl StreamListener for Recorder {
        fn on_frame(&self, json: String) {
            self.frames
                .lock()
                .unwrap()
                .push(serde_json::from_str(&json).unwrap());
        }
        fn on_closed(&self, error: Option<String>) {
            self.closed.send(error).unwrap();
        }
    }

    /// #963：流式调用把 ack 与之后推来的每一帧原样交出；对端 finish = on_closed(None)；
    /// 对端一直挂着时 cancel 能让读循环退出，on_closed 只来一次。
    /// 服务端和 daemon 一样**按连接串行**处理流：订阅挂着期间普通 call 照样要通（订阅独占连接）。
    #[test]
    fn open_stream_delivers_every_pushed_frame_and_cancels() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let server = rt
            .block_on(IrohTransport::bind(TransportConfig::loopback(vec![
                ALPN_CTRL.to_owned(),
            ])))
            .unwrap();
        let token = server.local_addr().to_string();
        let server = Arc::new(server);
        let accept = server.clone();
        rt.spawn(async move {
            let mut incoming = Box::pin(accept.listen().await);
            while let Some(conn) = next(&mut incoming).await {
                tokio::spawn(async move {
                    // 同 daemon router：一条连接上的流一个接一个服务完。
                    while let Ok(mut stream) = conn.accept_bi().await {
                        let Ok(Some(frame)) = stream.recv_frame().await else {
                            return;
                        };
                        let req: proto::Req = proto::codec::decode(&frame).unwrap();
                        if req.method != "timeline.subscribe" {
                            let resp =
                                proto::Resp::ok(req.id, serde_json::json!({ "echo": req.method }));
                            let _ = stream
                                .send_frame(&proto::codec::encode(&resp).unwrap())
                                .await;
                            let _ = stream.finish();
                            continue;
                        }
                        let hold = req.params["hold"].as_bool().unwrap_or(false);
                        let ack =
                            proto::Resp::ok(req.id, serde_json::json!({ "subscribed": true }));
                        let push = |event: &str, seq: u64| {
                            proto::codec::encode(&serde_json::json!({
                                "event": event, "data": { "queue_sequence": seq }
                            }))
                            .unwrap()
                        };
                        let _ = stream
                            .send_frame(&proto::codec::encode(&ack).unwrap())
                            .await;
                        let _ = stream.send_frame(&push("timeline.invalidated", 0)).await;
                        let _ = stream.send_frame(&push("flow.delivered", 7)).await;
                        if hold {
                            // 挂到对端断开为止（连接关闭时 recv 出错返回）。
                            let _ = stream.recv_frame().await;
                            let _ = conn.accept_bi().await;
                            return;
                        }
                        let _ = stream.finish();
                    }
                });
            }
        });

        let client = CtrlClient::bind(CtrlConfig {
            secret_key: None,
            relay_urls: Vec::new(),
            offline: true,
            bind_timeout_ms: 0,
        })
        .unwrap();

        // 对端读完就 finish：三帧齐、on_closed(None)。
        let (tx, rx) = std::sync::mpsc::sync_channel(4);
        let rec = Arc::new(Recorder {
            frames: Mutex::new(Vec::new()),
            closed: tx,
        });
        let _handle = client
            .open_stream(
                token.clone(),
                "timeline.subscribe".into(),
                String::new(),
                5_000,
                rec.clone(),
            )
            .unwrap();
        assert_eq!(rx.recv_timeout(Duration::from_secs(10)).unwrap(), None);
        {
            let frames = rec.frames.lock().unwrap();
            assert_eq!(frames.len(), 3, "{frames:?}");
            assert_eq!(frames[0]["ok"], true);
            assert_eq!(frames[0]["result"]["subscribed"], true);
            assert_eq!(frames[1]["event"], "timeline.invalidated");
            assert_eq!(frames[2]["event"], "flow.delivered");
            assert_eq!(frames[2]["data"]["queue_sequence"], 7);
        }

        // 对端一直挂着：收到推送后 cancel，读循环以 "cancelled" 结束，且只结束一次。
        let (tx, rx) = std::sync::mpsc::sync_channel(4);
        let rec = Arc::new(Recorder {
            frames: Mutex::new(Vec::new()),
            closed: tx,
        });
        let handle = client
            .open_stream(
                token.clone(),
                "timeline.subscribe".into(),
                r#"{"hold":true}"#.into(),
                5_000,
                rec.clone(),
            )
            .unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while rec.frames.lock().unwrap().len() < 3 {
            assert!(
                std::time::Instant::now() < deadline,
                "pushed frames never arrived"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(rx.try_recv().is_err(), "a held stream must stay open");
        // 订阅挂着时普通 call 不能被堵（daemon 按连接串行服务流）。
        let reply = client
            .call(token.clone(), "flow.offer".into(), "{}".into(), 5_000)
            .expect("a call must not queue behind an open subscription");
        let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(reply["result"]["echo"], "flow.offer");
        handle.cancel();
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(5)).unwrap().as_deref(),
            Some("cancelled")
        );
        assert!(
            rx.recv_timeout(Duration::from_millis(300)).is_err(),
            "on_closed fired twice"
        );

        // 坏 token 同步报错，不起读循环。
        let (tx, _rx) = std::sync::mpsc::sync_channel(4);
        let rec = Arc::new(Recorder {
            frames: Mutex::new(Vec::new()),
            closed: tx,
        });
        assert!(matches!(
            client.open_stream(
                "not-a-token".into(),
                "timeline.subscribe".into(),
                String::new(),
                1_000,
                rec
            ),
            Err(FfiError::InvalidArgument { .. })
        ));
        client.shutdown();
    }

    /// #953：取消句柄先触发时 fetch_blob 以 cancelled 返回，并删掉 dest 上的半截文件。
    #[test]
    fn fetch_blob_cancelled_returns_cancelled_and_removes_partial() {
        let client = CtrlClient::bind(CtrlConfig {
            secret_key: None,
            relay_urls: Vec::new(),
            offline: true,
            bind_timeout_ms: 0,
        })
        .unwrap();
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("half.part");
        std::fs::write(&dest, b"partial").unwrap();
        let cancel = FetchCancel::new();
        cancel.cancel();
        let err = client
            .fetch_blob(
                "not-a-ticket".into(),
                dir.path().to_string_lossy().into_owned(),
                dest.to_string_lossy().into_owned(),
                0,
                None,
                Some(cancel),
            )
            .unwrap_err();
        assert!(
            matches!(&err, FfiError::Transport { msg } if msg == "cancelled"),
            "{err:?}"
        );
        assert!(!dest.exists(), "partial file must be removed");
    }

    /// #1124：关闭监听收到的 (关闭方, 关闭码)。
    #[derive(Default)]
    struct Closes(Mutex<Vec<(String, u64)>>);

    impl PeerCloseListener for Closes {
        fn on_peer_closed(&self, node_id: String, code: u64) {
            self.0.lock().unwrap().push((node_id, code));
        }
    }

    fn offline_client() -> Arc<CtrlClient> {
        CtrlClient::bind(CtrlConfig {
            secret_key: None,
            relay_urls: Vec::new(),
            offline: true,
            bind_timeout_ms: 0,
        })
        .unwrap()
    }

    /// #1124：电脑在握手后用 401 拒绝（准入钩子）——请求、探测、订阅流、取原图四条路径都以
    /// 有类型的 PeerClosed 失败，并且每一次都回调关闭监听（关闭方 = 电脑的 NodeId）。
    /// 反证：取消、超时、本地关闭不回调。
    /// 反证（已实测）：去掉 `call` 里的 notify ⇒ 第一条计数断言红；去掉 blobs.rs `pull_observed`
    /// 里「取回失败后按连接关闭原因改报 PeerClosed」那一层 ⇒ 取原图报 Transport，红（401 在握手
    /// 完成后才发，拨号本身是成功的）。
    #[test]
    fn every_path_reports_a_peer_close_to_the_listener() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let server = Arc::new(
            rt.block_on(IrohTransport::bind(TransportConfig::loopback(vec![
                ALPN_CTRL.to_owned(),
                crate::ALPN_BLOBS.to_owned(),
            ])))
            .unwrap(),
        );
        server.set_admission(Arc::new(|_: crate::NodeId, _: &[u8]| false));
        let accept = server.clone();
        rt.spawn(async move {
            let mut incoming = Box::pin(accept.listen().await);
            while next(&mut incoming).await.is_some() {}
        });
        let token = server.local_addr().to_string();
        let desk = server.node_id().to_string();

        let client = offline_client();
        let closes = Arc::new(Closes::default());
        client.set_peer_close_listener(Some(closes.clone()));
        let count = || closes.0.lock().unwrap().len();

        let err = client
            .call(token.clone(), "hello".into(), String::new(), 5_000)
            .unwrap_err();
        assert!(
            matches!(&err, FfiError::PeerClosed { node_id, code: 401 } if *node_id == desk),
            "{err:?}"
        );
        assert_eq!(count(), 1);

        let trace = client
            .call_traced(token.clone(), "hello".into(), String::new(), 5_000)
            .unwrap();
        assert_eq!(
            trace.error_kind.as_deref(),
            Some("peer_closed"),
            "{trace:?}"
        );
        assert_eq!(trace.close_code, Some(401));
        assert_eq!(trace.closed_by.as_deref(), Some(desk.as_str()));
        assert!(trace.reply_json.is_none());
        assert_eq!(count(), 2);

        let (tx, rx) = std::sync::mpsc::sync_channel(4);
        let rec = Arc::new(Recorder {
            frames: Mutex::new(Vec::new()),
            closed: tx,
        });
        let _h = client
            .open_stream(
                token.clone(),
                "timeline.subscribe".into(),
                String::new(),
                5_000,
                rec,
            )
            .unwrap();
        let ended = rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(ended.is_some_and(|m| m.contains("401")));
        assert_eq!(count(), 3);

        let dir = tempfile::tempdir().unwrap();
        let ticket = blob_ticket_for_test(&server, [9; 32]);
        let err = client
            .fetch_blob(
                ticket,
                dir.path().to_string_lossy().into_owned(),
                dir.path().join("x").to_string_lossy().into_owned(),
                0,
                None,
                None,
            )
            .unwrap_err();
        assert!(
            matches!(&err, FfiError::PeerClosed { code: 401, .. }),
            "{err:?}"
        );
        assert_eq!(closes.0.lock().unwrap()[3], (desk.clone(), 401));
        assert_eq!(count(), 4);

        // 反证：取消、超时不算对端关闭。
        let cancel = FetchCancel::new();
        cancel.cancel();
        let _ = client.fetch_blob(
            "not-a-ticket".into(),
            dir.path().to_string_lossy().into_owned(),
            dir.path().join("y").to_string_lossy().into_owned(),
            0,
            None,
            Some(cancel),
        );
        let dead = rt
            .block_on(IrohTransport::bind(TransportConfig::loopback(vec![
                ALPN_CTRL.to_owned(),
            ])))
            .unwrap();
        let dead_token = dead.local_addr().to_string();
        rt.block_on(dead.close());
        let err = client
            .call(dead_token, "hello".into(), String::new(), 1_500)
            .unwrap_err();
        assert!(!matches!(err, FfiError::PeerClosed { .. }), "{err:?}");
        assert_eq!(count(), 4, "取消 / 超时 / 连不上不回调");

        // 撤掉监听后不再回调。
        client.set_peer_close_listener(None);
        let _ = client.call(token, "hello".into(), String::new(), 5_000);
        assert_eq!(count(), 4);
        client.shutdown();
    }

    /// #1124：订阅流挂着时，电脑删了这台设备的配对记录（`close_peer` ⇒ 410）——读循环以对端
    /// 关闭结束，关闭监听立刻收到 (电脑, 410)，不用等下一次请求。
    /// 反证（已实测）：去掉 open_stream 里 `failed` 的 notify ⇒ 计数为 0，红。
    #[test]
    fn a_held_stream_closed_with_410_reports_at_once() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let server = Arc::new(
            rt.block_on(IrohTransport::bind(TransportConfig::loopback(vec![
                ALPN_CTRL.to_owned(),
            ])))
            .unwrap(),
        );
        let accept = server.clone();
        rt.spawn(async move {
            let mut incoming = Box::pin(accept.listen().await);
            while let Some(conn) = next(&mut incoming).await {
                tokio::spawn(async move {
                    let Ok(mut stream) = conn.accept_bi().await else {
                        return;
                    };
                    let Ok(Some(frame)) = stream.recv_frame().await else {
                        return;
                    };
                    let req: proto::Req = proto::codec::decode(&frame).unwrap();
                    let ack = proto::Resp::ok(req.id, serde_json::json!({ "subscribed": true }));
                    let _ = stream
                        .send_frame(&proto::codec::encode(&ack).unwrap())
                        .await;
                    // 客户端发完请求就半关发送端：挂在下一条流上，直到连接被关。
                    let _ = conn.accept_bi().await;
                });
            }
        });
        let token = server.local_addr().to_string();
        let client = offline_client();
        let closes = Arc::new(Closes::default());
        client.set_peer_close_listener(Some(closes.clone()));
        let (tx, rx) = std::sync::mpsc::sync_channel(4);
        let rec = Arc::new(Recorder {
            frames: Mutex::new(Vec::new()),
            closed: tx,
        });
        let _h = client
            .open_stream(
                token,
                "timeline.subscribe".into(),
                String::new(),
                5_000,
                rec.clone(),
            )
            .unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while rec.frames.lock().unwrap().is_empty() {
            assert!(std::time::Instant::now() < deadline, "没收到订阅确认");
            std::thread::sleep(Duration::from_millis(20));
        }
        let client_node: crate::NodeId = client.node_id().unwrap().parse().unwrap();
        assert!(server.close_peer(client_node) >= 1);
        assert!(rx.recv_timeout(Duration::from_secs(10)).unwrap().is_some());
        assert_eq!(
            closes.0.lock().unwrap().as_slice(),
            [(server.node_id().to_string(), 410)]
        );
        client.shutdown();
    }

    /// #1124：Android 的 `PeerAddrParts.toToken()`（PeerAddrToken.kt）按这个形状拼 JSON 再 base64url；
    /// Rust 这边按同一个 token 拨号，必须读得懂（relay、IPv4、带方括号的 IPv6 都在）。
    #[test]
    fn a_kotlin_built_peer_token_parses() {
        use base64::Engine as _;
        let node = crate::node_id_from_secret_key(&[3; 32]).to_string();
        let json = format!(
            r#"{{"id":"{node}","addrs":[{{"Relay":"https://relay.example/"}},{{"Ip":"192.168.1.2:41145"}},{{"Ip":"[fe80::1]:41145"}}]}}"#
        );
        let token = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json);
        let addr: PeerAddr = token.parse().expect("Kotlin token must parse");
        assert_eq!(addr.node_id().to_string(), node);
        assert_eq!(addr.relay_url().as_deref(), Some("https://relay.example/"));
        let back = addr.to_string();
        assert!(back.parse::<PeerAddr>().is_ok());
    }

    /// #1118：导出给手机的 PairPhone 与电脑侧内核走一遍：同码完成、错码电脑不交 cB、
    /// 顺序被强制（finish 之前不能 verify、finish 只能一次）。
    #[test]
    fn pair_phone_runs_the_code_exchange_against_the_desktop_kernel() {
        let token = "ab".repeat(12);
        let phone = "a1".repeat(32);
        let desk = "b2".repeat(32);
        let unhex = |s: &str| super::unhex(s, "t").unwrap();
        let code = pair_code_generate().unwrap();
        assert_eq!(code.len(), 6);

        let p = PairPhone::start(code.clone(), token.clone(), phone.clone(), desk.clone()).unwrap();
        assert!(p.verify("00".repeat(32)).is_err(), "verify before finish");
        let (d, msg_b) = pair_pake::Desktop::respond(
            &code,
            &unhex(&token),
            node32(&phone, "p").unwrap(),
            node32(&desk, "d").unwrap(),
            &unhex(&p.pake_a()),
        )
        .unwrap();
        let ca = p.finish(hex_lower(&msg_b)).unwrap();
        assert!(p.finish(hex_lower(&msg_b)).is_err(), "finish only once");
        let cb = d.verify(&unhex(&ca)).unwrap();
        p.verify(hex_lower(&cb)).unwrap();
        assert!(p.verify("00".repeat(32)).is_err());

        // 电脑输错码：cA 对不上，电脑不交 cB。
        let p =
            PairPhone::start("111111".into(), token.clone(), phone.clone(), desk.clone()).unwrap();
        let (d, msg_b) = pair_pake::Desktop::respond(
            "111112",
            &unhex(&token),
            node32(&phone, "p").unwrap(),
            node32(&desk, "d").unwrap(),
            &unhex(&p.pake_a()),
        )
        .unwrap();
        let ca = p.finish(hex_lower(&msg_b)).unwrap();
        assert!(d.verify(&unhex(&ca)).is_err());

        assert!(PairPhone::start("12345".into(), token, phone, desk).is_err());
        assert_eq!(node_fingerprint("ab12cd34".repeat(8)), "AB12 CD34");
    }

    /// 测试用：指向 [server] 的 blobs 票据（内容不存在也无所谓——准入在握手时就拒了）。
    fn blob_ticket_for_test(server: &IrohTransport, hash: [u8; 32]) -> String {
        iroh_blobs::ticket::BlobTicket::new(
            server.endpoint().addr(),
            iroh_blobs::Hash::from_bytes(hash),
            iroh_blobs::BlobFormat::Raw,
        )
        .to_string()
    }
}
