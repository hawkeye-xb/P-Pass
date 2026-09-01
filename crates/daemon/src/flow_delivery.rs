//! REBUILD-02 single-item native iroh-blobs delivery.
//!
//! This module is intentionally independent from `backup.rs`: the frozen
//! manifest/push/commit batch pipeline never participates. A phone first
//! offers one exact tuple, then asks the Desktop to fetch that same tuple. The
//! Desktop checks the persisted current pairing epoch and the persisted grant
//! both before native fetch and before it writes a receipt.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use core_index::{IncomingFile, Ingestor};
use proto::{FlowCompletionReceipt, FlowFetchRequest};
use storage::{Db, FlowGrant, FlowGrantState};
use transport::{Blobs, NodeId};

#[derive(Debug, thiserror::Error)]
pub enum DeliveryError {
    #[error("request does not match the current pairing epoch, lease, and hash")]
    GuardMismatch,
    #[error("delivery was cancelled before completion")]
    Cancelled,
    #[error("invalid flow delivery request: {0}")]
    InvalidRequest(String),
    #[error("native iroh-blobs fetch: {0}")]
    Fetch(String),
    #[error("materialize fetched item: {0}")]
    Materialize(String),
    #[error("durable delivery state: {0}")]
    Storage(String),
}

/// Adapter from a current flow item to the native iroh-blobs receiver.
#[derive(Clone)]
pub struct FlowDelivery {
    db: Db,
    blobs: Arc<Blobs>,
    ingestor: Ingestor,
    staging: PathBuf,
}

impl FlowDelivery {
    /// `library_root` is the daemon data directory. The dedicated flow blob
    /// store is deliberately not the legacy `.ppf/blobs` inbox: that legacy
    /// store is cleared on daemon startup, while this store retains native
    /// partials across restart for iroh-blobs resume.
    pub fn new(db: Db, blobs: Arc<Blobs>, library_root: impl AsRef<Path>) -> Self {
        let root = library_root.as_ref().to_path_buf();
        Self {
            ingestor: Ingestor::new(db.clone(), &root),
            db,
            blobs,
            staging: root.join(".ppf/flow-staging"),
        }
    }

    /// Persist the current exact grant. This method transfers no bytes.
    pub async fn offer(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<(), DeliveryError> {
        let grant = self.checked_request(peer, request).await?;
        self.provider_for(&grant)?;
        self.db
            .upsert_flow_grant(&grant)
            .await
            .map_err(storage_error)?;
        // A completed receipt is immutable. Verify the upsert really made
        // this tuple current rather than silently acknowledging a different
        // completed item at the same queue sequence.
        let _ = self.matching_grant(&grant).await?;
        Ok(())
    }

    /// Fetch via `iroh-blobs`, materialize into the index, then atomically
    /// persist and return a receipt. A failed or cancelled request returns no
    /// receipt; a retry of an already completed exact tuple returns its stored
    /// receipt without another fetch.
    pub async fn fetch(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<FlowCompletionReceipt, DeliveryError> {
        let grant = self.checked_request(peer, request).await?;
        let stored = self.matching_grant(&grant).await?;
        if stored.state == FlowGrantState::Completed {
            return self.persisted_receipt(&grant).await;
        }
        if stored.state != FlowGrantState::Active {
            return Err(DeliveryError::Cancelled);
        }

        // The only data transport in this flow: native iroh-blobs fetch. Its
        // content-addressed fetch verifies the requested BLAKE3 hash and
        // resumes from the dedicated retained store on retry/restart.
        let hash = array32(&grant.content_hash).expect("validated by checked_request");
        let provider = self.provider_for(&grant)?;
        self.blobs
            .fetch_from(provider, hash)
            .await
            .map_err(|e| DeliveryError::Fetch(e.to_string()))?;

        // A concurrent cancel/superseding offer may have landed while the
        // fetch was in flight. Do not materialize or finalize old work.
        self.require_active(&grant).await?;
        std::fs::create_dir_all(&self.staging)
            .map_err(|e| DeliveryError::Materialize(format!("create staging: {e}")))?;
        let staged = self.staged_path(&grant);
        let _ = std::fs::remove_file(&staged);
        self.blobs
            .export_to(hash, &staged)
            .await
            .map_err(|e| DeliveryError::Materialize(e.to_string()))?;
        self.require_active(&grant).await?;

        match self
            .ingestor
            .ingest(&IncomingFile {
                src_path: staged.clone(),
                file_name: grant.file_name.clone(),
                media_type: grant.media_type.clone(),
                src_device: grant.node_id.clone(),
            })
            .await
        {
            Ok(_) => {
                // Duplicate leaves the staging export in place; it is not a
                // durable source and must not survive as a false partial.
                let _ = std::fs::remove_file(&staged);
            }
            Err(e) => return Err(DeliveryError::Materialize(e.to_string())),
        }

        // This update is the receipt adapter's irreversible boundary. It
        // repeats all tuple guards inside SQL and writes receipt_id before
        // this method returns it to the phone.
        let receipt_id = receipt_id()?;
        if !self
            .db
            .complete_flow_grant(&grant, &receipt_id)
            .await
            .map_err(storage_error)?
        {
            return Err(DeliveryError::Cancelled);
        }
        Ok(receipt_from(&grant, receipt_id))
    }

    /// Cancel only the exact active tuple. This has no success receipt path.
    pub async fn cancel(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<(), DeliveryError> {
        let grant = self.checked_request(peer, request).await?;
        if self
            .db
            .cancel_flow_grant(&grant)
            .await
            .map_err(storage_error)?
        {
            Ok(())
        } else {
            Err(DeliveryError::GuardMismatch)
        }
    }

    async fn checked_request(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<FlowGrant, DeliveryError> {
        if request.queue_sequence > i64::MAX as u64
            || request.pairing_epoch.is_empty()
            || request.lease_token.is_empty()
            || request.file_name.is_empty()
            || request.media_type.is_empty()
            || request.provider.is_empty()
        {
            return Err(DeliveryError::InvalidRequest(
                "missing required item field".into(),
            ));
        }
        let hash = parse_hash(&request.content_hash).ok_or_else(|| {
            DeliveryError::InvalidRequest("content_hash must be 64 hex characters".into())
        })?;
        let epoch = self
            .db
            .pairing_epoch(&peer.0)
            .await
            .map_err(storage_error)?;
        if epoch.as_deref() != Some(request.pairing_epoch.as_str()) {
            return Err(DeliveryError::GuardMismatch);
        }
        Ok(FlowGrant {
            node_id: peer.0.to_vec(),
            queue_sequence: request.queue_sequence as i64,
            pairing_epoch: request.pairing_epoch.clone(),
            lease_token: request.lease_token.clone(),
            content_hash: hash.to_vec(),
            file_name: request.file_name.clone(),
            media_type: request.media_type.clone(),
            provider: request.provider.clone(),
            state: FlowGrantState::Active,
            receipt_id: None,
        })
    }

    async fn matching_grant(&self, grant: &FlowGrant) -> Result<FlowGrant, DeliveryError> {
        let Some(stored) = self
            .db
            .flow_grant(&grant.node_id, grant.queue_sequence)
            .await
            .map_err(storage_error)?
        else {
            return Err(DeliveryError::GuardMismatch);
        };
        if stored.pairing_epoch != grant.pairing_epoch
            || stored.lease_token != grant.lease_token
            || stored.content_hash != grant.content_hash
            || stored.provider != grant.provider
        {
            return Err(DeliveryError::GuardMismatch);
        }
        Ok(stored)
    }

    /// The authenticated control peer owns the Flow grant, while Android's
    /// native iroh-blobs provider owns its own endpoint and ticket. The ticket
    /// is immutable inside the grant and its hash is rechecked before every
    /// fetch, so accepting a distinct provider does not weaken the tuple gate.
    fn provider_for(&self, grant: &FlowGrant) -> Result<NodeId, DeliveryError> {
        let (provider, ticket_hash) = match self.blobs.register_blob_ticket(&grant.provider) {
            Ok((provider, ticket_hash)) => (provider, Some(ticket_hash)),
            // Keep the existing Desktop-only fixture/address form valid while
            // Android's provider supplies the stronger self-contained ticket.
            Err(_) => (
                self.blobs
                    .register_peer(&grant.provider)
                    .map_err(|e| DeliveryError::InvalidRequest(format!("provider: {e}")))?,
                None,
            ),
        };
        if ticket_hash.is_some_and(|hash| hash.as_slice() != grant.content_hash.as_slice()) {
            return Err(DeliveryError::GuardMismatch);
        }
        Ok(provider)
    }

    async fn require_active(&self, grant: &FlowGrant) -> Result<(), DeliveryError> {
        match self.matching_grant(grant).await?.state {
            FlowGrantState::Active => Ok(()),
            FlowGrantState::Cancelled => Err(DeliveryError::Cancelled),
            FlowGrantState::Completed => Err(DeliveryError::GuardMismatch),
        }
    }

    async fn persisted_receipt(
        &self,
        grant: &FlowGrant,
    ) -> Result<FlowCompletionReceipt, DeliveryError> {
        let Some(receipt) = self
            .db
            .flow_receipt(&grant.node_id, grant.queue_sequence)
            .await
            .map_err(storage_error)?
        else {
            return Err(DeliveryError::GuardMismatch);
        };
        if receipt.pairing_epoch != grant.pairing_epoch
            || receipt.lease_token != grant.lease_token
            || receipt.content_hash != grant.content_hash
        {
            return Err(DeliveryError::GuardMismatch);
        }
        Ok(receipt_from(grant, receipt.receipt_id))
    }

    fn staged_path(&self, grant: &FlowGrant) -> PathBuf {
        self.staging.join(format!(
            "{}-{}-{}",
            hex::encode(&grant.node_id),
            grant.queue_sequence,
            hex::encode(&grant.content_hash)
        ))
    }
}

fn receipt_from(grant: &FlowGrant, receipt_id: String) -> FlowCompletionReceipt {
    FlowCompletionReceipt {
        queue_sequence: grant.queue_sequence as u64,
        receipt_id,
        pairing_epoch: grant.pairing_epoch.clone(),
        lease_token: grant.lease_token.clone(),
        content_hash: hex::encode(&grant.content_hash),
    }
}

fn parse_hash(value: &str) -> Option<[u8; 32]> {
    if value.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (index, chunk) in value.as_bytes().as_chunks::<2>().0.iter().enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[index] = ((hi << 4) | lo) as u8;
    }
    Some(out)
}

fn array32(value: &[u8]) -> Option<[u8; 32]> {
    value.try_into().ok()
}

fn receipt_id() -> Result<String, DeliveryError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|e| DeliveryError::Storage(format!("receipt randomness: {e}")))?;
    Ok(hex::encode(bytes))
}

fn storage_error(error: storage::StorageError) -> DeliveryError {
    DeliveryError::Storage(error.to_string())
}
