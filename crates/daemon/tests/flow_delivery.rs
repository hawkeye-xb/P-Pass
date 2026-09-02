use std::sync::Arc;

use daemon::flow_delivery::{DeliveryError, FlowDelivery};
use proto::FlowFetchRequest;
use storage::{Db, Device, Role};
use tempfile::tempdir;
use transport::{Blobs, IrohTransport, TransportConfig, ALPN_BLOBS};

fn request(epoch: &str, lease: &str, hash: [u8; 32], provider: String) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: 7,
        pairing_epoch: epoch.into(),
        lease_token: lease.into(),
        content_hash: hex::encode(hash),
        file_name: "IMG_0007.jpg".into(),
        media_type: "image/jpeg".into(),
        provider,
    }
}

async fn paired_db(epoch: &str, peer: transport::NodeId) -> Db {
    let db = Db::open_in_memory().await.unwrap();
    db.upsert_device(&Device {
        node_id: peer.0.to_vec(),
        name: "phone".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
        device_hint: None,
    })
    .await
    .unwrap();
    db.set_pairing_epoch(&peer.0, epoch).await.unwrap();
    db
}

#[tokio::test]
async fn mismatched_epoch_lease_or_hash_never_starts_a_native_fetch() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let provider_blobs = Arc::new(provider_blobs);
    let source = root.path().join("source.jpg");
    std::fs::write(&source, b"native fetch guard fixture").unwrap();
    let hash = *blake3::hash(b"native fetch guard fixture").as_bytes();
    provider_blobs.import(hash, &source).await.unwrap();

    let receiver_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", provider_transport.node_id()).await;
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
    let provider = provider_transport.local_addr().to_string();
    let current = request("epoch-current", "lease-current", hash, provider.clone());
    delivery
        .offer(provider_transport.node_id(), &current)
        .await
        .unwrap();

    for invalid in [
        request("epoch-stale", "lease-current", hash, provider.clone()),
        request("epoch-current", "lease-stale", hash, provider.clone()),
        request("epoch-current", "lease-current", [0x44; 32], provider),
    ] {
        assert!(matches!(
            delivery.fetch(provider_transport.node_id(), &invalid).await,
            Err(DeliveryError::GuardMismatch)
        ));
    }
    assert_eq!(receiver_blobs.local_bytes(hash).await.unwrap(), 0);
    assert!(db
        .flow_receipt(provider_transport.node_id().0.as_slice(), 7)
        .await
        .unwrap()
        .is_none());
}

#[tokio::test]
async fn verified_native_fetch_materializes_before_a_durable_receipt() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let provider_blobs = Arc::new(provider_blobs);
    let bytes = b"verified native fetch fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();

    let receiver_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", provider_transport.node_id()).await;
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs, root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket.clone());
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    let receipt = delivery
        .fetch(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    assert_eq!(receipt.queue_sequence, 7);
    assert_eq!(receipt.pairing_epoch, "epoch-current");
    assert_eq!(receipt.lease_token, "lease-current");
    assert_eq!(receipt.content_hash, hex::encode(hash));
    assert!(!receipt.receipt_id.is_empty());
    assert!(
        db.get_asset(&hash).await.unwrap().is_some(),
        "receipt requires indexed materialization"
    );
    let persisted = db
        .flow_receipt(provider_transport.node_id().0.as_slice(), 7)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        persisted.receipt_id, receipt.receipt_id,
        "receipt must be durable before returning"
    );

    let resumed = request("epoch-current", "lease-recovered", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &resumed)
        .await
        .expect("same epoch and hash may rebind a recovered lease");
    let resumed_receipt = delivery
        .fetch(provider_transport.node_id(), &resumed)
        .await
        .expect("completed content must replay its durable receipt");
    assert_eq!(resumed_receipt.receipt_id, receipt.receipt_id);
    assert_eq!(resumed_receipt.lease_token, "lease-recovered");
}

#[tokio::test]
async fn authenticated_control_peer_may_offer_a_distinct_native_provider_ticket() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"separate Android provider endpoint";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();

    let control_transport = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    assert_ne!(provider_transport.node_id(), control_transport.node_id());
    let receiver_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", control_transport.node_id()).await;
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs, root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket);

    delivery
        .offer(control_transport.node_id(), &offer)
        .await
        .unwrap();
    let receipt = delivery
        .fetch(control_transport.node_id(), &offer)
        .await
        .unwrap();

    assert_eq!(receipt.content_hash, hex::encode(hash));
    assert!(db.get_asset(&hash).await.unwrap().is_some());
}

#[tokio::test]
async fn cancelled_active_item_never_receives_a_receipt() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let source = root.path().join("source.jpg");
    let bytes = b"cancelled native fetch fixture";
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    provider_blobs.import(hash, &source).await.unwrap();

    let receiver_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", provider_transport.node_id()).await;
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
    let offer = request(
        "epoch-current",
        "lease-current",
        hash,
        provider_transport.local_addr().to_string(),
    );
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    delivery
        .cancel(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    assert!(matches!(
        delivery.fetch(provider_transport.node_id(), &offer).await,
        Err(DeliveryError::Cancelled)
    ));
    assert_eq!(
        receiver_blobs.local_bytes(hash).await.unwrap(),
        0,
        "cancelled work must not fetch"
    );
    assert!(db
        .flow_receipt(provider_transport.node_id().0.as_slice(), 7)
        .await
        .unwrap()
        .is_none());
}
