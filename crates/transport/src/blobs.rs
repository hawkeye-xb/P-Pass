//! iroh-blobs wrapper (T-021): content-addressed photo/video transfer
//! with transparent resume.
//!
//! 契约: `push(hash, path)` makes a local file fetchable under its BLAKE3
//! hash and returns a ticket; `pull(ticket, dest)` fetches it — resuming
//! from whatever partial data the store already holds — and exports to
//! `dest`. Verification is inherent: iroh-blobs streams are BLAKE3-verified
//! chunk by chunk, and the hash domain is the same one core-index uses for
//! dedup (架构 §4.2).
//!
//! Serving uses an [`iroh::protocol::Router`] on [`crate::ALPN_BLOBS`].
//! A daemon that serves both planes (ctrl + blobs) moves its ctrl accept
//! loop into the same Router at T-030 — an endpoint has one accept queue.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh::endpoint::Connection;
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh_blobs::provider::events::{
    AbortReason, ConnectMode, EventMask, EventResult, EventSender, ObserveMode, ProviderMessage,
    RequestMode, ThrottleMode,
};
use iroh_blobs::store::fs::{options::Options, FsStore};
use iroh_blobs::store::{GcConfig, ProtectCb, ProtectOutcome};
use iroh_blobs::ticket::BlobTicket;
use iroh_blobs::{BlobFormat, BlobsProtocol, Hash};

use crate::iroh_impl::{IrohTransport, PeerAddr};
use crate::{NodeId, Result, TransportError};

/// #546: may this peer use the blobs data plane right now? Asked once when
/// a connection arrives and again for every request on it, so a revocation
/// takes effect on the very next request of an already-open connection.
/// Anything but `true` (including a failed lookup) is a denial.
pub type PeerGate = Arc<dyn Fn(NodeId) -> Pin<Box<dyn Future<Output = bool> + Send>> + Send + Sync>;

/// QUIC application close code for a gate denial (0 is the normal close).
const DENIED_CLOSE_CODE: u32 = 403;

/// #546: the daemon's blobs handler. Two checkpoints, both the same
/// [`PeerGate`]:
///
/// 1. connection level — [`ProtocolHandler::accept`] refuses the connection
///    before iroh-blobs reads a single request from it;
/// 2. request level — iroh-blobs' own `Intercept` provider events: every
///    get / get-many / observe request re-asks the gate for the connection's
///    peer (revocation reaches already-open connections), and push requests
///    are always refused (nobody may write into the daemon's store over the
///    network; its only writers are its own pulls and imports).
///
/// A request-level denial also closes the connection.
#[derive(Clone)]
pub(crate) struct GatedBlobs {
    inner: BlobsProtocol,
    gate: PeerGate,
    /// Open connections by iroh-blobs' `connection_id` (= QUIC stable id):
    /// which peer the request events belong to, and what to close on denial.
    live: LiveConnections,
}

type LiveConnections = Arc<Mutex<HashMap<u64, (NodeId, Connection)>>>;

impl std::fmt::Debug for GatedBlobs {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GatedBlobs").finish_non_exhaustive()
    }
}

impl GatedBlobs {
    fn new(store: &FsStore, gate: PeerGate) -> Self {
        let live: LiveConnections = Arc::default();
        let events = spawn_request_gate(Arc::clone(&gate), Arc::clone(&live));
        Self {
            inner: BlobsProtocol::new(store, Some(events)),
            gate,
            live,
        }
    }
}

impl ProtocolHandler for GatedBlobs {
    async fn accept(&self, connection: Connection) -> std::result::Result<(), AcceptError> {
        let peer = NodeId(*connection.remote_id().as_bytes());
        if !(self.gate)(peer).await {
            connection.close(DENIED_CLOSE_CODE.into(), b"not authorized");
            return Ok(());
        }
        let id = connection.stable_id() as u64;
        self.live
            .lock()
            .expect("blobs live connections lock")
            .insert(id, (peer, connection.clone()));
        let result = self.inner.accept(connection).await;
        self.live
            .lock()
            .expect("blobs live connections lock")
            .remove(&id);
        result
    }

    async fn shutdown(&self) {
        self.inner.shutdown().await;
    }
}

/// The request-level half of [`GatedBlobs`]. Note iroh-blobs 0.103 routes
/// EVERY request kind (get, get-many, observe, push) through the `get`
/// request mode, so `get: Intercept` is what makes all of them arrive here;
/// each is answered on its own task so one slow lookup never serializes
/// other connections.
fn spawn_request_gate(gate: PeerGate, live: LiveConnections) -> EventSender {
    let mask = EventMask {
        connected: ConnectMode::None,
        get: RequestMode::Intercept,
        get_many: RequestMode::Intercept,
        push: RequestMode::Disabled,
        observe: ObserveMode::Intercept,
        throttle: ThrottleMode::None,
    };
    let (tx, mut rx) = EventSender::channel(64, mask);
    tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            let gate = Arc::clone(&gate);
            let live = Arc::clone(&live);
            match message {
                ProviderMessage::GetRequestReceived(msg) => {
                    let id = msg.inner.connection_id;
                    tokio::spawn(async move {
                        let verdict = request_verdict(&gate, &live, id, true).await;
                        msg.tx.send(verdict).await.ok();
                    });
                }
                ProviderMessage::GetManyRequestReceived(msg) => {
                    let id = msg.inner.connection_id;
                    tokio::spawn(async move {
                        let verdict = request_verdict(&gate, &live, id, true).await;
                        msg.tx.send(verdict).await.ok();
                    });
                }
                ProviderMessage::ObserveRequestReceived(msg) => {
                    let id = msg.inner.connection_id;
                    tokio::spawn(async move {
                        let verdict = request_verdict(&gate, &live, id, true).await;
                        msg.tx.send(verdict).await.ok();
                    });
                }
                ProviderMessage::PushRequestReceived(msg) => {
                    let id = msg.inner.connection_id;
                    tokio::spawn(async move {
                        let verdict = request_verdict(&gate, &live, id, false).await;
                        msg.tx.send(verdict).await.ok();
                    });
                }
                ProviderMessage::Throttle(msg) => {
                    msg.tx.send(Ok(())).await.ok();
                }
                // Notify-only variants carry no verdict; the mask above
                // never produces them.
                _ => {}
            }
        }
    });
    tx
}

/// `readable = false` (push) is refused without asking the gate. A request
/// on a connection the handler does not know (never admitted) is refused.
async fn request_verdict(
    gate: &PeerGate,
    live: &LiveConnections,
    connection_id: u64,
    readable: bool,
) -> EventResult {
    let entry = live
        .lock()
        .expect("blobs live connections lock")
        .get(&connection_id)
        .cloned();
    let allowed = match &entry {
        Some((peer, _)) if readable => gate(*peer).await,
        _ => false,
    };
    if allowed {
        return Ok(());
    }
    if let Some((_, connection)) = entry {
        connection.close(DENIED_CLOSE_CODE.into(), b"not authorized");
    }
    Err(AbortReason::Permission)
}

/// Blob store + optional serving router for one endpoint.
///
/// The store directory holds both complete blobs and partial downloads —
/// keeping it across restarts is what makes resume work.
pub struct Blobs {
    store: FsStore,
    transport: IrohTransport,
    /// Present while serving; dropped (with shutdown) in [`Self::close`].
    router: Option<Router>,
}

impl Blobs {
    /// Open (or create) the blob store at `store_dir` for this endpoint.
    pub async fn open(transport: &IrohTransport, store_dir: &Path) -> Result<Self> {
        let store = FsStore::load(store_dir)
            .await
            .map_err(|e| TransportError::Io(format!("blob store {store_dir:?}: {e}")))?;
        Ok(Self {
            store,
            transport: transport.clone(),
            router: None,
        })
    }

    /// Open a blob store with periodic iroh GC. `protected_hashes` is queried
    /// immediately before every collection run; only the hashes it returns
    /// are retained. A query error aborts that run rather than risking an
    /// active transfer's partial data.
    pub async fn open_with_periodic_gc<F>(
        transport: &IrohTransport,
        store_dir: &Path,
        interval: Duration,
        protected_hashes: F,
    ) -> Result<Self>
    where
        F: Fn() -> Pin<Box<dyn Future<Output = Result<HashSet<[u8; 32]>>> + Send>>
            + Send
            + Sync
            + 'static,
    {
        let protected_hashes = Arc::new(protected_hashes);
        let callback: ProtectCb = Arc::new(move |live| {
            let protected_hashes = Arc::clone(&protected_hashes);
            let query = tokio::spawn(async move { protected_hashes().await });
            Box::pin(async move {
                match query.await {
                    Ok(Ok(hashes)) => {
                        live.extend(hashes.into_iter().map(Hash::from_bytes));
                        ProtectOutcome::Continue
                    }
                    Ok(Err(error)) => {
                        tracing::warn!(
                            "BLOB-02: skipping flow-blobs GC because protected hash query failed: {error}"
                        );
                        ProtectOutcome::Abort
                    }
                    Err(error) => {
                        tracing::warn!(
                            "BLOB-02: skipping flow-blobs GC because protected hash task failed: {error}"
                        );
                        ProtectOutcome::Abort
                    }
                }
            })
        });
        let mut options = Options::new(store_dir);
        options.gc = Some(GcConfig {
            interval,
            add_protected: Some(callback),
        });
        let store = FsStore::load_with_opts(store_dir.join("blobs.db"), options)
            .await
            .map_err(|e| TransportError::Io(format!("blob store {store_dir:?}: {e}")))?;
        Ok(Self {
            store,
            transport: transport.clone(),
            router: None,
        })
    }

    /// Start answering fetch requests on [`crate::ALPN_BLOBS`], as the
    /// endpoint's ONLY accept consumer (pure provider — e.g. the phone
    /// side of a backup). A process that also runs [`Transport::listen`]
    /// must use [`Self::attach_to_listener`] instead: one endpoint has
    /// one accept queue.
    ///
    /// #546: this router is NOT gated — it answers anyone who knows a hash.
    /// No production process calls it (the phone serves through
    /// [`crate::AndroidBlobsProvider`], the daemon through
    /// [`Self::attach_to_listener`]); it stays as a test fixture for a
    /// stand-in provider.
    pub fn serve(&mut self) {
        if self.router.is_some() {
            return;
        }
        let proto = BlobsProtocol::new(&self.store, None);
        let router = Router::builder(self.transport.endpoint().clone())
            .accept(crate::ALPN_BLOBS.as_bytes(), proto)
            .spawn();
        self.router = Some(router);
    }

    /// Serve fetch requests through the transport's own `listen` loop —
    /// the daemon shape (ctrl + blobs on one endpoint, T-033). The
    /// transport dispatches `ALPN_BLOBS` connections to this store.
    ///
    /// #546: every inbound blobs connection AND every request on it passes
    /// `gate` first — the same whitelist the ctrl / upload / download planes
    /// enforce. There is deliberately no ungated variant: a daemon cannot
    /// attach its store to the network without saying who may read it.
    pub fn attach_to_listener(&self, gate: PeerGate) {
        self.transport
            .set_blobs_handler(GatedBlobs::new(&self.store, gate));
    }

    /// Import `path` into the store and return a ticket a peer can pull
    /// with. `hash` is the caller's BLAKE3 of the file (core-index already
    /// computed it) — a mismatch means the file changed underneath us and
    /// is an error, not a silent re-key.
    pub async fn push(&self, hash: [u8; 32], path: &Path) -> Result<String> {
        let tag = self
            .store
            .blobs()
            .add_path(path)
            .await
            .map_err(|e| TransportError::Io(format!("import {path:?}: {e}")))?;
        if tag.hash != Hash::from_bytes(hash) {
            return Err(TransportError::Io(format!(
                "content of {path:?} no longer matches its index hash (file changed?)"
            )));
        }
        let ticket = BlobTicket::new(self.transport.endpoint().addr(), tag.hash, BlobFormat::Raw);
        Ok(ticket.to_string())
    }

    /// Fetch the blob a ticket points at and export it to `dest`.
    /// Partial data already in the store is not re-downloaded (断点续传
    /// 透传 — iroh-blobs fetches only the missing ranges). Returns the
    /// verified BLAKE3 hash.
    pub async fn pull(&self, ticket: &str, dest: &Path) -> Result<[u8; 32]> {
        let ticket: BlobTicket = ticket
            .parse()
            .map_err(|e| TransportError::Io(format!("invalid blob ticket: {e}")))?;
        let (addr, hash, _format) = ticket.into_parts();

        let conn = self
            .transport
            .endpoint()
            .connect(addr, crate::ALPN_BLOBS.as_bytes())
            .await
            .map_err(|e| TransportError::Io(format!("connect for pull: {e}")))?;
        self.store
            .remote()
            .fetch(conn, hash)
            .await
            .map_err(|e| TransportError::Io(format!("fetch {hash}: {e}")))?;
        self.store
            .blobs()
            .export(hash, dest)
            .await
            .map_err(|e| TransportError::Io(format!("export to {dest:?}: {e}")))?;
        Ok(*hash.as_bytes())
    }

    /// Fetch one blob straight from a known peer (no ticket): the backup
    /// receive path (T-032) — the storage side pulls exactly the hashes
    /// it decided are missing, from the device that announced them.
    /// Inbound peers are dialable because the transport registers their
    /// observed addresses on accept.
    pub async fn fetch_from(&self, peer: crate::NodeId, hash: [u8; 32]) -> Result<()> {
        self.fetch_from_observing_path(peer, hash, |_| {}).await
    }

    /// Same data-plane operation, with one synchronous snapshot immediately
    /// after the cached blobs connection is ready and before a stream is
    /// opened. This reports iroh's selected path for *this exact ALPN*, not a
    /// ctrl-plane or remembered peer-level connection.
    pub async fn fetch_from_observing_path<F>(
        &self,
        peer: crate::NodeId,
        hash: [u8; 32],
        on_connected: F,
    ) -> Result<()>
    where
        F: FnOnce(crate::ConnectionStatus),
    {
        let conn = self
            .transport
            .connect_raw(peer, crate::ALPN_BLOBS)
            .await
            .map_err(|e| TransportError::Io(format!("connect for fetch: {e}")))?;
        on_connected(self.transport.path_status_of(peer, crate::ALPN_BLOBS));
        self.store
            .remote()
            .fetch(conn, Hash::from_bytes(hash))
            .await
            .map_err(|e| TransportError::Io(format!("fetch from {peer:?}: {e}")))?;
        Ok(())
    }

    /// NET-29 (#467): [`Self::fetch_from_observing_path`] with a byte-stall
    /// watchdog. The fetch fails once `byte_stall` passes without a single
    /// payload-byte progress event from iroh-blobs' own fetch stream — not a
    /// total-duration timeout, so a slow but moving relay transfer is never
    /// cut. On a stall the blobs connection is closed, so the next attempt
    /// redials instead of reusing a connection whose request went unanswered
    /// (#467 capture 1: request sent, then nothing, forever).
    pub async fn fetch_from_observing_path_with_stall<F>(
        &self,
        peer: crate::NodeId,
        hash: [u8; 32],
        byte_stall: Duration,
        on_connected: F,
    ) -> Result<()>
    where
        F: FnOnce(crate::ConnectionStatus),
    {
        use futures_core::Stream;
        use iroh_blobs::api::remote::GetProgressItem;

        let conn = self
            .transport
            .connect_raw(peer, crate::ALPN_BLOBS)
            .await
            .map_err(|e| TransportError::Io(format!("connect for fetch: {e}")))?;
        on_connected(self.transport.path_status_of(peer, crate::ALPN_BLOBS));
        let progress = self
            .store
            .remote()
            .fetch(conn.clone(), Hash::from_bytes(hash));
        let mut items = std::pin::pin!(progress.stream());
        loop {
            let next = tokio::time::timeout(
                byte_stall,
                std::future::poll_fn(|cx| items.as_mut().poll_next(cx)),
            )
            .await;
            match next {
                Ok(Some(GetProgressItem::Progress(_))) => continue,
                Ok(Some(GetProgressItem::Done(_))) => return Ok(()),
                Ok(Some(GetProgressItem::Error(e))) => {
                    return Err(TransportError::Io(format!("fetch from {peer:?}: {e}")))
                }
                Ok(None) => {
                    return Err(TransportError::Io(format!(
                        "fetch from {peer:?}: progress stream closed without a result"
                    )))
                }
                Err(_) => {
                    conn.close(0u32.into(), b"fetch stalled");
                    return Err(TransportError::Io(format!(
                        "fetch from {peer:?}: stalled, no payload bytes for {byte_stall:?}"
                    )));
                }
            }
        }
    }

    /// Export a (complete) blob from the store to a file.
    pub async fn export_to(&self, hash: [u8; 32], dest: &Path) -> Result<()> {
        self.store
            .blobs()
            .export(Hash::from_bytes(hash), dest)
            .await
            .map_err(|e| TransportError::Io(format!("export to {dest:?}: {e}")))?;
        Ok(())
    }

    /// Import a file into the store so peers can fetch it (backup client
    /// side). Returns an error if the content hash does not match.
    pub async fn import(&self, hash: [u8; 32], path: &Path) -> Result<()> {
        let tag = self
            .store
            .blobs()
            .add_path(path)
            .await
            .map_err(|e| TransportError::Io(format!("import {path:?}: {e}")))?;
        if tag.hash != Hash::from_bytes(hash) {
            return Err(TransportError::Io(format!(
                "content of {path:?} does not match its declared hash"
            )));
        }
        Ok(())
    }

    /// Admit a native iroh-blobs ticket and return its provider identity and
    /// hash. The caller must compare both values to its durable Flow grant.
    pub fn register_blob_ticket(&self, ticket: &str) -> Result<(NodeId, [u8; 32])> {
        let ticket = ticket
            .parse::<BlobTicket>()
            .map_err(|e| TransportError::Io(format!("invalid blob ticket: {e}")))?;
        let hash = *ticket.hash().as_bytes();
        let peer = self
            .transport
            .add_peer(PeerAddr::from_endpoint_addr(ticket.addr().clone()));
        Ok((peer, hash))
    }

    /// Register a peer's self-declared address token (see
    /// [`crate::PeerAddr`]'s Display) so later fetches dial it directly.
    pub fn register_peer(&self, addr_token: &str) -> Result<crate::NodeId> {
        let addr: crate::PeerAddr = addr_token.parse()?;
        Ok(self.transport.add_peer(addr))
    }

    /// Bytes of this blob already present locally (0 = nothing yet).
    /// Diagnostics + the resume test's evidence that a restart kept data.
    pub async fn local_bytes(&self, hash: [u8; 32]) -> Result<u64> {
        let info = self
            .store
            .remote()
            .local(Hash::from_bytes(hash))
            .await
            .map_err(|e| TransportError::Io(format!("local info: {e}")))?;
        Ok(info.local_bytes())
    }

    /// Where a store for `data_dir` lives (one fixed layout, so restarts
    /// find the same partial data).
    pub fn store_dir(data_dir: &Path) -> PathBuf {
        data_dir.join("blobs")
    }

    /// Shut down serving (if any) and flush the store.
    pub async fn close(mut self) {
        if let Some(router) = self.router.take() {
            let _ = router.shutdown().await;
        }
        let _ = self.store.shutdown().await;
    }
}
