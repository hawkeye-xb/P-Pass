//! Android JNI binding #1 over the provider kernel (IOS-05 #312).
//!
//! A thin layer: handle registry, JNI string/descriptor conversion and
//! exception mapping. Every behavior lives in [`crate::provider`]; the
//! exported symbol names are the Kotlin `AndroidNativeIrohBlobsProvider`
//! contract and must not change.

use std::collections::HashMap;
use std::fs::File;
use std::os::fd::{FromRawFd, RawFd};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use iroh_blobs::Hash;
use jni::objects::{JClass, JString};
use jni::sys::{jint, jlong, jstring};
use jni::JNIEnv;

use crate::android_wire::{import_wire, status_wire};
use crate::provider::{BlobsProvider, ServeError};
use crate::{Result, TransportError};

static PROVIDERS: OnceLock<Mutex<HashMap<jlong, Arc<BlobsProvider>>>> = OnceLock::new();
static NEXT_PROVIDER_HANDLE: AtomicU64 = AtomicU64::new(1);

fn providers() -> &'static Mutex<HashMap<jlong, Arc<BlobsProvider>>> {
    PROVIDERS.get_or_init(Mutex::default)
}

fn provider(handle: jlong) -> Result<Arc<BlobsProvider>> {
    providers()
        .lock()
        .expect("Android provider registry lock")
        .get(&handle)
        .cloned()
        .ok_or_else(|| TransportError::Io("unknown Android provider handle".into()))
}

fn throw(env: &mut JNIEnv<'_>, error: impl std::fmt::Display) {
    let _ = env.throw_new("java/lang/IllegalStateException", error.to_string());
}

/// Owned duplicate of a caller-owned descriptor (the caller closes its own).
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
    match BlobsProvider::new(root) {
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

/// #547: set the paired desktop's NodeId (64 hex) as the only peer allowed
/// to pull; `null` / empty refuses everyone. A malformed id refuses everyone
/// and throws.
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeSetAllowedPeer(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    node_id: JString<'_>,
) {
    let provider = match provider(handle) {
        Ok(provider) => provider,
        Err(error) => {
            throw(&mut env, error);
            return;
        }
    };
    if node_id.is_null() {
        provider.set_allowed_peer(None);
        return;
    }
    let text: String = match env.get_string(&node_id) {
        Ok(text) => text.into(),
        Err(error) => {
            provider.set_allowed_peer(None);
            throw(&mut env, error);
            return;
        }
    };
    if text.trim().is_empty() {
        provider.set_allowed_peer(None);
        return;
    }
    match text.parse::<crate::NodeId>() {
        Ok(peer) => provider.set_allowed_peer(Some(peer)),
        Err(error) => {
            provider.set_allowed_peer(None);
            throw(&mut env, format!("invalid paired desktop node id: {error}"));
        }
    }
}

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
    let result = provider(handle).and_then(|provider| {
        let source = duplicate_fd(fd)?;
        provider.register_file(*declared_hash.as_bytes(), source)
    });
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

/// #434: bind the provider endpoint ahead of the first serve of a round.
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativePrewarm(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    if let Err(error) = provider(handle).and_then(|provider| provider.prewarm()) {
        throw(&mut env, error);
    }
}

/// #434: close the provider endpoint while idle; `false` = refused (a peer
/// is connected), try again later.
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativePark(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) -> jni::sys::jboolean {
    match provider(handle) {
        Ok(provider) => provider.park() as jni::sys::jboolean,
        Err(error) => {
            throw(&mut env, error);
            0
        }
    }
}

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
