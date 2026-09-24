//! Android JNI bridge for a one-lease iroh-blobs provider.
//!
//! A provider owns one endpoint for its whole lifetime. Registrations add their
//! current source to the same private store; revocation only stops the active
//! fetch, leaving the endpoint alive until the provider is closed so daemon
//! connection reuse survives one-item Flow deliveries.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs::{File, Metadata};
use std::io::{Read, Seek, SeekFrom};
#[cfg(feature = "android-jni")]
use std::os::fd::{FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(feature = "android-jni")]
use std::sync::OnceLock;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use iroh::endpoint::Connection;
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh_blobs::api::blobs::{AddPathOptions, BlobStatus, ImportMode};
use iroh_blobs::api::TempTag;
use iroh_blobs::provider::events::{
    EventMask, EventSender, ProviderMessage, RequestMode, RequestUpdate,
};
use iroh_blobs::store::fs::options::Options;
use iroh_blobs::store::fs::FsStore;
use iroh_blobs::store::GcConfig;
use iroh_blobs::ticket::BlobTicket;
use iroh_blobs::{BlobFormat, BlobsProtocol, Hash};
#[cfg(feature = "android-jni")]
use jni::objects::{JClass, JString};
#[cfg(feature = "android-jni")]
use jni::sys::{jint, jlong, jstring};
#[cfg(feature = "android-jni")]
use jni::JNIEnv;

use crate::{IrohTransport, Result, TransportConfig, TransportError, ALPN_BLOBS};

/// A process-local provider that exposes the current Flow item over one
/// long-lived iroh endpoint. The returned ticket is the only network
/// capability handed to the desktop.
///
/// BLOB-03: the store is opened with periodic GC. Imports complete without a
/// named tag — the only thing keeping the active lease's blob alive between a
/// register and its revoke is the [`TempTag`] held in [`ActiveProvider`]. The
/// tag is dropped when the lease is revoked, so a validated completion receipt
/// (or a pause/cancel) releases the blob to the next 60s GC pass while a
/// still-active lease stays protected through any number of GC cycles.
pub struct AndroidBlobsProvider {
    runtime: tokio::runtime::Runtime,
    store: FsStore,
    transport: IrohTransport,
    config: TransportConfig,
    _router: Router,
    dispatch: Arc<Mutex<Option<StopAwareBlobsProtocol>>>,
    active: Mutex<Option<ActiveProvider>>,
    /// #413 §3: contents imported by [`Self::import_media`] and not yet
    /// released. The TempTag in each entry is the only thing keeping that
    /// content alive from import through serve until [`Self::release`].
    imports: Mutex<HashMap<Hash, HeldImport>>,
    /// What this process knows about where each hash's data lives in the
    /// store — see [`StoredAs`] for why this exists.
    stored: Mutex<HashMap<Hash, StoredAs>>,
    /// Imports run one at a time: the "was this hash already in the store"
    /// snapshot taken before a reference import must not race another import.
    import_lock: Mutex<()>,
}

struct ActiveProvider {
    handler: StopAwareBlobsProtocol,
    /// Legacy `register_*` path: the tag of the blob served by this lease.
    retained: Option<TempTag>,
    /// #413: the imported hash this lease serves (its tag lives in
    /// `AndroidBlobsProvider::imports`).
    served: Option<Hash>,
}

impl ActiveProvider {
    fn revoke(self) {
        self.handler.stop_active_fetch();
        // `retained` drops here, releasing its temp tag so the served blob
        // becomes eligible for the store's periodic GC.
    }
}

/// The endpoint's router is permanent, while each Flow item swaps the backing
/// handler only after the prior lease has been explicitly revoked.
#[derive(Clone, Debug)]
struct ActiveBlobsDispatch {
    handler: Arc<Mutex<Option<StopAwareBlobsProtocol>>>,
}

impl ProtocolHandler for ActiveBlobsDispatch {
    async fn accept(&self, connection: Connection) -> std::result::Result<(), AcceptError> {
        let handler = self
            .handler
            .lock()
            .expect("Android provider dispatch lock")
            .clone();
        match handler {
            Some(handler) => handler.accept(connection).await,
            None => {
                connection.close(0u32.into(), b"provider revoked");
                Ok(())
            }
        }
    }

    async fn shutdown(&self) {
        let handler = self
            .handler
            .lock()
            .expect("Android provider dispatch lock")
            .clone();
        if let Some(handler) = handler {
            handler.shutdown().await;
        }
    }
}

/// Local ground truth for "is anyone actually pulling bytes right now, and
/// did the last one finish or die". NET-14: the phone must never treat
/// "desktop hasn't answered yet" as equivalent to "nothing is happening" —
/// this comes from iroh-blobs' own provider events (get/notify), not a
/// derived guess, so a slow-but-alive relay transfer is never mistaken for a
/// stalled one.
#[derive(Debug, Default)]
struct ActivityState {
    last_progress_at: Option<Instant>,
    completed_hash: Option<Hash>,
    aborted_hash: Option<Hash>,
    /// #417 (#410 参数): the furthest `RequestUpdate::Progress.end_offset` seen
    /// for this lease — i.e. how many file bytes the peer has pulled.
    bytes_sent: Option<u64>,
    /// When [`Self::bytes_sent`] last moved FORWARD. Only file-byte progress
    /// refreshes this; connection-level events (ClientConnected,
    /// GetRequestReceived, Started) deliberately do not, so a peer that keeps
    /// a connection open without pulling bytes shows up as a byte stall.
    last_byte_at: Option<Instant>,
}

#[derive(Clone, Debug, Default)]
struct TransferActivity(Arc<Mutex<ActivityState>>);

impl TransferActivity {
    fn touch(&self) {
        self.0
            .lock()
            .expect("transfer activity lock")
            .last_progress_at = Some(Instant::now());
    }

    /// #417: record a file-byte progress event. Only a strictly larger
    /// `end_offset` counts as progress (a repeated or smaller offset — e.g. a
    /// resumed request re-reporting an earlier range — is not new bytes).
    fn record_bytes(&self, end_offset: u64) {
        let mut state = self.0.lock().expect("transfer activity lock");
        state.last_progress_at = Some(Instant::now());
        if state.bytes_sent.is_none_or(|sent| end_offset > sent) {
            state.bytes_sent = Some(end_offset);
            state.last_byte_at = Some(Instant::now());
        }
    }

    /// `(bytes pulled so far, time since that number last grew)`; `None`
    /// before the first byte-progress event of this lease.
    fn byte_progress(&self) -> Option<(u64, Duration)> {
        let state = self.0.lock().expect("transfer activity lock");
        match (state.bytes_sent, state.last_byte_at) {
            (Some(sent), Some(at)) => Some((sent, at.elapsed())),
            _ => None,
        }
    }

    /// #417: a new registration on the same (kept-alive) handler starts a new
    /// lease. Without this, item N+1 would inherit item N's `completed_hash`
    /// (status stuck at `Completed{previous}`) and its final `bytes_sent`
    /// (a false byte stall until the new file passes the old offset).
    fn reset(&self) {
        *self.0.lock().expect("transfer activity lock") = ActivityState::default();
    }

    fn mark_completed(&self, hash: Hash) {
        let mut state = self.0.lock().expect("transfer activity lock");
        state.completed_hash = Some(hash);
        state.last_progress_at = Some(Instant::now());
    }

    fn mark_aborted(&self, hash: Hash) {
        let mut state = self.0.lock().expect("transfer activity lock");
        state.aborted_hash = Some(hash);
        state.last_progress_at = Some(Instant::now());
    }

    /// How long since the last progress signal (started/progress/completed/
    /// aborted) for the current handler's lifetime. `None` = never any
    /// activity yet (nobody has connected to pull anything).
    fn idle_for(&self) -> Option<Duration> {
        self.0
            .lock()
            .expect("transfer activity lock")
            .last_progress_at
            .map(|at| at.elapsed())
    }

    /// Non-consuming read: has the peer's pull for this lease completed.
    /// Deliberately not "take" — [`StopAwareBlobsProtocol::status`] is a
    /// read-only query the caller may poll any number of times, and every
    /// call must see the same terminal fact until the lease itself is
    /// replaced (a fresh handler gets a fresh `TransferActivity`).
    fn completed_hash(&self) -> Option<Hash> {
        self.0
            .lock()
            .expect("transfer activity lock")
            .completed_hash
    }

    /// Non-consuming read, mirrors [`Self::completed_hash`].
    fn aborted_hash(&self) -> Option<Hash> {
        self.0.lock().expect("transfer activity lock").aborted_hash
    }
}

/// The caller-facing summary of [`TransferActivity`] + the connection table,
/// read together under `AndroidBlobsProvider::active`'s lock so the two
/// never observe inconsistent halves of the same instant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActiveTransferStatus {
    /// No lease is currently registered — nothing to report on.
    NoLease,
    /// The peer's pull for the current lease's hash completed.
    Completed { hash: [u8; 32] },
    /// iroh-blobs itself aborted the peer's request (rate limit/permission —
    /// see `AbortReason`), not a network condition.
    Aborted { hash: [u8; 32] },
    /// Still open: nobody has completed or been aborted yet.
    InProgress {
        /// At least one QUIC connection is currently accepted for this
        /// lease's ALPN (does not by itself prove bytes are moving, but
        /// rules out "nobody is even attempting to connect").
        connected: bool,
        /// Time since the last iroh-blobs get-request/progress/completed/
        /// aborted event, if any has ever fired for this lease.
        idle_for: Option<Duration>,
        /// #417: file bytes the peer has pulled so far (furthest
        /// `Progress.end_offset`); `None` before any byte moved.
        bytes_sent: Option<u64>,
        /// #417: time since [`Self::InProgress::bytes_sent`] last grew;
        /// connection events never reset it. `None` before any byte moved.
        byte_idle_for: Option<Duration>,
    },
}

/// Wire shape for [`ActiveTransferStatus`] over the JNI boundary — the
/// same `state`/`hash`/`connected`/`idle_for_ms` field vocabulary the
/// daemon's own `FlowStatusReply` uses for the analogous cross-process
/// concept. Built directly as a `serde_json::Value` (this crate depends
/// on `serde_json` alone, not `serde` — adding it just for one derive
/// pulled in a dependency-tree reresolution that broke iroh-blobs'
/// pinned `irpc` version; see NET-14 card notes).
///
/// BUILD-06: 闸门写成「存在即被使用」。唯一的非测试调用方是
/// `nativeTransferStatus` 那个 JNI 导出（`#[cfg(feature = "android-jni")]`），
/// 所以 feature 关闭时 lib target 里它没有调用方 ⇒ `-D warnings` 下的
/// `dead_code` 直接变 error（`--all-targets` 里的 test target 算不上调用方，
/// 两个 target 是分开编的）。加 `test` 是为了让 `wire_status_tests` 在默认
/// feature 下仍然跑得到——不用 `#[allow(dead_code)]` 把问题盖住。
#[cfg(any(feature = "android-jni", test))]
impl ActiveTransferStatus {
    fn to_wire(&self) -> serde_json::Value {
        match self {
            ActiveTransferStatus::NoLease => serde_json::json!({ "state": "no_lease" }),
            ActiveTransferStatus::Completed { hash } => serde_json::json!({
                "state": "completed",
                "hash": hex_of(hash),
            }),
            ActiveTransferStatus::Aborted { hash } => serde_json::json!({
                "state": "aborted",
                "hash": hex_of(hash),
            }),
            ActiveTransferStatus::InProgress {
                connected,
                idle_for,
                bytes_sent,
                byte_idle_for,
            } => serde_json::json!({
                "state": "in_progress",
                "connected": connected,
                "idle_for_ms": idle_for.map(|d| d.as_millis() as u64),
                "bytes_sent": bytes_sent,
                "byte_idle_for_ms": byte_idle_for.map(|d| d.as_millis() as u64),
            }),
        }
    }
}

// BUILD-06: 闸门同 to_wire——它只被 to_wire 调用，跟着一起存在或一起消失。
#[cfg(any(feature = "android-jni", test))]
fn hex_of(bytes: &[u8; 32]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod wire_status_tests {
    use super::*;

    #[test]
    fn no_lease_has_only_a_state_field() {
        assert_eq!(
            ActiveTransferStatus::NoLease.to_wire(),
            serde_json::json!({ "state": "no_lease" }),
        );
    }

    #[test]
    fn completed_carries_lowercase_hex_hash() {
        let hash = [0xabu8; 32];
        let wire = ActiveTransferStatus::Completed { hash }.to_wire();
        assert_eq!(wire["state"], "completed");
        assert_eq!(wire["hash"], "ab".repeat(32));
    }

    #[test]
    fn in_progress_reports_connected_and_idle_ms() {
        let wire = ActiveTransferStatus::InProgress {
            connected: true,
            idle_for: Some(Duration::from_millis(1234)),
            bytes_sent: Some(4096),
            byte_idle_for: Some(Duration::from_millis(180_000)),
        }
        .to_wire();
        assert_eq!(wire["state"], "in_progress");
        assert_eq!(wire["connected"], true);
        assert_eq!(wire["idle_for_ms"], 1234);
        assert_eq!(wire["bytes_sent"], 4096);
        assert_eq!(wire["byte_idle_for_ms"], 180_000);
    }

    #[test]
    fn in_progress_with_no_activity_yet_reports_null_idle() {
        let wire = ActiveTransferStatus::InProgress {
            connected: false,
            idle_for: None,
            bytes_sent: None,
            byte_idle_for: None,
        }
        .to_wire();
        assert_eq!(wire["connected"], false);
        assert!(wire["idle_for_ms"].is_null());
        assert!(wire["bytes_sent"].is_null());
        assert!(wire["byte_idle_for_ms"].is_null());
    }
}

/// Wraps iroh-blobs' protocol handler to retain/close active QUIC
/// connections and to record [`TransferActivity`] from iroh-blobs' own
/// provider events (NET-14: local ground truth, not a derived guess). The
/// blob wire protocol itself remains entirely upstream iroh-blobs; no chunk
/// or offset protocol is introduced here.
#[derive(Debug, Clone)]
struct StopAwareBlobsProtocol {
    inner: BlobsProtocol,
    accepting: Arc<AtomicBool>,
    next_connection: Arc<AtomicU64>,
    active: Arc<Mutex<HashMap<u64, Connection>>>,
    activity: TransferActivity,
}

impl StopAwareBlobsProtocol {
    fn new(store: &FsStore) -> Self {
        let activity = TransferActivity::default();
        let events = spawn_activity_event_sink(activity.clone());
        Self {
            inner: BlobsProtocol::new(store, Some(events)),
            accepting: Arc::new(AtomicBool::new(true)),
            next_connection: Arc::new(AtomicU64::new(1)),
            active: Arc::default(),
            activity,
        }
    }

    fn stop_active_fetch(&self) {
        self.accepting.store(false, Ordering::SeqCst);
        let connections = {
            let mut active = self
                .active
                .lock()
                .expect("active provider connections lock");
            std::mem::take(&mut *active)
        };
        for (_, connection) in connections {
            connection.close(0u32.into(), b"provider revoked");
        }
    }

    /// NET-14: the local, iroh-blobs-sourced fact for "what is happening to
    /// this exact lease's blob right now" — never derived from whether a
    /// remote peer has answered anything.
    fn status(&self) -> ActiveTransferStatus {
        if let Some(hash) = self.activity.completed_hash() {
            return ActiveTransferStatus::Completed {
                hash: *hash.as_bytes(),
            };
        }
        if let Some(hash) = self.activity.aborted_hash() {
            return ActiveTransferStatus::Aborted {
                hash: *hash.as_bytes(),
            };
        }
        let connected = !self
            .active
            .lock()
            .expect("active provider connections lock")
            .is_empty();
        let bytes = self.activity.byte_progress();
        ActiveTransferStatus::InProgress {
            connected,
            idle_for: self.activity.idle_for(),
            bytes_sent: bytes.map(|(sent, _)| sent),
            byte_idle_for: bytes.map(|(_, idle)| idle),
        }
    }
}

/// Builds the event channel iroh-blobs pushes `Notify` provider events
/// into, and spawns the task that turns them into [`TransferActivity`].
/// Deliberately uses the `Notify` request modes, not `Intercept` — the
/// transfer must never wait on this task's scheduling to proceed; this is
/// pure observation, not a permission gate (AGENTS.md 设计纪律 4: iroh 事实
/// 以库事件为唯一来源，这里就是把库已经在发、此前被 `None` 关掉的事件接上，
/// 不是发明新协议).
fn spawn_activity_event_sink(activity: TransferActivity) -> EventSender {
    let mask = EventMask {
        connected: iroh_blobs::provider::events::ConnectMode::Notify,
        get: RequestMode::NotifyLog,
        get_many: RequestMode::None,
        push: RequestMode::Disabled,
        observe: iroh_blobs::provider::events::ObserveMode::None,
        throttle: iroh_blobs::provider::events::ThrottleMode::None,
    };
    let (tx, mut rx) = EventSender::channel(64, mask);
    tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            match message {
                ProviderMessage::ClientConnectedNotify(_) => activity.touch(),
                ProviderMessage::GetRequestReceivedNotify(msg) => {
                    activity.touch();
                    // Inlined (not a separate typed fn): the update
                    // receiver's concrete type is irpc's, and this crate
                    // deliberately does not take irpc as a direct
                    // dependency — inference through `msg.rx` avoids
                    // spelling that type out, which is what triggered a
                    // transitive re-resolve incompatible with the pinned
                    // iroh-blobs 0.103.0 build (2026-09-16, NET-14).
                    let activity = activity.clone();
                    let mut updates = msg.rx;
                    tokio::spawn(async move {
                        let mut current_hash: Option<Hash> = None;
                        while let Ok(Some(update)) = updates.recv().await {
                            match update {
                                RequestUpdate::Started(started) => {
                                    current_hash = Some(started.hash);
                                    activity.touch();
                                }
                                // #417: only file-byte progress feeds the byte-stall
                                // clock (connection events above never do).
                                RequestUpdate::Progress(progress) => {
                                    activity.record_bytes(progress.end_offset)
                                }
                                RequestUpdate::Completed(_) => match current_hash {
                                    Some(hash) => activity.mark_completed(hash),
                                    None => activity.touch(),
                                },
                                RequestUpdate::Aborted(_) => match current_hash {
                                    Some(hash) => activity.mark_aborted(hash),
                                    None => activity.touch(),
                                },
                            }
                        }
                    });
                }
                _ => {}
            }
        }
    });
    tx
}

impl ProtocolHandler for StopAwareBlobsProtocol {
    async fn accept(&self, connection: Connection) -> std::result::Result<(), AcceptError> {
        if !self.accepting.load(Ordering::SeqCst) {
            connection.close(0u32.into(), b"provider revoked");
            return Ok(());
        }

        let id = self.next_connection.fetch_add(1, Ordering::Relaxed);
        self.active
            .lock()
            .expect("active provider connections lock")
            .insert(id, connection.clone());
        if !self.accepting.load(Ordering::SeqCst) {
            connection.close(0u32.into(), b"provider revoked");
        }
        let result = self.inner.accept(connection).await;
        self.active
            .lock()
            .expect("active provider connections lock")
            .remove(&id);
        result
    }

    async fn shutdown(&self) {
        self.stop_active_fetch();
        self.inner.shutdown().await;
    }
}

impl AndroidBlobsProvider {
    pub fn new(root: impl AsRef<Path>) -> Result<Self> {
        Self::with_config(
            root,
            TransportConfig::from_endpoints(Vec::new(), vec![ALPN_BLOBS.to_owned()]),
            Some(Duration::from_secs(60)),
        )
    }

    /// Loopback-only constructor for native-provider protocol verification.
    pub fn new_loopback(root: impl AsRef<Path>) -> Result<Self> {
        Self::with_config(
            root,
            TransportConfig::loopback(vec![ALPN_BLOBS.to_owned()]),
            None,
        )
    }

    /// Loopback constructor with an injected GC interval, for BLOB-03 tests
    /// that need to observe reclamation without waiting the production 60s.
    pub fn new_loopback_with_gc(root: impl AsRef<Path>, gc_interval: Duration) -> Result<Self> {
        Self::with_config(
            root,
            TransportConfig::loopback(vec![ALPN_BLOBS.to_owned()]),
            Some(gc_interval),
        )
    }

    fn with_config(
        root: impl AsRef<Path>,
        config: TransportConfig,
        gc_interval: Option<Duration>,
    ) -> Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|error| {
                TransportError::Io(format!("start Android provider runtime: {error}"))
            })?;
        let root = root.as_ref().join("iroh-blobs-provider");
        let dispatch: Arc<Mutex<Option<StopAwareBlobsProtocol>>> = Arc::default();
        let (store, transport, router) = runtime.block_on(async {
            let mut options = Options::new(&root);
            if let Some(interval) = gc_interval {
                options.gc = Some(GcConfig {
                    interval,
                    add_protected: None,
                });
            }
            let store = FsStore::load_with_opts(root.join("blobs.db"), options)
                .await
                .map_err(|error| {
                    TransportError::Io(format!("open Android provider store {root:?}: {error}"))
                })?;
            // BLOB-03 migration: versions before this card used the default
            // `AddProgress` await, which creates a persistent named tag for
            // every source blob. This store is dedicated to the Android
            // provider, and a fresh process has no active Flow lease, so all
            // named tags here are stale provider retention. Remove them before
            // serving anything; the following GC pass reclaims their payloads.
            // Current registrations use TempTag exclusively, so this is
            // idempotent and never clears an active source.
            let removed = store.tags().delete_all().await.map_err(|error| {
                TransportError::Io(format!("clear legacy Android provider tags: {error}"))
            })?;
            if removed > 0 {
                tracing::info!("BLOB-03: released {removed} legacy Android provider blob tags");
            }
            let transport = IrohTransport::bind(config.clone()).await?;
            let router = Router::builder(transport.endpoint().clone())
                .accept(
                    ALPN_BLOBS.as_bytes(),
                    ActiveBlobsDispatch {
                        handler: Arc::clone(&dispatch),
                    },
                )
                .spawn();
            Ok::<_, TransportError>((store, transport, router))
        })?;
        Ok(Self {
            runtime,
            store,
            transport,
            config,
            _router: router,
            dispatch,
            active: Mutex::default(),
            imports: Mutex::default(),
            stored: Mutex::default(),
            import_lock: Mutex::default(),
        })
    }

    /// Imports [path] under [declared_hash] into the provider's persistent
    /// store and returns a ticket for its long-lived endpoint.
    pub fn register_path(&self, declared_hash: [u8; 32], path: &Path) -> Result<String> {
        self.runtime
            .block_on(self.register_path_async(declared_hash, path))
    }

    /// Imports an Android ParcelFileDescriptor without relying on a filesystem
    /// path. The caller retains ownership of [fd]; this method duplicates it and
    /// completes the import before returning.
    #[cfg(feature = "android-jni")]
    fn register_fd(&self, declared_hash: [u8; 32], fd: RawFd) -> Result<String> {
        let source = duplicate_fd(fd)?;
        self.runtime
            .block_on(self.register_file_async(declared_hash, source))
    }

    pub fn stop_active_fetch(&self) {
        if let Some(active) = self.active.lock().expect("active provider lock").as_ref() {
            active.handler.stop_active_fetch();
        }
    }

    /// Stops the active fetch without discarding the provider endpoint. A later
    /// registration creates a fresh handler on the same endpoint and preserves
    /// receiver-side partials.
    ///
    /// #413: also drops every held import (pause / unpair end the round; the
    /// next round re-imports before serving).
    pub fn revoke(&self) {
        let active = self.active.lock().expect("active provider lock").take();
        *self
            .dispatch
            .lock()
            .expect("Android provider dispatch lock") = None;
        if let Some(active) = active {
            active.revoke();
        }
        let held = std::mem::take(&mut *self.imports.lock().expect("held imports lock"));
        drop(held);
    }

    /// BLOB-03: release provider retention of the current lease's blob WITHOUT
    /// stopping the handler or discarding the endpoint. This is the success
    /// boundary — a validated completion receipt means the daemon has the
    /// original, so the source copy may be GC'd. The endpoint and its ALPN
    /// handler stay alive (decision 5: connection reuse across serial items is
    /// intact); only the `TempTag` keeping the blob alive is dropped.
    pub fn release_retention(&self) {
        let served = match self.active.lock().expect("active provider lock").as_mut() {
            Some(active) => {
                active.retained = None;
                active.served.take()
            }
            None => None,
        };
        if let Some(hash) = served {
            let held = self
                .imports
                .lock()
                .expect("held imports lock")
                .remove(&hash);
            drop(held);
        }
    }

    pub fn is_active(&self) -> bool {
        self.active.lock().expect("active provider lock").is_some()
    }

    /// NET-14: local ground truth for "what is happening to the current
    /// lease's transfer right now" — sourced from iroh-blobs' own provider
    /// events plus the live connection table, never from asking the remote
    /// peer. Callers (the Android delivery loop) use this to decide whether
    /// a stalled-looking `flow.status` round trip is actually still fine
    /// (the local connection is alive and moving) or genuinely abandoned.
    pub fn transfer_status(&self) -> ActiveTransferStatus {
        match self.active.lock().expect("active provider lock").as_ref() {
            Some(active) => active.handler.status(),
            None => ActiveTransferStatus::NoLease,
        }
    }

    /// #417 (#410): `(file bytes pulled, time since that last grew)` for the
    /// current lease, independent of whether the pull has since completed.
    pub fn byte_progress(&self) -> Option<(u64, Duration)> {
        self.active
            .lock()
            .expect("active provider lock")
            .as_ref()
            .and_then(|active| active.handler.activity.byte_progress())
    }

    /// #417: tell iroh the OS network changed (Android `ConnectivityManager`
    /// callback), so it re-probes paths instead of waiting for its own timers.
    pub fn network_change(&self) {
        self.runtime
            .block_on(self.transport.endpoint().network_change());
    }

    /// BLOB-03 test hook: whether a complete blob is still present in the
    /// provider store (a named tag or an un-released TempTag keeps it there;
    /// periodic GC removes it once the lease's TempTag is dropped).
    pub fn has_blob(&self, hash: [u8; 32]) -> bool {
        self.runtime
            .block_on(self.store.blobs().has(Hash::from_bytes(hash)))
            .unwrap_or(false)
    }

    /// Async variant of [`Self::has_blob`], callable from inside a tokio test
    /// runtime (where `has_blob`'s nested `block_on` would panic).
    pub async fn has_blob_async(&self, hash: [u8; 32]) -> bool {
        self.store
            .blobs()
            .has(Hash::from_bytes(hash))
            .await
            .unwrap_or(false)
    }

    async fn register_path_async(&self, declared_hash: [u8; 32], path: &Path) -> Result<String> {
        // BLOB-03: import with `temp_tag` (ephemeral liveness), never a named
        // tag. The TempTag is carried into the active lease and dropped on
        // revoke, so once the lease is released the blob is reclaimable by the
        // store's periodic GC instead of lingering forever under a named tag.
        let tag = self
            .store
            .blobs()
            .add_path(path)
            .temp_tag()
            .await
            .map_err(|error| {
                TransportError::Io(format!("import Android provider path {path:?}: {error}"))
            })?;
        self.activate(declared_hash, tag).await
    }

    #[cfg(feature = "android-jni")]
    async fn register_file_async(&self, declared_hash: [u8; 32], source: File) -> Result<String> {
        // #413 §3: 1 MiB reads (the 4 KiB default was ~2.5x slower).
        let stream = tokio_util::io::ReaderStream::with_capacity(
            tokio::fs::File::from_std(source),
            COPY_READ_BUFFER,
        );
        let tag = self
            .store
            .blobs()
            .add_stream(stream)
            .await
            .temp_tag()
            .await
            .map_err(|error| {
                TransportError::Io(format!("import Android provider descriptor: {error}"))
            })?;
        self.activate(declared_hash, tag).await
    }

    fn ensure_active_handler(&self) {
        if self.active.lock().expect("active provider lock").is_some() {
            return;
        }
        let handler = StopAwareBlobsProtocol::new(&self.store);
        *self
            .dispatch
            .lock()
            .expect("Android provider dispatch lock") = Some(handler.clone());
        *self.active.lock().expect("active provider lock") = Some(ActiveProvider {
            handler,
            retained: None,
            served: None,
        });
    }

    async fn activate(&self, declared_hash: [u8; 32], tag: TempTag) -> Result<String> {
        let imported_hash = tag.hash();
        if imported_hash != Hash::from_bytes(declared_hash) {
            return Err(TransportError::Io(
                "Android provider source does not match its declared content hash".into(),
            ));
        }

        if self.config.n0_services
            && !self
                .transport
                .wait_online(std::time::Duration::from_secs(15))
                .await
        {
            return Err(TransportError::Io(
                "Android provider endpoint did not become online before ticket registration".into(),
            ));
        }

        self.ensure_active_handler();
        if let Some(active) = self.active.lock().expect("active provider lock").as_ref() {
            active.handler.activity.reset();
        }
        // BLOB-03: retain only the current lease's blob. A later register (in
        // the real Flow every strict-head advance is preceded by a revoke that
        // drops this tag, but the loopback tests register back-to-back) drops
        // the previous lease's tag, so it becomes reclaimable at the next GC.
        let mut active = self.active.lock().expect("active provider lock");
        let active = active
            .as_mut()
            .expect("ensure_active_handler installed an active provider");
        active.retained = Some(tag);
        active.served = None;
        Ok(BlobTicket::new(
            self.transport.endpoint().addr(),
            imported_hash,
            BlobFormat::Raw,
        )
        .to_string())
    }
}

// ------------------------------------------------------------------ #413 媒体导入

/// Sources at or below this size are inlined by the store whatever the import
/// mode (`Options::new` default `max_data_inlined`), so referencing buys
/// nothing.
const INLINE_MAX_BYTES: u64 = 16 * 1024;

/// #413 §3: read buffer of the copy fallback.
const COPY_READ_BUFFER: usize = 1 << 20;

/// How many leading bytes the reference check compares between the
/// descriptor and the path. Location redaction rewrites EXIF, which lives in
/// the file header, so a divergence between the two views shows up here.
const HEAD_COMPARE_BYTES: usize = 64 * 1024;

/// Why an import did not reference the original. Reported to the caller —
/// the fallback is correct but costs a full copy, so it must be visible.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportFallback {
    /// The caller has no filesystem path (API 29, or MediaStore has none).
    NoPath,
    /// At or below [`INLINE_MAX_BYTES`]: the store inlines it anyway.
    Small,
    /// The store already held this hash under a different or unknown data
    /// location. iroh-blobs 0.103 merges External paths and reopens only the
    /// sorted-first one, so a stale earlier path would poison this content;
    /// an owned copy overrides every External path.
    AlreadyInStore,
    /// The path does not name the descriptor's file (device / inode / size
    /// differ), or cannot be stat'ed.
    IdentityMismatch,
    /// Same file, but the leading bytes read through the path differ from
    /// the descriptor's (e.g. location redaction applied to only one view).
    HeadMismatch,
    /// iroh-blobs refused the reference import.
    ReferenceFailed,
    /// The file changed while its outboard was computed.
    ChangedDuringImport,
}

impl ImportFallback {
    pub fn as_str(self) -> &'static str {
        match self {
            ImportFallback::NoPath => "no_path",
            ImportFallback::Small => "small",
            ImportFallback::AlreadyInStore => "already_in_store",
            ImportFallback::IdentityMismatch => "identity_mismatch",
            ImportFallback::HeadMismatch => "head_mismatch",
            ImportFallback::ReferenceFailed => "reference_failed",
            ImportFallback::ChangedDuringImport => "changed_during_import",
        }
    }
}

/// Result of [`AndroidBlobsProvider::import_media`]. The import is held
/// (kept alive against GC) until [`AndroidBlobsProvider::release`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaImport {
    pub hash: [u8; 32],
    pub size: u64,
    /// The store references the original file instead of holding a copy.
    pub by_reference: bool,
    /// Set whenever `by_reference` is false.
    pub fallback: Option<ImportFallback>,
    /// Diagnostics for the fallback (e.g. both identity tuples).
    pub detail: Option<String>,
}

/// A referenced original that no longer matches what was imported. Serving it
/// fails (iroh-blobs validates every leaf before sending), so the caller must
/// treat the item as a source change, not a path or peer failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceFault {
    /// The path no longer resolves (deleted, moved, permission revoked).
    Missing,
    /// Still there, but size / mtime / file identity differ from the import.
    Changed,
}

impl SourceFault {
    pub fn as_str(self) -> &'static str {
        match self {
            SourceFault::Missing => "missing",
            SourceFault::Changed => "changed",
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ServeError {
    /// Serve is only possible for a held import; `has()` is not evidence
    /// (it stays true for an External entry whose file is gone).
    #[error("content {0} is not imported; import it before serving")]
    NotImported(String),
    #[error("referenced source {}", .0.as_str())]
    Source(SourceFault),
    #[error(transparent)]
    Transport(#[from] TransportError),
}

/// Snapshot of a referenced original at import time.
#[derive(Debug, Clone)]
struct SourceWatch {
    path: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
    file_id: Option<FileIdentity>,
}

impl SourceWatch {
    fn of(path: &Path, meta: &Metadata) -> Self {
        Self {
            path: path.to_owned(),
            len: meta.len(),
            modified: meta.modified().ok(),
            file_id: file_id(meta),
        }
    }

    fn check(&self) -> Option<SourceFault> {
        match std::fs::metadata(&self.path) {
            Err(_) => Some(SourceFault::Missing),
            Ok(meta) => (meta.len() != self.len
                || meta.modified().ok() != self.modified
                || file_id(&meta) != self.file_id)
                .then_some(SourceFault::Changed),
        }
    }
}

fn describe(meta: &Metadata) -> String {
    match file_id(meta) {
        Some(id) => format!(
            "dev={} ino={} size={} mtime={}.{:09} file={}",
            id.dev,
            id.ino,
            id.len,
            id.mtime_sec,
            id.mtime_nsec,
            meta.is_file()
        ),
        None => format!("size={} file={}", meta.len(), meta.is_file()),
    }
}

/// What `stat` says about one file. Only the Android bridge build reads it;
/// every other build has no identity and therefore always copies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    dev: u64,
    ino: u64,
    len: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
}

#[cfg(feature = "android-jni")]
fn file_id(meta: &Metadata) -> Option<FileIdentity> {
    use std::os::unix::fs::MetadataExt;
    Some(FileIdentity {
        dev: meta.dev(),
        ino: meta.ino(),
        len: meta.len(),
        mtime_sec: meta.mtime(),
        mtime_nsec: meta.mtime_nsec(),
    })
}

#[cfg(not(feature = "android-jni"))]
fn file_id(_meta: &Metadata) -> Option<FileIdentity> {
    None
}

/// Whether the descriptor's file and the path's file are the same file.
///
/// On Android 11+ `_data` goes through the FUSE mount while the
/// ContentResolver descriptor points at the lower filesystem: `st_dev`
/// always differs (emulator API 35: fd dev=65068, path dev=83) while inode,
/// size and mtime match. So `st_dev` is not compared; inode + size + mtime
/// (with nanoseconds) must all match. The 64 KiB head comparison afterwards
/// and iroh's per-leaf validation while serving remain the content guards.
fn same_file(fd: &FileIdentity, path: &FileIdentity) -> bool {
    fd.ino == path.ino
        && fd.len == path.len
        && fd.mtime_sec == path.mtime_sec
        && fd.mtime_nsec == path.mtime_nsec
}

struct HeldImport {
    _tag: TempTag,
    watch: Option<SourceWatch>,
}

/// Where this process last put a hash's data. A hash imported by copy is
/// owned (owned data wins every later merge); a referenced hash remembers
/// its paths, because a later reference import from another path would be
/// merged behind the sorted-first one.
#[derive(Debug, Clone, PartialEq, Eq)]
enum StoredAs {
    Owned,
    External(BTreeSet<PathBuf>),
}

type Fallback = (ImportFallback, Option<String>);

fn read_head(file: &mut File, len: usize) -> std::io::Result<Vec<u8>> {
    let mut head = vec![0u8; len];
    file.seek(SeekFrom::Start(0))?;
    file.read_exact(&mut head)?;
    Ok(head)
}

impl AndroidBlobsProvider {
    /// #413 §3: import one original, referencing it in place when [data_path]
    /// provably names the same file as [source] (the opened descriptor), and
    /// copying from [source] otherwise. Returns its BLAKE3 hash; the content
    /// stays held until [`Self::release`] (or [`Self::revoke`]).
    ///
    /// [source] is only read during this call; the caller may close its
    /// descriptor on return (a reference is re-opened by path).
    pub fn import_media(&self, data_path: Option<&Path>, source: File) -> Result<MediaImport> {
        let _serial = self.import_lock.lock().expect("media import lock");
        self.runtime
            .block_on(self.import_media_async(data_path, source))
    }

    async fn import_media_async(
        &self,
        data_path: Option<&Path>,
        mut source: File,
    ) -> Result<MediaImport> {
        let fd_meta = source.metadata().map_err(|error| {
            TransportError::Io(format!("stat Android source descriptor: {error}"))
        })?;
        let plan = match data_path {
            None => Err((ImportFallback::NoPath, None)),
            Some(path) => reference_plan(path, &fd_meta, &mut source),
        };
        let (fallback, keep) = match plan {
            Ok(watch) => match self.import_by_reference(watch).await {
                Ok(done) => return Ok(done),
                Err(failed) => failed,
            },
            Err(fallback) => (fallback, None),
        };
        let done = self.import_by_copy(source, fallback).await;
        // A reference entry kept alive until its owned copy replaced it.
        drop(keep);
        done
    }

    async fn import_by_reference(
        &self,
        watch: SourceWatch,
    ) -> std::result::Result<MediaImport, (Fallback, Option<TempTag>)> {
        let before: HashSet<Hash> = match self.store.blobs().list().hashes().await {
            Ok(hashes) => hashes.into_iter().collect(),
            Err(error) => {
                return Err((
                    (
                        ImportFallback::ReferenceFailed,
                        Some(format!("list store: {error}")),
                    ),
                    None,
                ))
            }
        };
        let tag = match self
            .store
            .blobs()
            .add_path_with_opts(AddPathOptions {
                path: watch.path.clone(),
                mode: ImportMode::TryReference,
                format: BlobFormat::Raw,
            })
            .temp_tag()
            .await
        {
            Ok(tag) => tag,
            Err(error) => {
                return Err((
                    (ImportFallback::ReferenceFailed, Some(error.to_string())),
                    None,
                ))
            }
        };
        let hash = tag.hash();
        {
            let mut stored = self.stored.lock().expect("stored locations lock");
            let only_this_path = StoredAs::External(BTreeSet::from([watch.path.clone()]));
            let safe = !before.contains(&hash)
                || matches!(stored.get(&hash), Some(StoredAs::Owned))
                || stored.get(&hash) == Some(&only_this_path);
            if !safe {
                let detail = format!("{} already stored as {:?}", hash, stored.get(&hash));
                return Err(((ImportFallback::AlreadyInStore, Some(detail)), Some(tag)));
            }
            if !before.contains(&hash) {
                stored.insert(hash, only_this_path);
            }
        }
        if let Some(fault) = watch.check() {
            let detail = format!("source {} during import", fault.as_str());
            return Err((
                (ImportFallback::ChangedDuringImport, Some(detail)),
                Some(tag),
            ));
        }
        let size = watch.len;
        self.imports.lock().expect("held imports lock").insert(
            hash,
            HeldImport {
                _tag: tag,
                watch: Some(watch),
            },
        );
        Ok(MediaImport {
            hash: *hash.as_bytes(),
            size,
            by_reference: true,
            fallback: None,
            detail: None,
        })
    }

    async fn import_by_copy(&self, mut source: File, fallback: Fallback) -> Result<MediaImport> {
        // The reference check may have read the head; a pipe cannot seek and
        // was never read.
        let _ = source.seek(SeekFrom::Start(0));
        let stream = tokio_util::io::ReaderStream::with_capacity(
            tokio::fs::File::from_std(source),
            COPY_READ_BUFFER,
        );
        let tag = self
            .store
            .blobs()
            .add_stream(stream)
            .await
            .temp_tag()
            .await
            .map_err(|error| {
                TransportError::Io(format!("copy Android source descriptor: {error}"))
            })?;
        let hash = tag.hash();
        let size = match self.store.blobs().status(hash).await {
            Ok(BlobStatus::Complete { size }) => size,
            Ok(other) => {
                return Err(TransportError::Io(format!(
                    "copied source {hash} is not complete: {other:?}"
                )))
            }
            Err(error) => {
                return Err(TransportError::Io(format!(
                    "status of copied source {hash}: {error}"
                )))
            }
        };
        self.stored
            .lock()
            .expect("stored locations lock")
            .insert(hash, StoredAs::Owned);
        self.imports.lock().expect("held imports lock").insert(
            hash,
            HeldImport {
                _tag: tag,
                watch: None,
            },
        );
        Ok(MediaImport {
            hash: *hash.as_bytes(),
            size,
            by_reference: false,
            fallback: Some(fallback.0),
            detail: fallback.1,
        })
    }

    /// #413: serve a held import through this provider's endpoint as the
    /// current lease and return its ticket. A referenced original is checked
    /// first: if it is gone or changed the ticket could only fail, so this
    /// reports [`ServeError::Source`] instead.
    pub fn serve(&self, content_hash: [u8; 32]) -> std::result::Result<String, ServeError> {
        self.runtime
            .block_on(self.serve_async(Hash::from_bytes(content_hash)))
    }

    async fn serve_async(&self, hash: Hash) -> std::result::Result<String, ServeError> {
        let fault = {
            let imports = self.imports.lock().expect("held imports lock");
            let held = imports
                .get(&hash)
                .ok_or_else(|| ServeError::NotImported(hash.to_string()))?;
            held.watch.as_ref().and_then(SourceWatch::check)
        };
        if let Some(fault) = fault {
            return Err(ServeError::Source(fault));
        }
        if self.config.n0_services
            && !self
                .transport
                .wait_online(std::time::Duration::from_secs(15))
                .await
        {
            return Err(TransportError::Io(
                "Android provider endpoint did not become online before serving".into(),
            )
            .into());
        }
        self.ensure_active_handler();
        {
            let mut active = self.active.lock().expect("active provider lock");
            let active = active
                .as_mut()
                .expect("ensure_active_handler installed an active provider");
            active.handler.activity.reset();
            active.retained = None;
            active.served = Some(hash);
        }
        Ok(BlobTicket::new(self.transport.endpoint().addr(), hash, BlobFormat::Raw).to_string())
    }

    /// #413: this content is no longer needed. Drops its hold (the store's GC
    /// reclaims it; a referenced original is never touched). Does not stop an
    /// in-flight fetch or close connections — pause does that. Idempotent.
    pub fn release(&self, content_hash: [u8; 32]) {
        let hash = Hash::from_bytes(content_hash);
        if let Some(active) = self.active.lock().expect("active provider lock").as_mut() {
            if active.served == Some(hash) {
                active.served = None;
            }
        }
        let held = self
            .imports
            .lock()
            .expect("held imports lock")
            .remove(&hash);
        drop(held);
    }

    /// Whether [content_hash] is currently held by an import.
    pub fn is_held(&self, content_hash: [u8; 32]) -> bool {
        self.imports
            .lock()
            .expect("held imports lock")
            .contains_key(&Hash::from_bytes(content_hash))
    }

    /// #413: whether the current lease's referenced original is gone or
    /// changed. Checked on every call (a stat), because the fetch abort that
    /// such a change causes carries no reason and may arrive after the
    /// desktop has already reported its failure.
    pub fn source_fault(&self) -> Option<SourceFault> {
        let served = self
            .active
            .lock()
            .expect("active provider lock")
            .as_ref()
            .and_then(|active| active.served)?;
        let watch = self
            .imports
            .lock()
            .expect("held imports lock")
            .get(&served)?
            .watch
            .clone()?;
        watch.check()
    }
}

/// Decide whether [path] may be referenced for the file behind [source].
fn reference_plan(
    path: &Path,
    fd_meta: &Metadata,
    source: &mut File,
) -> std::result::Result<SourceWatch, Fallback> {
    if !fd_meta.is_file() {
        return Err((
            ImportFallback::IdentityMismatch,
            Some(format!(
                "descriptor is not a regular file: {}",
                describe(fd_meta)
            )),
        ));
    }
    if fd_meta.len() <= INLINE_MAX_BYTES {
        return Err((ImportFallback::Small, None));
    }
    if !path.is_absolute() {
        return Err((
            ImportFallback::IdentityMismatch,
            Some(format!("path is not absolute: {path:?}")),
        ));
    }
    let path_meta = std::fs::metadata(path).map_err(|error| {
        (
            ImportFallback::IdentityMismatch,
            Some(format!("stat {path:?}: {error}")),
        )
    })?;
    let same = match (file_id(fd_meta), file_id(&path_meta)) {
        (Some(fd_id), Some(path_id)) => same_file(&fd_id, &path_id),
        _ => false,
    };
    if !same {
        return Err((
            ImportFallback::IdentityMismatch,
            Some(format!(
                "fd [{}] vs path {path:?} [{}]",
                describe(fd_meta),
                describe(&path_meta)
            )),
        ));
    }
    let head_len = HEAD_COMPARE_BYTES.min(fd_meta.len() as usize);
    let heads = read_head(source, head_len).and_then(|fd_head| {
        let mut by_path = File::open(path)?;
        Ok((fd_head, read_head(&mut by_path, head_len)?))
    });
    match heads {
        Ok((fd_head, path_head)) if fd_head == path_head => Ok(SourceWatch::of(path, &path_meta)),
        Ok(_) => Err((
            ImportFallback::HeadMismatch,
            Some(format!(
                "first {head_len} bytes differ between fd and {path:?}"
            )),
        )),
        Err(error) => Err((
            ImportFallback::IdentityMismatch,
            Some(format!("read head of fd / {path:?}: {error}")),
        )),
    }
}

/// Wire shape of [`MediaImport`] over the JNI boundary.
#[cfg(any(feature = "android-jni", test))]
fn import_wire(import: &MediaImport) -> serde_json::Value {
    serde_json::json!({
        "hash": hex_of(&import.hash),
        "size": import.size,
        "by_reference": import.by_reference,
        "fallback": import.fallback.map(ImportFallback::as_str),
        "detail": import.detail,
    })
}

/// [`ActiveTransferStatus::to_wire`] plus `"source"` when the lease's
/// referenced original is gone or changed. A completed pull already has
/// every byte, so no fault is attached to it.
#[cfg(any(feature = "android-jni", test))]
fn status_wire(status: &ActiveTransferStatus, fault: Option<SourceFault>) -> serde_json::Value {
    let mut wire = status.to_wire();
    if let (Some(fault), false) = (
        fault,
        matches!(status, ActiveTransferStatus::Completed { .. }),
    ) {
        wire["source"] = serde_json::Value::from(fault.as_str());
    }
    wire
}

#[cfg(test)]
mod media_wire_tests {
    use super::*;

    const FD: FileIdentity = FileIdentity {
        dev: 65068,
        ino: 499_733,
        len: 532_102,
        mtime_sec: 1_790_243_013,
        mtime_nsec: 123_456_789,
    };

    #[test]
    fn fuse_path_with_a_different_device_is_the_same_file() {
        // Emulator API 35 observation: only st_dev differs between the two views.
        assert!(same_file(&FD, &FileIdentity { dev: 83, ..FD }));
        assert!(same_file(&FD, &FD));
    }

    #[test]
    fn inode_size_or_mtime_difference_is_another_file() {
        assert!(!same_file(&FD, &FileIdentity { ino: 499_734, ..FD }));
        assert!(!same_file(
            &FD,
            &FileIdentity {
                dev: 83,
                ino: 1,
                ..FD
            }
        ));
        assert!(!same_file(&FD, &FileIdentity { len: 532_103, ..FD }));
        assert!(!same_file(
            &FD,
            &FileIdentity {
                mtime_sec: 1_790_243_014,
                ..FD
            }
        ));
        assert!(!same_file(
            &FD,
            &FileIdentity {
                mtime_nsec: 0,
                ..FD
            }
        ));
    }

    #[test]
    fn import_wire_reports_fallback_reason() {
        let wire = import_wire(&MediaImport {
            hash: [0x01; 32],
            size: 7,
            by_reference: false,
            fallback: Some(ImportFallback::NoPath),
            detail: None,
        });
        assert_eq!(wire["hash"], "01".repeat(32));
        assert_eq!(wire["size"], 7);
        assert_eq!(wire["by_reference"], false);
        assert_eq!(wire["fallback"], "no_path");
        assert!(wire["detail"].is_null());
    }

    #[test]
    fn status_wire_attaches_source_fault_except_to_completed() {
        let aborted = ActiveTransferStatus::Aborted { hash: [2; 32] };
        assert_eq!(
            status_wire(&aborted, Some(SourceFault::Changed))["source"],
            "changed"
        );
        assert!(status_wire(&aborted, None).get("source").is_none());
        let completed = ActiveTransferStatus::Completed { hash: [2; 32] };
        assert!(status_wire(&completed, Some(SourceFault::Missing))
            .get("source")
            .is_none());
    }
}

#[cfg(feature = "android-jni")]
static PROVIDERS: OnceLock<Mutex<HashMap<jlong, Arc<AndroidBlobsProvider>>>> = OnceLock::new();
#[cfg(feature = "android-jni")]
static NEXT_PROVIDER_HANDLE: AtomicU64 = AtomicU64::new(1);

#[cfg(feature = "android-jni")]
fn providers() -> &'static Mutex<HashMap<jlong, Arc<AndroidBlobsProvider>>> {
    PROVIDERS.get_or_init(Mutex::default)
}

#[cfg(feature = "android-jni")]
fn provider(handle: jlong) -> Result<Arc<AndroidBlobsProvider>> {
    providers()
        .lock()
        .expect("Android provider registry lock")
        .get(&handle)
        .cloned()
        .ok_or_else(|| TransportError::Io("unknown Android provider handle".into()))
}

#[cfg(feature = "android-jni")]
fn throw(env: &mut JNIEnv<'_>, error: impl std::fmt::Display) {
    let _ = env.throw_new("java/lang/IllegalStateException", error.to_string());
}

/// Owned duplicate of a caller-owned descriptor (the caller closes its own).
#[cfg(feature = "android-jni")]
fn duplicate_fd(fd: RawFd) -> Result<File> {
    let duplicated = unsafe { libc::dup(fd) };
    if duplicated < 0 {
        return Err(TransportError::Io(format!(
            "duplicate Android source descriptor: {}",
            std::io::Error::last_os_error()
        )));
    }
    // SAFETY: dup returned a distinct owned descriptor above.
    Ok(unsafe { File::from_raw_fd(duplicated) })
}

#[cfg(feature = "android-jni")]
fn jni_hash(env: &mut JNIEnv<'_>, hash: &JString<'_>) -> Result<[u8; 32]> {
    let hash: String = env
        .get_string(hash)
        .map_err(|error| TransportError::Io(error.to_string()))?
        .into();
    let hash: Hash = hash
        .parse()
        .map_err(|error| TransportError::Io(format!("invalid content hash: {error}")))?;
    Ok(*hash.as_bytes())
}

#[cfg(feature = "android-jni")]
fn return_string(env: &mut JNIEnv<'_>, value: Result<String>) -> jstring {
    match value.and_then(|value| {
        env.new_string(value)
            .map_err(|error| TransportError::Io(error.to_string()))
    }) {
        Ok(value) => value.into_raw(),
        Err(error) => {
            throw(env, error);
            std::ptr::null_mut()
        }
    }
}

/// #413: import one original (reference first, copy fallback). [path] may be
/// null. Returns the JSON of [`import_wire`]; the caller may close [fd] on
/// return.
#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeImportMedia(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    path: JString<'_>,
    fd: jint,
) -> jstring {
    let path: Option<PathBuf> = if path.is_null() {
        None
    } else {
        match env.get_string(&path) {
            Ok(path) => Some(PathBuf::from(String::from(path))),
            Err(error) => {
                throw(&mut env, error);
                return std::ptr::null_mut();
            }
        }
    };
    let result = provider(handle).and_then(|provider| {
        let source = duplicate_fd(fd)?;
        let import = provider.import_media(path.as_deref(), source)?;
        serde_json::to_string(&import_wire(&import))
            .map_err(|error| TransportError::Io(error.to_string()))
    });
    return_string(&mut env, result)
}

/// #413: serve a held import as the current lease, returning its ticket. A
/// referenced original that is gone or changed throws
/// `java.io.FileNotFoundException` (the Kotlin side's source-missing signal);
/// every other failure throws `IllegalStateException`.
#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeServe(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    hash: JString<'_>,
) -> jstring {
    let hash = match jni_hash(&mut env, &hash) {
        Ok(hash) => hash,
        Err(error) => {
            throw(&mut env, error);
            return std::ptr::null_mut();
        }
    };
    let provider = match provider(handle) {
        Ok(provider) => provider,
        Err(error) => {
            throw(&mut env, error);
            return std::ptr::null_mut();
        }
    };
    match provider.serve(hash) {
        Ok(ticket) => return_string(&mut env, Ok(ticket)),
        Err(error @ ServeError::Source(_)) => {
            let _ = env.throw_new("java/io/FileNotFoundException", error.to_string());
            std::ptr::null_mut()
        }
        Err(error) => {
            throw(&mut env, error);
            std::ptr::null_mut()
        }
    }
}

/// #413: drop the hold on an imported content. Idempotent.
#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeRelease(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    hash: JString<'_>,
) {
    match jni_hash(&mut env, &hash).and_then(|hash| Ok((provider(handle)?, hash))) {
        Ok((provider, hash)) => provider.release(hash),
        Err(error) => throw(&mut env, error),
    }
}

#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeOpen(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    root: JString<'_>,
) -> jlong {
    let root: String = match env.get_string(&root) {
        Ok(root) => root.into(),
        Err(error) => {
            throw(&mut env, error);
            return 0;
        }
    };
    match AndroidBlobsProvider::new(root) {
        Ok(provider) => {
            let handle = NEXT_PROVIDER_HANDLE.fetch_add(1, Ordering::Relaxed) as jlong;
            providers()
                .lock()
                .expect("Android provider registry lock")
                .insert(handle, Arc::new(provider));
            handle
        }
        Err(error) => {
            throw(&mut env, error);
            0
        }
    }
}

#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeRegister(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    hash: JString<'_>,
    fd: jint,
) -> jstring {
    let hash: String = match env.get_string(&hash) {
        Ok(hash) => hash.into(),
        Err(error) => {
            throw(&mut env, error);
            return std::ptr::null_mut();
        }
    };
    let declared_hash: Hash = match hash.parse() {
        Ok(hash) => hash,
        Err(error) => {
            throw(&mut env, format!("invalid declared content hash: {error}"));
            return std::ptr::null_mut();
        }
    };
    let result =
        provider(handle).and_then(|provider| provider.register_fd(*declared_hash.as_bytes(), fd));
    match result.and_then(|ticket| {
        env.new_string(ticket)
            .map_err(|error| TransportError::Io(error.to_string()))
    }) {
        Ok(ticket) => ticket.into_raw(),
        Err(error) => {
            throw(&mut env, error);
            std::ptr::null_mut()
        }
    }
}

#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeStopActiveFetch(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    match provider(handle) {
        Ok(provider) => provider.stop_active_fetch(),
        Err(error) => throw(&mut env, error),
    }
}

/// BLOB-03: release the current lease's provider retention (drop its
/// `TempTag`) so the served blob is reclaimable by the periodic GC, while
/// keeping the endpoint + ALPN handler alive for the next item.
#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeReleaseRetention(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    match provider(handle) {
        Ok(provider) => provider.release_retention(),
        Err(error) => throw(&mut env, error),
    }
}

#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeRevoke(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    match provider(handle) {
        Ok(provider) => provider.revoke(),
        Err(error) => throw(&mut env, error),
    }
}

#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeTransferStatus(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) -> jstring {
    let result =
        provider(handle).map(|provider| (provider.transfer_status(), provider.source_fault()));
    match result.and_then(|(status, fault)| {
        serde_json::to_string(&status_wire(&status, fault))
            .map_err(|error| TransportError::Io(error.to_string()))
    }) {
        Ok(json) => match env.new_string(json) {
            Ok(s) => s.into_raw(),
            Err(error) => {
                throw(&mut env, error);
                std::ptr::null_mut()
            }
        },
        Err(error) => {
            throw(&mut env, error);
            std::ptr::null_mut()
        }
    }
}

/// #417: forward an Android network-change callback to the provider endpoint.
#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeNetworkChange(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    match provider(handle) {
        Ok(provider) => provider.network_change(),
        Err(error) => throw(&mut env, error),
    }
}

#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeClose(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    let provider = providers()
        .lock()
        .expect("Android provider registry lock")
        .remove(&handle);
    match provider {
        Some(provider) => provider.revoke(),
        None => throw(&mut env, "unknown Android provider handle"),
    }
}
