use std::fs;
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
