use std::fs;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh_blobs::store::fs::FsStore;
use iroh_blobs::ticket::BlobTicket;
use tempfile::tempdir;
use transport::{
    AndroidBlobsProvider, Blobs, ConnectionStatus, IrohTransport, TransportConfig, ALPN_BLOBS,
};

fn blake3_of(bytes: &[u8]) -> [u8; 32] {
    *blake3::hash(bytes).as_bytes()
}

#[test]
fn provider_registration_serves_native_ticket_then_revoke_stops_it() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("source.jpg");
    let contents = b"android-native-provider";
    fs::write(&source, contents).unwrap();
    let hash = blake3_of(contents);
    let provider = AndroidBlobsProvider::new_loopback(dir.path()).unwrap();

    let ticket = provider.register_path(hash, &source).unwrap();
    let (_, ticket_hash, _) = ticket.parse::<BlobTicket>().unwrap().into_parts();
    assert_eq!(ticket_hash.as_bytes(), &hash);

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let receiver = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        let receiver_store = dir.path().join("receiver-store");
        let blobs = Blobs::open(&receiver, &receiver_store).await.unwrap();
        let destination = dir.path().join("received.jpg");
        assert_eq!(blobs.pull(&ticket, &destination).await.unwrap(), hash);
        assert_eq!(fs::read(&destination).unwrap(), contents);

        blobs.close().await;
        receiver.close().await;
    });

    provider.stop_active_fetch();
    provider.revoke();
    assert!(!provider.is_active());
}

/// NET-14 RED→GREEN: the phone (acting as the iroh-blobs sender/provider
/// here — the daemon pulls from it) must have a LOCAL fact for "did the
/// peer actually finish pulling my bytes", sourced from iroh-blobs' own
/// provider events, not from asking the remote peer anything. Before a
/// pull: no lease = `NoLease`. After a full pull completes: `Completed`
/// with the exact hash — this must flip on its own, the test never calls
/// any completion API on the provider side.
#[test]
fn transfer_status_reports_no_lease_then_completed_after_a_real_pull() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("source.jpg");
    let contents = b"net-14-local-ground-truth-completion";
    fs::write(&source, contents).unwrap();
    let hash = blake3_of(contents);
    let provider = AndroidBlobsProvider::new_loopback(dir.path()).unwrap();

    assert_eq!(
        provider.transfer_status(),
        transport::ActiveTransferStatus::NoLease,
        "before any registration there is no lease to report on"
    );

    let ticket = provider.register_path(hash, &source).unwrap();

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let receiver = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        let receiver_store = dir.path().join("receiver-store");
        let blobs = Blobs::open(&receiver, &receiver_store).await.unwrap();
        let destination = dir.path().join("received.jpg");
        assert_eq!(blobs.pull(&ticket, &destination).await.unwrap(), hash);
        blobs.close().await;
        receiver.close().await;
    });

    assert_eq!(
        provider.transfer_status(),
        transport::ActiveTransferStatus::Completed { hash },
        "a real completed pull must flip local status without anyone asking the remote peer"
    );
}

/// NET-14 RED→GREEN: while nobody has connected yet, status must say so
/// honestly (`InProgress { connected: false, .. }`), never `Completed` and
/// never silently indistinguishable from a lease that's actually being
/// pulled right now.
#[test]
fn transfer_status_before_any_connection_is_in_progress_not_connected() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("source.jpg");
    let contents = b"net-14-nobody-has-connected-yet";
    fs::write(&source, contents).unwrap();
    let hash = blake3_of(contents);
    let provider = AndroidBlobsProvider::new_loopback(dir.path()).unwrap();
    provider.register_path(hash, &source).unwrap();

    match provider.transfer_status() {
        transport::ActiveTransferStatus::InProgress {
            connected,
            idle_for,
            bytes_sent,
            byte_idle_for,
        } => {
            assert!(!connected, "nobody has dialed in yet");
            assert!(
                idle_for.is_none(),
                "no iroh-blobs event has fired yet, so there is no idle duration to report"
            );
            assert!(bytes_sent.is_none() && byte_idle_for.is_none());
        }
        other => panic!("expected InProgress{{connected:false}}, got {other:?}"),
    }
}

/// #417 (#410 参数)：3 分钟无新字节判路径失败，前提是 `RequestUpdate::Progress` 在当前
/// EventMask 下真的会到达。用一个多 MB 的 blob 做一次真实拉取，断言记录下了文件字节进度，
/// 而且进度是按 `end_offset` 前进的（不是连接事件）。反证：把 Progress 分支改回 `touch()`
/// （不记字节）→ `byte_progress()` 为 None，这条变红。
#[test]
fn byte_progress_is_recorded_from_real_transfer_progress_events() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("big.bin");
    let contents: Vec<u8> = (0..(8 * 1024 * 1024u32)).map(|i| (i % 251) as u8).collect();
    fs::write(&source, &contents).unwrap();
    let hash = blake3_of(&contents);
    let provider = AndroidBlobsProvider::new_loopback(dir.path()).unwrap();
    let ticket = provider.register_path(hash, &source).unwrap();
    assert!(
        provider.byte_progress().is_none(),
        "no bytes before anyone pulls"
    );

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let receiver = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        let blobs = Blobs::open(&receiver, &dir.path().join("receiver-store"))
            .await
            .unwrap();
        assert_eq!(
            blobs
                .pull(&ticket, &dir.path().join("received.bin"))
                .await
                .unwrap(),
            hash
        );
        blobs.close().await;
        receiver.close().await;
    });

    // The event sink is a separate task; give it a moment to drain.
    let mut progress = None;
    for _ in 0..50 {
        progress = provider.byte_progress();
        if progress.is_some_and(|(sent, _)| sent > 0) {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let (sent, _) = progress.expect("Progress events must reach the activity sink");
    assert!(
        sent > 0 && sent <= contents.len() as u64,
        "bytes_sent={sent}"
    );
}

/// #417：同一个 handler 上连续两张（成功之后只 release_retention、不 revoke——生产路径就是这样）。
/// 第二张的状态必须是它自己的：不能继承上一张的 `Completed{A}`，也不能继承上一张的 `bytes_sent`。
/// 反证：去掉 activate() 里的 activity.reset() → 注册 B 之后 status 仍是 Completed{A}，红。
#[test]
fn serial_items_on_one_handler_do_not_inherit_the_previous_lease_activity() {
    let dir = tempdir().unwrap();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    let provider = AndroidBlobsProvider::new_loopback(dir.path()).unwrap();
    let a: Vec<u8> = (0..(4 * 1024 * 1024u32)).map(|i| (i % 241) as u8).collect();
    let b: Vec<u8> = (0..(1024 * 1024u32)).map(|i| (i % 239) as u8).collect();
    let (pa, pb) = (dir.path().join("a.bin"), dir.path().join("b.bin"));
    fs::write(&pa, &a).unwrap();
    fs::write(&pb, &b).unwrap();
    let (ha, hb) = (blake3_of(&a), blake3_of(&b));

    let pull = |ticket: String, name: &str| {
        let receiver_dir = dir.path().join(format!("recv-{name}"));
        runtime.block_on(async {
            let receiver = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
            let blobs = Blobs::open(&receiver, &receiver_dir).await.unwrap();
            blobs
                .pull(&ticket, &receiver_dir.join("out.bin"))
                .await
                .unwrap();
            blobs.close().await;
            receiver.close().await;
        });
    };

    let ta = provider.register_path(ha, &pa).unwrap();
    pull(ta, "a");
    let mut completed_a = false;
    for _ in 0..50 {
        if provider.transfer_status() == (transport::ActiveTransferStatus::Completed { hash: ha }) {
            completed_a = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(completed_a, "A completes first");
    provider.release_retention();

    let tb = provider.register_path(hb, &pb).unwrap();
    match provider.transfer_status() {
        transport::ActiveTransferStatus::InProgress { bytes_sent, .. } => {
            assert!(
                bytes_sent.is_none(),
                "B starts with no bytes, not A's {bytes_sent:?}"
            )
        }
        other => panic!("B must start InProgress, got {other:?}"),
    }
    assert!(provider.byte_progress().is_none());

    pull(tb, "b");
    let mut progress = None;
    for _ in 0..50 {
        progress = provider.byte_progress();
        if progress.is_some_and(|(sent, _)| sent > 0) {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let (sent, _) = progress.expect("B reports its own byte progress");
    assert!(
        sent <= b.len() as u64,
        "bytes_sent={sent} must describe B, not A"
    );
}

#[test]
fn provider_keeps_one_endpoint_for_serial_flow_items() {
    let dir = tempdir().unwrap();
    let provider = AndroidBlobsProvider::new_loopback(dir.path()).unwrap();
    let first = b"first Android Flow item";
    let second = b"second Android Flow item";
    let first_path = dir.path().join("first.jpg");
    let second_path = dir.path().join("second.jpg");
    fs::write(&first_path, first).unwrap();
    fs::write(&second_path, second).unwrap();
    let first_hash = blake3_of(first);
    let second_hash = blake3_of(second);
    let first_ticket = provider.register_path(first_hash, &first_path).unwrap();
    let (first_addr, ticket_hash, _) = first_ticket.parse::<BlobTicket>().unwrap().into_parts();
    assert_eq!(ticket_hash.as_bytes(), &first_hash);

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    let receiver = runtime
        .block_on(IrohTransport::bind(TransportConfig::loopback(vec![
            ALPN_BLOBS.into(),
        ])))
        .unwrap();
    let blobs = runtime
        .block_on(Blobs::open(&receiver, &dir.path().join("receiver-store")))
        .unwrap();
    let provider_id = receiver.add_peer(transport::PeerAddr::from_endpoint_addr(first_addr));
    let observed = Arc::new(Mutex::new(None));
    let observed_by_callback = Arc::clone(&observed);
    runtime
        .block_on(
            blobs.fetch_from_observing_path(provider_id, first_hash, move |status| {
                *observed_by_callback.lock().unwrap() = Some(status);
            }),
        )
        .unwrap();
    assert_eq!(
        *observed.lock().unwrap(),
        Some(ConnectionStatus::Direct),
        "the callback must report the selected blobs-plane path, not ctrl state"
    );

    // This registration happens after the first fetch completed, mirroring
    // Flow's strict one-item progression. It must retain the provider NodeId
    // so the receiver's `(NodeId, ALPN)` cache can open its next stream there.
    let second_ticket = provider.register_path(second_hash, &second_path).unwrap();
    let (second_addr, ticket_hash, _) = second_ticket.parse::<BlobTicket>().unwrap().into_parts();
    assert_eq!(ticket_hash.as_bytes(), &second_hash);
    assert_eq!(provider_id, transport::NodeId(*second_addr.id.as_bytes()));
    runtime
        .block_on(blobs.fetch_from(provider_id, second_hash))
        .unwrap();

    let destination = dir.path().join("second-received.jpg");
    runtime
        .block_on(blobs.export_to(second_hash, &destination))
        .unwrap();
    assert_eq!(fs::read(destination).unwrap(), second);
    runtime.block_on(blobs.close());
    runtime.block_on(receiver.close());
}

/// BLOB-03 RED: a registered source with an active lease must survive at least
/// one GC interval while its `TempTag` holds it — the import must not create a
/// named tag (which would also survive, masking the bug), so the only thing
/// keeping the blob present is the provider's lease retention.
#[test]
fn active_lease_blob_survives_a_gc_cycle() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("source.jpg");
    let contents = b"android-provider-retained-while-leased";
    fs::write(&source, contents).unwrap();
    let hash = blake3_of(contents);

    let provider =
        AndroidBlobsProvider::new_loopback_with_gc(dir.path(), Duration::from_millis(20)).unwrap();
    provider.register_path(hash, &source).unwrap();
    assert!(provider.has_blob(hash), "blob must be imported before GC");

    // Sleep several GC periods: the active lease's TempTag is still held, so
    // the blob must not be reaped even though no named tag pins it.
    std::thread::sleep(Duration::from_millis(120));
    assert!(
        provider.has_blob(hash),
        "an active lease's blob must survive multiple GC cycles"
    );

    // Revoke drops the TempTag; the next pass must reclaim it.
    provider.revoke();
    wait_until_gone(&provider, hash);
}

/// BLOB-03: release_retention (the success boundary) drops only the lease tag
/// — not the handler — so the blob is reclaimable while the endpoint and ALPN
/// handler remain alive for the next serial item's connection reuse.
#[test]
fn released_blob_is_reclaimed_but_endpoint_survives_for_reuse() {
    let dir = tempdir().unwrap();
    let first = dir.path().join("first.jpg");
    let second = dir.path().join("second.jpg");
    let first_bytes = b"first serial Flow item";
    let second_bytes = b"second serial Flow item";
    fs::write(&first, first_bytes).unwrap();
    fs::write(&second, second_bytes).unwrap();
    let first_hash = blake3_of(first_bytes);
    let second_hash = blake3_of(second_bytes);

    let provider =
        AndroidBlobsProvider::new_loopback_with_gc(dir.path(), Duration::from_millis(20)).unwrap();

    let first_ticket = provider.register_path(first_hash, &first).unwrap();
    let (first_addr, ticket_hash, _) = first_ticket.parse::<BlobTicket>().unwrap().into_parts();
    assert_eq!(ticket_hash.as_bytes(), &first_hash);

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    let provider_id = runtime.block_on(async {
        let receiver = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        let blobs = Blobs::open(&receiver, &dir.path().join("receiver-store"))
            .await
            .unwrap();
        let provider_id = receiver.add_peer(transport::PeerAddr::from_endpoint_addr(first_addr));
        blobs.fetch_from(provider_id, first_hash).await.unwrap();
        (provider_id, receiver, blobs)
    });
    let (provider_id, receiver, blobs) = provider_id;

    // Validated successful transfer -> release retention WITHOUT revoking.
    provider.release_retention();
    assert!(provider.is_active(), "release must not drop the endpoint");
    // GC must reclaim the released blob even though the endpoint stays alive.
    wait_until_gone(&provider, first_hash);

    // The next serial item reuses the same endpoint and serves correctly.
    let second_ticket = provider.register_path(second_hash, &second).unwrap();
    let (second_addr, ticket_hash, _) = second_ticket.parse::<BlobTicket>().unwrap().into_parts();
    assert_eq!(ticket_hash.as_bytes(), &second_hash);
    assert_eq!(provider_id, transport::NodeId(*second_addr.id.as_bytes()));
    runtime
        .block_on(blobs.fetch_from(provider_id, second_hash))
        .unwrap();

    provider.revoke();
    runtime.block_on(blobs.close());
    runtime.block_on(receiver.close());
}

/// BLOB-03 migration: old builds awaited AddProgress directly, leaving a
/// persistent named tag in the provider-only store. Opening a repaired
/// provider must release that legacy tag so its data is eligible for GC; an
/// upgrade must not merely prevent future growth while preserving old copies.
#[test]
fn opening_provider_releases_legacy_named_tag_for_gc() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("legacy-source.jpg");
    let bytes = b"legacy Android provider blob";
    fs::write(&source, bytes).unwrap();
    let hash = blake3_of(bytes);
    let provider_root = dir.path().join("iroh-blobs-provider");

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let store = FsStore::load(&provider_root).await.unwrap();
        // Intentionally reproduce the pre-BLOB-03 default: IntoFuture calls
        // AddProgress::with_tag(), which creates a persistent named tag.
        store.blobs().add_path(&source).await.unwrap();
        assert!(store.blobs().has(hash).await.unwrap());
        // An app update starts a new process. Explicitly shut down this
        // old-version store before the upgraded provider reopens its database,
        // rather than hanging the test on an intentional exclusive store lock.
        store.shutdown().await.unwrap();
    });
    drop(runtime);

    let provider =
        AndroidBlobsProvider::new_loopback_with_gc(dir.path(), Duration::from_millis(20)).unwrap();
    wait_until_gone(&provider, hash);
}

fn wait_until_gone(provider: &AndroidBlobsProvider, hash: [u8; 32]) {
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while provider.has_blob(hash) {
        assert!(
            std::time::Instant::now() < deadline,
            "revoked blob was not reclaimed by periodic GC"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
