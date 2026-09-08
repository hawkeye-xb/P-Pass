//! iroh-backed implementation of the [`Transport`] trait (ADR-001).
//!
//! All iroh types stay private to this module; the public surface exposes
//! only opaque wrappers ([`PeerAddr`], [`Incoming`], [`BiStream`]).

use std::collections::HashMap;
use std::fmt;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex, Weak};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use iroh::endpoint::{presets, Connection, ReadExactError, RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr};

use crate::conninfo::{classify, status_of_live, ConnInfo, ConnectionStatus, PathFacts};
use crate::{NodeId, Result, Transport, TransportError, MAX_FRAME};

/// Construction inputs, mapped from the daemon `Config` (T-004): the daemon
/// passes `Config.relay_urls` in here. Address lookup (发现) stays on n0
/// public infrastructure for MVP per ADR-009 (Phase 2: self-hosted pkarr);
/// `Config.rendezvous_url` belongs to the pairing flow (T-031), not here.
#[derive(Debug, Clone)]
pub struct TransportConfig {
    /// Custom relay servers. Empty = n0 default relays (when `n0_services`
    /// is on) or fully relay-less (when off).
    pub relay_urls: Vec<String>,
    /// Use n0 public infrastructure defaults (relays + address lookup).
    /// Off = offline mode: only peers registered via [`IrohTransport::add_peer`]
    /// are reachable — what tests and LAN-only setups need.
    pub n0_services: bool,
    /// Stable identity key (32 bytes). `None` = fresh ephemeral key.
    pub secret_key: Option<[u8; 32]>,
    /// ALPNs accepted when listening (e.g. [`crate::ALPN_CTRL`]).
    pub alpns: Vec<String>,
    /// UDP bind address. `None` = OS-assigned port.
    pub bind_addr: Option<SocketAddr>,
}

impl TransportConfig {
    /// Production shape: endpoints from the daemon config (T-004).
    pub fn from_endpoints(relay_urls: Vec<String>, alpns: Vec<String>) -> Self {
        Self {
            relay_urls,
            n0_services: true,
            secret_key: None,
            alpns,
            bind_addr: None,
        }
    }

    /// Offline loopback shape: no relays, no address lookup, random port.
    /// Fully self-contained — CI runs this without network access.
    pub fn loopback(alpns: Vec<String>) -> Self {
        Self {
            relay_urls: Vec::new(),
            n0_services: false,
            secret_key: None,
            alpns,
            bind_addr: None,
        }
    }
}

/// Opaque peer address bundle (identity key + direct addresses + relay URL).
/// Obtained from [`IrohTransport::local_addr`] and handed to the other side —
/// in-process for now; pairing tickets serialize this in T-031.
#[derive(Debug, Clone)]
pub struct PeerAddr(EndpointAddr);

impl PeerAddr {
    pub fn from_endpoint_addr(addr: EndpointAddr) -> Self {
        Self(addr)
    }

    pub fn node_id(&self) -> NodeId {
        NodeId(*self.0.id.as_bytes())
    }

    /// First relay URL, if any. Pairing QR (H-10b rework): the QR's `a=`
    /// param used to carry the full PeerAddr (id + relay + direct IPs,
    /// 100–180 chars base64) — too dense to scan. Now the QR carries just
    /// the relay URL (`r=`), and the Android side rebuilds the token.
    pub fn relay_url(&self) -> Option<String> {
        self.0.addrs.iter().find_map(|a| match a {
            TransportAddr::Relay(u) => Some(u.to_string()),
            _ => None,
        })
    }
}

/// Compact URL-safe token (base64url over the serialized address) — what
/// pairing QR codes carry so a scan connects without any discovery
/// service (the serialization T-020 predicted T-031 would need; landed
/// during the dogfood smoke that proved discovery can't be relied on).
impl fmt::Display for PeerAddr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        use base64::Engine as _;
        let json = serde_json::to_vec(&self.0).map_err(|_| fmt::Error)?;
        write!(
            f,
            "{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json)
        )
    }
}

impl std::str::FromStr for PeerAddr {
    type Err = TransportError;

    fn from_str(s: &str) -> Result<Self> {
        use base64::Engine as _;
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(s.trim())
            .map_err(|_| TransportError::InvalidNodeId)?;
        let addr: EndpointAddr =
            serde_json::from_slice(&bytes).map_err(|_| TransportError::InvalidNodeId)?;
        Ok(PeerAddr(addr))
    }
}

/// Connections unused for this duration are explicitly closed by the cache reaper.
const CONNECTION_IDLE_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct ConnectionKey {
    peer: NodeId,
    alpn: String,
}

impl ConnectionKey {
    fn new(peer: NodeId, alpn: &str) -> Self {
        Self {
            peer,
            alpn: alpn.to_owned(),
        }
    }
}

struct CachedConnection {
    conn: Connection,
    last_stream_at: Instant,
}

/// One live QUIC connection per `(NodeId, ALPN)`. QUIC multiplexes streams,
/// so callers share the connection instead of building a traditional pool.
#[derive(Default)]
struct ConnectionCache {
    entries: HashMap<ConnectionKey, CachedConnection>,
}

impl ConnectionCache {
    fn get_live(&mut self, peer: NodeId, alpn: &str) -> Option<Connection> {
        let key = ConnectionKey::new(peer, alpn);
        let entry = self.entries.get_mut(&key)?;
        if entry.conn.close_reason().is_some() {
            self.entries.remove(&key);
            return None;
        }
        entry.last_stream_at = Instant::now();
        Some(entry.conn.clone())
    }

    fn insert(&mut self, peer: NodeId, alpn: &str, conn: Connection) {
        self.entries.insert(
            ConnectionKey::new(peer, alpn),
            CachedConnection {
                conn,
                last_stream_at: Instant::now(),
            },
        );
    }

    fn latest_live(&mut self, peer: NodeId) -> Option<Connection> {
        let now = Instant::now();
        let key = self
            .entries
            .iter()
            .filter(|(key, entry)| key.peer == peer && entry.conn.close_reason().is_none())
            .max_by_key(|(_, entry)| entry.last_stream_at)
            .map(|(key, _)| key.clone())?;
        let entry = self.entries.get_mut(&key).expect("cache key exists");
        entry.last_stream_at = now;
        Some(entry.conn.clone())
    }

    fn evict_idle(&mut self, now: Instant) -> Vec<Connection> {
        let mut stale = Vec::new();
        self.entries.retain(|_, entry| {
            let closed = entry.conn.close_reason().is_some();
            let idle = now.duration_since(entry.last_stream_at) >= CONNECTION_IDLE_TIMEOUT;
            if !closed && idle {
                stale.push(entry.conn.clone());
            }
            !closed && !idle
        });
        stale
    }

    fn remove_if_same(&mut self, key: &ConnectionKey, conn: &Connection) {
        if self
            .entries
            .get(key)
            .is_some_and(|entry| entry.conn.stable_id() == conn.stable_id())
        {
            self.entries.remove(key);
        }
    }
}

fn spawn_connection_reaper(cache: Weak<Mutex<ConnectionCache>>) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(CONNECTION_IDLE_TIMEOUT);
        loop {
            tick.tick().await;
            let Some(cache) = cache.upgrade() else {
                return;
            };
            let stale = cache
                .lock()
                .expect("connection cache lock")
                .evict_idle(Instant::now());
            for conn in stale {
                conn.close(0u32.into(), b"connection cache idle");
            }
        }
    });
}

fn watch_connection_close(
    cache: Weak<Mutex<ConnectionCache>>,
    key: ConnectionKey,
    conn: Connection,
) {
    tokio::spawn(async move {
        let _ = conn.closed().await;
        if let Some(cache) = cache.upgrade() {
            cache
                .lock()
                .expect("connection cache lock")
                .remove_if_same(&key, &conn);
        }
    });
}

/// The iroh transport: one QUIC endpoint plus its keyed connection cache.
#[derive(Clone)]
pub struct IrohTransport {
    ep: Endpoint,
    /// Peer address book, fed by [`Self::add_peer`] (pairing/tickets).
    peers: Arc<Mutex<HashMap<NodeId, EndpointAddr>>>,
    connections: Arc<Mutex<ConnectionCache>>,
    /// Serializes cache misses so concurrent requests for one key cannot
    /// perform duplicate handshakes before either inserts its connection.
    connect_gate: Arc<tokio::sync::Mutex<()>>,
    /// Optional blobs handler: `listen` routes `ALPN_BLOBS` connections
    /// here instead of the ctrl stream (one endpoint = one accept queue;
    /// a daemon serving both planes shares the loop, T-033).
    blobs_handler: Arc<Mutex<Option<iroh_blobs::BlobsProtocol>>>,
}

/// DAE-02: derive the stable node id from the identity secret key
/// WITHOUT binding an endpoint.
///
/// The single-instance claim must run before the transport bind: with a
/// fixed-port config, binding first fails outright while the incumbent
/// holds the port (real machine finding — a 0.2.1 upgrade died on
/// "Failed to bind sockets" before its version handshake ever ran, so
/// the takeover never happened). The IPC socket name depends on the node
/// id, which is a pure function of the identity key — no endpoint needed.
pub fn node_id_from_secret_key(bytes: &[u8; 32]) -> NodeId {
    let sk = SecretKey::from_bytes(bytes);
    NodeId(*sk.public().as_bytes())
}

impl IrohTransport {
    pub async fn bind(cfg: TransportConfig) -> Result<Self> {
        let mut builder = if cfg.n0_services {
            Endpoint::builder(presets::N0)
        } else {
            Endpoint::builder(presets::Minimal)
        };

        if !cfg.relay_urls.is_empty() {
            let urls = cfg
                .relay_urls
                .iter()
                .map(|u| u.parse::<RelayUrl>())
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|e| TransportError::Bind(format!("invalid relay url: {e}")))?;
            builder = builder.relay_mode(RelayMode::custom(urls));
        }
        if let Some(bytes) = cfg.secret_key {
            builder = builder.secret_key(SecretKey::from_bytes(&bytes));
        }
        if let Some(addr) = cfg.bind_addr {
            builder = builder
                .bind_addr(addr)
                .map_err(|e| TransportError::Bind(e.to_string()))?;
        }

        let alpns = cfg.alpns.iter().map(|a| a.as_bytes().to_vec()).collect();
        let ep = builder
            .alpns(alpns)
            .bind()
            .await
            .map_err(|e| TransportError::Bind(e.to_string()))?;

        let connections = Arc::<Mutex<ConnectionCache>>::default();
        spawn_connection_reaper(Arc::downgrade(&connections));
        Ok(Self {
            ep,
            peers: Arc::default(),
            connections,
            connect_gate: Arc::default(),
            blobs_handler: Arc::default(),
        })
    }

    pub fn node_id(&self) -> NodeId {
        NodeId(*self.ep.id().as_bytes())
    }

    /// Our address bundle, for handing to a peer. CGNAT-range addresses
    /// (100.64.0.0/10 — Tailscale & carrier NAT) are filtered out: they
    /// are only reachable inside that overlay and poison path selection
    /// for everyone else (real-world bug: a Tailscale install made the
    /// same-machine backup pull time out).
    pub fn local_addr(&self) -> PeerAddr {
        let mut addr = self.ep.addr();
        addr.addrs.retain(|a| match a {
            TransportAddr::Ip(sa) => !is_cgnat(&sa.ip()),
            _ => true,
        });
        PeerAddr(addr)
    }

    /// Register a peer's address bundle; returns its [`NodeId`] for use
    /// with [`Transport::connect`].
    pub fn add_peer(&self, addr: PeerAddr) -> NodeId {
        let id = addr.node_id();
        self.peers.lock().expect("peers lock").insert(id, addr.0);
        id
    }

    /// Wait until address discovery is far enough that hole-punching works
    /// — a relay home is assigned and the endpoint's advertised address
    /// carries it. Bounded by `timeout`; returns whether it became ready.
    ///
    /// The backup provider MUST await this before announcing its address,
    /// or a same-network peer that can't直连 has no relay to fall back to
    /// (real bug: fresh endpoint announces a bare IP, reverse-dial times
    /// out). iroh's own docs: "After online() returns…holepunching should
    /// work as expected."
    pub async fn wait_online(&self, timeout: std::time::Duration) -> bool {
        tokio::time::timeout(timeout, self.ep.online())
            .await
            .is_ok()
    }

    /// Gracefully close the endpoint (flushes connection close frames).
    pub async fn close(&self) {
        self.ep.close().await;
    }

    /// T-090: neutral connection status of one peer, for `devices.list`.
    ///
    /// This legacy peer-only projection selects the most recently used live
    /// cached connection. New transport callers that need ALPN-specific facts
    /// use [`Self::path_of`].
    pub fn connection_status(&self, peer: NodeId) -> ConnectionStatus {
        let mut cache = self.connections.lock().expect("connection cache lock");
        let Some(conn) = cache.latest_live(peer) else {
            return ConnectionStatus::Offline;
        };
        status_of_live(classify(&path_facts(&conn)))
    }

    /// Return the current path facts for one cached `(peer, ALPN)` connection.
    /// No cache entry or a connection closed by either endpoint yields `None`.
    pub fn path_of(&self, peer: NodeId, alpn: &str) -> Option<ConnInfo> {
        let conn = self
            .connections
            .lock()
            .expect("connection cache lock")
            .get_live(peer, alpn)?;
        Some(classify(&path_facts(&conn)))
    }

    /// Exact route verdict for one live `(peer, ALPN)` cache entry. Absence
    /// after a successful connect is represented as `Unknown`, never as
    /// `Offline`: callers use this while a higher-level operation is active.
    pub fn path_status_of(&self, peer: NodeId, alpn: &str) -> ConnectionStatus {
        self.path_of(peer, alpn)
            .map(status_of_live)
            .unwrap_or(ConnectionStatus::Unknown)
    }

    /// Crate-internal endpoint access (blobs.rs shares the endpoint).
    pub(crate) fn endpoint(&self) -> &Endpoint {
        &self.ep
    }

    /// Crate-internal: register the blobs handler the `listen` loop
    /// dispatches `ALPN_BLOBS` connections to.
    pub(crate) fn set_blobs_handler(&self, handler: iroh_blobs::BlobsProtocol) {
        *self.blobs_handler.lock().expect("blobs handler lock") = Some(handler);
    }

    fn discard_if_same(&self, peer: NodeId, alpn: &str, conn: &Connection) {
        self.connections
            .lock()
            .expect("connection cache lock")
            .remove_if_same(&ConnectionKey::new(peer, alpn), conn);
    }

    /// Crate-internal: fetch or create the single live connection for one
    /// `(peer, ALPN)` key. A live connection returns immediately; a closed
    /// one is removed before reconnecting.
    pub(crate) async fn get_or_connect(&self, peer: NodeId, alpn: &str) -> Result<Connection> {
        if let Some(conn) = self
            .connections
            .lock()
            .expect("connection cache lock")
            .get_live(peer, alpn)
        {
            return Ok(conn);
        }

        let _connect_gate = self.connect_gate.lock().await;
        if let Some(conn) = self
            .connections
            .lock()
            .expect("connection cache lock")
            .get_live(peer, alpn)
        {
            return Ok(conn);
        }

        let known = self.peers.lock().expect("peers lock").get(&peer).cloned();
        let addr = match known {
            Some(addr) => addr,
            None => EndpointAddr::from(endpoint_id(peer)?),
        };
        let conn =
            self.ep
                .connect(addr, alpn.as_bytes())
                .await
                .map_err(|e| TransportError::Connect {
                    peer,
                    reason: e.to_string(),
                })?;
        let key = ConnectionKey::new(peer, alpn);
        self.connections
            .lock()
            .expect("connection cache lock")
            .insert(peer, alpn, conn.clone());
        watch_connection_close(Arc::downgrade(&self.connections), key, conn.clone());
        Ok(conn)
    }

    /// Crate-internal raw connection for the blobs fetch path.
    pub(crate) async fn connect_raw(&self, peer: NodeId, alpn: &str) -> Result<Connection> {
        self.get_or_connect(peer, alpn).await
    }
}

impl Transport for IrohTransport {
    /// Spawns an accept loop and yields handshake-complete connections.
    /// Intended to be called once by the daemon's serve loop.
    async fn listen(&self) -> impl futures_core::Stream<Item = Incoming> {
        let (tx, rx) = tokio::sync::mpsc::channel(16);
        let ep = self.ep.clone();
        let connections = Arc::clone(&self.connections);

        let peers = Arc::clone(&self.peers);
        let blobs_handler = Arc::clone(&self.blobs_handler);
        tokio::spawn(async move {
            while let Some(incoming) = ep.accept().await {
                let Ok(mut accepting) = incoming.accept() else {
                    continue;
                };
                let tx = tx.clone();
                let connections = Arc::clone(&connections);
                let peers = Arc::clone(&peers);
                let blobs_handler = Arc::clone(&blobs_handler);
                // Finish each handshake off the accept loop so one slow
                // client cannot stall the others.
                tokio::spawn(async move {
                    let Ok(alpn) = accepting.alpn().await else {
                        return;
                    };
                    let Ok(conn) = accepting.await else {
                        return;
                    };
                    let peer = NodeId(*conn.remote_id().as_bytes());
                    let alpn = String::from_utf8_lossy(&alpn).into_owned();
                    let key = ConnectionKey::new(peer, &alpn);
                    connections.lock().expect("connection cache lock").insert(
                        peer,
                        &alpn,
                        conn.clone(),
                    );
                    watch_connection_close(Arc::downgrade(&connections), key, conn.clone());
                    // Register the dialer's observed addresses so this side
                    // can dial BACK (e.g. blobs pull during backup, T-032) —
                    // inbound peers are reachable without discovery services.
                    let addrs: std::collections::BTreeSet<TransportAddr> = conn
                        .paths()
                        .iter()
                        .map(|p| p.remote_addr().clone())
                        .collect();
                    if addrs.is_empty() {
                        tracing::debug!("inbound {peer:?}: no observable addresses to register");
                    } else {
                        tracing::debug!("inbound {peer:?}: registering {addrs:?}");
                        let ep_addr = EndpointAddr {
                            id: conn.remote_id(),
                            addrs,
                        };
                        peers.lock().expect("peers lock").insert(peer, ep_addr);
                    }
                    // Data-plane connections go straight to the blobs
                    // handler; only ctrl-plane connections reach the app.
                    if alpn == crate::ALPN_BLOBS {
                        let handler = blobs_handler.lock().expect("blobs handler lock").clone();
                        if let Some(h) = handler {
                            use iroh::protocol::ProtocolHandler;
                            let _ = h.accept(conn).await;
                        }
                        return;
                    }
                    let _ = tx.send(Incoming { peer, alpn, conn }).await;
                });
            }
        });

        IncomingStream { rx }
    }

    async fn connect(&self, peer: NodeId, alpn: &str) -> Result<BiStream> {
        let conn = self.get_or_connect(peer, alpn).await?;
        let (send, recv) = match conn.open_bi().await {
            Ok(streams) => streams,
            Err(_) => {
                // A remote close can be in flight before `close_reason()` is
                // observable locally. Drop this cache entry and retry once on
                // a fresh connection rather than handing callers a dead stream.
                self.discard_if_same(peer, alpn, &conn);
                let fresh = self.get_or_connect(peer, alpn).await?;
                fresh
                    .open_bi()
                    .await
                    .map_err(|e| TransportError::Io(e.to_string()))?
            }
        };
        Ok(BiStream { send, recv })
    }

    fn conn_info(&self, peer: NodeId) -> ConnInfo {
        let mut cache = self.connections.lock().expect("connection cache lock");
        let Some(conn) = cache.latest_live(peer) else {
            return ConnInfo::NONE;
        };
        classify(&path_facts(&conn))
    }
}

/// iroh-independent snapshot of a connection's open paths (shared by
/// `conn_info` and `connection_status`).
fn path_facts(conn: &Connection) -> Vec<PathFacts> {
    conn.paths()
        .iter()
        .map(|p| PathFacts {
            selected: p.is_selected(),
            relay: p.is_relay(),
            remote_ip: match p.remote_addr() {
                TransportAddr::Ip(sa) => Some(sa.ip()),
                _ => None,
            },
            rtt: p.rtt(),
        })
        .collect()
}

/// 100.64.0.0/10 — RFC 6598 carrier-grade NAT, also used by Tailscale.
fn is_cgnat(ip: &std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(v4) => {
            let o = v4.octets();
            o[0] == 100 && (64..128).contains(&o[1])
        }
        std::net::IpAddr::V6(_) => false,
    }
}

fn endpoint_id(id: NodeId) -> Result<EndpointId> {
    EndpointId::from_bytes(&id.0).map_err(|_| TransportError::InvalidNodeId)
}

/// Stream of inbound connections, backed by the accept-loop channel.
pub struct IncomingStream {
    rx: tokio::sync::mpsc::Receiver<Incoming>,
}

impl futures_core::Stream for IncomingStream {
    type Item = Incoming;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Incoming>> {
        self.rx.poll_recv(cx)
    }
}

/// An inbound connection whose handshake (including ALPN) has completed.
pub struct Incoming {
    peer: NodeId,
    alpn: String,
    conn: Connection,
}

impl Incoming {
    pub fn peer(&self) -> NodeId {
        self.peer
    }

    pub fn alpn(&self) -> &str {
        &self.alpn
    }

    /// Accept the next bidirectional stream the dialer opens.
    /// QUIC streams are lazy: this resolves once the dialer sends data.
    pub async fn accept_bi(&self) -> Result<BiStream> {
        let (send, recv) = self
            .conn
            .accept_bi()
            .await
            .map_err(|e| TransportError::Io(e.to_string()))?;
        Ok(BiStream { send, recv })
    }
}

/// A bidirectional stream carrying length-prefixed frames (详细设计 §3.2
/// control plane). Frames are opaque bytes here — encoding/decoding lives
/// in `proto::codec`; the 4-byte LE length header is shared wire format.
pub struct BiStream {
    send: SendStream,
    recv: RecvStream,
}

impl BiStream {
    /// Send one complete frame, as produced by `proto::codec::encode`
    /// (the buffer already starts with its 4-byte LE length header).
    pub async fn send_frame(&mut self, frame: &[u8]) -> Result<()> {
        self.send
            .write_all(frame)
            .await
            .map_err(|e| TransportError::Io(e.to_string()))
    }

    /// Receive one complete frame (header + payload), ready for
    /// `proto::codec::decode`. `Ok(None)` = peer finished cleanly.
    pub async fn recv_frame(&mut self) -> Result<Option<Vec<u8>>> {
        let mut header = [0u8; 4];
        match self.recv.read_exact(&mut header).await {
            Ok(()) => {}
            Err(ReadExactError::FinishedEarly(0)) => return Ok(None),
            Err(e) => return Err(TransportError::Io(e.to_string())),
        }
        let len = u32::from_le_bytes(header);
        if len > MAX_FRAME {
            return Err(TransportError::FrameTooLarge(len));
        }
        let mut frame = vec![0u8; 4 + len as usize];
        frame[..4].copy_from_slice(&header);
        self.recv
            .read_exact(&mut frame[4..])
            .await
            .map_err(|e| match e {
                ReadExactError::FinishedEarly(got) => TransportError::TruncatedFrame {
                    expected: len as usize,
                    got,
                },
                e => TransportError::Io(e.to_string()),
            })?;
        Ok(Some(frame))
    }

    /// Read the next chunk of raw (unframed) bytes — the upload plane's
    /// payload after its header frame. `Ok(None)` = sender finished.
    pub async fn recv_chunk(&mut self, max: usize) -> Result<Option<Vec<u8>>> {
        let mut buf = vec![0u8; max];
        match self.recv.read(&mut buf).await {
            Ok(Some(n)) => {
                buf.truncate(n);
                Ok(Some(buf))
            }
            Ok(None) => Ok(None),
            Err(e) => Err(TransportError::Io(e.to_string())),
        }
    }

    /// Finish the send side (graceful half-close). The peer's
    /// `recv_frame` then returns `Ok(None)`.
    pub fn finish(&mut self) -> Result<()> {
        self.send
            .finish()
            .map_err(|e| TransportError::Io(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn node_id_from_secret_key_matches_bound_endpoint() {
        // DAE-02 根基：不 bind 预派的 node_id 必须与真实 endpoint 的
        // node_id 逐字节一致——main 用它在 transport bind 之前跑单实例
        // claim（socket_name 依赖 node_id）。漂移 = 身份错乱。
        let secret = [0x77; 32];
        let predicted = node_id_from_secret_key(&secret);
        let mut cfg = TransportConfig::loopback(vec![crate::ALPN_CTRL.into()]);
        cfg.secret_key = Some(secret);
        let tp = IrohTransport::bind(cfg).await.unwrap();
        assert_eq!(
            tp.node_id(),
            predicted,
            "pre-derived node id must match the bound endpoint"
        );
        assert_eq!(predicted.to_string().len(), 64);
    }
}
