//! Android JNI bridge for a one-lease iroh-blobs provider.
//!
//! A provider owns one endpoint for its whole lifetime. Registrations add their
//! current source to the same private store; revocation only stops the active
//! fetch, leaving the endpoint alive until the provider is closed so daemon
//! connection reuse survives one-item Flow deliveries.

use std::collections::HashMap;
#[cfg(feature = "android-jni")]
use std::fs::File;
#[cfg(feature = "android-jni")]
use std::os::fd::{FromRawFd, RawFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(feature = "android-jni")]
use std::sync::OnceLock;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh::endpoint::Connection;
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh_blobs::api::TempTag;
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
}

struct ActiveProvider {
    handler: StopAwareBlobsProtocol,
    retained: Option<TempTag>,
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

/// Wraps iroh-blobs' protocol handler only to retain/close active QUIC
/// connections. The blob wire protocol itself remains entirely upstream
/// iroh-blobs; no chunk or offset protocol is introduced here.
#[derive(Debug, Clone)]
struct StopAwareBlobsProtocol {
    inner: BlobsProtocol,
    accepting: Arc<AtomicBool>,
    next_connection: Arc<AtomicU64>,
    active: Arc<Mutex<HashMap<u64, Connection>>>,
}

impl StopAwareBlobsProtocol {
    fn new(store: &FsStore) -> Self {
        Self {
            inner: BlobsProtocol::new(store, None),
            accepting: Arc::new(AtomicBool::new(true)),
            next_connection: Arc::new(AtomicU64::new(1)),
            active: Arc::default(),
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
        let duplicated = unsafe { libc::dup(fd) };
        if duplicated < 0 {
            return Err(TransportError::Io(format!(
                "duplicate Android source descriptor: {}",
                std::io::Error::last_os_error()
            )));
        }
        // SAFETY: dup returned a distinct owned descriptor above.
        let source = unsafe { File::from_raw_fd(duplicated) };
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
    pub fn revoke(&self) {
        let active = self.active.lock().expect("active provider lock").take();
        *self
            .dispatch
            .lock()
            .expect("Android provider dispatch lock") = None;
        if let Some(active) = active {
            active.revoke();
        }
    }

    /// BLOB-03: release provider retention of the current lease's blob WITHOUT
    /// stopping the handler or discarding the endpoint. This is the success
    /// boundary — a validated completion receipt means the daemon has the
    /// original, so the source copy may be GC'd. The endpoint and its ALPN
    /// handler stay alive (decision 5: connection reuse across serial items is
    /// intact); only the `TempTag` keeping the blob alive is dropped.
    pub fn release_retention(&self) {
        if let Some(active) = self.active.lock().expect("active provider lock").as_mut() {
            active.retained = None;
        }
    }

    pub fn is_active(&self) -> bool {
        self.active.lock().expect("active provider lock").is_some()
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
        let stream = tokio_util::io::ReaderStream::new(tokio::fs::File::from_std(source));
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
        // BLOB-03: retain only the current lease's blob. A later register (in
        // the real Flow every strict-head advance is preceded by a revoke that
        // drops this tag, but the loopback tests register back-to-back) drops
        // the previous lease's tag, so it becomes reclaimable at the next GC.
        let mut active = self.active.lock().expect("active provider lock");
        active
            .as_mut()
            .expect("ensure_active_handler installed an active provider")
            .retained = Some(tag);
        Ok(BlobTicket::new(
            self.transport.endpoint().addr(),
            imported_hash,
            BlobFormat::Raw,
        )
        .to_string())
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
