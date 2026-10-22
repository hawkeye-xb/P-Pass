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
use crate::{NodeId, Result, Transport, TransportError};

/// Construction inputs, mapped from the daemon `Config` (T-004): the daemon
/// passes `Config.relay_urls` in here. Address lookup (发现) stays on n0
/// public infrastructure for MVP per ADR-009 (Phase 2: self-hosted pkarr);
/// `Config.rendezvous_url` is retired (#1041: accepted and ignored).
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

    /// Address of `node` reachable via `relay` (pairing link `r=`), or with no
    /// address hints at all (`relay = None`: iroh resolves it through address
    /// lookup when the endpoint has n0 services on).
    pub fn from_node_relay(node: NodeId, relay: Option<&str>) -> Result<Self> {
        let mut addr = EndpointAddr::from(endpoint_id(node)?);
        if let Some(relay) = relay {
            let url: RelayUrl = relay.parse().map_err(|e| {
                TransportError::InvalidPairLink(format!("relay url {relay:?}: {e}"))
            })?;
            addr.addrs.insert(TransportAddr::Relay(url));
        }
        Ok(Self(addr))
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

    /// #1119：取出这台设备的全部缓存连接（任意 ALPN），交给调用方关闭。
    fn take_peer(&mut self, peer: NodeId) -> Vec<Connection> {
        let mut taken = Vec::new();
        self.entries.retain(|key, entry| {
            if key.peer == peer {
                taken.push(entry.conn.clone());
                false
            } else {
                true
            }
        });
        taken
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

/// #1119：登记一条入站连接，连接关闭时自动移除。
fn track_inbound(inbound: &InboundConnections, peer: NodeId, conn: Connection) {
    let id = conn.stable_id();
    inbound
        .lock()
        .expect("inbound connections lock")
        .insert(id, (peer, conn.clone()));
    let weak = Arc::downgrade(inbound);
    tokio::spawn(async move {
        let _ = conn.closed().await;
        if let Some(inbound) = weak.upgrade() {
            inbound
                .lock()
                .expect("inbound connections lock")
                .remove(&id);
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

type ConnectGate = Arc<tokio::sync::Mutex<()>>;

/// The iroh transport: one QUIC endpoint plus its keyed connection cache.
#[derive(Clone)]
pub struct IrohTransport {
    ep: Endpoint,
    /// Peer address book, fed by [`Self::add_peer`] (pairing/tickets).
    peers: Arc<Mutex<lru::LruCache<NodeId, EndpointAddr>>>,
    connections: Arc<Mutex<ConnectionCache>>,
    /// One gate per `(peer, ALPN)`: serializes cache misses for the SAME key
    /// so concurrent requests cannot perform duplicate handshakes before
    /// either inserts its connection. NET-26 (#419): this used to be a
    /// single transport-wide gate, so one phone whose handshake hung
    /// (up to the ~30s connect timeout) queued every other peer's first
    /// connect behind it. Different keys now handshake in parallel.
    /// Entries are never pruned — the map is bounded by peers × ALPNs.
    connect_gates: Arc<Mutex<HashMap<ConnectionKey, ConnectGate>>>,
    /// Optional blobs handler: `listen` routes `ALPN_BLOBS` connections
    /// here instead of the ctrl stream (one endpoint = one accept queue;
    /// a daemon serving both planes shares the loop, T-033).
    blobs_handler: Arc<Mutex<Option<crate::blobs::GatedBlobs>>>,
    /// #1119：每一条仍活着的入站连接（按 QUIC stable id）。连接缓存按
    /// (设备, ALPN) 只记一条，客户端每次请求新开连接时长连接（订阅）的登记会被
    /// 覆盖；`close_peer` 要关掉一台设备的**全部**连接，靠的是这张表（三星真机
    /// E3 抓到：订阅开着，`close_peer` 却一条都没找到）。
    inbound: InboundConnections,
    /// #1122：入站连接的准入判据（见 [`Self::set_admission`]）。
    admission: AdmissionSlot,
}

/// #1122：入站连接准入判据：`(对端, ALPN) -> 放行？`。未设置 = 全部放行。
pub type Admission = Arc<dyn Fn(NodeId, &[u8]) -> bool + Send + Sync>;

#[derive(Clone, Default)]
struct AdmissionSlot(Arc<std::sync::RwLock<Option<Admission>>>);

impl AdmissionSlot {
    fn admits(&self, peer: NodeId, alpn: &[u8]) -> bool {
        match self.0.read().unwrap_or_else(|e| e.into_inner()).as_ref() {
            Some(admit) => admit(peer, alpn),
            None => true,
        }
    }
}

/// 装在端点上的 iroh 钩子：只管入站（我方是服务端）的连接，出站一律放行。
#[derive(Clone)]
struct AdmissionHook(AdmissionSlot);

impl std::fmt::Debug for AdmissionHook {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AdmissionHook")
    }
}

impl iroh::endpoint::EndpointHooks for AdmissionHook {
    fn after_handshake<'a>(
        &'a self,
        conn: &'a Connection,
    ) -> impl std::future::Future<Output = iroh::endpoint::AfterHandshakeOutcome> + Send + 'a {
        let outcome = if conn.side() == iroh::endpoint::Side::Server
            && !self
                .0
                .admits(NodeId(*conn.remote_id().as_bytes()), conn.alpn())
        {
            iroh::endpoint::AfterHandshakeOutcome::Reject {
                error_code: crate::NOT_PAIRED_CLOSE_CODE.into(),
                reason: b"not_paired".to_vec(),
            }
        } else {
            iroh::endpoint::AfterHandshakeOutcome::Accept
        };
        async move { outcome }
    }
}

type InboundConnections = Arc<Mutex<HashMap<usize, (NodeId, Connection)>>>;

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

        // #1122：每条连接上对端可同时打开的双向流数（iroh/quinn 自带的传输参数）。
        let quic = iroh::endpoint::QuicTransportConfig::builder()
            .max_concurrent_bidi_streams(crate::MAX_CONCURRENT_BIDI_STREAMS.into())
            .build();
        // #1122：入站连接握手完成（已知对端 NodeId 与 ALPN）即按准入判据放行或拒绝，
        // 用 iroh 自带的 EndpointHooks::after_handshake——被拒的不读任何请求。
        let admission = AdmissionSlot::default();
        let alpns = cfg.alpns.iter().map(|a| a.as_bytes().to_vec()).collect();
        let ep = builder
            .transport_config(quic)
            .hooks(AdmissionHook(admission.clone()))
            .alpns(alpns)
            .bind()
            .await
            .map_err(|e| TransportError::Bind(e.to_string()))?;

        let connections = Arc::<Mutex<ConnectionCache>>::default();
        spawn_connection_reaper(Arc::downgrade(&connections));
        Ok(Self {
            ep,
            peers: Arc::new(Mutex::new(lru::LruCache::new(
                std::num::NonZeroUsize::new(crate::PEER_BOOK_CAPACITY).expect("nonzero"),
            ))),
            admission,
            connections,
            connect_gates: Arc::default(),
            blobs_handler: Arc::default(),
            inbound: Arc::default(),
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
        self.peers.lock().expect("peers lock").put(id, addr.0);
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

    /// #1119：这台设备的配对记录已删除——用 iroh 自带的 `Connection::close`
    /// 关掉与它的全部连接（控制面、下载，以及 blobs 处理器里在服务的连接），
    /// 不等空闲回收。对端看到关闭码 [`crate::UNPAIRED_CLOSE_CODE`]。之后它再连
    /// 进来，每个请求照常过 authz（没有配对记录 ⇒ 只剩配对那扇门）。返回关掉了
    /// 几条连接（同一连接只算一次）。
    pub fn close_peer(&self, peer: NodeId) -> usize {
        let mut conns = self
            .connections
            .lock()
            .expect("connection cache lock")
            .take_peer(peer);
        conns.extend(
            self.inbound
                .lock()
                .expect("inbound connections lock")
                .values()
                .filter(|(p, _)| *p == peer)
                .map(|(_, c)| c.clone()),
        );
        if let Some(blobs) = self
            .blobs_handler
            .lock()
            .expect("blobs handler lock")
            .as_ref()
        {
            conns.extend(blobs.connections_of(peer));
        }
        let mut seen = std::collections::HashSet::new();
        for conn in &conns {
            if seen.insert(conn.stable_id()) {
                conn.close(crate::UNPAIRED_CLOSE_CODE.into(), b"unpaired");
            }
        }
        seen.len()
    }

    /// #1122：设置入站连接的准入判据。握手完成后、读任何请求之前判定；被拒的
    /// 连接收到 [`crate::NOT_PAIRED_CLOSE_CODE`]，不登记地址、不进连接缓存。
    pub fn set_admission(&self, admit: Admission) {
        *self.admission.0.write().unwrap_or_else(|e| e.into_inner()) = Some(admit);
    }

    /// Crate-internal endpoint access (blobs.rs shares the endpoint).
    pub(crate) fn endpoint(&self) -> &Endpoint {
        &self.ep
    }

    /// Crate-internal: register the blobs handler the `listen` loop
    /// dispatches `ALPN_BLOBS` connections to.
    pub(crate) fn set_blobs_handler(&self, handler: crate::blobs::GatedBlobs) {
        *self.blobs_handler.lock().expect("blobs handler lock") = Some(handler);
    }

    fn discard_if_same(&self, peer: NodeId, alpn: &str, conn: &Connection) {
        self.connections
            .lock()
            .expect("connection cache lock")
            .remove_if_same(&ConnectionKey::new(peer, alpn), conn);
    }

    /// The dedup gate for one `(peer, ALPN)` key (created on first use).
    /// The std lock is released before the caller awaits the gate.
    fn connect_gate(&self, peer: NodeId, alpn: &str) -> ConnectGate {
        Arc::clone(
            self.connect_gates
                .lock()
                .expect("connect gates lock")
                .entry(ConnectionKey::new(peer, alpn))
                .or_default(),
        )
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

        let gate = self.connect_gate(peer, alpn);
        let _connect_gate = gate.lock().await;
        if let Some(conn) = self
            .connections
            .lock()
            .expect("connection cache lock")
            .get_live(peer, alpn)
        {
            return Ok(conn);
        }

        let conn = self.dial(peer, alpn).await?;
        let key = ConnectionKey::new(peer, alpn);
        self.connections
            .lock()
            .expect("connection cache lock")
            .insert(peer, alpn, conn.clone());
        watch_connection_close(Arc::downgrade(&self.connections), key, conn.clone());
        Ok(conn)
    }

    /// Dials [peer] at its registered address (or by NodeId lookup).
    async fn dial(&self, peer: NodeId, alpn: &str) -> Result<Connection> {
        let known = self.peers.lock().expect("peers lock").get(&peer).cloned();
        let addr = match known {
            Some(addr) => addr,
            None => EndpointAddr::from(endpoint_id(peer)?),
        };
        self.ep
            .connect(addr, alpn.as_bytes())
            .await
            .map_err(|e| TransportError::Connect {
                peer,
                reason: e.to_string(),
            })
    }

    /// A connection of its own, outside the per-peer cache, plus one stream
    /// on it — the iOS control client's request model (#963): one connection
    /// per request or per push stream, like HTTP without keep-alive. The
    /// daemon serves one connection's streams one after another (`router.rs`
    /// serve loop), so requests sharing a cached connection queue behind
    /// each other and a push stream would block them all. Android does the
    /// same (`DaemonClient.call` dials per call). Path knowledge is still
    /// shared through the one Endpoint, so this costs a handshake, not a
    /// fresh hole-punch. The caller owns the connection and closes it.
    #[cfg(feature = "ios-ffi")]
    pub(crate) async fn connect_dedicated(
        &self,
        peer: NodeId,
        alpn: &str,
    ) -> Result<(Connection, BiStream)> {
        let conn = self.dial(peer, alpn).await?;
        let (send, recv) = conn
            .open_bi()
            .await
            .map_err(|e| TransportError::Io(e.to_string()))?;
        Ok((conn, BiStream { send, recv }))
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
        let inbound = Arc::clone(&self.inbound);
        tokio::spawn(async move {
            while let Some(incoming) = ep.accept().await {
                let Ok(mut accepting) = incoming.accept() else {
                    continue;
                };
                let tx = tx.clone();
                let connections = Arc::clone(&connections);
                let peers = Arc::clone(&peers);
                let blobs_handler = Arc::clone(&blobs_handler);
                let inbound = Arc::clone(&inbound);
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
                    track_inbound(&inbound, peer, conn.clone());
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
                        // #544：只记数量与类别，不记具体地址。
                        let relay = addrs
                            .iter()
                            .filter(|a| matches!(a, TransportAddr::Relay(_)))
                            .count();
                        tracing::debug!(
                            "inbound {peer:?}: registering {} addrs ({relay} relay)",
                            addrs.len()
                        );
                        let ep_addr = EndpointAddr {
                            id: conn.remote_id(),
                            addrs,
                        };
                        peers.lock().expect("peers lock").put(peer, ep_addr);
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

/// #1122：读帧正文时每次最多读这么多（缓冲按实际收到的数据增长）。
const READ_CHUNK: usize = 64 * 1024;

/// #1122：全进程的在途帧字节预算（见 [`crate::FRAME_BUDGET_BYTES`]）。
fn frame_budget() -> &'static tokio::sync::Semaphore {
    static BUDGET: std::sync::OnceLock<tokio::sync::Semaphore> = std::sync::OnceLock::new();
    BUDGET.get_or_init(|| tokio::sync::Semaphore::new(crate::FRAME_BUDGET_BYTES as usize))
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
        self.recv_frame_max(crate::MAX_FRAME).await
    }

    /// #1122：读一帧，正文不超过 `max` 字节。
    ///
    /// - 不按对端声明的长度预分配：缓冲随实际收到的数据增量增长（每次最多
    ///   [`READ_CHUNK`]），声明了 16 MiB 却只发几个字节的对端只占几个字节。
    /// - 声明长度超过 `max` 直接拒绝，一个字节的正文都不读。
    /// - 正文必须在 [`crate::FRAME_READ_TIMEOUT`] 内读完（含等待在途字节预算），
    ///   慢速发送者超时即放弃这条流。
    /// - 读正文期间占用全进程在途字节预算 [`crate::FRAME_BUDGET_BYTES`]，读完归还。
    pub async fn recv_frame_max(&mut self, max: u32) -> Result<Option<Vec<u8>>> {
        self.recv_frame_within(max, crate::FRAME_READ_TIMEOUT).await
    }

    /// [`Self::recv_frame_max`] with an explicit body deadline (tests use a short one).
    pub async fn recv_frame_within(
        &mut self,
        max: u32,
        deadline: std::time::Duration,
    ) -> Result<Option<Vec<u8>>> {
        let mut header = [0u8; 4];
        match self.recv.read_exact(&mut header).await {
            Ok(()) => {}
            Err(ReadExactError::FinishedEarly(0)) => return Ok(None),
            Err(e) => return Err(TransportError::Io(e.to_string())),
        }
        let len = u32::from_le_bytes(header);
        let max = max.min(crate::MAX_FRAME);
        if len > max {
            return Err(TransportError::FrameTooLarge { len, max });
        }
        let recv = &mut self.recv;
        let body = async move {
            let _budget = frame_budget()
                .acquire_many(len.max(1))
                .await
                .map_err(|e| TransportError::Io(e.to_string()))?;
            let mut frame = Vec::with_capacity(4 + (len as usize).min(READ_CHUNK));
            frame.extend_from_slice(&header);
            let mut chunk = vec![0u8; READ_CHUNK.min(len as usize)];
            while frame.len() < 4 + len as usize {
                let want = (4 + len as usize - frame.len()).min(chunk.len());
                match recv.read(&mut chunk[..want]).await {
                    Ok(Some(n)) => frame.extend_from_slice(&chunk[..n]),
                    Ok(None) => {
                        return Err(TransportError::TruncatedFrame {
                            expected: len as usize,
                            got: frame.len() - 4,
                        })
                    }
                    Err(e) => return Err(TransportError::Io(e.to_string())),
                }
            }
            Ok(Some(frame))
        };
        tokio::time::timeout(deadline, body)
            .await
            .map_err(|_| TransportError::FrameTimeout(deadline))?
    }

    /// Read the next chunk of raw (unframed) bytes — a raw-stream plane's
    /// payload after its header frame (the download plane, T-056).
    /// `Ok(None)` = sender finished.
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

    /// #1119：等对端确认收齐这条流已发出的全部数据（QUIC 层确认，不代表对端
    /// 已处理）。在 [`Self::finish`] 之后、主动关闭连接之前用——QUIC 的连接关闭
    /// 会丢弃尚未送达的流数据。对端停止接收或连接已断也算结束。
    pub async fn delivered(&self) {
        let _ = self.send.stopped().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal `StreamExt::next` stand-in (no futures-util dependency).
    async fn next_incoming<S: futures_core::Stream + Unpin>(s: &mut S) -> Option<S::Item> {
        std::future::poll_fn(|cx| Pin::new(&mut *s).poll_next(cx)).await
    }

    fn ctrl_loopback() -> TransportConfig {
        TransportConfig::loopback(vec![crate::ALPN_CTRL.into()])
    }

    /// A reachable ctrl-ALPN server whose accept loop runs (without it the
    /// dialer's handshake never completes).
    async fn serving_peer() -> (IrohTransport, tokio::task::JoinHandle<()>) {
        let server = IrohTransport::bind(ctrl_loopback())
            .await
            .expect("bind server");
        let listener = server.clone();
        let task = tokio::spawn(async move {
            let mut incoming = listener.listen().await;
            let mut held = Vec::new();
            while let Some(inc) = next_incoming(&mut incoming).await {
                held.push(inc);
            }
        });
        (server, task)
    }

    /// Register a peer whose only address is a bound-but-never-read UDP
    /// socket: nothing answers and no ICMP unreachable comes back, so a
    /// handshake to it hangs until iroh's own connect timeout.
    fn blackhole_peer(client: &IrohTransport) -> (NodeId, std::net::UdpSocket) {
        let sink = std::net::UdpSocket::bind("127.0.0.1:0").expect("bind blackhole");
        let id = SecretKey::from_bytes(&[0x42; 32]).public();
        let addr = EndpointAddr {
            id,
            addrs: [TransportAddr::Ip(
                sink.local_addr().expect("blackhole addr"),
            )]
            .into_iter()
            .collect(),
        };
        (client.add_peer(PeerAddr(addr)), sink)
    }

    /// NET-26 (#419): a handshake hung on one peer must not queue another
    /// peer's first connect behind it. With the old transport-wide gate,
    /// B's connect waits for A's handshake to time out and this budget fails.
    #[tokio::test]
    async fn hung_handshake_to_one_peer_does_not_block_another_peer() {
        let client = IrohTransport::bind(ctrl_loopback())
            .await
            .expect("bind client");
        let (server, server_task) = serving_peer().await;
        let reachable = client.add_peer(server.local_addr());
        let (blackhole, _sink) = blackhole_peer(&client);

        let hung_client = client.clone();
        let hung = tokio::spawn(async move {
            hung_client
                .get_or_connect(blackhole, crate::ALPN_CTRL)
                .await
                .map(|_| ())
        });
        // Let the hung handshake take its gate first.
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(
            !hung.is_finished(),
            "blackhole handshake must still be pending"
        );

        let started = Instant::now();
        let conn = tokio::time::timeout(
            Duration::from_secs(5),
            client.get_or_connect(reachable, crate::ALPN_CTRL),
        )
        .await
        .expect("connect to a reachable peer must not wait on another peer's hung handshake")
        .expect("connect to reachable peer");
        assert_eq!(NodeId(*conn.remote_id().as_bytes()), reachable);
        eprintln!("reachable peer connected in {:?}", started.elapsed());
        assert!(
            !hung.is_finished(),
            "blackhole handshake should still be hanging"
        );

        hung.abort();
        server_task.abort();
        client.close().await;
        server.close().await;
    }

    /// The gate's original job (a9ea255f): concurrent cache misses for the
    /// SAME `(peer, ALPN)` share one handshake instead of racing duplicates.
    #[tokio::test]
    async fn concurrent_connects_to_one_key_share_one_handshake() {
        let client = IrohTransport::bind(ctrl_loopback())
            .await
            .expect("bind client");
        let (server, server_task) = serving_peer().await;
        let peer = client.add_peer(server.local_addr());

        let attempts: Vec<_> = (0..8)
            .map(|_| {
                let client = client.clone();
                tokio::spawn(async move {
                    client
                        .get_or_connect(peer, crate::ALPN_CTRL)
                        .await
                        .expect("connect")
                        .stable_id()
                })
            })
            .collect();
        let mut ids = std::collections::BTreeSet::new();
        for attempt in attempts {
            ids.insert(attempt.await.expect("connect task"));
        }
        assert_eq!(
            ids.len(),
            1,
            "one key must yield exactly one handshake, got {ids:?}"
        );

        server_task.abort();
        client.close().await;
        server.close().await;
    }

    /// Diagnostic: how long a blackhole handshake hangs on its own. The
    /// budget in the cross-peer test must sit well below this.
    #[tokio::test]
    #[ignore = "diagnostic: measures the iroh connect timeout (slow)"]
    async fn measure_blackhole_handshake_duration() {
        let client = IrohTransport::bind(ctrl_loopback())
            .await
            .expect("bind client");
        let (blackhole, _sink) = blackhole_peer(&client);
        let started = Instant::now();
        let result = client.get_or_connect(blackhole, crate::ALPN_CTRL).await;
        eprintln!(
            "blackhole connect ended after {:?}: {:?}",
            started.elapsed(),
            result.map(|_| ())
        );
        client.close().await;
    }

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
