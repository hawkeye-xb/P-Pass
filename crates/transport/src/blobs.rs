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

    /// Start answering fetch requests on [`crate::ALPN_BLOBS`].
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
