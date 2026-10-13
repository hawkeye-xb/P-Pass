//! UniFFI binding #2 (IOS-06 #313): what the iOS app links from Rust, as one
//! static library inside one XCFramework. Built only with the `ios-ffi`
//! feature by `tools/build-ios-transport-xcframework.sh`.
//!
//! Five surfaces, none of which iOS re-implements:
//! - [`Provider`]: the same one-lease iroh-blobs provider kernel the Android
//!   JNI binding wraps ([`crate::provider::BlobsProvider`]).
//! - BLAKE3: [`blake3_hex`], [`blake3_file_hex`], [`Blake3Hasher`].
//! - `crates/proto` framing: [`encode_frame_json`] / [`decode_frame_json`]
//!   (Swift only handles JSON), plus a typed `crates/proto` decode of `FlowFetchRequest`
//!   ([`ProtoFlowFetchRequest`]) that tests use to check Swift's JSON field for field.
//! - [`parse_pair_link`]: the `ppf://pair?...` link the desktop shows as a QR.
//! - [`CtrlClient`]: a minimal control-plane client (`ppf/ctrl/1`), so the app
//!   does not need iroh-ffi's own Swift XCFramework — two Rust static
//!   libraries in one app means two copies of std and clashing symbols.
//!
//! The control client and the provider deliberately do NOT share one
//! endpoint: the control endpoint carries the paired identity key (pairing
//! and authz are bound to that NodeId), while the provider binds an
//! ephemeral key per endpoint generation and replaces/parks it on its own
//! schedule (NET-29 #467, #434). Android splits them the same way.
//!
//! All calls block the calling thread (each object owns a tokio runtime);
//! call them off the main thread.

use std::fs::File;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::provider::{ActiveTransferStatus, BlobsProvider, ImportFallback, ServeError};
use crate::{IrohTransport, PeerAddr, Transport, TransportConfig, TransportError, ALPN_CTRL};

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
}

impl From<TransportError> for FfiError {
    fn from(error: TransportError) -> Self {
        FfiError::Transport {
            msg: error.to_string(),
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
    pub pairing_epoch: String,
    pub lease_token: String,
    pub content_hash: String,
    pub file_name: String,
    pub media_type: String,
    pub provider: String,
    pub capture_at_ms: i64,
    pub size_bytes: i64,
}

impl From<ProtoFlowFetchRequest> for proto::FlowFetchRequest {
    fn from(value: ProtoFlowFetchRequest) -> Self {
        let ProtoFlowFetchRequest {
            queue_sequence,
            pairing_epoch,
            lease_token,
            content_hash,
            file_name,
            media_type,
            provider,
            capture_at_ms,
            size_bytes,
        } = value;
        proto::FlowFetchRequest {
            queue_sequence,
            pairing_epoch,
            lease_token,
            content_hash,
            file_name,
            media_type,
            provider,
            capture_at_ms,
            size_bytes,
        }
    }
}

impl From<proto::FlowFetchRequest> for ProtoFlowFetchRequest {
    fn from(value: proto::FlowFetchRequest) -> Self {
        let proto::FlowFetchRequest {
            queue_sequence,
            pairing_epoch,
            lease_token,
            content_hash,
            file_name,
            media_type,
            provider,
            capture_at_ms,
            size_bytes,
        } = value;
        ProtoFlowFetchRequest {
            queue_sequence,
            pairing_epoch,
            lease_token,
            content_hash,
            file_name,
            media_type,
            provider,
            capture_at_ms,
            size_bytes,
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
        let import = self.inner.import_media(None, source)?;
        Ok(MediaImport {
            hash: hex32(&import.hash),
            size: import.size,
            by_reference: import.by_reference,
            fallback: import
                .fallback
                .map(ImportFallback::as_str)
                .map(str::to_owned),
            detail: import.detail,
        })
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

    /// Ends the current lease (same as the Android `nativeClose`).
    pub fn close(&self) {
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

/// Minimal `ppf/ctrl/1` client: one request frame, one reply frame per call,
/// `crates/proto` framing, JSON in and out.
#[derive(uniffi::Object)]
pub struct CtrlClient {
    runtime: tokio::runtime::Runtime,
    transport: Mutex<Option<Arc<IrohTransport>>>,
    next_id: AtomicU64,
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
        }))
    }

    /// This endpoint's NodeId (64 hex).
    pub fn node_id(&self) -> Result<String, FfiError> {
        Ok(self.live()?.node_id().to_string())
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
        let transport = self.live()?;
        let addr = PeerAddr::from_str(peer_token.trim())
            .map_err(|error| invalid(format!("peer token: {error}")))?;
        let params: serde_json::Value = if params_json.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(&params_json)
                .map_err(|error| invalid(format!("params: {error}")))?
        };
        let request = proto::Req {
            id: self.request_id(),
            method,
            params,
            ..proto::Req::default()
        };
        let frame = proto::codec::encode(&request)?;
        let deadline = ms_or(timeout_ms, DEFAULT_CALL_TIMEOUT_MS);
        let reply = self.runtime.block_on(async {
            tokio::time::timeout(deadline, async {
                let peer = transport.add_peer(addr);
                let mut stream = transport.connect(peer, ALPN_CTRL).await?;
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

    /// Closes the endpoint. Later calls fail; idempotent.
    pub fn close(&self) {
        let transport = self.transport.lock().expect("ctrl transport lock").take();
        if let Some(transport) = transport {
            self.runtime.block_on(transport.close());
        }
    }
}

impl CtrlClient {
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
        format!("ios-{nanos:x}-{n}")
    }
}

impl Drop for CtrlClient {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_core::Stream;
    use std::pin::Pin;

    /// Minimal `StreamExt::next` stand-in (same as tests/loopback.rs).
    async fn next<S: Stream + Unpin>(s: &mut S) -> Option<S::Item> {
        std::future::poll_fn(|cx| Pin::new(&mut *s).poll_next(cx)).await
    }

    fn sample() -> ProtoFlowFetchRequest {
        ProtoFlowFetchRequest {
            queue_sequence: 42,
            pairing_epoch: "epoch-7".into(),
            lease_token: "lease-abc".into(),
            content_hash: "ab".repeat(32),
            file_name: "IMG_0001.HEIC".into(),
            media_type: "image/heic".into(),
            provider: "provider-token".into(),
            capture_at_ms: 1_790_243_013_123,
            size_bytes: 532_102,
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
        client.close();
        assert!(client
            .call(token, "hello".into(), String::new(), 1_000)
            .is_err());
    }
}
