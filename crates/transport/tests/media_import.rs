//! #413 §3: reference-first media import, then serve / release as separate
//! steps. The copy fallback works in every build; referencing an original
//! needs the file identity only the Android bridge build (`android-jni`)
//! reads, so those cases live in the gated module below.

use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::time::Duration;

use tempfile::tempdir;
use transport::{
    ActiveTransferStatus, AndroidBlobsProvider, Blobs, ImportFallback, IrohTransport, ServeError,
    TransportConfig, ALPN_BLOBS,
};

const GC: Duration = Duration::from_millis(20);
const PULL_TIMEOUT: Duration = Duration::from_secs(20);

fn blake3_of(bytes: &[u8]) -> [u8; 32] {
    *blake3::hash(bytes).as_bytes()
}

/// Deterministic, incompressible-looking bytes; `seed` makes contents differ.
fn photo_bytes(len: usize, seed: u64) -> Vec<u8> {
    let mut x = 0x9E37_79B9_7F4A_7C15u64 ^ seed;
    (0..len)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

fn write_photo(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, bytes).unwrap();
    path
}

fn store_files(dir: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(&path, out);
            } else {
                out.push(path);
            }
        }
    }
    let mut out = Vec::new();
    walk(&dir.join("iroh-blobs-provider"), &mut out);
    out
}

fn has_extension(files: &[PathBuf], extension: &str) -> bool {
    files
        .iter()
        .any(|file| file.extension().is_some_and(|e| e == extension))
}

/// Pull [ticket] from a fresh loopback receiver, bounded by [PULL_TIMEOUT].
fn pull(dir: &Path, ticket: &str) -> Result<Vec<u8>, String> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let receiver = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        let store = tempfile::tempdir_in(dir).unwrap();
        let blobs = Blobs::open(&receiver, store.path()).await.unwrap();
        let destination = store.path().join("received.bin");
        let result =
            match tokio::time::timeout(PULL_TIMEOUT, blobs.pull(ticket, &destination)).await {
                Ok(Ok(_)) => Ok(fs::read(&destination).unwrap()),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err("pull timed out".into()),
            };
        blobs.close().await;
        receiver.close().await;
        result
    })
}

fn wait_until_gone(provider: &AndroidBlobsProvider, hash: [u8; 32]) {
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while provider.has_blob(hash) {
        assert!(
            std::time::Instant::now() < deadline,
            "released content was not reclaimed by periodic GC"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn null_path_copies_from_the_descriptor_and_serves() {
    let dir = tempdir().unwrap();
    let bytes = photo_bytes(300 * 1024, 1);
    let source = write_photo(dir.path(), "photo.jpg", &bytes);
    let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

    let import = provider
        .import_media(None, File::open(&source).unwrap())
        .unwrap();
    assert_eq!(import.hash, blake3_of(&bytes));
    assert_eq!(import.size, bytes.len() as u64);
    assert!(!import.by_reference);
    assert_eq!(import.fallback, Some(ImportFallback::NoPath));

    let ticket = provider.serve(import.hash).unwrap();
    assert_eq!(pull(dir.path(), &ticket).unwrap(), bytes);
    assert_eq!(
        provider.transfer_status(),
        ActiveTransferStatus::Completed { hash: import.hash }
    );
    assert_eq!(
        provider.source_fault(),
        None,
        "a copy has no source to lose"
    );
}

#[test]
fn serve_requires_a_held_import_and_release_is_idempotent() {
    let dir = tempdir().unwrap();
    let bytes = photo_bytes(40 * 1024, 2);
    let source = write_photo(dir.path(), "photo.jpg", &bytes);
    let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

    assert!(matches!(
        provider.serve(blake3_of(b"never imported")),
        Err(ServeError::NotImported(_))
    ));

    let import = provider
        .import_media(None, File::open(&source).unwrap())
        .unwrap();
    assert!(provider.is_held(import.hash));
    provider.release(import.hash);
    provider.release(import.hash);
    assert!(!provider.is_held(import.hash));
    assert!(
        matches!(provider.serve(import.hash), Err(ServeError::NotImported(_))),
        "has() may still be true until GC, but a released import is not servable"
    );
    wait_until_gone(&provider, import.hash);
}

#[test]
fn copy_import_serve_release_leaves_nothing_behind() {
    let dir = tempdir().unwrap();
    let bytes = photo_bytes(2 * 1024 * 1024, 3);
    let source = write_photo(dir.path(), "photo.jpg", &bytes);
    let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

    let import = provider
        .import_media(None, File::open(&source).unwrap())
        .unwrap();
    // Several GC passes while held: the import must survive until release.
    std::thread::sleep(Duration::from_millis(120));
    let ticket = provider.serve(import.hash).unwrap();
    assert_eq!(pull(dir.path(), &ticket).unwrap(), bytes);

    provider.release(import.hash);
    wait_until_gone(&provider, import.hash);
    let files = store_files(dir.path());
    assert!(
        !has_extension(&files, "data") && !has_extension(&files, "obao4"),
        "store must hold no payload after release + GC: {files:?}"
    );
    assert_eq!(fs::read(&source).unwrap(), bytes);
}

#[test]
fn revoke_drops_every_held_import() {
    let dir = tempdir().unwrap();
    let bytes = photo_bytes(40 * 1024, 4);
    let source = write_photo(dir.path(), "photo.jpg", &bytes);
    let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();
    let import = provider
        .import_media(None, File::open(&source).unwrap())
        .unwrap();
    provider.serve(import.hash).unwrap();

    provider.revoke();
    assert!(!provider.is_held(import.hash));
    assert_eq!(provider.transfer_status(), ActiveTransferStatus::NoLease);
    wait_until_gone(&provider, import.hash);
}

#[cfg(feature = "android-jni")]
mod reference {
    use super::*;
    use std::io::{Seek, SeekFrom, Write};
    use transport::SourceFault;

    fn import_ref(provider: &AndroidBlobsProvider, path: &Path) -> transport::MediaImport {
        provider
            .import_media(Some(path), File::open(path).unwrap())
            .unwrap()
    }

    /// The desktop's failed pull must come with a local reason: the aborted
    /// transfer itself carries none.
    fn assert_pull_fails_with_fault(
        dir: &Path,
        provider: &AndroidBlobsProvider,
        ticket: &str,
        expected: SourceFault,
    ) {
        let pulled = pull(dir, ticket);
        assert!(pulled.is_err(), "a changed original must not be served");
        assert_eq!(provider.source_fault(), Some(expected));
        // The abort event is delivered asynchronously after the reset.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            match provider.transfer_status() {
                ActiveTransferStatus::Aborted { .. } => break,
                ActiveTransferStatus::Completed { .. } => panic!("changed source completed"),
                _ if std::time::Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                other => panic!("expected Aborted, got {other:?}"),
            }
        }
    }

    #[test]
    fn reference_import_serves_without_a_copy() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(5 * 1024 * 1024, 10);
        let source = write_photo(dir.path(), "photo.jpg", &bytes);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

        let import = import_ref(&provider, &source);
        assert!(import.by_reference, "{import:?}");
        assert_eq!(import.fallback, None);
        assert_eq!(import.hash, blake3_of(&bytes));
        assert_eq!(import.size, bytes.len() as u64);
        let files = store_files(dir.path());
        assert!(!has_extension(&files, "data"), "no copy: {files:?}");
        assert!(has_extension(&files, "obao4"), "outboard only: {files:?}");

        let ticket = provider.serve(import.hash).unwrap();
        assert_eq!(pull(dir.path(), &ticket).unwrap(), bytes);
        assert_eq!(provider.source_fault(), None);
    }

    #[test]
    fn small_sources_are_copied() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(16 * 1024, 11);
        let source = write_photo(dir.path(), "tiny.jpg", &bytes);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

        let import = import_ref(&provider, &source);
        assert!(!import.by_reference);
        assert_eq!(import.fallback, Some(ImportFallback::Small));
        assert_eq!(import.hash, blake3_of(&bytes));
    }

    #[test]
    fn path_naming_another_file_falls_back_to_the_descriptor() {
        let dir = tempdir().unwrap();
        let a = photo_bytes(200 * 1024, 12);
        let b = photo_bytes(200 * 1024, 13);
        let path_a = write_photo(dir.path(), "a.jpg", &a);
        let path_b = write_photo(dir.path(), "b.jpg", &b);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

        let import = provider
            .import_media(Some(&path_a), File::open(&path_b).unwrap())
            .unwrap();
        assert!(!import.by_reference);
        assert_eq!(import.fallback, Some(ImportFallback::IdentityMismatch));
        assert!(
            import.detail.as_deref().unwrap_or("").contains("ino="),
            "both identity tuples must be reported: {:?}",
            import.detail
        );
        assert_eq!(import.hash, blake3_of(&b), "the descriptor is the truth");

        let missing = dir.path().join("missing.jpg");
        let import = provider
            .import_media(Some(&missing), File::open(&path_b).unwrap())
            .unwrap();
        assert_eq!(import.fallback, Some(ImportFallback::IdentityMismatch));
        assert_eq!(import.hash, blake3_of(&b));
    }

    /// Same content at a second path: iroh would merge the paths and reopen
    /// the sorted-first one, so deleting that one would poison the entry.
    /// The second import must copy instead, and survive the deletion.
    #[test]
    fn content_already_referenced_elsewhere_is_copied() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(1024 * 1024, 14);
        let first = write_photo(dir.path(), "a-first.jpg", &bytes);
        let second = write_photo(dir.path(), "b-second.jpg", &bytes);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

        let a = import_ref(&provider, &first);
        assert!(a.by_reference);
        // Re-importing the same path (a retry) keeps the reference.
        let again = import_ref(&provider, &first);
        assert!(again.by_reference, "{again:?}");

        let b = import_ref(&provider, &second);
        assert_eq!(b.hash, a.hash);
        assert!(!b.by_reference);
        assert_eq!(b.fallback, Some(ImportFallback::AlreadyInStore));

        fs::remove_file(&first).unwrap();
        let ticket = provider.serve(b.hash).unwrap();
        assert_eq!(pull(dir.path(), &ticket).unwrap(), bytes);
    }

    /// A reference released but not yet collected is still in the store:
    /// importing the same content from a new path must copy, too.
    #[test]
    fn released_but_uncollected_reference_is_not_reused_from_another_path() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(1024 * 1024, 15);
        let first = write_photo(dir.path(), "a-first.jpg", &bytes);
        let second = write_photo(dir.path(), "b-second.jpg", &bytes);
        // No GC: the released entry stays.
        let provider = AndroidBlobsProvider::new_loopback(dir.path()).unwrap();

        let a = import_ref(&provider, &first);
        provider.release(a.hash);
        assert!(provider.has_blob(a.hash));

        let b = import_ref(&provider, &second);
        assert_eq!(b.fallback, Some(ImportFallback::AlreadyInStore));
    }

    #[test]
    fn in_place_edit_during_serve_aborts_and_reports_changed() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(5 * 1024 * 1024, 16);
        let source = write_photo(dir.path(), "photo.jpg", &bytes);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();
        let import = import_ref(&provider, &source);
        let ticket = provider.serve(import.hash).unwrap();

        let mut file = fs::OpenOptions::new().write(true).open(&source).unwrap();
        file.seek(SeekFrom::Start(bytes.len() as u64 / 2)).unwrap();
        file.write_all(b"XXXX").unwrap();
        drop(file);

        assert_pull_fails_with_fault(dir.path(), &provider, &ticket, SourceFault::Changed);
        assert!(matches!(
            provider.serve(import.hash),
            Err(ServeError::Source(SourceFault::Changed))
        ));
    }

    #[test]
    fn truncation_during_serve_aborts_and_reports_changed() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(5 * 1024 * 1024, 17);
        let source = write_photo(dir.path(), "photo.jpg", &bytes);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();
        let import = import_ref(&provider, &source);
        let ticket = provider.serve(import.hash).unwrap();

        let file = fs::OpenOptions::new().write(true).open(&source).unwrap();
        file.set_len(bytes.len() as u64 / 4).unwrap();
        drop(file);

        assert_pull_fails_with_fault(dir.path(), &provider, &ticket, SourceFault::Changed);
    }

    /// Unix keeps an unlinked file readable through an already-open handle,
    /// so whether the pull itself fails is not deterministic; the fault and
    /// the refusal to serve again are.
    #[test]
    fn deleted_original_is_reported_missing_and_not_served() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(1024 * 1024, 18);
        let source = write_photo(dir.path(), "photo.jpg", &bytes);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();
        let import = import_ref(&provider, &source);
        provider.serve(import.hash).unwrap();

        fs::remove_file(&source).unwrap();
        assert_eq!(provider.source_fault(), Some(SourceFault::Missing));
        assert!(matches!(
            provider.serve(import.hash),
            Err(ServeError::Source(SourceFault::Missing))
        ));
    }

    #[test]
    fn reference_import_serve_release_leaves_nothing_but_the_original() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(2 * 1024 * 1024, 19);
        let source = write_photo(dir.path(), "photo.jpg", &bytes);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

        let import = import_ref(&provider, &source);
        assert!(import.by_reference);
        std::thread::sleep(Duration::from_millis(120));
        let ticket = provider.serve(import.hash).unwrap();
        assert_eq!(pull(dir.path(), &ticket).unwrap(), bytes);

        provider.release(import.hash);
        wait_until_gone(&provider, import.hash);
        let files = store_files(dir.path());
        assert!(
            !has_extension(&files, "data") && !has_extension(&files, "obao4"),
            "store must hold no payload after release + GC: {files:?}"
        );
        assert_eq!(
            fs::read(&source).unwrap(),
            bytes,
            "GC never touches originals"
        );

        // After collection the same path references again.
        let again = import_ref(&provider, &source);
        assert!(again.by_reference, "{again:?}");
    }
}
