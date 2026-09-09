use std::sync::Arc;

use daemon::events;
use daemon::flow_delivery::{DeliveryError, FlowDelivery, FlowPathRegistry};
use proto::FlowFetchRequest;
use storage::{Db, Device, Role};
use tempfile::tempdir;
use transport::{Blobs, ConnectionStatus, IrohTransport, TransportConfig, ALPN_BLOBS};

fn request(epoch: &str, lease: &str, hash: [u8; 32], provider: String) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: 7,
        pairing_epoch: epoch.into(),
        lease_token: lease.into(),
        content_hash: hex::encode(hash),
        file_name: "IMG_0007.jpg".into(),
        media_type: "image/jpeg".into(),
        provider,
        capture_at_ms: 0,
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

#[tokio::test(flavor = "multi_thread")]
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

#[tokio::test(flavor = "multi_thread")]
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

/// BLOB-02: the production Flow sequence uses the durable active-grant query
/// to protect the actual iroh fetch, then releases the fetched hash after the
/// receipt makes that grant completed.
#[tokio::test(flavor = "multi_thread")]
async fn completed_flow_fetch_is_reclaimed_by_periodic_gc() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"BLOB-02 real Flow GC fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();

    let receiver_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let db = paired_db("epoch-current", provider_transport.node_id()).await;
    let callback_db = db.clone();
    let receiver_blobs = Arc::new(
        Blobs::open_with_periodic_gc(
            &receiver_transport,
            &root.path().join("flow-blobs"),
            std::time::Duration::from_millis(20),
            move || {
                let db = callback_db.clone();
                Box::pin(async move {
                    db.active_flow_content_hashes().await.map_err(|error| {
                        transport::TransportError::Io(format!(
                            "query active Flow hashes for GC protection: {error}"
                        ))
                    })
                })
                    as std::pin::Pin<
                        Box<
                            dyn std::future::Future<
                                    Output = transport::Result<std::collections::HashSet<[u8; 32]>>,
                                > + Send,
                        >,
                    >
            },
        )
        .await
        .unwrap(),
    );
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket);

    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    delivery
        .fetch(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    assert!(db
        .flow_receipt(provider_transport.node_id().0.as_slice(), 7)
        .await
        .unwrap()
        .is_some());

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while receiver_blobs.local_bytes(hash).await.unwrap() != 0 {
        assert!(
            std::time::Instant::now() < deadline,
            "the completed Flow hash was not reclaimed within one GC test window"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
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

#[tokio::test(flavor = "multi_thread")]
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

// DESK-11 RED: a successful Flow fetch materializes and receipts a phone's
// photo, but FlowDelivery (unlike BackupEngine, which wires `with_events`)
// carries no event bus — the desktop timeline is never told to refresh.
// Real-device symptom: "photo arrived, confirmed on phone, but desktop
// library doesn't show it until the next batch/hourly reconcile"
// (2026-09-06, test.5). Root cause confirmed by source read: `FlowDelivery`
// struct has no throttle/events field and `main.rs` never calls an
// equivalent `.with_events(...)` on it (contrast with
// `BackupEngine::new(...).with_events(event_bus.clone())`).
#[tokio::test(flavor = "multi_thread")]
async fn successful_flow_fetch_notifies_the_desktop_timeline() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"DESK-11 timeline notification fixture";
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
    let (event_bus, mut event_rx) = events::bus();
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs, root.path())
        .with_events_and_window(event_bus, std::time::Duration::from_millis(20));
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    delivery
        .fetch(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    // NET-05 adds three device refreshes around the pre-existing timeline
    // signal: admitted/unknown, exact blobs route, and terminal clear. The
    // timeline event must still arrive; device refreshes must not mask it.
    let mut device_changes = 0;
    let mut saw_timeline = false;
    for _ in 0..4 {
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
            .await
            .expect("Flow events must reach the desktop")
            .unwrap();
        match event["event"].as_str() {
            Some(events::DEVICE_CHANGED) => device_changes += 1,
            Some(events::TIMELINE_INVALIDATED) => saw_timeline = true,
            other => panic!("unexpected Flow desktop event: {other:?}"),
        }
    }
    assert_eq!(
        device_changes, 3,
        "begin, ready, and terminal clear must each refresh devices"
    );
    assert!(
        saw_timeline,
        "a completed Flow fetch must still refresh the timeline"
    );
}

// NET-05 RED: an old request finishing after the next strict item has started
// must not erase the new item's data-plane path. The key is the exact Flow
// lease, not only the paired control peer.
#[test]
fn old_flow_lease_cannot_clear_a_newer_data_plane_path() {
    let paths = FlowPathRegistry::default();
    let peer = transport::NodeId([0x5a; 32]);

    paths.begin(peer, 7, "lease-old");
    paths.set_if_current(peer, 7, "lease-old", ConnectionStatus::Direct);
    paths.begin(peer, 8, "lease-new");
    paths.set_if_current(peer, 8, "lease-new", ConnectionStatus::Relay);

    assert!(
        !paths.clear_if_current(peer, 7, "lease-old"),
        "stale completion must not clear the newer active transfer"
    );
    assert_eq!(paths.get(peer), Some(ConnectionStatus::Relay));
}
