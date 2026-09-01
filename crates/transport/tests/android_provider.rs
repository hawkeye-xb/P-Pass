use std::fs;

use iroh_blobs::ticket::BlobTicket;
use tempfile::tempdir;
use transport::{AndroidBlobsProvider, Blobs, IrohTransport, TransportConfig, ALPN_BLOBS};

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
