//! REBUILD-02 single-item native iroh-blobs delivery.
//!
//! This module is intentionally independent from `backup.rs`: the frozen
//! manifest/push/commit batch pipeline never participates. A phone first
//! offers one exact tuple; the Desktop fetches it in the background. The
//! Desktop checks the persisted current pairing epoch and the persisted grant
//! both before native fetch and before it writes a receipt.
//!
//! NET-06: `offer` used to only persist the grant — the phone then had to
//! call a long-blocking `flow.fetch` RPC itself, which welded "submit the
//! job" and "wait for the result" into one round trip (NET-01's root cause).
//! Now `offer` durably persists the grant AND immediately spawns the native
//! fetch in the background (`spawn_fetch_task`); the phone polls `status` (a
//! short, control-plane-only RPC) and pulls the receipt once it reports
//! `completed`. #1050: the `flow.fetch` / `flow.cancel` RPCs themselves are
//! gone (only phones older than Android v0.9.0 ever sent them).

use std::collections::HashMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::Mutex as AsyncMutex;
use tokio_util::sync::CancellationToken;

use core_index::{
    device_dir, IncomingFile, IndexError, IngestOutcome, Ingestor, SupersedeApplied, SupersedeCheck,
};
use platform::PlatformAdapter as _;
use proto::{
    DesktopHealth, FlowCompletionReceipt, FlowFetchRequest, FlowStatusReply, FlowSupersedeReply,
    FlowSupersedeRequest, FlowTupleRef, Reason, SupersedeRefusal,
};
use storage::{Db, FlowGrant, FlowGrantState};
use transport::{Blobs, ConnectionStatus, NodeId};

use crate::awake::AwakeHold;
use crate::events::{EventBus, Throttle, DEFAULT_THROTTLE_WINDOW};
use crate::stats;
use crate::subscriptions::SubscriptionRegistry;
use crate::thumb_pregen::ThumbPregen;

type PeerFetchLock = Arc<AsyncMutex<()>>;
type FetchLocks = Arc<Mutex<HashMap<[u8; 32], PeerFetchLock>>>;
type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;
type FreeSpaceProbe = Arc<dyn Fn(&Path) -> Option<u64> + Send + Sync>;
type StageHook = Arc<
    dyn Fn(FetchStage) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>
        + Send
        + Sync,
>;

/// #1076: the points a background fetch passes between its tuple checks.
/// Only [`FlowDelivery::with_fetch_stage_hook`] observes them (tests pause a
/// fetch there to land a re-offer inside the window).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FetchStage {
    /// Bytes fetched and `require_active` passed; nothing materialized yet.
    Verified,
    /// The photo is in the library; the receipt is not written yet.
    Ingested,
}

/// #413 §6: an active grant nobody resumed (offer / status respawn) for this
/// long is cancelled, so its partial leaves the GC protection set. Covers a
/// phone that will never come back for the item (App uninstalled, item
/// dropped while the Desktop was unreachable).
pub const GRANT_RESUME_TTL_MS: i64 = 3 * 24 * 60 * 60 * 1000;

/// Headroom kept free on top of what one item needs at offer time, and the
/// line below which an unexplained write failure is read as "disk full".
/// Covers the index WAL, thumbnails and other writers sharing the volume.
pub const SPACE_RESERVE_BYTES: u64 = 256 * 1024 * 1024;

/// #413 contract §5: the public reason a Desktop could not store an item,
/// carried as `flow.failed.reason` and as an offer rejection's `reason`. The
/// phone maps each one to `PeerFailure(PeerFailureKind)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerFailure {
    /// ENOSPC / quota: the library volume has no room.
    StorageFull,
    /// The photo library folder is missing or not writable.
    LibraryUnavailable,
    /// Any other write failure (index database, blob store, ...).
    StorageFailed,
}

impl PeerFailure {
    pub fn reason(self) -> Reason {
        match self {
            Self::StorageFull => Reason::StorageFull,
            Self::LibraryUnavailable => Reason::LibraryUnavailable,
            Self::StorageFailed => Reason::StorageFailed,
        }
    }
}

/// Pure classification of a Desktop-side write failure. The io error, when
/// there is one, is trusted first; a failure that carries no usable kind
/// (blob-store errors arrive as text) is explained by the environment
/// observed right after it: a library that is gone, then a volume that is
/// out of space. Unknown free space is never guessed as full.
pub fn classify_peer_failure(
    io_kind: Option<ErrorKind>,
    library_writable: bool,
    free_bytes: Option<u64>,
) -> PeerFailure {
    match io_kind {
        Some(ErrorKind::StorageFull | ErrorKind::QuotaExceeded) => return PeerFailure::StorageFull,
        Some(ErrorKind::ReadOnlyFilesystem | ErrorKind::PermissionDenied | ErrorKind::NotFound) => {
            return PeerFailure::LibraryUnavailable
        }
        _ => {}
    }
    if !library_writable {
        PeerFailure::LibraryUnavailable
    } else if free_bytes.is_some_and(|free| free < SPACE_RESERVE_BYTES) {
        PeerFailure::StorageFull
    } else {
        PeerFailure::StorageFailed
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DeliveryError {
    /// #1070: the request's pairing epoch is not the current one.
    #[error("request does not carry the current pairing epoch")]
    PairingMismatch,
    /// #1070: no grant matches this exact tuple and can still advance.
    #[error("no grant matches this exact tuple and can still advance")]
    GrantNotFound,
    /// #1070: the queue sequence is already held by another completed item.
    #[error("queue sequence is already held by another completed item")]
    GrantConflict,
    /// #1070: durable delivery state contradicts itself (a bug, not the
    /// phone's fault).
    #[error("inconsistent delivery state: {0}")]
    Inconsistent(&'static str),
    #[error("delivery was cancelled before completion")]
    Cancelled,
    #[error("invalid flow delivery request: {0}")]
    InvalidRequest(String),
    #[error("native iroh-blobs fetch: {0}")]
    Fetch(String),
    /// #413: each materialize failure carries its public classification
    /// (`failure`) next to the fine-grained detail stage (the variant).
    #[error("create flow staging directory: {detail}")]
    MaterializeStaging {
        failure: PeerFailure,
        detail: String,
    },
    #[error("export fetched item from blob store: {detail}")]
    MaterializeExport {
        failure: PeerFailure,
        detail: String,
    },
    #[error("ingest materialized item into the index: {detail}")]
    MaterializeIngest {
        failure: PeerFailure,
        detail: String,
    },
    #[error("durable delivery state: {0}")]
    Storage(String),
    /// #413 §7: offer-time precheck — the item cannot fit, nothing started.
    #[error("not enough free space: need {needed} bytes, {free} free")]
    InsufficientSpace { needed: u64, free: u64 },
    /// #413 §7: the photo library folder is missing or not writable.
    #[error("photo library unavailable: {0}")]
    LibraryUnavailable(String),
}

impl DeliveryError {
    /// TEL-03: fixed fine-grained failure code — one per distinct failure
    /// class (logged as `detail=` next to the public [`Self::wire_code`]).
    /// Never the wrapped `String` (that text comes from `e.to_string()` on
    /// third-party errors and may carry a path or other unknown content).
    /// Materialize is split into staging/export/ingest instead
    /// of one generic code because those are three different subsystems
    /// (filesystem, blob store, index) with different fix-it implications.
    fn detail_code(&self) -> &'static str {
        match self {
            DeliveryError::PairingMismatch => "pairing_mismatch",
            DeliveryError::GrantNotFound => "grant_not_found",
            DeliveryError::GrantConflict => "grant_conflict",
            DeliveryError::Inconsistent(_) => "inconsistent_state",
            DeliveryError::Cancelled => "cancelled",
            DeliveryError::InvalidRequest(_) => "invalid_request",
            DeliveryError::Fetch(_) => "fetch_failed",
            DeliveryError::MaterializeStaging { .. } => "materialize_staging_failed",
            DeliveryError::MaterializeExport { .. } => "materialize_export_failed",
            DeliveryError::MaterializeIngest { .. } => "materialize_ingest_failed",
            DeliveryError::Storage(_) => "storage_failed",
            DeliveryError::InsufficientSpace { .. } => "offer_storage_full",
            DeliveryError::LibraryUnavailable(_) => "library_unavailable",
        }
    }

    /// #413 contract §5 / #1070: the reason the phone sees — `flow.failed.reason`
    /// and an offer rejection's `reason`. Storage-side failures collapse to
    /// the three [`PeerFailure`] reasons. The log line keeps the finer
    /// [`Self::detail_code`].
    pub fn wire_code(&self) -> Reason {
        match self {
            DeliveryError::MaterializeStaging { failure, .. }
            | DeliveryError::MaterializeExport { failure, .. }
            | DeliveryError::MaterializeIngest { failure, .. } => failure.reason(),
            DeliveryError::InsufficientSpace { .. } => Reason::StorageFull,
            DeliveryError::LibraryUnavailable(_) => Reason::LibraryUnavailable,
            DeliveryError::Storage(_) => Reason::StorageFailed,
            DeliveryError::PairingMismatch => Reason::PairingMismatch,
            DeliveryError::GrantNotFound => Reason::GrantNotFound,
            DeliveryError::GrantConflict => Reason::GrantConflict,
            DeliveryError::Cancelled => Reason::Cancelled,
            DeliveryError::InvalidRequest(_) => Reason::BadRequest,
            DeliveryError::Fetch(_) => Reason::FetchFailed,
            DeliveryError::Inconsistent(_) => Reason::Internal,
        }
    }

    /// The storage-side classification, if this is a storage-side failure.
    pub fn peer_failure(&self) -> Option<PeerFailure> {
        match self {
            DeliveryError::MaterializeStaging { failure, .. }
            | DeliveryError::MaterializeExport { failure, .. }
            | DeliveryError::MaterializeIngest { failure, .. } => Some(*failure),
            DeliveryError::InsufficientSpace { .. } => Some(PeerFailure::StorageFull),
            DeliveryError::LibraryUnavailable(_) => Some(PeerFailure::LibraryUnavailable),
            DeliveryError::Storage(_) => Some(PeerFailure::StorageFailed),
            _ => None,
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

    /// #1117：配对记录被删——不论哪一项，这台设备的路径登记都清掉。
    pub fn clear_peer(&self, peer: NodeId) -> bool {
        self.entries
            .lock()
            .expect("flow path registry lock")
            .remove(&peer.0)
            .is_some()
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

/// NET-06: process-local registry of the native-fetch task currently running
/// for one exact grant tuple, so `flow.suspend`/`flow.cancel_tuple` (or a
/// superseding retry) can interrupt it from a concurrent RPC. Keyed by
/// (peer, queue_sequence, lease_token) — deliberately NOT by content_hash:
/// distinct devices (or a retried lease on the same device) can independently
/// hold a grant for the same content, and suspending one must never abort
/// another device's unrelated transfer. Same tuple-identity discipline as
/// [`FlowPathRegistry`].
///
/// Uses `tokio_util::sync::CancellationToken` — the same primitive
/// `SubscriptionRegistry` (SYNC-03) already established in this codebase for
/// "cancel a task from outside" — instead of `JoinHandle::abort()`. This is a
/// deliberate choice over raw abort: `abort()` drops the task's future at an
/// arbitrary await point, so any cleanup code that runs *after* the awaited
/// work needs a `Drop`-based guard to survive that (a real trap; see the
/// card's review history). A `CancellationToken` observed through
/// `tokio::select!` is cooperative — the surrounding async block always
/// finishes executing past the `select!`, so ordinary sequential cleanup
/// code after it is never skipped. This sidesteps the abort/Drop-guard
/// problem architecturally instead of working around it.
#[derive(Clone, Default)]
pub struct FlowTaskRegistry {
    entries: Arc<Mutex<HashMap<TaskKey, TaskEntry>>>,
    next_generation: Arc<AtomicU64>,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct TaskKey {
    peer: [u8; 32],
    queue_sequence: i64,
    lease_token: String,
}

impl TaskKey {
    fn of(peer: NodeId, grant: &FlowGrant) -> Self {
        Self {
            peer: peer.0,
            queue_sequence: grant.queue_sequence,
            lease_token: grant.lease_token.clone(),
        }
    }
}

struct TaskEntry {
    token: CancellationToken,
    generation: u64,
    /// #1084: fired by the task itself when it has actually ended (success,
    /// error, cancel, panic or runtime shutdown — it is a drop guard held by
    /// the task). Cancelling `token` only *asks* the task to stop;
    /// `interrupt*` hand this back so callers wait for the stop to happen.
    exited: CancellationToken,
}

/// #1084: the exit signals of interrupted tasks. Awaiting it is the standard
/// cancel-and-await: once it returns, the interrupted fetch tasks have ended
/// and no longer pull bytes, so the caller may answer "stopped" truthfully
/// and a respawn for the same tuple cannot overlap the old task.
/// Held by a running fetch task; dropping it is the task's exit.
struct TaskExit {
    tasks: FlowTaskRegistry,
    key: TaskKey,
    generation: u64,
    exited: CancellationToken,
}

impl Drop for TaskExit {
    fn drop(&mut self) {
        self.tasks.unregister(&self.key, self.generation);
        self.exited.cancel();
    }
}

#[must_use = "await the interrupted tasks' exit"]
struct Interrupted(Vec<CancellationToken>);

impl Interrupted {
    fn count(&self) -> usize {
        self.0.len()
    }

    async fn exited(self) {
        for exited in self.0 {
            exited.cancelled().await;
        }
    }
}

impl FlowTaskRegistry {
    /// True if a task is currently registered (running) for this exact tuple.
    fn is_running(&self, peer: NodeId, grant: &FlowGrant) -> bool {
        self.entries
            .lock()
            .expect("flow task registry lock")
            .contains_key(&TaskKey::of(peer, grant))
    }

    /// NET-15: atomic "register only if absent". The spawn path's check-
    /// then-register used to be two separate lock acquisitions, so two
    /// concurrent spawns for the same tuple could both pass the check and
    /// double-spawn competing fetch tasks. `status()`'s restart respawn
    /// adds a new concurrent spawn source, making the atomic form
    /// structural rather than theoretical. Does not change the key
    /// structure or any existing semantics.
    fn try_register(
        &self,
        peer: NodeId,
        grant: &FlowGrant,
    ) -> Option<(CancellationToken, u64, CancellationToken)> {
        let mut entries = self.entries.lock().expect("flow task registry lock");
        if entries.contains_key(&TaskKey::of(peer, grant)) {
            return None;
        }
        let (token, generation, exited) = self.fresh_entry();
        entries.insert(
            TaskKey::of(peer, grant),
            TaskEntry {
                token: token.clone(),
                generation,
                exited: exited.clone(),
            },
        );
        Some((token, generation, exited))
    }

    fn fresh_entry(&self) -> (CancellationToken, u64, CancellationToken) {
        (
            CancellationToken::new(),
            self.next_generation.fetch_add(1, Ordering::Relaxed),
            CancellationToken::new(),
        )
    }

    /// Called by the spawned task itself once it exits (completed, failed,
    /// or was cancelled) — removes its own entry, but only if it is still
    /// *this* task's registration (a newer spawn for the same reused key may
    /// have replaced it; then this is a safe no-op). #1084: the only remover,
    /// so a registered entry always means a live task.
    fn unregister(&self, key: &TaskKey, generation: u64) {
        let mut entries = self.entries.lock().expect("flow task registry lock");
        if entries
            .get(key)
            .is_some_and(|entry| entry.generation == generation)
        {
            entries.remove(key);
        }
    }

    /// `flow.suspend`/`flow.cancel_tuple`: cancel the task registered for this
    /// exact tuple, if any. The caller awaits [`Interrupted::exited`].
    ///
    /// #1084: the entry is NOT removed here — the task removes it itself
    /// (`unregister`) on its way out. So "registered" means "still alive":
    /// `is_running` stays true while it winds down, and a racing
    /// `offer`/`status` cannot spawn a second task for the tuple meanwhile.
    fn interrupt(&self, peer: NodeId, grant: &FlowGrant) -> Interrupted {
        let entries = self.entries.lock().expect("flow task registry lock");
        Interrupted(
            entries
                .get(&TaskKey::of(peer, grant))
                .map(|entry| {
                    entry.token.cancel();
                    entry.exited.clone()
                })
                .into_iter()
                .collect(),
        )
    }

    /// #563 `device.revoke`: cancel and remove every task registered for
    /// this control peer, whatever its tuple. Same per-tuple tokens as
    /// [`Self::interrupt`]; the caller awaits [`Interrupted::exited`].
    fn interrupt_peer(&self, peer: NodeId) -> Interrupted {
        let entries = self.entries.lock().expect("flow task registry lock");
        Interrupted(
            entries
                .iter()
                .filter(|(key, _)| key.peer == peer.0)
                .map(|(_, entry)| {
                    entry.token.cancel();
                    entry.exited.clone()
                })
                .collect(),
        )
    }
}

/// #1126: see [`FlowDelivery::provider_endpoints`].
type ProviderEndpoints = Arc<Mutex<HashMap<[u8; 32], Vec<NodeId>>>>;

/// #1126: how many provider endpoints to remember per phone (it rebinds on network trouble and
/// after parking; older ones are long closed).
const PROVIDER_ENDPOINTS_PER_PEER: usize = 4;

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
    /// Android can retry an item after its RPC times out while the daemon is
    /// still materializing that same fetch. One lock per paired phone prevents
    /// the retry from deleting or moving the first fetch's staging path.
    fetch_locks: FetchLocks,
    /// #1126: the provider endpoints each paired phone's fetches dialled (a phone's upload
    /// provider runs its own endpoint identity, not the phone's control-plane NodeId). Removing
    /// the phone closes these too, so its provider hears the 410. A few most recent per phone.
    provider_endpoints: ProviderEndpoints,
    /// NET-06: process-local registry of the background native-fetch task
    /// per exact tuple, so `suspend`/`cancel_by_tuple` can interrupt it and
    /// `status` can tell "still working" from "stopped".
    tasks: FlowTaskRegistry,
    /// NET-25: 只用来在推送发出时记一句"这台手机此刻在不在订阅表里"。
    /// `None`（测试/单组件构造）= 不记这一维，推送行为完全不变。
    subscriptions: Option<SubscriptionRegistry>,
    /// NET-26 (#419): every running background fetch task holds one lease;
    /// the platform "stay awake" assertion lives while any lease does.
    /// Default is a no-op; `main.rs` wires [`AwakeHold::platform`].
    awake: AwakeHold,
    /// #413: the photo library folder (the daemon data dir). Health and the
    /// materialize guard check it; nothing here ever recreates it.
    library_root: PathBuf,
    /// #413 §6: resume-deadline clock (unix ms). Tests inject one.
    now: Clock,
    /// #413 §7: free bytes on `library_root`'s volume. Tests inject one.
    free_space: FreeSpaceProbe,
    /// IDX-06 (#442): background thumbnail pre-generation. `None` = no
    /// pre-generation; `thumb.get` still generates on first view.
    thumbs: Option<ThumbPregen>,
    /// NET-29 (#467): how long one native fetch may go without receiving a
    /// payload byte before it fails as `fetch_failed`. Tests inject one.
    fetch_byte_stall: std::time::Duration,
    /// #763: landing folders (`originals/<device>/<yyyy>/<mm>`) where a real
    /// ingest failed. `hello.health` re-probes each one and reports the
    /// library unwritable for that phone until the folder takes a file
    /// again. Process-local: a daemon restart forgets them (one more failed
    /// item re-learns the folder).
    landing_failures: Arc<Mutex<std::collections::HashSet<PathBuf>>>,
    /// #1076: see [`FetchStage`]. `None` in production.
    stage_hook: Option<StageHook>,
}

/// #763: bound on remembered failing landing folders. Each is one month of
/// one phone; past the cap a new failure is simply not remembered (the phone
/// side still stops on its own retry cap).
const MAX_LANDING_FAILURES: usize = 64;

/// NET-29 (#467) capture 1: the daemon's fetch sent its request and then
/// waited forever — no bytes, no error — while the phone kept polling an
/// `active` grant. With no byte progress for this long the fetch fails, the
/// daemon pushes `flow.failed` (`fetch_failed` → a path failure on the phone)
/// and the phone serves and offers again. Byte progress resets the clock, so
/// only a transfer that has stopped moving is cut. Set below the phone's own
/// 180 s byte-stall give-up (`BYTE_STALL_THRESHOLD_MS`) so the desktop, which
/// sees the stall first-hand, reports it first.
pub const FETCH_BYTE_STALL_LIMIT: std::time::Duration = std::time::Duration::from_secs(60);

impl FlowDelivery {
    /// `library_root` is the daemon data directory. The dedicated flow blob
    /// store is deliberately not the legacy `.ppf/blobs` inbox: that legacy
    /// store is cleared on daemon startup, while this store retains native
    /// partials across restart for iroh-blobs resume.
    pub fn new(db: Db, blobs: Arc<Blobs>, library_root: impl AsRef<Path>) -> Self {
        let root = library_root.as_ref().to_path_buf();
        Self {
            ingestor: Ingestor::new(db.clone(), &root)
                .with_file_name_sanitizer(platform::adapter().ingest_file_name_sanitizer()),
            db,
            blobs,
            staging: root.join(".ppf/flow-staging"),
            throttle: None,
            paths: FlowPathRegistry::default(),
            events: None,
            fetch_locks: Arc::default(),
            provider_endpoints: Arc::default(),
            tasks: FlowTaskRegistry::default(),
            subscriptions: None,
            awake: AwakeHold::noop(),
            library_root: root,
            now: Arc::new(unix_ms_now),
            free_space: Arc::new(platform_free_bytes),
            thumbs: None,
            fetch_byte_stall: FETCH_BYTE_STALL_LIMIT,
            landing_failures: Arc::default(),
            stage_hook: None,
        }
    }

    /// NET-29: override [`FETCH_BYTE_STALL_LIMIT`] (tests).
    pub fn with_fetch_byte_stall(mut self, limit: std::time::Duration) -> Self {
        self.fetch_byte_stall = limit;
        self
    }

    /// #1076: await `hook` at each [`FetchStage`] of a background fetch (tests).
    pub fn with_fetch_stage_hook(
        mut self,
        hook: impl Fn(FetchStage) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>
            + Send
            + Sync
            + 'static,
    ) -> Self {
        self.stage_hook = Some(Arc::new(hook));
        self
    }

    async fn reached(&self, stage: FetchStage) {
        if let Some(hook) = &self.stage_hook {
            hook(stage).await;
        }
    }

    /// IDX-06 (#442): hand every freshly materialized item to the
    /// low-priority thumbnail pre-generation pool.
    pub fn with_thumb_pregen(mut self, thumbs: ThumbPregen) -> Self {
        self.thumbs = Some(thumbs);
        self
    }

    /// #413 §6: override the resume-deadline clock (unix ms).
    pub fn with_clock(mut self, now: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.now = Arc::new(now);
        self
    }

    /// #413 §7: override the free-space source for the library volume.
    pub fn with_free_space_probe(
        mut self,
        probe: impl Fn(&Path) -> Option<u64> + Send + Sync + 'static,
    ) -> Self {
        self.free_space = Arc::new(probe);
        self
    }

    /// #413 §7 / contract §5: the `hello.health` answer for `peer`. Filesystem
    /// probes run off the async workers: a sleeping external drive can stall
    /// `statvfs`, and hello is on the control path.
    ///
    /// #763: `library_writable` answers "can this phone's next photo land",
    /// not only "is `.ppf/` writable": see [`landing_writable`].
    pub async fn health(&self, peer: NodeId) -> DesktopHealth {
        let root = self.library_root.clone();
        let probe = self.free_space.clone();
        let failures = self.landing_failures.clone();
        let (free, writable) = tokio::task::spawn_blocking(move || {
            (probe(&root), landing_writable(&root, &peer, &failures))
        })
        .await
        .unwrap_or((None, false));
        DesktopHealth {
            free_bytes: free.map(|bytes| i64::try_from(bytes).unwrap_or(i64::MAX)),
            library_writable: writable,
            index_ok: self.db.index_health_check().await.is_ok(),
        }
    }

    /// Classify a storage-side failure against the environment right now.
    fn classify(&self, io_kind: Option<ErrorKind>) -> PeerFailure {
        // #555：Full（盘满）不算「不可用」——否则 classify_peer_failure 的
        // !writable → LibraryUnavailable 分支会先抢走，free 检查永远轮不到。
        classify_peer_failure(
            io_kind,
            library_probe(&self.library_root) != LibraryProbe::Unavailable,
            (self.free_space)(&self.library_root),
        )
    }

    fn ingest_failure(&self, error: &IndexError) -> DeliveryError {
        let io_kind = match error {
            IndexError::Io { source, path } => {
                self.remember_landing_failure(path);
                Some(source.kind())
            }
            _ => None,
        };
        DeliveryError::MaterializeIngest {
            failure: self.classify(io_kind),
            detail: error.to_string(),
        }
    }

    /// #763: an ingest failed at `path`; remember the landing folder it
    /// belongs to so `hello.health` stops reporting this phone's library as
    /// writable until that folder takes a file again. Paths outside
    /// `originals/` (staging, the source file) say nothing about landing.
    fn remember_landing_failure(&self, path: &Path) {
        let Some(dir) = landing_dir_of(&self.library_root, path) else {
            return;
        };
        let mut failures = self
            .landing_failures
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if failures.len() < MAX_LANDING_FAILURES || failures.contains(&dir) {
            tracing::warn!(dir = %dir.display(), "flow: landing folder refused a photo; health reports it until it accepts one");
            failures.insert(dir);
        }
    }

    /// #413 §7: offer-time admission for an item the library does not have
    /// yet. The library must be writable, and — when the phone knows the
    /// size — the volume must hold the rest of the blob plus the staging
    /// export (one full copy) with [`SPACE_RESERVE_BYTES`] to spare. A
    /// resumed partial already on disk is not counted twice.
    async fn admit(&self, hash: &[u8; 32], size_bytes: i64) -> Result<(), DeliveryError> {
        match library_probe(&self.library_root) {
            LibraryProbe::Unavailable => {
                return Err(DeliveryError::LibraryUnavailable(
                    "library folder missing or not writable".into(),
                ));
            }
            // #555：探针 ENOSPC = 空间不足，与下面的容量预检同一公开语义
            // （storage_full）。free 探测答不上来时按 0 记——探针连一个空文件
            // 都建不了已是铁证；这行措辞只进日志，wire code 不变。
            LibraryProbe::Full => {
                return Err(DeliveryError::InsufficientSpace {
                    needed: SPACE_RESERVE_BYTES,
                    free: (self.free_space)(&self.library_root).unwrap_or(0),
                });
            }
            LibraryProbe::Writable => {}
        }
        let Ok(size) = u64::try_from(size_bytes) else {
            return Ok(());
        };
        if size == 0 {
            return Ok(());
        }
        let Some(free) = (self.free_space)(&self.library_root) else {
            return Ok(());
        };
        let partial = self.blobs.local_bytes(*hash).await.unwrap_or(0).min(size);
        let needed = (size - partial)
            .saturating_add(size)
            .saturating_add(SPACE_RESERVE_BYTES);
        if free < needed {
            return Err(DeliveryError::InsufficientSpace { needed, free });
        }
        Ok(())
    }

    /// #413 §6: cancel every active grant nobody resumed within
    /// [`GRANT_RESUME_TTL_MS`], so GC may reclaim its partial. A grant whose
    /// fetch is still running in this process is never expired, however old
    /// its last offer. Returns how many grants were cancelled.
    pub async fn expire_stale_grants(&self) -> Result<usize, DeliveryError> {
        let cutoff = (self.now)().saturating_sub(GRANT_RESUME_TTL_MS);
        let stale = self
            .db
            .stale_active_flow_grants(cutoff)
            .await
            .map_err(storage_error)?;
        let mut expired = 0;
        for grant in stale {
            let peer = match array32(&grant.node_id) {
                Some(bytes) => NodeId(bytes),
                None => continue,
            };
            if self.tasks.is_running(peer, &grant) {
                continue;
            }
            if self
                .db
                .cancel_flow_grant(&grant)
                .await
                .map_err(storage_error)?
            {
                tracing::info!(
                    "flow grant expired after {} days without resume seq={} peer={peer:?}",
                    GRANT_RESUME_TTL_MS / (24 * 60 * 60 * 1000),
                    grant.queue_sequence
                );
                expired += 1;
            }
        }
        Ok(expired)
    }

    /// NET-26 (#419): hold this awake assertion while any background fetch
    /// task runs (reference counted across tasks, released by the last).
    pub fn with_awake(mut self, awake: AwakeHold) -> Self {
        self.awake = awake;
        self
    }

    /// NET-25: 接上按 `NodeId` 登记的订阅表，**只读**，只为 `emit_flow_delivered`
    /// 那行日志服务——推送本身发不发、发给谁，一概不受影响。
    pub fn with_subscriptions(mut self, subscriptions: SubscriptionRegistry) -> Self {
        self.subscriptions = Some(subscriptions);
        self
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

    /// Persist the current exact grant, then immediately start the native
    /// fetch in the background (idempotent: a no-op if one is already
    /// running for this exact tuple). This method itself never touches the
    /// data plane and always returns promptly — "offer秒回" per the card.
    /// NET-24: replies with the same [`FlowStatusReply`] a `flow.status`
    /// call issued right now would return. The async-202 shape stays for
    /// work that really is async (`state == "active"`), but when the grant
    /// is already terminal at offer time — NET-20's content dedup, NET-22's
    /// rebind of an already-completed tuple — the terminal state travels
    /// back on the reply the caller is already blocked on. Standard 202
    /// practice: 200/201-with-the-result and 202-go-poll are chosen per
    /// response, not fixed per endpoint (cf. Docker Registry v2 blob mount:
    /// 201 when the digest is already present, 202 when an upload is
    /// actually needed).
    pub async fn offer(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<FlowStatusReply, DeliveryError> {
        self.offer_inner(peer, request).await
    }

    async fn offer_inner(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<FlowStatusReply, DeliveryError> {
        // DIAG-B：offer 到达时这台手机有没有挂着订阅。手机的推送订阅是在 offer 之后才建的，
        // 与后面的 `flow.delivered push … peer_subscribed=` 对照，判断推送是否早于订阅。
        tracing::info!(
            "flow.offer received seq={} peer_subscribed={} peer={peer:?}",
            request.queue_sequence,
            self.subscriptions.as_ref().map_or_else(
                || "unwired".to_string(),
                |r| r.is_subscribed(peer).to_string()
            ),
        );
        let grant = self.checked_request(peer, request).await?;
        self.provider_for(&grant)?;
        if self
            .db
            .rebind_completed_flow_grant(&grant)
            .await
            .map_err(storage_error)?
        {
            // NET-22: this tuple was already completed under a DIFFERENT
            // lease_token/provider (a restarted discovery cursor re-offering
            // the exact same queue_sequence — the ordinary re-pairing/
            // re-install case, not NET-20's cross-tuple content match).
            // Historically this just silently rebound the row and returned
            // Ok — no push, no wake for the caller. NET-20's sibling branch
            // (complete_without_fetch) already emits flow.delivered on a
            // fresh completion; this branch is the SAME "already have it,
            // just tell them" fact and must behave identically, not leave
            // the phone's poll-on-local-idle fallback as the only way out
            // (real device, 2026-09-16: a 30s local-idle stall before the
            // phone's own flow.status() fallback kicked in, for a receipt
            // the daemon had known about the entire time).
            let rebound = self.matching_grant(&grant).await?;
            let receipt = self.persisted_receipt(&rebound).await?;
            // NET-24: the push stays (it is the acceleration path for any
            // caller already subscribed), but it is no longer the ONLY way
            // out — the terminal state also rides back on this reply.
            self.emit_flow_delivered(peer, &rebound, &receipt);
            return Ok(FlowStatusReply {
                state: "completed".into(),
                receipt: Some(receipt),
                task_running: false,
            });
        }
        // NET-20: the content may already have a durable copy in the
        // library under a different (or even the same) tuple — a restarted
        // discovery cursor re-offering, the same photo arriving from a
        // second device, or a retried offer after a dropped reply all hit
        // this. Skip the network fetch entirely instead of pulling bytes we
        // already have only to discard them at ingest time (NET-20).
        let hash = array32(&grant.content_hash).expect("validated by checked_request");
        let durable = self
            .ingestor
            .has_durable_copy(&hash)
            .await
            .map_err(|e| self.ingest_failure(&e))?;
        // #413 §7: decided BEFORE anything is persisted — a refused offer
        // leaves no active grant behind (it would hold GC protection for an
        // item that never starts). Content the library already has needs no
        // space, so it is never refused as full.
        if !durable {
            self.admit(&hash, request.size_bytes).await?;
        }
        // #413 §6: an offer is the phone (re)starting this tuple — it stamps
        // the resume clock `expire_stale_grants` measures from.
        self.db
            .upsert_flow_grant_at(&grant, (self.now)())
            .await
            .map_err(storage_error)?;
        // A completed receipt is immutable. Verify the upsert really made
        // this tuple current rather than silently acknowledging a different
        // completed item at the same queue sequence.
        let stored = self.matching_grant(&grant).await?;
        if durable {
            return self.complete_without_fetch(peer, &stored).await;
        }
        // NET-06: this is the async-202 trigger — offer's job ends here; the
        // actual transfer runs on its own task, tracked by `self.tasks` so
        // `suspend`/`cancel`/`status` can observe or interrupt it.
        self.spawn_fetch_task(peer, stored.clone(), request.clone());
        // NET-24: the genuinely-async case, and the only one that still
        // answers "202 — go wait". #1076: `task_running` is queried, not
        // asserted — a re-offer whose task was already running keeps that
        // task, and one that ended in between reports so.
        Ok(FlowStatusReply {
            state: "active".into(),
            receipt: None,
            task_running: self.tasks.is_running(peer, &stored),
        })
    }

    /// NET-20: the presence-checked path — content already has a durable
    /// copy, so there is nothing to fetch. Writes the exact same durable
    /// receipt shape a real transfer would (`complete_flow_grant`), so
    /// `status()`/`fetch()` callers cannot tell this apart from an ordinary
    /// completed transfer — this deliberately reuses the existing complete
    /// path instead of inventing a new "skipped/duplicate" wire state
    /// (the card's own default: don't add protocol fields without deciding
    /// to).
    async fn complete_without_fetch(
        &self,
        peer: NodeId,
        grant: &FlowGrant,
    ) -> Result<FlowStatusReply, DeliveryError> {
        let receipt_id = receipt_id()?;
        if !self
            .db
            .complete_flow_grant(grant, &receipt_id)
            .await
            .map_err(storage_error)?
        {
            // Lost a race with cancel/suspend or a concurrent completion.
            // NET-24: never fabricate a receipt here — re-read whichever
            // outcome actually won and report that, exactly as `status()`
            // would. The caller then sees `cancelled` (or a completion it
            // did not mint) instead of a completion that never happened.
            let current = self.matching_grant(grant).await?;
            return self.reply_for_grant(peer, &current).await;
        }
        let receipt = receipt_from(grant, receipt_id);
        // NET-24: push kept as the acceleration path; the reply below is
        // the guaranteed one.
        self.emit_flow_delivered(peer, grant, &receipt);
        Ok(FlowStatusReply {
            state: "completed".into(),
            receipt: Some(receipt),
            task_running: false,
        })
    }

    /// NET-06: idempotently ensure exactly one background native-fetch task
    /// is running for this exact tuple. Fire-and-forget from the caller's
    /// perspective — completion is observed later via durable state
    /// (`status`), never via this task's
    /// return value directly.
    fn spawn_fetch_task(&self, peer: NodeId, grant: FlowGrant, request: FlowFetchRequest) {
        // NET-15: `try_register` makes the idempotency check atomic — a
        // concurrent `offer`/`status` respawn can no longer both
        // pass the "not running" check and double-spawn for this tuple.
        // #1076: a re-offer carrying a new provider ticket lands here too and
        // keeps the running task: the provider is where the bytes come from,
        // not which item this is. A later attempt reads the stored provider.
        let Some((token, generation, exited)) = self.tasks.try_register(peer, &grant) else {
            return;
        };
        let key = TaskKey::of(peer, &grant);
        let delivery = self.clone();
        // NET-26: taken only after `try_register` won (the idempotent early
        // return above holds nothing) and moved into the task, so every way
        // the task ends — success, error, cancel, panic, runtime shutdown —
        // drops it, same as the `TaskExit` guard below.
        let awake = self.awake.lease();
        tokio::spawn(async move {
            // #1084: dropped last, on every way out (including panic and
            // runtime shutdown): unregisters, then fires `exited` — what
            // `Interrupted::exited` waits for.
            let _exit = TaskExit {
                tasks: delivery.tasks.clone(),
                key,
                generation,
                exited,
            };
            let _awake = awake;
            let outcome = tokio::select! {
                result = delivery.run_fetch_body(peer, &grant, &request) => Some(result),
                _ = token.cancelled() => None,
            };
            match outcome {
                Some(Ok(receipt)) => {
                    // NET-14: push the completion fact instead of waiting for
                    // the phone's next status() poll to discover it — the
                    // durable receipt was already written inside
                    // run_fetch_body; this is purely a "hurry up and tell
                    // the phone" notification, never the source of truth.
                    delivery.emit_flow_delivered(peer, &grant, &receipt);
                }
                Some(Err(error)) => {
                    tracing::warn!("flow delivery background task for {peer:?} failed: {error}");
                    delivery.emit_flow_failed(peer, &grant, &error);
                }
                None => {
                    tracing::debug!(
                        "flow delivery background task for {peer:?} suspended or cancelled"
                    );
                }
            }
        });
    }

    /// NET-14: best-effort push — `self.events` is `None` in tests/single-
    /// component construction (same contract as `emit_device_changed`), and
    /// even in production a dropped subscription just means the phone falls
    /// back to its next `status()` poll (the recipient-side rule this card
    /// establishes: push accelerates, it is never the only path).
    fn emit_flow_delivered(
        &self,
        peer: NodeId,
        grant: &FlowGrant,
        receipt: &FlowCompletionReceipt,
    ) {
        let Some(events) = &self.events else { return };
        // NET-25: 推送发出的那一刻，这台手机在不在订阅表里。broadcast 无订阅
        // 者时 send 直接丢弃，所以 subscribed=false 就是"这条推送被丢掉了"的
        // 直接证据。带上 seq——DedupGuard 会折叠完全相同的行。
        tracing::info!(
            "flow.delivered push seq={} peer_subscribed={} peer={peer:?}",
            grant.queue_sequence,
            self.subscriptions.as_ref().map_or_else(
                || "unwired".to_string(),
                |r| r.is_subscribed(peer).to_string()
            ),
        );
        crate::events::emit(
            events,
            crate::events::FLOW_DELIVERED,
            serde_json::json!({
                "node_id": peer.to_string(),
                "queue_sequence": grant.queue_sequence,
                "pairing_id": grant.pairing_id,
                "lease_token": grant.lease_token,
                "receipt": receipt,
            }),
        );
    }

    fn emit_flow_failed(&self, peer: NodeId, grant: &FlowGrant, error: &DeliveryError) {
        let Some(events) = &self.events else { return };
        // DIAG-B2：与 flow.delivered 那行对称——失败推送发出时这台手机在不在订阅表里。
        tracing::info!(
            "flow.failed push seq={} code={} detail={} peer_subscribed={} peer={peer:?}",
            grant.queue_sequence,
            error.wire_code(),
            error.detail_code(),
            self.subscriptions.as_ref().map_or_else(
                || "unwired".to_string(),
                |r| r.is_subscribed(peer).to_string()
            ),
        );
        crate::events::emit(
            events,
            crate::events::FLOW_FAILED,
            // #413 contract §5: public reason only; the fine-grained
            // detail code stays in the log line above.
            serde_json::to_value(proto::FlowFailedPush {
                node_id: peer.to_string(),
                queue_sequence: grant.queue_sequence,
                pairing_id: grant.pairing_id.clone(),
                lease_token: grant.lease_token.clone(),
                reason: error.wire_code(),
            })
            .unwrap_or_default(),
        );
    }

    /// The actual native-fetch → materialize → ingest → durable-receipt
    /// pipeline for one exact tuple. Runs entirely inside the task
    /// `spawn_fetch_task` spawns; interruption is handled by the caller's
    /// `tokio::select!` racing this future against a `CancellationToken`,
    /// not by anything inside this method.
    async fn run_fetch_body(
        &self,
        peer: NodeId,
        grant: &FlowGrant,
        request: &FlowFetchRequest,
    ) -> Result<FlowCompletionReceipt, DeliveryError> {
        let item_started = std::time::Instant::now();
        let hash = array32(&grant.content_hash).expect("validated by checked_request");
        let provider = self.provider_for(grant)?;
        self.note_provider_endpoint(peer, provider);

        // The visible path is scoped to this exact strict item and cleared by
        // its guard on every terminal branch. Start as unknown before opening
        // data-plane bytes; never infer direct/relay from the ctrl connection.
        let path_guard = FlowPathGuard::start(self.paths.clone(), self.events.clone(), peer, grant);

        // The only data transport in this flow: native iroh-blobs fetch. Its
        // content-addressed fetch verifies the requested BLAKE3 hash and
        // resumes from the dedicated retained store on retry/restart.
        let fetch_started = std::time::Instant::now();
        let mut conn_path: &'static str = "unknown";
        let fetch_result = self
            .blobs
            .fetch_from_observing_path_with_stall(provider, hash, self.fetch_byte_stall, |status| {
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
        self.require_active(grant).await?;
        self.reached(FetchStage::Verified).await;
        // #413: `create_dir_all` below would quietly recreate a library
        // folder that vanished (external drive unplugged) and ingest into an
        // empty stand-in. Refuse instead: the phone waits, nothing is lost.
        if !self.library_root.is_dir() {
            return Err(DeliveryError::LibraryUnavailable(
                "library folder is gone".into(),
            ));
        }
        std::fs::create_dir_all(&self.staging).map_err(|e| DeliveryError::MaterializeStaging {
            failure: self.classify(Some(e.kind())),
            detail: format!("create staging: {e}"),
        })?;
        let staged = self.staged_path(grant);
        let _ = std::fs::remove_file(&staged);
        self.blobs.export_to(hash, &staged).await.map_err(|e| {
            // The blob store reports as text; the environment explains it.
            DeliveryError::MaterializeExport {
                failure: self.classify(None),
                detail: e.to_string(),
            }
        })?;
        // #563: last gate before the photo enters the library. The owner may
        // have removed this device while the bytes were in flight; its
        // revoke cancels this task, and this re-check covers a revoke that
        // lands between that sweep and here.
        self.require_authorized(grant).await?;
        let item_bytes = std::fs::metadata(&staged).map(|m| m.len()).unwrap_or(0);

        // #1044 B1（AUDIT-01）：Flow 一轮只有一条 `flow.round.finished`；
        // 逐张入库只在两种例外写审计（见 `Ingestor::ingest_flow`）。
        match self
            .ingestor
            .ingest_flow(&IncomingFile {
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
            Ok(outcome) => {
                // IDX-06 (#442): fire-and-forget, never blocks the receipt.
                if let (IngestOutcome::New(rel) | IngestOutcome::Moved(rel), Some(thumbs)) =
                    (&outcome, &self.thumbs)
                {
                    thumbs.ingested(rel);
                }
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
            Err(e) => return Err(self.ingest_failure(&e)),
        }
        self.reached(FetchStage::Ingested).await;

        // This update is the receipt adapter's irreversible boundary. It
        // repeats all tuple guards inside SQL and writes receipt_id before
        // this method returns it to the phone.
        let receipt_id = receipt_id()?;
        if !self
            .db
            .complete_flow_grant(grant, &receipt_id)
            .await
            .map_err(storage_error)?
        {
            // #1076: lost the race. A re-offer that found the photo already
            // in the library completed this same tuple (`complete_without_fetch`);
            // that receipt is this item's outcome, not a failure. Only a
            // cancellation stays one — as in `complete_without_fetch`.
            let current = self.matching_grant(grant).await?;
            if current.state == FlowGrantState::Completed {
                return self.persisted_receipt(&current).await;
            }
            return Err(DeliveryError::Cancelled);
        }
        // TEL-02: `resumed` has no cheap signal yet from this call path —
        // iroh-blobs resume detection would need a store-level query this
        // card does not add. Hardcoded false per the card's explicit
        // allowance; a real resume-detection signal is separate follow-up
        // work, not silently invented here.
        self.record_flow_item(item_bytes, item_started.elapsed().as_secs(), false);
        Ok(receipt_from(grant, receipt_id))
    }

    /// #851 `flow.supersede`: replace this phone's location-redacted copy with the original, in
    /// place. Only the metadata byte ranges of the original travel (verified against its hash by
    /// iroh-blobs); the spliced file must hash to `new_hash` and differ from the old copy only where
    /// the old copy has zeros. Every refusal leaves the library untouched.
    ///
    /// The network fetch is bounded by the byte-stall watchdog; the local splice and swap are never
    /// cut short (a half-applied swap is what `finish_pending_swaps` exists for, not a timeout).
    /// Serialized with this phone's fetches through the same per-phone lock.
    pub async fn supersede(
        &self,
        peer: NodeId,
        request: &FlowSupersedeRequest,
    ) -> Result<FlowSupersedeReply, DeliveryError> {
        let refused = |reason: SupersedeRefusal| FlowSupersedeReply {
            outcome: "refused".into(),
            reason: Some(reason),
        };
        let (Some(old), Some(new)) = (parse_hash(&request.old_hash), parse_hash(&request.new_hash))
        else {
            return Ok(refused(SupersedeRefusal::BadRequest));
        };
        // #1117：只认这台设备当前配对记录的 id（内存副本）。
        let current = self.db.active_pairing(&peer.0).map(|p| p.id);
        if request.pairing_id.is_empty() || current.as_deref() != Some(request.pairing_id.as_str())
        {
            return Ok(refused(SupersedeRefusal::PairingMismatch));
        }
        let Ok((provider, ticket_hash)) = self.blobs.register_blob_ticket(&request.provider) else {
            return Ok(refused(SupersedeRefusal::BadRequest));
        };
        // 提供方是手机的 blobs 端点（独立于控制面身份，与 flow.offer 一样不比对）；取到的每个字节都按
        // new_hash 校验，票据指向别的内容就拒绝。
        if ticket_hash != new {
            return Ok(refused(SupersedeRefusal::BadRequest));
        }
        let fetch_lock = self.fetch_lock(peer);
        let _guard = fetch_lock.lock().await;

        let plan = match self
            .ingestor
            .plan_supersede(&old, &new, &peer.0)
            .await
            .map_err(|e| self.ingest_failure(&e))?
        {
            SupersedeCheck::AlreadyDone => {
                return Ok(FlowSupersedeReply {
                    outcome: "replaced".into(),
                    reason: None,
                })
            }
            SupersedeCheck::Refused(reason) => {
                tracing::info!(
                    "#851 supersede {} → {} refused: {reason}",
                    &request.old_hash[..8],
                    &request.new_hash[..8]
                );
                return Ok(refused(supersede_refusal(reason)));
            }
            SupersedeCheck::Ready(plan) => plan,
        };
        let (size, pieces) = match self
            .blobs
            .fetch_byte_ranges(provider, new, &plan.ranges, self.fetch_byte_stall)
            .await
        {
            Ok(got) => got,
            Err(e) => {
                tracing::warn!(
                    "#851 supersede {}: ranged fetch failed: {e}",
                    &request.new_hash[..8]
                );
                return Ok(refused(SupersedeRefusal::FetchFailed));
            }
        };
        let fetched: u64 = pieces.iter().map(|(_, b)| b.len() as u64).sum();
        let applied = self
            .ingestor
            .apply_supersede(&plan, &new, size, &pieces, (self.now)())
            .await
            .map_err(|e| self.ingest_failure(&e))?;
        match applied {
            SupersedeApplied::Refused(reason) => {
                tracing::info!(
                    "#851 supersede {} → {} refused after fetch: {reason}",
                    &request.old_hash[..8],
                    &request.new_hash[..8]
                );
                Ok(refused(supersede_refusal(reason)))
            }
            SupersedeApplied::Replaced {
                rel_path,
                quarantined,
            } => {
                // 旧指纹的缩略图没人再引用：删掉（不留孤儿）；新指纹的照常预生成。
                let thumbs_root = self.library_root.join(".ppf/thumbs");
                let stale = media_codec::thumb_paths(&thumbs_root, &old);
                let _ = std::fs::remove_file(stale.t256);
                let _ = std::fs::remove_file(stale.t1024);
                if let Some(thumbs) = &self.thumbs {
                    thumbs.ingested(&rel_path);
                }
                if let Some(throttle) = &self.throttle {
                    throttle.signal();
                }
                let _ = self
                    .db
                    .append_audit(&storage::AuditEntry::local(
                        (self.now)(),
                        Some(peer.0.to_vec()),
                        "asset.superseded",
                        Some(new.to_vec()),
                        Some(
                            serde_json::json!({
                                "old_hash": request.old_hash,
                                "rel_path": rel_path,
                                "quarantined": quarantined,
                                "fetched_bytes": fetched,
                                "size": size,
                            })
                            .to_string(),
                        ),
                    ))
                    .await;
                tracing::info!("#851 supersede {} → {} replaced at {rel_path} ({fetched} of {size} bytes fetched)", &request.old_hash[..8], &request.new_hash[..8]);
                Ok(FlowSupersedeReply {
                    outcome: "replaced".into(),
                    reason: None,
                })
            }
        }
    }

    /// NET-06: cancel by tuple identity alone — same lookup path as
    /// `status`/`suspend` (`tuple_grant`, which needs only queue_sequence +
    /// pairing_id + lease_token). Reuses the daemon's own stored
    /// content_hash/provider instead of requiring the caller to supply
    /// them, so a phone that already discarded a failed item's one-shot
    /// provider ticket can still cancel the daemon's matching grant.
    /// Mark the grant Cancelled, interrupt any in-progress task, clear the
    /// active path entry.
    pub async fn cancel_by_tuple(
        &self,
        peer: NodeId,
        tuple: &FlowTupleRef,
    ) -> Result<(), DeliveryError> {
        self.cancel_by_tuple_inner(peer, tuple).await
    }

    async fn cancel_by_tuple_inner(
        &self,
        peer: NodeId,
        tuple: &FlowTupleRef,
    ) -> Result<(), DeliveryError> {
        let Some(grant) = self.tuple_grant(peer, tuple).await? else {
            return Err(DeliveryError::GrantNotFound);
        };
        if self
            .db
            .cancel_flow_grant(&grant)
            .await
            .map_err(storage_error)?
        {
            self.tasks.interrupt(peer, &grant).exited().await;
            if self
                .paths
                .clear_if_current(peer, grant.queue_sequence, &grant.lease_token)
            {
                emit_device_changed(self.events.as_ref());
            }
            Ok(())
        } else {
            // #1027: the grant exists but is no longer active — it already
            // completed or was cancelled. The caller's goal (this tuple stops)
            // is reached: answer Ok as an idempotent no-op and move nothing.
            // Only a missing / superseded tuple is a guard mismatch.
            Ok(())
        }
    }

    /// NET-06: read-only status query. Never touches the data plane and
    /// never blocks on it — this is the control-plane answer new phones
    /// poll instead of inferring task state from an RPC round-trip timing
    /// out (NET-01's root cause).
    pub async fn status(
        &self,
        peer: NodeId,
        tuple: &FlowTupleRef,
    ) -> Result<FlowStatusReply, DeliveryError> {
        let Some(grant) = self.tuple_grant(peer, tuple).await? else {
            return Ok(FlowStatusReply {
                state: "not_found".into(),
                receipt: None,
                task_running: false,
            });
        };
        // NET-15: a daemon restart wipes the in-memory task registry while
        // the durable grant stays Active, orphaning the delivery: the phone
        // keeps polling and this kept answering "active, nothing running"
        // forever. The poll is the only signal a restarted daemon gets from
        // a waiting phone, so the poll itself must respawn the lost task.
        // `spawn_fetch_task` is idempotent (atomic `try_register`), so a
        // poll racing a running task is a no-op. A deliberately suspended
        // grant is safe here as well: polling this exact tuple means a
        // phone is actively waiting on it — the same fact a resuming
        // `flow.offer` carries, which is the documented resume trigger.
        if grant.state == FlowGrantState::Active && !self.tasks.is_running(peer, &grant) {
            // #413 §6: a phone polling this exact tuple is resuming it.
            self.db
                .touch_active_flow_grant(&grant, (self.now)())
                .await
                .map_err(storage_error)?;
            self.spawn_fetch_task(peer, grant.clone(), resume_request(&grant));
        }
        self.reply_for_grant(peer, &grant).await
    }

    /// NET-24: the durable-state → `FlowStatusReply` mapping, shared by
    /// [`Self::status`] and by [`Self::offer`]'s own reply. `offer`
    /// answering with "what `status()` would say right now" is the whole
    /// point of NET-24: when the work is already done at offer time, the
    /// caller must learn it from the reply it is already awaiting, not
    /// from an out-of-band push it may not be subscribed for yet.
    async fn reply_for_grant(
        &self,
        peer: NodeId,
        grant: &FlowGrant,
    ) -> Result<FlowStatusReply, DeliveryError> {
        match grant.state {
            FlowGrantState::Active => Ok(FlowStatusReply {
                state: "active".into(),
                receipt: None,
                task_running: self.tasks.is_running(peer, grant),
            }),
            FlowGrantState::Cancelled => Ok(FlowStatusReply {
                state: "cancelled".into(),
                receipt: None,
                task_running: false,
            }),
            FlowGrantState::Completed => {
                let receipt = self.persisted_receipt(grant).await?;
                Ok(FlowStatusReply {
                    state: "completed".into(),
                    receipt: Some(receipt),
                    task_running: false,
                })
            }
        }
    }

    /// NET-06: pause semantics. Interrupts the in-progress native fetch task
    /// for this exact tuple (best-effort — a no-op if nothing is running)
    /// WITHOUT touching the durable grant state, so it stays `active` and
    /// therefore stays in the GC protection set (`active_flow_content_hashes`).
    /// A later `flow.offer` on the same tuple resumes from the retained
    /// partial instead of restarting (`spawn_fetch_task` starts a fresh
    /// attempt; iroh-blobs itself resumes by content hash). Distinct from
    /// `cancel_by_tuple`, which marks the grant `cancelled` and lets the partial fall
    /// out of protection.
    pub async fn suspend(&self, peer: NodeId, tuple: &FlowTupleRef) -> Result<(), DeliveryError> {
        let Some(grant) = self.tuple_grant(peer, tuple).await? else {
            return Err(DeliveryError::GrantNotFound);
        };
        // #1027: a grant that already completed or was cancelled has nothing
        // left to interrupt — idempotent Ok, the stored state is untouched.
        if grant.state != FlowGrantState::Active {
            return Ok(());
        }
        // #1084: answer only once the fetch has really stopped pulling. The
        // store's own import task may still persist the few items already
        // received (iroh-blobs offers no handle to await it) — verified data
        // the resume keeps, never a new network read.
        self.tasks.interrupt(peer, &grant).exited().await;
        Ok(())
    }

    /// #1084: read-only "is a fetch task running for this tuple" — unlike
    /// [`Self::status`], never respawns one. After [`Self::suspend`] returns
    /// this is `false`: suspend waits for the task to end.
    pub async fn task_running(
        &self,
        peer: NodeId,
        tuple: &FlowTupleRef,
    ) -> Result<bool, DeliveryError> {
        Ok(self
            .tuple_grant(peer, tuple)
            .await?
            .is_some_and(|grant| self.tasks.is_running(peer, &grant)))
    }

    /// Looks up the exact grant a [`FlowTupleRef`] names, or `None` if
    /// no grant exists for this (peer, pairing_id, queue_sequence) or if
    /// the stored lease_token no longer matches (a newer offer has already
    /// superseded this exact lease — from the caller's perspective, this
    /// tuple identity is gone).
    async fn tuple_grant(
        &self,
        peer: NodeId,
        tuple: &FlowTupleRef,
    ) -> Result<Option<FlowGrant>, DeliveryError> {
        let Some(stored) = self
            .db
            .flow_grant(&peer.0, &tuple.pairing_id, tuple.queue_sequence as i64)
            .await
            .map_err(storage_error)?
        else {
            return Ok(None);
        };
        if stored.lease_token != tuple.lease_token {
            return Ok(None);
        }
        Ok(Some(stored))
    }

    async fn checked_request(
        &self,
        peer: NodeId,
        request: &FlowFetchRequest,
    ) -> Result<FlowGrant, DeliveryError> {
        if request.queue_sequence > i64::MAX as u64
            || request.pairing_id.is_empty()
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
        let current = self.db.active_pairing(&peer.0).map(|p| p.id);
        if current.as_deref() != Some(request.pairing_id.as_str()) {
            return Err(DeliveryError::PairingMismatch);
        }
        Ok(FlowGrant {
            node_id: peer.0.to_vec(),
            queue_sequence: request.queue_sequence as i64,
            pairing_id: request.pairing_id.clone(),
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
            .flow_grant(&grant.node_id, &grant.pairing_id, grant.queue_sequence)
            .await
            .map_err(storage_error)?
        else {
            return Err(DeliveryError::GrantNotFound);
        };
        // #1076: identity is the tuple. `provider` only says where the bytes
        // come from — a re-offer may replace it while a fetch runs — so it is
        // never compared. The content itself is pinned by `content_hash`.
        if stored.pairing_id != grant.pairing_id
            || stored.lease_token != grant.lease_token
            || stored.content_hash != grant.content_hash
        {
            return Err(DeliveryError::GrantConflict);
        }
        Ok(stored)
    }

    /// The authenticated control peer owns the Flow grant, while Android's
    /// native iroh-blobs provider owns its own endpoint and ticket. A re-offer
    /// may replace the ticket (#1076); whichever one a fetch uses, its hash is
    /// rechecked against the grant's content hash here and iroh-blobs verifies
    /// every byte against that hash, so the provider never decides what
    /// content lands and does not weaken the tuple gate.
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
            return Err(DeliveryError::InvalidRequest(
                "provider ticket names different content".into(),
            ));
        }
        Ok(provider)
    }

    /// #563: [`Self::require_active`] plus "the device still holds this
    /// grant's pairing record". #1117: a deleted pairing record already took
    /// its grants with it (cascade), so `require_active` fails first; the
    /// check below covers a record replaced in between.
    async fn require_authorized(&self, grant: &FlowGrant) -> Result<(), DeliveryError> {
        self.require_active(grant).await?;
        let current = self.db.active_pairing(&grant.node_id).map(|p| p.id);
        if current.as_deref() == Some(grant.pairing_id.as_str()) {
            return Ok(());
        }
        let _ = self
            .db
            .cancel_flow_grant(grant)
            .await
            .map_err(storage_error)?;
        tracing::info!(
            "#563: device no longer authorized, dropping flow item before ingest seq={}",
            grant.queue_sequence
        );
        Err(DeliveryError::Cancelled)
    }

    /// #1117 / #563：`peer` 的配对记录已被删除（`crate::unpair` 唯一入口调用）。
    /// 它的交付记录已随配对记录级联删除；这里收掉内存态：中断它的全部在途拉取
    /// 并等其退出（在途的那张不会进照片库），清掉它的传输路径登记与拉取锁。
    /// 返回中断了几个任务。
    /// #1126: remember that [peer]'s fetch dials [provider].
    fn note_provider_endpoint(&self, peer: NodeId, provider: NodeId) {
        let mut map = self
            .provider_endpoints
            .lock()
            .expect("flow provider endpoints lock");
        let seen = map.entry(peer.0).or_default();
        seen.retain(|p| *p != provider);
        seen.push(provider);
        if seen.len() > PROVIDER_ENDPOINTS_PER_PEER {
            seen.remove(0);
        }
    }

    /// #1126: the provider endpoints [peer]'s fetches dialled, forgotten as they are handed out
    /// (the unpair path closes their connections).
    pub fn take_provider_endpoints(&self, peer: NodeId) -> Vec<NodeId> {
        self.provider_endpoints
            .lock()
            .expect("flow provider endpoints lock")
            .remove(&peer.0)
            .unwrap_or_default()
    }

    pub async fn release_peer(&self, peer: NodeId) -> usize {
        let tasks = self.tasks.interrupt_peer(peer);
        let interrupted = tasks.count();
        tasks.exited().await;
        if self.paths.clear_peer(peer) {
            emit_device_changed(self.events.as_ref());
        }
        self.fetch_locks
            .lock()
            .expect("flow fetch lock registry")
            .remove(&peer.0);
        tracing::info!(
            "#1117: pairing removed, interrupted {interrupted} fetch task(s) peer={peer:?}"
        );
        interrupted
    }

    async fn require_active(&self, grant: &FlowGrant) -> Result<(), DeliveryError> {
        match self.matching_grant(grant).await?.state {
            FlowGrantState::Active => Ok(()),
            FlowGrantState::Cancelled => Err(DeliveryError::Cancelled),
            FlowGrantState::Completed => Err(DeliveryError::GrantNotFound),
        }
    }

    async fn persisted_receipt(
        &self,
        grant: &FlowGrant,
    ) -> Result<FlowCompletionReceipt, DeliveryError> {
        let Some(receipt) = self
            .db
            .flow_receipt(&grant.node_id, &grant.pairing_id, grant.queue_sequence)
            .await
            .map_err(storage_error)?
        else {
            return Err(DeliveryError::Inconsistent(
                "completed grant has no receipt",
            ));
        };
        if receipt.pairing_id != grant.pairing_id
            || receipt.lease_token != grant.lease_token
            || receipt.content_hash != grant.content_hash
        {
            return Err(DeliveryError::Inconsistent(
                "receipt does not match its grant",
            ));
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

    fn fetch_lock(&self, peer: NodeId) -> PeerFetchLock {
        self.fetch_locks
            .lock()
            .expect("flow fetch lock registry")
            .entry(peer.0)
            .or_insert_with(|| Arc::new(AsyncMutex::new(())))
            .clone()
    }

    /// TEL-02 / #949: `conn` — one local stats line per background fetch
    /// attempt, terminal state only (success or the `fetch` failure stage).
    /// `path` is never a raw error string, only `ConnectionStatus::as_str()`'s
    /// fixed vocabulary.
    fn record_conn(&self, path: &'static str, ms: u64, fail_stage: Option<&'static str>) {
        stats::record(stats::Event::Conn {
            path,
            ms,
            fail_stage,
        });
    }

    /// TEL-02 / #949: `flow_item` — one local stats line per successful
    /// background fetch, after the receipt is durable. Never called on a
    /// failed or cancelled request.
    fn record_flow_item(&self, bytes: u64, dur_s: u64, resumed: bool) {
        stats::record(stats::Event::FlowItem {
            bytes,
            dur_s,
            resumed,
        });
    }
}

/// NET-15: rebuild the offer-shaped request from the durable grant so a
/// restart respawn goes through the one existing `spawn_fetch_task` path
/// instead of inventing a second startup path. `capture_at_ms` is not
/// persisted on the grant row; `0` (unknown) is the protocol's documented
/// old-client value, and ingest then falls back EXIF → mtime (see
/// core-index `taken_at_ms`) — the same behavior an old phone build gets.
fn resume_request(grant: &FlowGrant) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: grant.queue_sequence as u64,
        pairing_id: grant.pairing_id.clone(),
        lease_token: grant.lease_token.clone(),
        content_hash: hex::encode(&grant.content_hash),
        file_name: grant.file_name.clone(),
        media_type: grant.media_type.clone(),
        provider: grant.provider.clone(),
        capture_at_ms: 0,
        // Only the offer-time precheck reads it; a respawn is past that.
        size_bytes: 0,
    }
}

fn receipt_from(grant: &FlowGrant, receipt_id: String) -> FlowCompletionReceipt {
    FlowCompletionReceipt {
        queue_sequence: grant.queue_sequence as u64,
        receipt_id,
        pairing_id: grant.pairing_id.clone(),
        lease_token: grant.lease_token.clone(),
        content_hash: hex::encode(&grant.content_hash),
    }
}

/// #1070: core-index names a supersede refusal with a `&'static str`; the
/// wire carries the registered [`SupersedeRefusal`]. Every string core-index
/// returns is registered (pinned by `every_core_index_refusal_is_registered`);
/// an unregistered one is a bug, logged and answered as `bad_request` —
/// either way nothing changed on disk.
fn supersede_refusal(reason: &str) -> SupersedeRefusal {
    SupersedeRefusal::from_wire(reason).unwrap_or_else(|| {
        tracing::error!("#1070: unregistered supersede refusal {reason:?}");
        SupersedeRefusal::BadRequest
    })
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

/// #413 §7 / #763 `library_writable` for `peer`: every folder this phone's
/// next photo depends on accepts a file.
///
/// 1. The library itself ([`library_probe`]: `.ppf/` or the root).
/// 2. The phone's device folder `originals/<device>` — the parent of every
///    month folder a new photo may need to create ([`dir_accepts`]).
/// 3. Every landing folder of this phone where a real ingest failed
///    (`failures`); one that accepts a file again is forgotten.
///
/// A month folder that refuses writes while its parent does not is only
/// learned from the first failed photo — which month the next photo needs is
/// not known here.
///
/// Probe files under `originals/` are dot-files, created and removed at once:
/// the watcher and the reconcile scan skip hidden paths
/// (`watcher.rs` `affected_dirs` / `walk_media`, `rebuild.rs`), so a probe
/// on every hello (as often as every 30 s while the phone app is open) costs
/// no sync work. Nothing else is ever created: a missing folder is probed at
/// its nearest existing ancestor, never made.
///
/// 盘满时探针建不了文件——bool 视图如实报 false（此时确实建不了）；
/// 「这是盘满还是文件夹坏了」的三态裁决在 [`library_probe`]。
fn landing_writable(
    root: &Path,
    peer: &NodeId,
    failures: &Mutex<std::collections::HashSet<PathBuf>>,
) -> bool {
    if library_probe(root) != LibraryProbe::Writable {
        return false;
    }
    let device = root.join("originals").join(device_dir(&peer.0));
    if dir_accepts(root, &device) != LibraryProbe::Writable {
        return false;
    }
    let mut failures = failures.lock().unwrap_or_else(|e| e.into_inner());
    let mine: Vec<PathBuf> = failures
        .iter()
        .filter(|dir| dir.starts_with(&device))
        .cloned()
        .collect();
    let mut writable = true;
    for dir in mine {
        if dir_accepts(root, &dir) == LibraryProbe::Writable {
            tracing::info!(dir = %dir.display(), "flow: landing folder accepts files again");
            failures.remove(&dir);
        } else {
            writable = false;
        }
    }
    writable
}

/// #763: the landing folder (`originals/<device>/<yyyy>/<mm>`, the layout
/// `Ingestor::place` writes) a failed ingest path belongs to. `None` for a
/// path outside `originals/` or shallower than a month folder.
fn landing_dir_of(root: &Path, path: &Path) -> Option<PathBuf> {
    let originals = root.join("originals");
    let rel = path.strip_prefix(&originals).ok()?;
    let parts: Vec<_> = rel.components().take(3).collect();
    if parts.len() < 3 {
        return None;
    }
    Some(parts.iter().fold(originals, |dir, part| dir.join(part)))
}

/// #763: could a file be created in `dir` (inside `root`) the way
/// `Ingestor::place` does — `create_dir_all` then create a file? Probed
/// without creating any folder: walk up to the nearest existing ancestor; it
/// must be a folder that accepts a file. A plain file in the way is
/// [`LibraryProbe::Unavailable`].
fn dir_accepts(root: &Path, dir: &Path) -> LibraryProbe {
    let mut nearest = dir;
    while !nearest.exists() {
        match nearest.parent() {
            Some(parent) if parent.starts_with(root) => nearest = parent,
            _ => return LibraryProbe::Unavailable,
        }
    }
    if !nearest.is_dir() {
        return LibraryProbe::Unavailable;
    }
    write_probe(nearest)
}

/// #555：库目录写入探针的三态裁决。「文件夹打不开」与「盘满了」不是一回事——
/// 磁盘满时探针以 ENOSPC / 配额失败，此前一律归 false（不可用），手机据此报
/// 「存储电脑照片库文件夹无法打开」（错误归因；2026-09-30 真机实录：Mac 剩
/// 约 200MB，261KB 截图被报成文件夹打不开）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryProbe {
    /// 文件夹存在且能建文件。
    Writable,
    /// 文件夹在，但探针因空间耗尽失败——归为空间不足，不是不可用。
    Full,
    /// 文件夹不存在或不可写。
    Unavailable,
}

fn library_probe(root: &Path) -> LibraryProbe {
    if !root.is_dir() {
        return LibraryProbe::Unavailable;
    }
    let internal = root.join(".ppf");
    let dir = if internal.is_dir() {
        internal
    } else {
        root.to_path_buf()
    };
    write_probe(&dir)
}

/// Create and remove one hidden probe file in `dir`.
fn write_probe(dir: &Path) -> LibraryProbe {
    static PROBE_SEQ: AtomicU64 = AtomicU64::new(0);
    let probe = dir.join(format!(
        ".write-probe-{}-{}",
        std::process::id(),
        PROBE_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
    {
        Ok(file) => {
            drop(file);
            let _ = std::fs::remove_file(&probe);
            LibraryProbe::Writable
        }
        Err(e) => probe_failure_verdict(e.kind()),
    }
}

/// #555：探针失败的归类（纯函数）：ENOSPC / 配额 = 盘满，其余 = 不可用。
/// 反证：去掉 StorageFull|QuotaExceeded 那一支，#555 的两条断言变红。
pub fn probe_failure_verdict(kind: ErrorKind) -> LibraryProbe {
    match kind {
        ErrorKind::StorageFull | ErrorKind::QuotaExceeded => LibraryProbe::Full,
        _ => LibraryProbe::Unavailable,
    }
}

/// Same volume query as `status.disk_free_bytes` (T-090 / DAE-05):
/// `statvfs` `f_bavail` semantics, `None` where the platform cannot answer.
fn platform_free_bytes(path: &Path) -> Option<u64> {
    use platform::PlatformAdapter as _;
    platform::adapter().volume_stats(path).map(|v| v.free)
}

fn unix_ms_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn storage_error(error: storage::StorageError) -> DeliveryError {
    DeliveryError::Storage(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #1070: every refusal string core-index can return is a registered
    /// `SupersedeRefusal` (scanned from its source, so a new one fails here).
    #[test]
    fn every_core_index_refusal_is_registered() {
        let src = include_str!("../../core-index/src/supersede.rs");
        let mut seen = 0;
        for line in src.lines() {
            for marker in ["Refused(\"", "Err(\""] {
                if let Some(at) = line.find(marker) {
                    let rest = &line[at + marker.len()..];
                    let name = &rest[..rest.find('"').unwrap()];
                    assert!(
                        SupersedeRefusal::from_wire(name).is_some(),
                        "core-index refusal {name:?} is not registered"
                    );
                    seen += 1;
                }
            }
        }
        assert!(seen >= 9, "scanner found only {seen} refusals");
        assert_eq!(
            supersede_refusal("not_a_redaction"),
            SupersedeRefusal::NotARedaction
        );
        assert_eq!(
            supersede_refusal("never_registered"),
            SupersedeRefusal::BadRequest
        );
    }

    /// #1070: each DeliveryError names one registered reason.
    #[test]
    fn delivery_errors_map_to_registered_reasons() {
        let cases = [
            (DeliveryError::PairingMismatch, Reason::PairingMismatch),
            (DeliveryError::GrantNotFound, Reason::GrantNotFound),
            (DeliveryError::GrantConflict, Reason::GrantConflict),
            (DeliveryError::Cancelled, Reason::Cancelled),
            (
                DeliveryError::InvalidRequest("x".into()),
                Reason::BadRequest,
            ),
            (DeliveryError::Fetch("x".into()), Reason::FetchFailed),
            (DeliveryError::Inconsistent("x"), Reason::Internal),
            (DeliveryError::Storage("x".into()), Reason::StorageFailed),
            (
                DeliveryError::InsufficientSpace { needed: 2, free: 1 },
                Reason::StorageFull,
            ),
            (
                DeliveryError::LibraryUnavailable("x".into()),
                Reason::LibraryUnavailable,
            ),
            (
                DeliveryError::MaterializeIngest {
                    failure: PeerFailure::StorageFull,
                    detail: "x".into(),
                },
                Reason::StorageFull,
            ),
        ];
        for (error, reason) in cases {
            assert_eq!(error.wire_code(), reason, "{error}");
        }
    }
}
