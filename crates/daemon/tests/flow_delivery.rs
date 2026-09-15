use std::path::Path;
use std::sync::Arc;

use daemon::events;
use daemon::flow_delivery::{DeliveryError, FlowDelivery, FlowPathRegistry};
use daemon::Telemetry;
use proto::FlowFetchRequest;
use storage::{Db, Device, Role};
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
        // state — so status must NOT report cancelled/not_found.
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
            !status.task_running,
            "the interrupted task must be gone from the registry"
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
