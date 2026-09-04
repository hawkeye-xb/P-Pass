//! Android JNI bridge for a one-lease iroh-blobs provider.
//!
//! Each registration gets an isolated store and endpoint. Revocation closes the
//! active iroh connection and endpoint, so a stale store is never served again;
//! the receiver's iroh-blobs partial is left untouched and is resumed by the
//! next ticket fetch.

use std::collections::HashMap;
#[cfg(feature = "android-jni")]
use std::fs::File;
#[cfg(feature = "android-jni")]
use std::os::fd::{FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(feature = "android-jni")]
use std::sync::OnceLock;
use std::sync::{Arc, Mutex};

use iroh::endpoint::Connection;
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh_blobs::store::fs::FsStore;
use iroh_blobs::{BlobFormat, BlobsProtocol, Hash};
#[cfg(feature = "android-jni")]
use jni::objects::{JClass, JString};
#[cfg(feature = "android-jni")]
use jni::sys::{jint, jlong, jstring};
#[cfg(feature = "android-jni")]
use jni::JNIEnv;

use crate::{IrohTransport, Result, TransportConfig, TransportError, ALPN_BLOBS};

/// A process-local provider that exposes exactly one imported blob at a time.
/// The returned ticket is the only network capability handed to the desktop.
pub struct AndroidBlobsProvider {
    runtime: tokio::runtime::Runtime,
    root: PathBuf,
    config: TransportConfig,
    sequence: AtomicU64,
    active: Mutex<Option<ActiveProvider>>,
}

struct ActiveProvider {
    router: Router,
    handler: StopAwareBlobsProtocol,
}

impl ActiveProvider {
    async fn revoke(self) {
        self.handler.stop_active_fetch();
        let _ = self.router.shutdown().await;
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
        )
    }

    /// Loopback-only constructor for native-provider protocol verification.
    pub fn new_loopback(root: impl AsRef<Path>) -> Result<Self> {
        Self::with_config(root, TransportConfig::loopback(vec![ALPN_BLOBS.to_owned()]))
    }

    fn with_config(root: impl AsRef<Path>, config: TransportConfig) -> Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|error| {
                TransportError::Io(format!("start Android provider runtime: {error}"))
            })?;
        Ok(Self {
            runtime,
            root: root.as_ref().to_owned(),
            config,
            sequence: AtomicU64::new(1),
            active: Mutex::default(),
        })
    }

    /// Imports [path] under [declared_hash], starts the standard iroh-blobs
    /// provider, and returns its standard blob ticket.
    pub fn register_path(&self, declared_hash: [u8; 32], path: &Path) -> Result<String> {
        self.revoke();
        self.runtime
            .block_on(self.register_path_async(declared_hash, path))
    }

    /// Imports an Android ParcelFileDescriptor without relying on a filesystem
    /// path. The caller retains ownership of [fd]; this method duplicates it and
    /// completes the import before returning.
    #[cfg(feature = "android-jni")]
    fn register_fd(&self, declared_hash: [u8; 32], fd: RawFd) -> Result<String> {
        self.revoke();
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

    /// Stops serving and closes the per-registration endpoint. It intentionally
    /// does not inspect or delete a receiver's persisted iroh-blobs partial.
    pub fn revoke(&self) {
        let active = self.active.lock().expect("active provider lock").take();
        if let Some(active) = active {
            self.runtime.block_on(active.revoke());
        }
    }

    pub fn is_active(&self) -> bool {
        self.active.lock().expect("active provider lock").is_some()
    }

    async fn register_path_async(&self, declared_hash: [u8; 32], path: &Path) -> Result<String> {
        let (store, transport) = self.open_session().await?;
        let tag = store.blobs().add_path(path).await.map_err(|error| {
            TransportError::Io(format!("import Android provider path {path:?}: {error}"))
        })?;
        self.activate(declared_hash, store, transport, tag.hash)
            .await
    }

    #[cfg(feature = "android-jni")]
    async fn register_file_async(&self, declared_hash: [u8; 32], source: File) -> Result<String> {
        let (store, transport) = self.open_session().await?;
        let stream = tokio_util::io::ReaderStream::new(tokio::fs::File::from_std(source));
        let tag = store
            .blobs()
            .add_stream(stream)
            .await
            .await
            .map_err(|error| {
                TransportError::Io(format!("import Android provider descriptor: {error}"))
            })?;
        self.activate(declared_hash, store, transport, tag.hash)
            .await
    }

    async fn open_session(&self) -> Result<(FsStore, IrohTransport)> {
        let id = self.sequence.fetch_add(1, Ordering::Relaxed);
        let store_dir = self.root.join("iroh-blobs-provider").join(id.to_string());
        let store = FsStore::load(&store_dir).await.map_err(|error| {
            TransportError::Io(format!(
                "open Android provider store {store_dir:?}: {error}"
            ))
        })?;
        let transport = IrohTransport::bind(self.config.clone()).await?;
        Ok((store, transport))
    }

    async fn activate(
        &self,
        declared_hash: [u8; 32],
        store: FsStore,
        transport: IrohTransport,
        imported_hash: Hash,
    ) -> Result<String> {
        if imported_hash != Hash::from_bytes(declared_hash) {
            transport.close().await;
            let _ = store.shutdown().await;
            return Err(TransportError::Io(
                "Android provider source does not match its declared content hash".into(),
            ));
        }

        if self.config.n0_services
            && !transport
                .wait_online(std::time::Duration::from_secs(15))
                .await
        {
            transport.close().await;
            let _ = store.shutdown().await;
            return Err(TransportError::Io(
                "Android provider endpoint did not become online before ticket registration".into(),
            ));
        }

        let handler = StopAwareBlobsProtocol::new(&store);
        let router = Router::builder(transport.endpoint().clone())
            .accept(ALPN_BLOBS.as_bytes(), handler.clone())
            .spawn();
        let ticket = iroh_blobs::ticket::BlobTicket::new(
            transport.endpoint().addr(),
            imported_hash,
            BlobFormat::Raw,
        )
        .to_string();
        *self.active.lock().expect("active provider lock") =
            Some(ActiveProvider { router, handler });
        Ok(ticket)
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
