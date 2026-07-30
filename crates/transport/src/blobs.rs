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

use std::path::{Path, PathBuf};

use iroh::protocol::Router;
use iroh_blobs::store::fs::FsStore;
use iroh_blobs::ticket::BlobTicket;
use iroh_blobs::{BlobFormat, BlobsProtocol, Hash};

use crate::iroh_impl::IrohTransport;
use crate::{Result, TransportError};

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

    /// Start answering fetch requests on [`crate::ALPN_BLOBS`], as the
    /// endpoint's ONLY accept consumer (pure provider — e.g. the phone
    /// side of a backup). A process that also runs [`Transport::listen`]
    /// must use [`Self::attach_to_listener`] instead: one endpoint has
    /// one accept queue.
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
    pub fn attach_to_listener(&self) {
        self.transport
            .set_blobs_handler(BlobsProtocol::new(&self.store, None));
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
        let conn = self
            .transport
            .connect_raw(peer, crate::ALPN_BLOBS)
            .await
            .map_err(|e| TransportError::Io(format!("connect for fetch: {e}")))?;
        self.store
            .remote()
            .fetch(conn, Hash::from_bytes(hash))
            .await
            .map_err(|e| TransportError::Io(format!("fetch from {peer:?}: {e}")))?;
        Ok(())
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
