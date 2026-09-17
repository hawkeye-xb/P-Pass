use std::path::Path;
use std::sync::Arc;

use daemon::events;
use daemon::flow_delivery::{DeliveryError, FlowDelivery, FlowPathRegistry};
use daemon::Telemetry;
use proto::FlowFetchRequest;
use storage::{Asset, Db, Device, Role};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
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
        .flow_receipt(
            provider_transport.node_id().0.as_slice(),
            "epoch-current",
            7
        )
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
        .flow_receipt(
            provider_transport.node_id().0.as_slice(),
            "epoch-current",
            7,
        )
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

#[tokio::test(flavor = "multi_thread")]
async fn concurrent_retries_of_one_grant_share_the_durable_receipt() {
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
    // Big enough that the two loopback fetches overlap without relying on a
    // timing sleep in the production code.
    let bytes = vec![0x5a; 8 * 1024 * 1024];
    let source = root.path().join("large-source.jpg");
    std::fs::write(&source, &bytes).unwrap();
    let hash = *blake3::hash(&bytes).as_bytes();
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
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    let (first, second) = tokio::join!(
        delivery.fetch(provider_transport.node_id(), &offer),
        delivery.fetch(provider_transport.node_id(), &offer),
    );
    let first = first.expect("first fetch must materialize");
    let second = second.expect("concurrent retry must replay receipt");
    assert_eq!(first.receipt_id, second.receipt_id);
    assert!(db.get_asset(&hash).await.unwrap().is_some());
}

/// REBUILD-07 RED: a phone keeps its NodeId across a revoke/rejoin, but a
/// rejoin rotates the pairing epoch and Android restarts its durable sequence
/// at 1. Old completed receipts must remain history, never occupy the new
/// epoch's sequence namespace.
#[tokio::test(flavor = "multi_thread")]
async fn rejoined_device_reuses_a_sequence_in_its_new_pairing_epoch() {
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
    let receiver_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-before-rejoin", provider_transport.node_id()).await;
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs, root.path());

    let old_bytes = b"REBUILD-07 original photo";
    let old_source = root.path().join("old.jpg");
    std::fs::write(&old_source, old_bytes).unwrap();
    let old_hash = *blake3::hash(old_bytes).as_bytes();
    let old_ticket = provider_blobs.push(old_hash, &old_source).await.unwrap();
    let old_request = request("epoch-before-rejoin", "old-lease", old_hash, old_ticket);
    delivery
        .offer(provider_transport.node_id(), &old_request)
        .await
        .unwrap();
    delivery
        .fetch(provider_transport.node_id(), &old_request)
        .await
        .unwrap();
    assert!(db.get_asset(&old_hash).await.unwrap().is_some());

    db.set_pairing_epoch(&provider_transport.node_id().0, "epoch-after-rejoin")
        .await
        .unwrap();
    let new_bytes = b"REBUILD-07 photo after rejoin";
    let new_source = root.path().join("new.jpg");
    std::fs::write(&new_source, new_bytes).unwrap();
    let new_hash = *blake3::hash(new_bytes).as_bytes();
    let new_ticket = provider_blobs.push(new_hash, &new_source).await.unwrap();
    let new_request = request("epoch-after-rejoin", "new-lease", new_hash, new_ticket);

    delivery
        .offer(provider_transport.node_id(), &new_request)
        .await
        .expect("the new pairing epoch owns a fresh sequence namespace");
    delivery
        .fetch(provider_transport.node_id(), &new_request)
        .await
        .expect("newly authorised work with the reused sequence must complete");
    assert!(db.get_asset(&old_hash).await.unwrap().is_some());
    assert!(db.get_asset(&new_hash).await.unwrap().is_some());
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
        .flow_receipt(
            provider_transport.node_id().0.as_slice(),
            "epoch-current",
            7
        )
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
    std::fs::write(&source, &bytes).unwrap();
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
        .flow_receipt(
            provider_transport.node_id().0.as_slice(),
            "epoch-current",
            7
        )
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
    // NET-14 adds one more: a completed fetch also pushes `flow.delivered`
    // for the phone's subscribed status.
    let mut device_changes = 0;
    let mut saw_timeline = false;
    let mut saw_delivered = false;
    for _ in 0..5 {
        let event = tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
            .await
            .expect("Flow events must reach the desktop")
            .unwrap();
        match event["event"].as_str() {
            Some(events::DEVICE_CHANGED) => device_changes += 1,
            Some(events::TIMELINE_INVALIDATED) => saw_timeline = true,
            Some(events::FLOW_DELIVERED) => {
                saw_delivered = true;
                assert_eq!(
                    event["data"]["node_id"].as_str(),
                    Some(provider_transport.node_id().to_string()).as_deref(),
                    "flow.delivered must name the phone it belongs to"
                );
                assert!(
                    event["data"]["receipt"]["receipt_id"].as_str().is_some(),
                    "flow.delivered must carry the same receipt the phone would get from status()"
                );
            }
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
    assert!(
        saw_delivered,
        "NET-14: a completed Flow fetch must push flow.delivered, not rely solely on the phone's next status() poll"
    );
}

// NET-14 RED: a background fetch task that ends in a real (not suspended/
// cancelled) failure must push `flow.failed` — the phone must learn this
// from a push, not only by noticing its next status() poll still says
// "in progress" forever.
#[tokio::test(flavor = "multi_thread")]
async fn failed_background_fetch_pushes_flow_failed_with_node_id_and_tuple() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"NET-14 flow.failed push fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let provider_node = provider_transport.node_id();

    let receiver_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", provider_node).await;
    let (event_bus, mut event_rx) = events::bus();
    let delivery = FlowDelivery::new(db, receiver_blobs, root.path())
        .with_events_and_window(event_bus, std::time::Duration::from_millis(20));
    let offer = request("epoch-current", "lease-current", hash, ticket);

    // Take the provider fully offline BEFORE offer() spawns the background
    // fetch task — mirrors network_fetch_failure_records_a_fetch_failed_
    // error_at_fetch_stage's proven pattern for a real (not fabricated)
    // network failure.
    provider_transport.close().await;
    drop(provider_blobs);
    drop(provider_transport);
    delivery.offer(provider_node, &offer).await.unwrap();

    // Drain events until flow.failed arrives (device_changed/timeline
    // events may interleave; this test only cares that flow.failed shows
    // up with the right shape).
    let failed = tokio::time::timeout(std::time::Duration::from_secs(45), async {
        loop {
            let event = event_rx.recv().await.unwrap();
            if event["event"].as_str() == Some(events::FLOW_FAILED) {
                return event;
            }
        }
    })
    .await
    .expect("a background fetch failure must push flow.failed within a few seconds");

    assert_eq!(
        failed["data"]["node_id"].as_str(),
        Some(provider_node.to_string()).as_deref(),
        "flow.failed must name the phone whose fetch failed"
    );
    assert_eq!(failed["data"]["queue_sequence"].as_u64(), Some(7));
    assert_eq!(
        failed["data"]["lease_token"].as_str(),
        Some("lease-current")
    );
    assert_eq!(failed["data"]["code"].as_str(), Some("fetch_failed"));
}

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

// ── TEL-02: FlowDelivery.fetch() records anonymized telemetry ──

/// Minimal HTTP/1.1 server: counts requests, captures JSON bodies. Mirrors
/// `crates/daemon/tests/telemetry_flow.rs`'s helper (kept local — that file
/// is a different test binary, and the fixture is small enough not to be
/// worth a shared dev-dependency crate for two call sites).
async fn mock_telemetry_server() -> (
    String,
    Arc<std::sync::atomic::AtomicUsize>,
    Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/telemetry", listener.local_addr().unwrap());
    let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let bodies: Arc<std::sync::Mutex<Vec<serde_json::Value>>> = Arc::default();
    let (h, b) = (Arc::clone(&hits), Arc::clone(&bodies));
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            h.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let b = Arc::clone(&b);
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut tmp = [0u8; 4096];
                loop {
                    let Ok(n) = sock.read(&mut tmp).await else {
                        return;
                    };
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
                    {
                        let headers = String::from_utf8_lossy(&buf[..pos]);
                        let len = headers
                            .lines()
                            .find_map(|l| {
                                l.to_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().ok())
                            })
                            .flatten()
                            .unwrap_or(0);
                        if buf.len() >= pos + len {
                            if let Ok(v) = serde_json::from_slice(&buf[pos..pos + len]) {
                                b.lock().unwrap().push(v);
                            }
                            break;
                        }
                    }
                }
                let _ = sock
                    .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
                    .await;
            });
        }
    });
    (url, hits, bodies)
}

#[tokio::test(flavor = "multi_thread")]
async fn successful_fetch_records_one_conn_and_one_flow_item_event() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"TEL-02 telemetry fixture bytes";
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

    let (telemetry_url, hits, bodies) = mock_telemetry_server().await;
    let telemetry_dir = tempdir().unwrap();
    let telemetry = Telemetry::new(true, telemetry_url, telemetry_dir.path());
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs, root.path())
        .with_telemetry(telemetry.clone());
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    delivery
        .fetch(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    assert_eq!(telemetry.flush_now().await, 2, "one conn + one flow_item");
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
    let batch = bodies.lock().unwrap()[0].clone();
    let events: Vec<&str> = batch
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["event"].as_str().unwrap())
        .collect();
    assert_eq!(events, ["conn", "flow_item"]);
    assert_eq!(batch[0]["fail_stage"], serde_json::Value::Null);
    assert_eq!(batch[1]["bytes"], bytes.len() as u64);
    assert_eq!(batch[1]["resumed"], false);
}

#[tokio::test(flavor = "multi_thread")]
async fn disabled_telemetry_means_zero_network_calls_from_flow_delivery() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"TEL-02 disabled telemetry fixture";
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

    let (telemetry_url, hits, _bodies) = mock_telemetry_server().await;
    let telemetry_dir = tempdir().unwrap();
    let telemetry = Telemetry::new(false, telemetry_url, telemetry_dir.path());
    let delivery = FlowDelivery::new(db.clone(), receiver_blobs, root.path())
        .with_telemetry(telemetry.clone());
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    delivery
        .fetch(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    assert_eq!(telemetry.flush_now().await, 0);
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(
        hits.load(std::sync::atomic::Ordering::SeqCst),
        0,
        "disabled telemetry must mean ZERO network calls even through FlowDelivery"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn invalid_request_records_an_error_event_tagged_with_its_stage() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&provider_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", provider_transport.node_id()).await;

    let (telemetry_url, _hits, bodies) = mock_telemetry_server().await;
    let telemetry_dir = tempdir().unwrap();
    let telemetry = Telemetry::new(true, telemetry_url, telemetry_dir.path());
    let delivery =
        FlowDelivery::new(db, receiver_blobs, root.path()).with_telemetry(telemetry.clone());

    // Empty file_name trips checked_request's field presence guard —
    // InvalidRequest, no network involved at all.
    let mut bad = request(
        "epoch-current",
        "lease-current",
        [0x11; 32],
        "unused".into(),
    );
    bad.file_name = String::new();
    assert!(matches!(
        delivery.offer(provider_transport.node_id(), &bad).await,
        Err(DeliveryError::InvalidRequest(_))
    ));

    assert_eq!(telemetry.flush_now().await, 1, "one error event");
    let batch = bodies.lock().unwrap()[0].clone();
    let event = &batch.as_array().unwrap()[0];
    assert_eq!(event["event"], "error");
    assert_eq!(event["code"], "invalid_request");
    assert_eq!(event["stage"], "offer");
    // 隐私红线：code/stage 只能是固定词汇，绝不能带原始错误文本/路径。
    let raw = event.to_string();
    assert!(!raw.contains("missing required item field"));
}

#[tokio::test(flavor = "multi_thread")]
async fn network_fetch_failure_records_a_fetch_failed_error_at_fetch_stage() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"TEL-03 network failure fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let provider_node = provider_transport.node_id();

    let receiver_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", provider_node).await;

    let (telemetry_url, _hits, bodies) = mock_telemetry_server().await;
    let telemetry_dir = tempdir().unwrap();
    let telemetry = Telemetry::new(true, telemetry_url, telemetry_dir.path());
    let delivery =
        FlowDelivery::new(db, receiver_blobs, root.path()).with_telemetry(telemetry.clone());
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery.offer(provider_node, &offer).await.unwrap();

    // Take the provider fully offline after the ticket is issued but
    // before the fetch runs — a real network failure, not a fabricated
    // error variant.
    provider_transport.close().await;
    drop(provider_blobs);
    drop(provider_transport);

    assert!(matches!(
        delivery.fetch(provider_node, &offer).await,
        Err(DeliveryError::Fetch(_))
    ));

    assert_eq!(telemetry.flush_now().await, 2, "one conn + one error");
    let batch = bodies.lock().unwrap()[0].clone();
    let events: Vec<&str> = batch
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["event"].as_str().unwrap())
        .collect();
    assert_eq!(events, ["conn", "error"]);
    let error_event = &batch.as_array().unwrap()[1];
    assert_eq!(error_event["code"], "fetch_failed");
    assert_eq!(error_event["stage"], "fetch");
}

#[tokio::test(flavor = "multi_thread")]
async fn repeated_same_error_is_deduped_within_the_flush_window() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&provider_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", provider_transport.node_id()).await;

    let (telemetry_url, _hits, bodies) = mock_telemetry_server().await;
    let telemetry_dir = tempdir().unwrap();
    let telemetry = Telemetry::new(true, telemetry_url, telemetry_dir.path());
    let delivery =
        FlowDelivery::new(db, receiver_blobs, root.path()).with_telemetry(telemetry.clone());

    let mut bad = request(
        "epoch-current",
        "lease-current",
        [0x22; 32],
        "unused".into(),
    );
    bad.file_name = String::new();
    for _ in 0..5 {
        assert!(matches!(
            delivery.offer(provider_transport.node_id(), &bad).await,
            Err(DeliveryError::InvalidRequest(_))
        ));
    }

    assert_eq!(
        telemetry.flush_now().await,
        1,
        "5 identical (code, stage) failures must collapse to 1 event within the dedup window"
    );
    let batch = bodies.lock().unwrap()[0].clone();
    assert_eq!(batch.as_array().unwrap().len(), 1);
}

// ── NET-06: flow.status / flow.suspend (control-plane, async 202 model) ──

fn tuple_ref(epoch: &str, lease: &str, queue_sequence: u64) -> proto::FlowTupleRef {
    proto::FlowTupleRef {
        queue_sequence,
        pairing_epoch: epoch.into(),
        lease_token: lease.into(),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn status_reports_not_found_for_an_unknown_tuple() {
    let root = tempdir().unwrap();
    let peer = transport::NodeId([0x33; 32]);
    let db = paired_db("epoch-current", peer).await;
    let transport = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let blobs = Arc::new(
        Blobs::open(&transport, &root.path().join("store"))
            .await
            .unwrap(),
    );
    let delivery = FlowDelivery::new(db, blobs, root.path());

    let reply = delivery
        .status(peer, &tuple_ref("epoch-current", "lease-current", 7))
        .await
        .unwrap();
    assert_eq!(reply.state, "not_found");
    assert!(reply.receipt.is_none());
    assert!(!reply.task_running);
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_immediately_starts_the_background_fetch_task() {
    // NET-06 core fix: `offer` must itself trigger the transfer instead of
    // waiting for the phone to call the long-blocking `fetch` RPC — that
    // "submit and wait in one round trip" shape was NET-01's root cause.
    // Uses a payload large enough that the background task is still
    // running when `status` is polled right after `offer` returns.
    const PAYLOAD: usize = 8 * 1024 * 1024;
    let mut payload = Vec::with_capacity(PAYLOAD);
    let mut s: u64 = 0x0FFE_2026_0914_0001;
    while payload.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        payload.extend_from_slice(&s.to_le_bytes());
    }
    payload.truncate(PAYLOAD);

    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let source = root.path().join("source.bin");
    std::fs::write(&source, &payload).unwrap();
    let hash = *blake3::hash(&payload).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
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
    let delivery = FlowDelivery::new(db, receiver_blobs.clone(), root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket);

    // offer() itself must return promptly (it never awaits the transfer).
    let offer_started = std::time::Instant::now();
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    assert!(
        offer_started.elapsed() < std::time::Duration::from_secs(1),
        "offer() must return promptly and never block on the data plane"
    );

    // Poll status until either the task is observed running, or the
    // transfer already completed (a fast loopback transfer can beat the
    // poll) — either outcome proves offer triggered work without a
    // separate fetch() call from the caller.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut saw_active_or_completed = false;
    while std::time::Instant::now() < deadline {
        let reply = delivery
            .status(
                provider_transport.node_id(),
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        if reply.state == "completed" || (reply.state == "active" && reply.task_running) {
            saw_active_or_completed = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert!(
        saw_active_or_completed,
        "offer() must have started the transfer without any fetch() call from the caller"
    );

    // It must actually finish on its own, with zero further calls from us.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let reply = delivery
            .status(
                provider_transport.node_id(),
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        if reply.state == "completed" {
            assert!(reply.receipt.is_some());
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "offer-triggered background fetch did not complete within 5s"
        );
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
}

// NET-22 RED: rebind_completed_flow_grant's branch (a DIFFERENT
// lease_token/provider re-offering the SAME already-completed queue_sequence
// — e.g. a restarted discovery cursor, not NET-20's cross-tuple content
// match) historically rebound the row and returned Ok silently: no push,
// no wake. The phone was left with only its 30s local-idle-stall fallback
// to discover a receipt the daemon had known about the entire time (real
// device, 2026-09-16). This must behave identically to NET-20's sibling
// branch (complete_without_fetch): same fact ("already have it"), same
// flow.delivered push.
#[tokio::test(flavor = "multi_thread")]
async fn reoffering_an_already_completed_tuple_under_a_new_lease_still_pushes_flow_delivered() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"NET-22 re-offer after completion fixture";
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

    // First pass: genuinely complete the tuple (same shape as
    // successful_flow_fetch_notifies_the_desktop_timeline).
    let first_offer = request("epoch-current", "lease-first", hash, ticket.clone());
    delivery
        .offer(provider_transport.node_id(), &first_offer)
        .await
        .unwrap();
    delivery
        .fetch(provider_transport.node_id(), &first_offer)
        .await
        .unwrap();
    // Drain the first pass's events (device changes x3, timeline, delivered)
    // — already covered by successful_flow_fetch_notifies_the_desktop_timeline.
    for _ in 0..5 {
        tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
            .await
            .expect("first pass events must arrive")
            .unwrap();
    }

    // Second pass: the SAME queue_sequence re-offered under a new
    // lease_token/provider (the tuple key request() always uses is
    // queue_sequence=1, pairing_epoch="epoch-current" — see request()).
    // This must hit rebind_completed_flow_grant, not complete_without_fetch.
    let reoffer = request("epoch-current", "lease-second", hash, ticket);
    let rebind_reply = delivery
        .offer(provider_transport.node_id(), &reoffer)
        .await
        .unwrap();
    // NET-24: the rebind branch is terminal at offer time too — its reply
    // must carry the receipt, not leave the caller waiting on the push.
    assert_eq!(
        rebind_reply.state, "completed",
        "NET-24: re-offering an already-completed tuple must report the terminal \
         state on the offer reply itself"
    );
    assert!(
        rebind_reply.receipt.is_some(),
        "NET-24: a completed offer reply must carry the durable receipt"
    );

    let mut saw_delivered = false;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
    while tokio::time::Instant::now() < deadline {
        let Ok(Ok(event)) =
            tokio::time::timeout(std::time::Duration::from_millis(200), event_rx.recv()).await
        else {
            continue;
        };
        if event["event"].as_str() == Some(events::FLOW_DELIVERED) {
            assert_eq!(
                event["data"]["lease_token"].as_str(),
                Some("lease-second"),
                "the pushed receipt must reflect the rebound (new) lease, not the stale first one"
            );
            saw_delivered = true;
            break;
        }
    }
    assert!(
        saw_delivered,
        "NET-22: re-offering an already-completed tuple under a new lease must still push \
         flow.delivered — the phone must not be left waiting on its local-idle-stall fallback \
         for a receipt the daemon already had"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_skips_the_network_fetch_when_content_already_has_a_durable_copy() {
    // NET-20: content already in the library (a different tuple, or a
    // rediscovered/re-offered item) must never trigger a real iroh-blobs
    // fetch — it should complete immediately from the presence check.
    let root = tempdir().unwrap();
    let peer = transport::NodeId([0x55; 32]);
    let db = paired_db("epoch-current", peer).await;
    let bytes = b"NET-20 presence check fixture";
    let hash = *blake3::hash(bytes).as_bytes();
    // Seed the library with a durable copy under this hash — the file must
    // actually exist on disk (has_durable_copy checks existence, not just
    // the index row) at the rel_path the row claims.
    std::fs::create_dir_all(root.path().join("originals")).unwrap();
    let rel_path = "originals/existing.jpg".to_string();
    std::fs::write(root.path().join(&rel_path), bytes).unwrap();
    db.insert_asset(&Asset {
        hash: hash.to_vec(),
        rel_path: rel_path.clone(),
        media_type: "image/jpeg".into(),
        bytes: bytes.len() as i64,
        taken_at: Some(1),
        width: None,
        height: None,
        src_device: vec![9u8; 32],
        added_at: 1,
        thumb_state: 0,
    })
    .await
    .unwrap();

    let transport = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let delivery = FlowDelivery::new(db, receiver_blobs.clone(), root.path());
    // A syntactically valid provider address that is never dialed — the
    // presence check must short-circuit before any fetch attempt touches
    // it. Uses the receiver's own address only because `provider_for` just
    // parses/registers it (no dial happens here); if the code under test
    // ever did dial it, this would still be a harmless loopback no-op, not
    // a false pass.
    let never_dialed_provider = transport.local_addr().to_string();
    let offer = request(
        "epoch-current",
        "lease-new-tuple",
        hash,
        never_dialed_provider,
    );

    delivery.offer(peer, &offer).await.unwrap();

    // Must resolve to completed promptly without ever needing a task poll —
    // there is no background fetch task to wait on.
    let reply = delivery
        .status(peer, &tuple_ref("epoch-current", "lease-new-tuple", 7))
        .await
        .unwrap();
    assert_eq!(
        reply.state, "completed",
        "presence-checked content must complete without a network fetch"
    );
    assert!(!reply.task_running);
    let receipt = reply
        .receipt
        .expect("completed status must carry a receipt");
    assert_eq!(receipt.content_hash, hex::encode(hash));
    // Nothing was ever pulled into the flow-blobs store for this hash.
    assert_eq!(receiver_blobs.local_bytes(hash).await.unwrap(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_reply_carries_the_terminal_receipt_when_content_already_exists() {
    // NET-24: the fix itself. NET-20's dedup completes synchronously inside
    // the offer handler, so `emit_flow_delivered` fires before a caller that
    // subscribes *after* offer can possibly be listening — and the event bus
    // drops a broadcast with no subscribers outright. The reply the caller is
    // already awaiting is therefore the only guaranteed channel, and it must
    // carry the terminal state. Real device 2026-09-16: without this the
    // phone sat out a 30s local-idle timeout per photo for receipts the
    // daemon had the whole time.
    let root = tempdir().unwrap();
    let peer = transport::NodeId([0x5A; 32]);
    let db = paired_db("epoch-current", peer).await;
    let bytes = b"NET-24 offer-reply terminal fixture";
    let hash = *blake3::hash(bytes).as_bytes();
    std::fs::create_dir_all(root.path().join("originals")).unwrap();
    let rel_path = "originals/net24-existing.jpg".to_string();
    std::fs::write(root.path().join(&rel_path), bytes).unwrap();
    db.insert_asset(&Asset {
        hash: hash.to_vec(),
        rel_path: rel_path.clone(),
        media_type: "image/jpeg".into(),
        bytes: bytes.len() as i64,
        taken_at: Some(1),
        width: None,
        height: None,
        src_device: vec![9u8; 32],
        added_at: 1,
        thumb_state: 0,
    })
    .await
    .unwrap();

    let transport = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let delivery = FlowDelivery::new(db, receiver_blobs.clone(), root.path());
    let offer = request(
        "epoch-current",
        "lease-net24",
        hash,
        transport.local_addr().to_string(),
    );

    // The assertion that matters: no status() poll, no push subscription —
    // the offer call alone hands back the completed receipt.
    let reply = delivery.offer(peer, &offer).await.unwrap();

    assert_eq!(
        reply.state, "completed",
        "NET-24: a dedup hit must report `completed` on the offer reply itself, \
         not force the caller onto the push/timeout path"
    );
    assert!(
        !reply.task_running,
        "nothing was spawned — there is no fetch task for a dedup hit"
    );
    let receipt = reply
        .receipt
        .expect("NET-24: a completed offer reply must carry the durable receipt");
    assert_eq!(receipt.content_hash, hex::encode(hash));
    // And it is the same receipt a later status() reports — the reply is not
    // a separate, weaker fact invented for this path.
    let polled = delivery
        .status(peer, &tuple_ref("epoch-current", "lease-net24", 7))
        .await
        .unwrap();
    assert_eq!(
        polled.receipt.map(|r| r.receipt_id),
        Some(receipt.receipt_id)
    );
    assert_eq!(receiver_blobs.local_bytes(hash).await.unwrap(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_reply_is_active_when_a_real_fetch_must_run() {
    // NET-24 counterpart: the genuinely-async case must still answer "202 —
    // go wait". If this regressed to `completed` the caller would accept a
    // receipt for bytes that never moved.
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let payload = vec![7u8; 4 * 1024 * 1024];
    let source = root.path().join("net24-source.bin");
    std::fs::write(&source, &payload).unwrap();
    let hash = *blake3::hash(&payload).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
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
    let delivery = FlowDelivery::new(db, receiver_blobs, root.path());
    let offer = request("epoch-current", "lease-net24-miss", hash, ticket);

    let reply = delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    assert_eq!(
        reply.state, "active",
        "NET-24: content the library does not have must still be the async case"
    );
    assert!(
        reply.task_running,
        "spawn_fetch_task just registered this tuple, so the reply must say so"
    );
    assert!(
        reply.receipt.is_none(),
        "NET-24: an active reply must never carry a receipt — nothing completed yet"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_still_fetches_when_content_is_not_yet_in_the_library() {
    // NET-20 regression guard: the presence check must not swallow the
    // normal "content genuinely missing" path — this is byte-for-byte the
    // pre-existing `verified_native_fetch_materializes_before_a_durable_receipt`
    // shape, just re-asserted here to pin it against the new short-circuit.
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"NET-20 genuine miss fixture";
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
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let reply = delivery
            .status(
                provider_transport.node_id(),
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        if reply.state == "completed" {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "genuinely missing content must still be fetched and complete"
        );
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert!(
        db.get_asset(&hash).await.unwrap().is_some(),
        "a real fetch must still land the asset in the index"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn status_reports_active_with_no_task_running_before_any_fetch_starts() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let bytes = b"NET-06 status active fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
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
    let delivery = FlowDelivery::new(db, receiver_blobs, root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    // NET-06: offer() now triggers the background fetch itself, so for a
    // tiny payload it may already have completed by the time this polls —
    // the only thing this test still asserts is that `status` never lies
    // about a task still running once it has certainly stopped.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let reply = delivery
            .status(
                provider_transport.node_id(),
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        if reply.state == "completed" {
            assert!(
                !reply.task_running,
                "a completed grant must never report a running task"
            );
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "offer-triggered background fetch for a tiny fixture did not complete within 5s"
        );
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn status_reports_completed_with_the_durable_receipt() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"NET-06 status completed fixture";
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
    let delivery = FlowDelivery::new(db, receiver_blobs, root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    let receipt = delivery
        .fetch(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    let reply = delivery
        .status(
            provider_transport.node_id(),
            &tuple_ref("epoch-current", "lease-current", 7),
        )
        .await
        .unwrap();
    assert_eq!(reply.state, "completed");
    assert!(!reply.task_running);
    let got = reply
        .receipt
        .expect("completed status must carry a receipt");
    assert_eq!(got.receipt_id, receipt.receipt_id);
}

#[tokio::test(flavor = "multi_thread")]
async fn repeated_fetch_and_status_on_a_completed_grant_never_retouch_the_data_plane() {
    // NET-16 (split from NET-06): `status_reports_completed_with_the_durable_receipt`
    // proves a status() *reads* the receipt; nothing proved that repeated
    // calls are *pure* receipt reads. Cut the provider's endpoint dead right
    // after the one genuine completion, then call fetch()/status() again:
    // any defensive re-fetch or re-spawn would now hit a dead network, and
    // removing the completed short-circuit in fetch_inner() turns the repeat
    // fetch() into Err(Cancelled) — either way the case below goes red.
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"NET-16 zero-retransmit fixture";
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
    let delivery = FlowDelivery::new(db, receiver_blobs.clone(), root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket);
    let peer = provider_transport.node_id();

    delivery.offer(peer, &offer).await.unwrap();
    let first = delivery.fetch(peer, &offer).await.unwrap();
    // The first fetch really did run the data plane — bytes landed locally.
    assert_eq!(
        receiver_blobs.local_bytes(hash).await.unwrap(),
        bytes.len() as u64,
        "the initial fetch must have pulled the content"
    );

    // Sever the data plane: the provider endpoint no longer accepts any
    // connection, so any later network attempt cannot silently succeed.
    provider_transport.close().await;

    for round in 1..=3 {
        let again = delivery
            .fetch(peer, &offer)
            .await
            .unwrap_or_else(|error| {
                panic!("repeat fetch #{round} on a completed grant must replay the durable receipt, got {error:?}")
            });
        assert_eq!(
            again.receipt_id, first.receipt_id,
            "repeat fetch #{round} must return the same durable receipt"
        );
        let reply = delivery
            .status(peer, &tuple_ref("epoch-current", "lease-current", 7))
            .await
            .unwrap();
        assert_eq!(reply.state, "completed");
        assert!(
            !reply.task_running,
            "repeat fetch/status #{round} must never register a new fetch task",
        );
        assert_eq!(
            reply
                .receipt
                .expect("completed status must carry a receipt")
                .receipt_id,
            first.receipt_id
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn status_reports_cancelled_after_cancel() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let bytes = b"NET-06 status cancelled fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
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
    let delivery = FlowDelivery::new(db, receiver_blobs, root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();
    delivery
        .cancel(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    let reply = delivery
        .status(
            provider_transport.node_id(),
            &tuple_ref("epoch-current", "lease-current", 7),
        )
        .await
        .unwrap();
    assert_eq!(reply.state, "cancelled");
}

/// NET-06 Android wiring gap: `CancellationRoundController` batch-cancels
/// items whose local one-shot provider ticket is already gone (a phone
/// that exhausted its retry budget discards `content_hash`/`provider`
/// before moving on). `cancel_tuple` must cancel using only the tuple
/// identity — no ticket/content_hash/provider round-trip required.
#[tokio::test(flavor = "multi_thread")]
async fn cancel_by_tuple_cancels_without_content_hash_or_provider() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let bytes = b"NET-06 cancel_tuple fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
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
    let delivery = FlowDelivery::new(db, receiver_blobs, root.path());
    let offer = request("epoch-current", "lease-current", hash, ticket);
    delivery
        .offer(provider_transport.node_id(), &offer)
        .await
        .unwrap();

    // The phone has already discarded `offer` (content_hash/provider) —
    // only the tuple identity survives. `cancel_tuple` must still work.
    delivery
        .cancel_by_tuple(
            provider_transport.node_id(),
            &tuple_ref("epoch-current", "lease-current", 7),
        )
        .await
        .unwrap();

    let reply = delivery
        .status(
            provider_transport.node_id(),
            &tuple_ref("epoch-current", "lease-current", 7),
        )
        .await
        .unwrap();
    assert_eq!(
        reply.state, "cancelled",
        "cancel_by_tuple must mark the grant cancelled, same terminal state as flow.cancel"
    );
}

/// Counterexample: a tuple with no matching grant (never offered, or a
/// stale lease_token from a superseded offer) must not be silently
/// accepted — it is a guard mismatch, same as `flow.cancel` against an
/// unknown tuple.
#[tokio::test(flavor = "multi_thread")]
async fn cancel_by_tuple_rejects_an_unknown_tuple() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let receiver_blobs = Arc::new(
        Blobs::open(&provider_transport, &root.path().join("receiver-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-current", provider_transport.node_id()).await;
    let delivery = FlowDelivery::new(db, receiver_blobs, root.path());

    let result = delivery
        .cancel_by_tuple(
            provider_transport.node_id(),
            &tuple_ref("epoch-current", "never-offered", 99),
        )
        .await;
    assert!(
        matches!(result, Err(DeliveryError::GuardMismatch)),
        "an unknown tuple must be rejected, not silently accepted as a no-op"
    );
}

/// (peer, queue_sequence, lease_token), never by content_hash alone — two
/// distinct devices independently holding a grant for the *same* content
/// (e.g. both backing up the same screenshot) must not let one device's
/// suspend abort the other device's unrelated in-flight transfer.
#[tokio::test(flavor = "multi_thread")]
async fn suspend_on_one_device_does_not_touch_another_devices_grant_for_the_same_hash() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let bytes = b"NET-06 cross-device isolation fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
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

    let device_a = transport::NodeId([0xAA; 32]);
    let device_b = transport::NodeId([0xBB; 32]);
    let db = Db::open_in_memory().await.unwrap();
    for (peer, name) in [(device_a, "phone-a"), (device_b, "phone-b")] {
        db.upsert_device(&Device {
            node_id: peer.0.to_vec(),
            name: name.into(),
            role: Role::Member,
            paired_at: 1,
            last_seen: None,
            revoked: false,
            device_hint: None,
        })
        .await
        .unwrap();
        db.set_pairing_epoch(&peer.0, "epoch-current")
            .await
            .unwrap();
    }
    let delivery = FlowDelivery::new(db, receiver_blobs, root.path());

    let offer_a = request("epoch-current", "lease-a", hash, ticket.clone());
    let offer_b = request("epoch-current", "lease-b", hash, ticket);
    delivery.offer(device_a, &offer_a).await.unwrap();
    delivery.offer(device_b, &offer_b).await.unwrap();

    // Suspending device A's tuple must be a no-op for device B's grant: B
    // is untouched (still active, no interruption reported as an error).
    delivery
        .suspend(device_a, &tuple_ref("epoch-current", "lease-a", 7))
        .await
        .unwrap();
    let status_b = delivery
        .status(device_b, &tuple_ref("epoch-current", "lease-b", 7))
        .await
        .unwrap();
    assert_eq!(
        status_b.state, "active",
        "device B's independent grant for the same content hash must be unaffected by device A's suspend"
    );

    // Both fetches must still be able to complete independently.
    delivery.fetch(device_a, &offer_a).await.unwrap();
    delivery.fetch(device_b, &offer_b).await.unwrap();
}

/// Core NET-06 review fix #1 + suspend acceptance: interrupting the
/// in-progress native fetch task must actually stop it quickly (not wait
/// for the transfer to finish naturally), and must leave the grant `active`
/// so a later offer resumes from the partial instead of restarting —
/// contrasted with `cancel`, which marks the grant `cancelled` and lets the
/// partial fall out of GC protection. Uses the same kill/retry idiom as
/// `transport::tests::blobs_resume` (`abort()` racing a live transfer).
#[tokio::test(flavor = "multi_thread")]
async fn suspend_interrupts_an_in_progress_fetch_and_keeps_the_grant_active() {
    const PAYLOAD: usize = 24 * 1024 * 1024;
    let mut payload = Vec::with_capacity(PAYLOAD);
    let mut s: u64 = 0xC0FF_EE00_1234_5678;
    while payload.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        payload.extend_from_slice(&s.to_le_bytes());
    }
    payload.truncate(PAYLOAD);

    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let source = root.path().join("source.bin");
    std::fs::write(&source, &payload).unwrap();
    let hash = *blake3::hash(&payload).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let provider_node = provider_transport.node_id();

    let db = paired_db("epoch-current", provider_node).await;
    let offer = request("epoch-current", "lease-current", hash, ticket);
    let receiver_store = root.path().join("receiver-store");

    const KILL_THRESHOLD: u64 = 2 * 1024 * 1024;
    let mut suspended_mid_flight = false;
    for attempt in 0..8 {
        let _ = std::fs::remove_dir_all(&receiver_store);
        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let receiver_blobs = Arc::new(
            Blobs::open(&receiver_transport, &receiver_store)
                .await
                .unwrap(),
        );
        let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
        delivery.offer(provider_node, &offer).await.unwrap();

        let fetch_delivery = delivery.clone();
        let fetch_offer = offer.clone();
        let fetch =
            tokio::spawn(async move { fetch_delivery.fetch(provider_node, &fetch_offer).await });

        let started = std::time::Instant::now();
        while !fetch.is_finished() && dir_bytes(&receiver_store) < KILL_THRESHOLD {
            assert!(
                started.elapsed() < std::time::Duration::from_secs(60),
                "fetch moved no bytes toward the kill threshold in 60s"
            );
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        if fetch.is_finished() {
            eprintln!("attempt {attempt}: transfer outran the kill threshold, retrying");
            continue;
        }

        delivery
            .suspend(
                provider_node,
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();

        let outcome = tokio::time::timeout(std::time::Duration::from_secs(2), fetch)
            .await
            .expect("suspend must interrupt the fetch task within 2s, not wait for it to finish naturally")
            .expect("the spawned test task itself must not panic/be cancelled");
        assert!(
            matches!(outcome, Err(DeliveryError::Fetch(_))),
            "a suspended fetch's poll must resolve as an error (task ended without completing), got: {outcome:?}"
        );

        // The grant must still be active — suspend never touches durable
        // state — so status must NOT report cancelled/not_found. NET-15
        // changed what a status poll MEANS on an Active grant with no
        // running task: the poll itself respawns the delivery — a caller
        // polling this exact tuple is waiting on it, which is the same
        // resume fact a later `flow.offer` carries (grants are per-peer, so
        // one peer's pause can never be disturbed by another peer's poll).
        // The interrupt itself is asserted above via the fetch outcome and
        // the 2s bound; the registry is no longer a read-only observable.
        let status = delivery
            .status(
                provider_node,
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        assert_eq!(
            status.state, "active",
            "suspend must leave the grant active, unlike cancel"
        );
        assert!(
            status.task_running,
            "NET-15: a status poll on the Active-but-interrupted grant respawns the delivery"
        );

        suspended_mid_flight = true;
        break;
    }
    assert!(
        suspended_mid_flight,
        "never managed to suspend mid-flight across 8 attempts — transfer kept outrunning the kill threshold"
    );
}

/// Suspend→resume: after an interrupted fetch, a fresh `flow.offer` +
/// `flow.fetch` on the same tuple must complete using the partial bytes
/// already on disk (iroh-blobs' own resume, same guarantee `blobs_resume.rs`
/// validates), not restart the transfer from zero.
#[tokio::test(flavor = "multi_thread")]
async fn suspend_then_resume_completes_from_the_retained_partial() {
    const PAYLOAD: usize = 24 * 1024 * 1024;
    let mut payload = Vec::with_capacity(PAYLOAD);
    let mut s: u64 = 0xABCD_1234_9876_0001;
    while payload.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        payload.extend_from_slice(&s.to_le_bytes());
    }
    payload.truncate(PAYLOAD);

    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let source = root.path().join("source.bin");
    std::fs::write(&source, &payload).unwrap();
    let hash = *blake3::hash(&payload).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let provider_node = provider_transport.node_id();

    let db = paired_db("epoch-current", provider_node).await;
    let offer = request("epoch-current", "lease-current", hash, ticket);
    let receiver_store = root.path().join("receiver-store");

    const KILL_THRESHOLD: u64 = 2 * 1024 * 1024;
    let mut resumed_successfully = false;
    for attempt in 0..8 {
        let _ = std::fs::remove_dir_all(&receiver_store);
        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let receiver_blobs = Arc::new(
            Blobs::open(&receiver_transport, &receiver_store)
                .await
                .unwrap(),
        );
        let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
        delivery.offer(provider_node, &offer).await.unwrap();

        let fetch_delivery = delivery.clone();
        let fetch_offer = offer.clone();
        let fetch =
            tokio::spawn(async move { fetch_delivery.fetch(provider_node, &fetch_offer).await });

        let started = std::time::Instant::now();
        while !fetch.is_finished() && dir_bytes(&receiver_store) < KILL_THRESHOLD {
            assert!(started.elapsed() < std::time::Duration::from_secs(60));
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        if fetch.is_finished() {
            eprintln!("attempt {attempt}: transfer outran the kill threshold, retrying");
            continue;
        }

        delivery
            .suspend(
                provider_node,
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), fetch).await;
        let partial_bytes_on_disk = receiver_blobs.local_bytes(hash).await.unwrap();
        assert!(
            partial_bytes_on_disk > 0 && partial_bytes_on_disk < PAYLOAD as u64,
            "expected a genuine partial on disk after suspend, got {partial_bytes_on_disk} of {PAYLOAD}"
        );

        // Fresh delivery handle (simulates the phone re-offering after a
        // "continue" tap) — resume must not restart from zero.
        let resume_delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
        resume_delivery.offer(provider_node, &offer).await.unwrap();
        let receipt = resume_delivery
            .fetch(provider_node, &offer)
            .await
            .expect("resume after suspend must complete, not restart-and-fail");
        assert_eq!(receipt.content_hash, hex::encode(hash));
        assert_eq!(
            receiver_blobs.local_bytes(hash).await.unwrap(),
            PAYLOAD as u64,
            "resumed transfer must end with the full byte count, not the partial"
        );

        resumed_successfully = true;
        break;
    }
    assert!(
        resumed_successfully,
        "never captured a genuine partial to resume from across 8 attempts"
    );
}

/// NET-15: a daemon restart must not orphan an Active delivery. A brand-new
/// `FlowDelivery` over the same durable db + retained blob store models the
/// process restart: the in-memory task registry is empty while the grant row
/// still says Active. The phone's only post-restart signal is its `flow.status`
/// poll — that poll must respawn the background fetch itself (no fresh offer)
/// and the respawned transfer must resume from the retained partial, not
/// restart from zero bytes. `suspend` here is only the in-process stand-in
/// for process death: it interrupts the task and, exactly like a restart,
/// leaves the durable grant Active with nothing running.
#[tokio::test(flavor = "multi_thread")]
async fn status_respawns_the_delivery_task_lost_to_a_daemon_restart() {
    const PAYLOAD: usize = 24 * 1024 * 1024;
    let mut payload = Vec::with_capacity(PAYLOAD);
    let mut s: u64 = 0x5EAF_00D1_2345_6789;
    while payload.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        payload.extend_from_slice(&s.to_le_bytes());
    }
    payload.truncate(PAYLOAD);

    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let source = root.path().join("source.bin");
    std::fs::write(&source, &payload).unwrap();
    let hash = *blake3::hash(&payload).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let provider_node = provider_transport.node_id();

    let db = paired_db("epoch-current", provider_node).await;
    let offer = request("epoch-current", "lease-current", hash, ticket);
    let receiver_store = root.path().join("receiver-store");

    const KILL_THRESHOLD: u64 = 2 * 1024 * 1024;
    let mut recovered = false;
    for attempt in 0..8 {
        let _ = std::fs::remove_dir_all(&receiver_store);
        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let receiver_blobs = Arc::new(
            Blobs::open(&receiver_transport, &receiver_store)
                .await
                .unwrap(),
        );
        let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
        delivery.offer(provider_node, &offer).await.unwrap();

        let fetch_delivery = delivery.clone();
        let fetch_offer = offer.clone();
        let fetch =
            tokio::spawn(async move { fetch_delivery.fetch(provider_node, &fetch_offer).await });
        let started = std::time::Instant::now();
        while !fetch.is_finished() && dir_bytes(&receiver_store) < KILL_THRESHOLD {
            assert!(
                started.elapsed() < std::time::Duration::from_secs(60),
                "fetch moved no bytes toward the kill threshold in 60s"
            );
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        if fetch.is_finished() {
            eprintln!("attempt {attempt}: transfer outran the kill threshold, retrying");
            continue;
        }

        // Stand-in for process death: interrupt the task, durable grant
        // stays Active, then drop the old handle entirely.
        delivery
            .suspend(
                provider_node,
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), fetch).await;
        let partial = receiver_blobs.local_bytes(hash).await.unwrap();
        assert!(
            partial > 0 && partial < PAYLOAD as u64,
            "expected a genuine partial on disk before the restart, got {partial} of {PAYLOAD}"
        );
        drop(delivery);

        // The restarted daemon: fresh handle, same db + same retained store.
        let restarted = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
        let reply = restarted
            .status(
                provider_node,
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        assert_eq!(
            reply.state, "active",
            "the grant must still be Active after restart"
        );
        assert!(
            reply.task_running,
            "NET-15: status() must respawn the delivery task lost to the restart \
             (grant Active, no task running)"
        );

        // No fresh offer happens — the waiting phone only polls status. The
        // delivery must converge to completed on the respawned task alone.
        let started = std::time::Instant::now();
        let receipt = loop {
            let reply = restarted
                .status(
                    provider_node,
                    &tuple_ref("epoch-current", "lease-current", 7),
                )
                .await
                .unwrap();
            match reply.state.as_str() {
                "completed" => break reply.receipt.expect("completed carries a receipt"),
                "active" => {}
                other => panic!("unexpected state while waiting for respawned delivery: {other}"),
            }
            assert!(
                started.elapsed() < std::time::Duration::from_secs(60),
                "respawned delivery did not converge to completed within 60s"
            );
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        };
        assert_eq!(receipt.content_hash, hex::encode(hash));
        assert_eq!(
            receiver_blobs.local_bytes(hash).await.unwrap(),
            PAYLOAD as u64,
            "respawned transfer must end with the full byte count, not the partial"
        );

        recovered = true;
        break;
    }
    assert!(
        recovered,
        "never captured a genuine partial to restart-recover from across 8 attempts"
    );
}

/// Contrast with suspend: `cancel` marks the grant `cancelled`, so its
/// partial is NOT GC-protected and gets reclaimed — the opposite of
/// suspend's "keep it for resume" contract. Reuses the periodic-GC harness
/// from `completed_flow_fetch_is_reclaimed_by_periodic_gc`.
#[tokio::test(flavor = "multi_thread")]
async fn cancel_after_interrupt_lets_the_partial_fall_out_of_gc_protection() {
    const PAYLOAD: usize = 24 * 1024 * 1024;
    let mut payload = Vec::with_capacity(PAYLOAD);
    let mut s: u64 = 0x5EAF_00D1_2345_6789;
    while payload.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        payload.extend_from_slice(&s.to_le_bytes());
    }
    payload.truncate(PAYLOAD);

    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let source = root.path().join("source.bin");
    std::fs::write(&source, &payload).unwrap();
    let hash = *blake3::hash(&payload).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let provider_node = provider_transport.node_id();

    let db = paired_db("epoch-current", provider_node).await;
    let callback_db = db.clone();
    let receiver_store = root.path().join("receiver-store");

    const KILL_THRESHOLD: u64 = 2 * 1024 * 1024;
    let mut cancelled_and_reclaimed = false;
    for attempt in 0..8 {
        let _ = std::fs::remove_dir_all(&receiver_store);
        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let gc_db = callback_db.clone();
        let receiver_blobs = Arc::new(
            Blobs::open_with_periodic_gc(
                &receiver_transport,
                &receiver_store,
                std::time::Duration::from_millis(20),
                move || {
                    let db = gc_db.clone();
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
                                        Output = transport::Result<
                                            std::collections::HashSet<[u8; 32]>,
                                        >,
                                    > + Send,
                            >,
                        >
                },
            )
            .await
            .unwrap(),
        );
        let offer = request("epoch-current", "lease-current", hash, ticket.clone());
        let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), root.path());
        delivery.offer(provider_node, &offer).await.unwrap();

        let fetch_delivery = delivery.clone();
        let fetch_offer = offer.clone();
        let fetch =
            tokio::spawn(async move { fetch_delivery.fetch(provider_node, &fetch_offer).await });

        let started = std::time::Instant::now();
        while !fetch.is_finished() && dir_bytes(&receiver_store) < KILL_THRESHOLD {
            assert!(started.elapsed() < std::time::Duration::from_secs(60));
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        if fetch.is_finished() {
            eprintln!("attempt {attempt}: transfer outran the kill threshold, retrying");
            continue;
        }

        delivery.cancel(provider_node, &offer).await.unwrap();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), fetch).await;

        let status = delivery
            .status(
                provider_node,
                &tuple_ref("epoch-current", "lease-current", 7),
            )
            .await
            .unwrap();
        assert_eq!(
            status.state, "cancelled",
            "cancel must mark the grant cancelled, unlike suspend"
        );

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while receiver_blobs.local_bytes(hash).await.unwrap() != 0 {
            assert!(
                std::time::Instant::now() < deadline,
                "cancelled partial was not reclaimed by periodic GC within the window"
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }

        cancelled_and_reclaimed = true;
        break;
    }
    assert!(
        cancelled_and_reclaimed,
        "never captured a genuine partial to cancel across 8 attempts"
    );
}

fn dir_bytes(dir: &Path) -> u64 {
    fn walk(dir: &Path, total: &mut u64) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, total);
            } else if let Ok(meta) = entry.metadata() {
                *total += meta.len();
            }
        }
    }
    let mut total = 0u64;
    walk(dir, &mut total);
    total
}
