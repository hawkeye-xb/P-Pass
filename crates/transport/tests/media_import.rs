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

/// Pull [ticket] from a fresh loopback receiver, bounded by [PULL_TIMEOUT].
/// The receiver plays the paired desktop: #547 admits only the NodeId the
/// provider was told about, so the helper registers it first.
fn pull(provider: &AndroidBlobsProvider, dir: &Path, ticket: &str) -> Result<Vec<u8>, String> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let receiver = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        provider.set_allowed_peer(Some(receiver.node_id()));
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

/// Wait until the store reports `hash` gone. The 15 s cap only matters when GC
/// really never reclaims it; on a healthy run this returns within a few GC ticks.
fn wait_until_gone(provider: &AndroidBlobsProvider, hash: [u8; 32]) {
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while provider.has_blob(hash) {
        assert!(
            std::time::Instant::now() < deadline,
            "released content was not reclaimed by periodic GC"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// #703: `has_blob` going false is the store's bookkeeping; the payload files are
/// removed only when the batch holding the GC delete commits. Sync the store so
/// the disk assertion that follows measures the committed state, not a race.
#[cfg(feature = "android-jni")]
fn wait_until_gone_on_disk(provider: &AndroidBlobsProvider, hash: [u8; 32]) {
    wait_until_gone(provider, hash);
    provider.sync_store().expect("sync provider store");
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
    assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), bytes);
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
    assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), bytes);

    provider.release(import.hash);
    wait_until_gone(&provider, import.hash);
    // The on-disk residue check lives in the gated module: on Windows a file
    // the store still has open may outlive its entry.
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

/// NET-29: an endpoint whose only relay is a closed local port — iroh's
/// `online()` can never resolve, exactly like the provider endpoint in the
/// #467 captures that never got a home relay connected. Minimal preset: no
/// n0 address lookup, so this stays fully offline.
fn never_online() -> TransportConfig {
    TransportConfig {
        relay_urls: vec!["http://127.0.0.1:1".into()],
        n0_services: false,
        secret_key: None,
        alpns: vec![ALPN_BLOBS.into()],
        bind_addr: None,
    }
}

const NET29_ONLINE_TIMEOUT: Duration = Duration::from_millis(400);

/// NET-29 (#467) RED→GREEN: the first endpoint never comes online. The serve
/// must fail as `provider_offline` (wording the Android caller classifies)
/// with the stuck endpoint's diagnostics, and must leave a freshly bound
/// endpoint behind — so the very next serve in the SAME process succeeds and
/// the bytes pull intact, with the held import and the shared store surviving
/// the stuck endpoint's retirement.
#[test]
fn an_endpoint_that_never_comes_online_is_replaced_and_the_next_serve_succeeds() {
    let dir = tempdir().unwrap();
    let bytes = photo_bytes(40 * 1024, 29);
    let source = write_photo(dir.path(), "photo.jpg", &bytes);
    let provider = AndroidBlobsProvider::with_endpoint_factory(
        dir.path(),
        |generation| match generation {
            0 => never_online(),
            _ => TransportConfig::loopback(vec![ALPN_BLOBS.into()]),
        },
        NET29_ONLINE_TIMEOUT,
    )
    .unwrap();
    let import = provider
        .import_media(None, File::open(&source).unwrap())
        .unwrap();
    let stuck = provider.endpoint_node_id().expect("bind provider endpoint");

    let error = provider.serve(import.hash).unwrap_err().to_string();
    assert!(error.contains("did not become online"), "{error}");
    assert!(
        error.contains("homeRelay=["),
        "diagnostics missing: {error}"
    );
    assert!(
        provider.is_held(import.hash),
        "replacing the endpoint must not drop held imports"
    );

    // Let the stuck endpoint's retirement (router shutdown) finish first: it
    // must not have shut the shared store down.
    std::thread::sleep(Duration::from_millis(500));
    let ticket = provider
        .serve(import.hash)
        .expect("the next serve in the same process must not hit the stuck endpoint again");
    assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), bytes);
    assert_eq!(
        provider.transfer_status(),
        ActiveTransferStatus::Completed { hash: import.hash }
    );
    assert_eq!(provider.endpoint_generation(), 1, "{error}");
    assert_ne!(
        provider.endpoint_node_id().expect("bind provider endpoint"),
        stuck,
        "the ticket must come from a new endpoint"
    );
}

/// NET-29: retiring a replaced endpoint while an earlier lease's handler is
/// installed (serial items: item 1 served, the endpoint then loses its relay)
/// must only close that endpoint. Its router shutdown reaching the shared
/// handler would shut the provider store down (`BlobsProtocol::shutdown`),
/// and every later item would fail on the replacement endpoint.
#[test]
fn retiring_a_replaced_endpoint_keeps_the_shared_store_serving() {
    let dir = tempdir().unwrap();
    let first = photo_bytes(40 * 1024, 31);
    let second = photo_bytes(40 * 1024, 32);
    let first_source = write_photo(dir.path(), "first.jpg", &first);
    let second_source = write_photo(dir.path(), "second.jpg", &second);
    let provider = AndroidBlobsProvider::with_endpoint_factory(
        dir.path(),
        |_| TransportConfig::loopback(vec![ALPN_BLOBS.into()]),
        NET29_ONLINE_TIMEOUT,
    )
    .unwrap();
    let first_import = provider
        .import_media(None, File::open(&first_source).unwrap())
        .unwrap();
    let ticket = provider.serve(first_import.hash).unwrap();
    assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), first);
    provider.release_retention();

    let replaced = provider.replace_endpoint_for_test();
    assert!(replaced.starts_with("replaced by"), "{replaced}");
    std::thread::sleep(Duration::from_millis(500));

    let second_import = provider
        .import_media(None, File::open(&second_source).unwrap())
        .expect("the provider store must survive the old endpoint's retirement");
    let ticket = provider.serve(second_import.hash).unwrap();
    assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), second);
}

/// NET-29: an endpoint that stays offline is replaced on EVERY failed serve —
/// every attempt gets a fresh endpoint instead of the same stuck one, and the
/// deadline stays the same (no widened wait inside one serve).
#[test]
fn a_persistently_offline_provider_replaces_its_endpoint_on_each_failed_serve() {
    let dir = tempdir().unwrap();
    let bytes = photo_bytes(20 * 1024, 30);
    let source = write_photo(dir.path(), "photo.jpg", &bytes);
    let provider = AndroidBlobsProvider::with_endpoint_factory(
        dir.path(),
        |_| never_online(),
        NET29_ONLINE_TIMEOUT,
    )
    .unwrap();
    let import = provider
        .import_media(None, File::open(&source).unwrap())
        .unwrap();

    let mut seen = vec![provider.endpoint_node_id().expect("bind provider endpoint")];
    for attempt in 1..=3u64 {
        let started = std::time::Instant::now();
        let error = provider.serve(import.hash).unwrap_err().to_string();
        let took = started.elapsed();
        assert!(error.contains("did not become online"), "{error}");
        assert!(
            took < NET29_ONLINE_TIMEOUT * 3,
            "one serve waits one deadline, took {took:?}"
        );
        assert_eq!(provider.endpoint_generation(), attempt);
        let id = provider.endpoint_node_id().expect("bind provider endpoint");
        assert!(
            !seen.contains(&id),
            "attempt {attempt} reused a stuck endpoint"
        );
        seen.push(id);
    }
    assert!(provider.is_held(import.hash));
}

#[cfg(feature = "android-jni")]
mod reference {
    use super::*;
    use std::io::{Seek, SeekFrom, Write};
    use transport::SourceFault;

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
        let pulled = pull(provider, dir, ticket);
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
        assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), bytes);
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
        assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), bytes);
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
    fn copy_import_release_leaves_no_payload_on_disk() {
        let dir = tempdir().unwrap();
        let bytes = photo_bytes(2 * 1024 * 1024, 20);
        let source = write_photo(dir.path(), "photo.jpg", &bytes);
        let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();

        let import = provider
            .import_media(None, File::open(&source).unwrap())
            .unwrap();
        assert!(has_extension(&store_files(dir.path()), "data"));
        provider.release(import.hash);
        wait_until_gone_on_disk(&provider, import.hash);
        let files = store_files(dir.path());
        assert!(
            !has_extension(&files, "data") && !has_extension(&files, "obao4"),
            "store must hold no payload after release + GC: {files:?}"
        );
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
        assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), bytes);

        provider.release(import.hash);
        wait_until_gone_on_disk(&provider, import.hash);
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

/// #434: an idle provider holds no endpoint (a bound one pings relays and
/// re-runs net reports forever); park after a finished pull drops it, and the
/// next serve binds a fresh one that still serves from the same store.
#[test]
fn endpoint_is_bound_on_demand_and_parked_when_idle() {
    let dir = tempdir().unwrap();
    let first = photo_bytes(64 * 1024, 434);
    let second = photo_bytes(64 * 1024, 435);
    let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();
    assert!(
        !provider.is_endpoint_bound(),
        "open must not bind an endpoint"
    );

    let import = provider
        .import_media(
            None,
            File::open(write_photo(dir.path(), "a.jpg", &first)).unwrap(),
        )
        .unwrap();
    assert!(
        !provider.is_endpoint_bound(),
        "import is local: still no endpoint"
    );
    let ticket = provider.serve(import.hash).unwrap();
    assert!(provider.is_endpoint_bound());
    assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), first);
    let first_id = provider.endpoint_node_id().unwrap();

    assert!(provider.park(), "a finished pull must not block park");
    assert!(!provider.is_endpoint_bound());
    provider.network_change(); // no endpoint: a no-op, not a rebind
    assert!(!provider.is_endpoint_bound());
    provider.prewarm().unwrap();
    assert!(provider.is_endpoint_bound(), "prewarm binds ahead of serve");
    let prewarmed = provider.endpoint_node_id().unwrap();

    let import = provider
        .import_media(
            None,
            File::open(write_photo(dir.path(), "b.jpg", &second)).unwrap(),
        )
        .unwrap();
    let ticket = provider.serve(import.hash).unwrap();
    assert!(provider.is_endpoint_bound(), "serve after park rebinds");
    assert_ne!(provider.endpoint_node_id().unwrap(), first_id);
    assert_eq!(
        provider.endpoint_node_id().unwrap(),
        prewarmed,
        "serve uses the prewarmed endpoint"
    );
    assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), second);
}

/// #434 反证: park must refuse while the desktop is connected to the current
/// lease — it would cut a live transfer.
#[test]
fn park_is_refused_while_a_peer_is_connected() {
    let dir = tempdir().unwrap();
    let bytes = photo_bytes(8 * 1024 * 1024, 436);
    let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();
    let import = provider
        .import_media(
            None,
            File::open(write_photo(dir.path(), "big.jpg", &bytes)).unwrap(),
        )
        .unwrap();
    let ticket = provider.serve(import.hash).unwrap();

    std::thread::scope(|scope| {
        let puller = scope.spawn(|| pull(&provider, dir.path(), &ticket));
        let deadline = std::time::Instant::now() + PULL_TIMEOUT;
        let mut refused = false;
        while std::time::Instant::now() < deadline && !puller.is_finished() {
            if matches!(
                provider.transfer_status(),
                ActiveTransferStatus::InProgress {
                    connected: true,
                    ..
                }
            ) {
                refused = !provider.park();
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(refused, "park was not refused while the peer was connected");
        assert!(provider.is_endpoint_bound());
        assert_eq!(puller.join().unwrap().unwrap(), bytes);
    });
}

/// #584: park must RELEASE the endpoint's UDP sockets, not just stop using
/// them. iroh frees the sockets only once every `Endpoint` clone is dropped,
/// and a retired endpoint whose shutdown pends on the peer's close ack leaks
/// them (observed on Mate60 / Samsung: one v4+v6 pair per transfer round).
/// Guard: after park, the retirement settles and the previously bound ports
/// disappear from /proc/net/udp{,6}. Both are polled: the retire task runs on
/// the provider's runtime, and iroh's own internal tasks drop their endpoint
/// clones a beat after `Endpoint::close` resolves — a one-shot read would
/// race that teardown.
#[test]
fn park_releases_the_endpoints_udp_sockets() {
    let dir = tempdir().unwrap();
    let bytes = photo_bytes(64 * 1024, 584);
    let provider = AndroidBlobsProvider::new_loopback_with_gc(dir.path(), GC).unwrap();
    let import = provider
        .import_media(
            None,
            File::open(write_photo(dir.path(), "a.jpg", &bytes)).unwrap(),
        )
        .unwrap();
    let ticket = provider.serve(import.hash).unwrap();
    assert_eq!(pull(&provider, dir.path(), &ticket).unwrap(), bytes);
    let ports = provider.bound_socket_ports();
    assert!(!ports.is_empty(), "a bound endpoint must hold UDP sockets");

    assert!(provider.park(), "a finished pull must not block park");

    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while provider.pending_retirements() > 0 && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        provider.pending_retirements(),
        0,
        "retire did not settle: the endpoint shutdown is stuck"
    );

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let in_use = udp_ports_in_use();
        let leaked: Vec<u16> = ports
            .iter()
            .copied()
            .filter(|port| in_use.contains(port))
            .collect();
        if leaked.is_empty() {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "ports {leaked:?} still bound after park: the endpoint's socket leaked"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// #584: UDP ports currently bound on this host, read from
/// /proc/net/udp{,6} (hex `local_address` column).
fn udp_ports_in_use() -> std::collections::HashSet<u16> {
    let mut ports = std::collections::HashSet::new();
    for path in ["/proc/net/udp", "/proc/net/udp6"] {
        let Ok(table) = std::fs::read_to_string(path) else {
            continue;
        };
        for line in table.lines().skip(1) {
            let Some(local) = line.split_whitespace().nth(1) else {
                continue;
            };
            let Some((_, port)) = local.rsplit_once(':') else {
                continue;
            };
            if let Ok(port) = u16::from_str_radix(port, 16) {
                ports.insert(port);
            }
        }
    }
    ports
}
