//! REBUILD-02 single-item native iroh-blobs delivery.
//!
//! This module is intentionally independent from `backup.rs`: the frozen
//! manifest/push/commit batch pipeline never participates. A phone first
//! offers one exact tuple, then asks the Desktop to fetch that same tuple. The
//! Desktop checks the persisted current pairing epoch and the persisted grant
//! both before native fetch and before it writes a receipt.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use core_index::{IncomingFile, Ingestor};
use proto::{FlowCompletionReceipt, FlowFetchRequest};
use storage::{Db, FlowGrant, FlowGrantState};
use transport::{Blobs, ConnectionStatus, NodeId};

use crate::events::{EventBus, Throttle, DEFAULT_THROTTLE_WINDOW};
use crate::telemetry::{Event as TelemetryEvent, Telemetry};

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
    #[error("create flow staging directory: {0}")]
    MaterializeStaging(String),
    #[error("export fetched item from blob store: {0}")]
    MaterializeExport(String),
    #[error("ingest materialized item into the index: {0}")]
    MaterializeIngest(String),
    #[error("durable delivery state: {0}")]
    Storage(String),
}

impl DeliveryError {
    /// TEL-03: fixed, anonymized telemetry code — one per distinct failure
    /// class. Never the wrapped `String` (that text comes from
    /// `e.to_string()` on third-party errors and may carry a path or other
    /// unknown content); only this fixed vocabulary crosses into
    /// telemetry. Materialize is split into staging/export/ingest instead
    /// of one generic code because those are three different subsystems
    /// (filesystem, blob store, index) with different fix-it implications.
    fn telemetry_code(&self) -> &'static str {
        match self {
            DeliveryError::GuardMismatch => "guard_mismatch",
            DeliveryError::Cancelled => "cancelled",
            DeliveryError::InvalidRequest(_) => "invalid_request",
            DeliveryError::Fetch(_) => "fetch_failed",
            DeliveryError::MaterializeStaging(_) => "materialize_staging_failed",
            DeliveryError::MaterializeExport(_) => "materialize_export_failed",
            DeliveryError::MaterializeIngest(_) => "materialize_ingest_failed",
            DeliveryError::Storage(_) => "storage_failed",
        }
    }
}

/// NET-05: process-local route fact for an active Flow data fetch. The map is
/// keyed by the paired control peer because desktop device rows are keyed that
/// way; the stored status itself is read from the possibly-distinct blobs
/// provider. It is neither history nor a billing source.
#[derive(Clone, Default)]
pub struct FlowPathRegistry {
    entries: Arc<Mutex<HashMap<[u8; 32], ActiveFlowPath>>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ActiveFlowPath {
    queue_sequence: i64,
    lease_token: String,
    status: ConnectionStatus,
}

impl FlowPathRegistry {
    /// A request has been admitted but its data-plane connection is not ready.
    /// `Unknown` means exactly that; it never guesses a route.
    pub fn begin(&self, peer: NodeId, queue_sequence: i64, lease_token: &str) -> bool {
        self.replace_if_changed(
            peer,
            ActiveFlowPath {
                queue_sequence,
                lease_token: lease_token.to_owned(),
                status: ConnectionStatus::Unknown,
            },
        )
    }

    /// Update only the exact strict item that is still active for this peer.
    pub fn set_if_current(
        &self,
        peer: NodeId,
        queue_sequence: i64,
        lease_token: &str,
        status: ConnectionStatus,
    ) -> bool {
        let mut entries = self.entries.lock().expect("flow path registry lock");
        let Some(current) = entries.get_mut(&peer.0) else {
            return false;
        };
        if current.queue_sequence != queue_sequence || current.lease_token != lease_token {
            return false;
        }
        if current.status == status {
            return false;
        }
        current.status = status;
        true
    }

    /// A late old request cannot remove a newer item's route: both lease and
    /// sequence must match. The boolean tells the caller whether to refresh UI.
    pub fn clear_if_current(&self, peer: NodeId, queue_sequence: i64, lease_token: &str) -> bool {
        let mut entries = self.entries.lock().expect("flow path registry lock");
        let Some(current) = entries.get(&peer.0) else {
            return false;
        };
        if current.queue_sequence != queue_sequence || current.lease_token != lease_token {
            return false;
        }
        entries.remove(&peer.0);
        true
    }

    /// `None` means no active Flow fetch, not that the device is offline.
    pub fn get(&self, peer: NodeId) -> Option<ConnectionStatus> {
        self.entries
            .lock()
            .expect("flow path registry lock")
            .get(&peer.0)
            .map(|entry| entry.status)
    }

    fn replace_if_changed(&self, peer: NodeId, next: ActiveFlowPath) -> bool {
        let mut entries = self.entries.lock().expect("flow path registry lock");
        if entries.get(&peer.0) == Some(&next) {
            return false;
        }
        entries.insert(peer.0, next);
        true
    }
}

/// Clears a transient route on every terminal branch, including `?` returns.
struct FlowPathGuard {
    paths: FlowPathRegistry,
    events: Option<EventBus>,
    peer: NodeId,
    queue_sequence: i64,
    lease_token: String,
}

impl FlowPathGuard {
    fn start(
        paths: FlowPathRegistry,
        events: Option<EventBus>,
        peer: NodeId,
        grant: &FlowGrant,
    ) -> Self {
        if paths.begin(peer, grant.queue_sequence, &grant.lease_token) {
            emit_device_changed(events.as_ref());
        }
        Self {
            paths,
            events,
            peer,
            queue_sequence: grant.queue_sequence,
            lease_token: grant.lease_token.clone(),
        }
    }

    fn set_path(&self, status: ConnectionStatus) {
        if self
            .paths
            .set_if_current(self.peer, self.queue_sequence, &self.lease_token, status)
        {
            emit_device_changed(self.events.as_ref());
        }
    }
}

impl Drop for FlowPathGuard {
    fn drop(&mut self) {
        if self
            .paths
            .clear_if_current(self.peer, self.queue_sequence, &self.lease_token)
        {
            emit_device_changed(self.events.as_ref());
        }
    }
}

fn emit_device_changed(events: Option<&EventBus>) {
    if let Some(events) = events {
        crate::events::emit(events, crate::events::DEVICE_CHANGED, serde_json::json!({}));
    }
}

/// Adapter from a current flow item to the native iroh-blobs receiver.
#[derive(Clone)]
pub struct FlowDelivery {
    db: Db,
    blobs: Arc<Blobs>,
    ingestor: Ingestor,
    staging: PathBuf,
    /// DESK-11: mirrors `BackupEngine`'s throttle — a completed fetch signals
    /// the desktop timeline the same way a legacy batch ingest does. `None`
    /// (the pre-fix default) means "no one is listening", matching how
    /// `main.rs` constructs this port today.
    throttle: Option<Throttle>,
    /// NET-05: process-local path state for currently-active Flow data streams.
    paths: FlowPathRegistry,
    /// Path mutations notify the desktop device rows independently of the
    /// ingestion throttle above.
    events: Option<EventBus>,
    /// TEL-02: optional anonymized telemetry sink for `conn`/`flow_item`.
    /// `None` (main.rs default before wiring) means no telemetry client
    /// is attached; `Telemetry::record` itself is also a no-op when
    /// disabled, so this is a second independent off switch, not a
    /// replacement for it.
    telemetry: Option<Telemetry>,
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
            throttle: None,
            paths: FlowPathRegistry::default(),
            events: None,
            telemetry: None,
        }
    }

    /// DESK-11: wire the desktop timeline event bus, same contract as
    /// `BackupEngine::with_events` — a completed fetch's ingest schedules a
    /// throttled `timeline.invalidated` instead of leaving the desktop to
    /// wait for the next batch/hourly reconcile.
    pub fn with_events(self, events: EventBus) -> Self {
        self.with_events_and_window(events, DEFAULT_THROTTLE_WINDOW)
    }

    /// Variant with an injectable throttle window — same rationale as
    /// `BackupEngine::with_events_and_window` (tests need a deterministic,
    /// short window rather than relying on wall-clock timing).
    pub fn with_events_and_window(mut self, events: EventBus, window: std::time::Duration) -> Self {
        self.throttle = Some(Throttle::new(events.clone(), window));
        self.events = Some(events);
        self
    }

    /// Main injects the same registry into IPC, so `devices.list` can expose
    /// only an active Flow's real data-plane path without persisting it.
    pub fn with_path_registry(mut self, paths: FlowPathRegistry) -> Self {
        self.paths = paths;
        self
    }

    pub fn path_registry(&self) -> FlowPathRegistry {
        self.paths.clone()
    }

    /// TEL-02: wire an anonymized telemetry sink so `fetch()` records one
    /// `conn` (path/latency/failure stage) and, on success, one `flow_item`
    /// (bytes/duration/resumed) per request. `Telemetry::record` is already
    /// a no-op when the client itself is disabled — this builder only
    /// controls whether `FlowDelivery` has a sink to call at all.
    pub fn with_telemetry(mut self, telemetry: Telemetry) -> Self {
        self.telemetry = Some(telemetry);
        self
    }

    /// Persist the current exact grant. This method transfers no bytes.
    pub async fn offer(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<(), DeliveryError> {
        let result = self.offer_inner(peer, request).await;
        if let Err(error) = &result {
            self.record_error("offer", error);
        }
        result
    }

    async fn offer_inner(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<(), DeliveryError> {
        let grant = self.checked_request(peer, request).await?;
        self.provider_for(&grant)?;
        if self
            .db
            .rebind_completed_flow_grant(&grant)
            .await
            .map_err(storage_error)?
        {
            return Ok(());
        }
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
        let result = self.fetch_inner(peer, request).await;
        if let Err(error) = &result {
            self.record_error("fetch", error);
        }
        result
    }

    async fn fetch_inner(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<FlowCompletionReceipt, DeliveryError> {
        let item_started = std::time::Instant::now();
        let grant = self.checked_request(peer, request).await?;
        let stored = self.matching_grant(&grant).await?;
        if stored.state == FlowGrantState::Completed {
            return self.persisted_receipt(&grant).await;
        }
        if stored.state != FlowGrantState::Active {
            return Err(DeliveryError::Cancelled);
        }

        // The visible path is scoped to this exact strict item and cleared by
        // its guard on every terminal branch. Start as unknown before opening
        // data-plane bytes; never infer direct/relay from the ctrl connection.
        let path_guard =
            FlowPathGuard::start(self.paths.clone(), self.events.clone(), peer, &grant);

        // The only data transport in this flow: native iroh-blobs fetch. Its
        // content-addressed fetch verifies the requested BLAKE3 hash and
        // resumes from the dedicated retained store on retry/restart.
        let hash = array32(&grant.content_hash).expect("validated by checked_request");
        let provider = self.provider_for(&grant)?;
        let fetch_started = std::time::Instant::now();
        let mut conn_path: &'static str = "unknown";
        let fetch_result = self
            .blobs
            .fetch_from_observing_path(provider, hash, |status| {
                conn_path = status.as_str();
                path_guard.set_path(status);
            })
            .await;
        let fetch_ms = fetch_started.elapsed().as_millis() as u64;
        if let Err(e) = fetch_result {
            self.record_conn(conn_path, fetch_ms, Some("fetch"));
            return Err(DeliveryError::Fetch(e.to_string()));
        }
        self.record_conn(conn_path, fetch_ms, None);

        // A concurrent cancel/superseding offer may have landed while the
        // fetch was in flight. Do not materialize or finalize old work.
        self.require_active(&grant).await?;
        std::fs::create_dir_all(&self.staging)
            .map_err(|e| DeliveryError::MaterializeStaging(format!("create staging: {e}")))?;
        let staged = self.staged_path(&grant);
        let _ = std::fs::remove_file(&staged);
        self.blobs
            .export_to(hash, &staged)
            .await
            .map_err(|e| DeliveryError::MaterializeExport(e.to_string()))?;
        self.require_active(&grant).await?;
        let item_bytes = std::fs::metadata(&staged).map(|m| m.len()).unwrap_or(0);

        match self
            .ingestor
            .ingest(&IncomingFile {
                src_path: staged.clone(),
                file_name: grant.file_name.clone(),
                media_type: grant.media_type.clone(),
                src_device: grant.node_id.clone(),
                // DESK-12: the phone's own capture-time fact travels on the
                // wire in this same request — reading it here (not from the
                // durable `grant`) avoids a schema migration for a value
                // that is only ever needed once, at this ingest call.
                capture_at_ms_hint: Some(request.capture_at_ms),
            })
            .await
        {
            Ok(_) => {
                // Duplicate leaves the staging export in place; it is not a
                // durable source and must not survive as a false partial.
                let _ = std::fs::remove_file(&staged);
                // DESK-11: signal the desktop timeline the same way a legacy
                // batch ingest does — without this, a materialized Flow item
                // is invisible until the next batch/hourly reconcile.
                if let Some(throttle) = &self.throttle {
                    throttle.signal();
                }
            }
            Err(e) => return Err(DeliveryError::MaterializeIngest(e.to_string())),
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
        // TEL-02: `resumed` has no cheap signal yet from this call path —
        // iroh-blobs resume detection would need a store-level query this
        // card does not add. Hardcoded false per the card's explicit
        // allowance; a real resume-detection signal is separate follow-up
        // work, not silently invented here.
        self.record_flow_item(item_bytes, item_started.elapsed().as_secs(), false);
        Ok(receipt_from(&grant, receipt_id))
    }

    /// Cancel only the exact active tuple. This has no success receipt path.
    pub async fn cancel(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<(), DeliveryError> {
        let result = self.cancel_inner(peer, request).await;
        if let Err(error) = &result {
            self.record_error("cancel", error);
        }
        result
    }

    async fn cancel_inner(
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
            if self
                .paths
                .clear_if_current(peer, grant.queue_sequence, &grant.lease_token)
            {
                emit_device_changed(self.events.as_ref());
            }
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
            .flow_grant(&grant.node_id, &grant.pairing_epoch, grant.queue_sequence)
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
            .flow_receipt(&grant.node_id, &grant.pairing_epoch, grant.queue_sequence)
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

    /// TEL-02: `conn` — one per `fetch()` attempt, terminal state only
    /// (success or the `fetch` failure stage). `path` is never a raw error
    /// string, only `ConnectionStatus::as_str()`'s fixed vocabulary.
    fn record_conn(&self, path: &'static str, ms: u64, fail_stage: Option<&'static str>) {
        if let Some(telemetry) = &self.telemetry {
            telemetry.record(TelemetryEvent::Conn {
                path,
                ms,
                fail_stage,
            });
        }
    }

    /// TEL-02: `flow_item` — one per successful `fetch()`, after the
    /// receipt is durable. Never called on a failed or cancelled request.
    fn record_flow_item(&self, bytes: u64, dur_s: u64, resumed: bool) {
        if let Some(telemetry) = &self.telemetry {
            telemetry.record(TelemetryEvent::FlowItem {
                bytes,
                dur_s,
                resumed,
            });
        }
    }

    /// TEL-03: `error` — one per terminal failure returned to the caller,
    /// tagged with which public method produced it (`offer`/`fetch`/
    /// `cancel`) plus the fine-grained failure class from
    /// `DeliveryError::telemetry_code`. `GuardMismatch`/`Cancelled` are
    /// deliberately excluded: they are routine control-flow outcomes (a
    /// stale retry after a superseding offer, an intentional user cancel),
    /// not diagnosable problems — recording them as "errors" would dilute
    /// the signal this event exists to carry, even with dedup capping
    /// their volume. `Telemetry::record` itself deduplicates repeats of
    /// the same `(code, stage)` within one flush window, so a persistent
    /// real failure (e.g. an unreachable peer) reports once instead of
    /// flooding the batch.
    fn record_error(&self, stage: &'static str, error: &DeliveryError) {
        if matches!(
            error,
            DeliveryError::GuardMismatch | DeliveryError::Cancelled
        ) {
            return;
        }
        if let Some(telemetry) = &self.telemetry {
            telemetry.record(TelemetryEvent::Error {
                code: error.telemetry_code(),
                stage,
            });
        }
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
