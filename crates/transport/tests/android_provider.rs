use std::fs;
use std::sync::{Arc, Mutex};

use iroh_blobs::ticket::BlobTicket;
use tempfile::tempdir;
use transport::{
    AndroidBlobsProvider, Blobs, ConnectionStatus, IrohTransport, TransportConfig, ALPN_BLOBS,
};

#[test]
fn provider_registration_serves_native_ticket_then_revoke_stops_it() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("source.jpg");
    let contents = b"android-native-provider";
    fs::write(&source, contents).unwrap();
    let hash = *blake3::hash(contents).as_bytes();
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
    let first_hash = *blake3::hash(first).as_bytes();
    let second_hash = *blake3::hash(second).as_bytes();
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
