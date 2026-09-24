//! #413 W4: Desktop health (`hello.health`), offer-time space precheck, the
//! public failure codes (`storage_full` / `library_unavailable` /
//! `storage_failed` / `fetch_failed`), and the grant lifecycle around
//! `flow.suspend` and the 3-day resume deadline.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use daemon::events;
use daemon::flow_delivery::{
    classify_peer_failure, DeliveryError, FlowDelivery, PeerFailure, GRANT_RESUME_TTL_MS,
    LOW_SPACE_THRESHOLD_BYTES,
};
use daemon::Router;
use proto::{FlowFetchRequest, FlowTupleRef, Req, Resp};
use storage::{Asset, Db, Device, Role};
use tempfile::tempdir;
use transport::{Blobs, IrohTransport, NodeId, Transport, TransportConfig, ALPN_BLOBS};

const GIB: u64 = 1024 * 1024 * 1024;

fn request(lease: &str, hash: [u8; 32], provider: String, size_bytes: i64) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: 7,
        pairing_epoch: "epoch-current".into(),
        lease_token: lease.into(),
        content_hash: hex::encode(hash),
        file_name: "IMG_0007.jpg".into(),
        media_type: "image/jpeg".into(),
        provider,
        capture_at_ms: 0,
        size_bytes,
    }
}

fn tuple(lease: &str) -> FlowTupleRef {
    FlowTupleRef {
        queue_sequence: 7,
        pairing_epoch: "epoch-current".into(),
        lease_token: lease.into(),
    }
}

async fn pair(db: &Db, peer: NodeId) {
    db.upsert_device(&Device {
        node_id: peer.0.to_vec(),
        name: "phone".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
        revoked_at: None,
        revoked_by: None,
    })
    .await
    .unwrap();
    db.set_pairing_epoch(&peer.0, "epoch-current")
        .await
        .unwrap();
}

async fn paired_db(peer: NodeId) -> Db {
    let db = Db::open_in_memory().await.unwrap();
    pair(&db, peer).await;
    db
}

/// A library folder that is a subdirectory of the test root, so it can be
/// removed without touching the blob stores next to it.
fn library(root: &Path) -> PathBuf {
    let dir = root.join("library");
    std::fs::create_dir_all(dir.join(".ppf")).unwrap();
    dir
}

async fn receiver_blobs(root: &Path) -> (IrohTransport, Arc<Blobs>) {
    let transport = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let blobs = Arc::new(
        Blobs::open(&transport, &root.join("receiver-store"))
            .await
            .unwrap(),
    );
    (transport, blobs)
}

fn free_space(bytes: Option<u64>) -> impl Fn(&Path) -> Option<u64> + Send + Sync + 'static {
    move |_| bytes
}

// ── hello.health ─────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn health_reports_free_bytes_a_writable_library_and_a_working_index() {
    let root = tempdir().unwrap();
    let library = library(root.path());
    let db = paired_db(NodeId([0x11; 32])).await;
    let (_t, blobs) = receiver_blobs(root.path()).await;
    let delivery =
        FlowDelivery::new(db, blobs, &library).with_free_space_probe(free_space(Some(6 * GIB)));

    let health = delivery.health().await;
    assert_eq!(health.free_bytes, Some((6 * GIB) as i64));
    assert!(health.library_writable);
    assert!(health.index_ok);
    // The write probe cleans up after itself.
    let leftovers: Vec<_> = std::fs::read_dir(library.join(".ppf"))
        .unwrap()
        .flatten()
        .map(|e| e.file_name())
        .collect();
    assert!(
        leftovers.is_empty(),
        "probe left files behind: {leftovers:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn health_reports_a_missing_library_and_an_unknown_free_space_honestly() {
    let root = tempdir().unwrap();
    let library = library(root.path());
    let db = paired_db(NodeId([0x11; 32])).await;
    let (_t, blobs) = receiver_blobs(root.path()).await;
    let delivery = FlowDelivery::new(db, blobs, &library).with_free_space_probe(free_space(None));

    std::fs::remove_dir_all(&library).unwrap();
    let health = delivery.health().await;
    assert_eq!(health.free_bytes, None, "unknown must stay null, not 0");
    assert!(!health.library_writable);
    assert!(
        !library.exists(),
        "a health probe must never recreate a vanished library folder"
    );

    // A library path that is a plain file is not a writable library either.
    std::fs::write(&library, b"not a folder").unwrap();
    assert!(!delivery.health().await.library_writable);
}

#[test]
fn low_space_threshold_is_exactly_five_gib() {
    assert_eq!(LOW_SPACE_THRESHOLD_BYTES, 5 * GIB);
}

// ── Router: hello carries health only for a paired member ────────────────

async fn ctrl_endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec!["ppf/ctrl/1".into()]))
        .await
        .unwrap()
}

async fn call(
    client: &IrohTransport,
    daemon: NodeId,
    method: &str,
    params: serde_json::Value,
) -> Resp {
    let mut stream = client.connect(daemon, "ppf/ctrl/1").await.unwrap();
    let req = Req {
        id: format!("req-{method}"),
        method: method.into(),
        params,
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&req).unwrap())
        .await
        .unwrap();
    stream.finish().unwrap();
    let frame = stream.recv_frame().await.unwrap().expect("a response");
    proto::codec::decode::<Resp>(&frame).unwrap()
}

struct RouterHarness {
    _blobs_transport: IrohTransport,
    daemon: IrohTransport,
    member: IrohTransport,
    stranger: IrohTransport,
    _root: tempfile::TempDir,
}

async fn router_harness(free: Option<u64>) -> RouterHarness {
    let root = tempdir().unwrap();
    let library = library(root.path());
    let db = Db::open_in_memory().await.unwrap();
    let (blobs_transport, blobs) = receiver_blobs(root.path()).await;
    let delivery =
        FlowDelivery::new(db.clone(), blobs, &library).with_free_space_probe(free_space(free));
    let daemon = ctrl_endpoint().await;
    let router = Router::new(db.clone(), "storage").with_flow_delivery(delivery);
    let serving = daemon.clone();
    tokio::spawn(async move { router.serve(&serving).await });

    let member = ctrl_endpoint().await;
    member.add_peer(daemon.local_addr());
    pair(&db, member.node_id()).await;
    let stranger = ctrl_endpoint().await;
    stranger.add_peer(daemon.local_addr());
    RouterHarness {
        _blobs_transport: blobs_transport,
        daemon,
        member,
        stranger,
        _root: root,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn hello_reply_carries_health_for_a_paired_member_only() {
    let h = router_harness(Some(6 * GIB)).await;

    let resp = call(
        &h.member,
        h.daemon.node_id(),
        "hello",
        serde_json::json!({}),
    )
    .await;
    assert!(resp.ok, "{resp:?}");
    let result = resp.result.unwrap();
    assert_eq!(
        result["health"],
        serde_json::json!({"free_bytes": 6 * GIB, "library_writable": true, "index_ok": true})
    );

    let resp = call(
        &h.stranger,
        h.daemon.node_id(),
        "hello",
        serde_json::json!({}),
    )
    .await;
    assert!(resp.ok, "{resp:?}");
    assert!(
        resp.result.unwrap().get("health").is_none(),
        "hello stays a zero-data handshake for an unpaired peer"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_that_cannot_fit_is_refused_with_the_storage_full_msg_key() {
    let h = router_harness(Some(GIB)).await;
    let hash = *blake3::hash(b"too big").as_bytes();
    let offer = request(
        "lease-big",
        hash,
        h.daemon.local_addr().to_string(),
        (2 * GIB) as i64,
    );
    let resp = call(
        &h.member,
        h.daemon.node_id(),
        "flow.offer",
        serde_json::to_value(&offer).unwrap(),
    )
    .await;
    assert!(!resp.ok);
    let error = resp.error.unwrap();
    assert_eq!(error.msg_key, "storage_full");
    assert_eq!(error.code, proto::codes::STORAGE_FULL);
}

// ── Offer-time precheck ─────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn offer_refuses_an_item_that_does_not_fit_and_writes_nothing() {
    let root = tempdir().unwrap();
    let library = library(root.path());
    let peer = NodeId([0x22; 32]);
    let db = paired_db(peer).await;
    let (transport, blobs) = receiver_blobs(root.path()).await;
    let delivery = FlowDelivery::new(db.clone(), blobs.clone(), &library)
        .with_free_space_probe(free_space(Some(GIB)));
    let hash = *blake3::hash(b"precheck").as_bytes();
    let offer = request(
        "lease-1",
        hash,
        transport.local_addr().to_string(),
        (GIB / 2) as i64,
    );

    let error = delivery.offer(peer, &offer).await.unwrap_err();
    assert!(
        matches!(error, DeliveryError::InsufficientSpace { .. }),
        "{error:?}"
    );
    assert_eq!(error.wire_code(), "storage_full");
    let status = delivery.status(peer, &tuple("lease-1")).await.unwrap();
    assert_eq!(
        status.state, "not_found",
        "a refused offer must not persist a grant"
    );
    assert!(!status.task_running);
    assert_eq!(blobs.local_bytes(hash).await.unwrap(), 0);
    assert!(db.active_flow_content_hashes().await.unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_with_unknown_size_skips_the_space_precheck() {
    let root = tempdir().unwrap();
    let library = library(root.path());
    let peer = NodeId([0x22; 32]);
    let db = paired_db(peer).await;
    let (transport, blobs) = receiver_blobs(root.path()).await;
    let delivery =
        FlowDelivery::new(db, blobs, &library).with_free_space_probe(free_space(Some(0)));
    let hash = *blake3::hash(b"unknown size").as_bytes();
    let offer = request("lease-1", hash, transport.local_addr().to_string(), 0);

    let reply = delivery.offer(peer, &offer).await.unwrap();
    assert_eq!(reply.state, "active");
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_of_content_the_library_already_has_completes_even_on_a_full_disk() {
    let root = tempdir().unwrap();
    let library = library(root.path());
    let peer = NodeId([0x22; 32]);
    let db = paired_db(peer).await;
    let bytes = b"already in the library";
    let hash = *blake3::hash(bytes).as_bytes();
    std::fs::create_dir_all(library.join("originals")).unwrap();
    std::fs::write(library.join("originals/existing.jpg"), bytes).unwrap();
    db.insert_asset(&Asset {
        hash: hash.to_vec(),
        rel_path: "originals/existing.jpg".into(),
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
    let (transport, blobs) = receiver_blobs(root.path()).await;
    let delivery =
        FlowDelivery::new(db, blobs, &library).with_free_space_probe(free_space(Some(0)));
    let offer = request(
        "lease-1",
        hash,
        transport.local_addr().to_string(),
        (4 * GIB) as i64,
    );

    let reply = delivery.offer(peer, &offer).await.unwrap();
    assert_eq!(
        reply.state, "completed",
        "dedup must win over the space precheck"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn offer_refuses_with_library_unavailable_when_the_library_folder_is_gone() {
    let root = tempdir().unwrap();
    let library = library(root.path());
    let peer = NodeId([0x22; 32]);
    let db = paired_db(peer).await;
    let (transport, blobs) = receiver_blobs(root.path()).await;
    let delivery =
        FlowDelivery::new(db, blobs, &library).with_free_space_probe(free_space(Some(100 * GIB)));
    std::fs::remove_dir_all(&library).unwrap();
    let hash = *blake3::hash(b"no library").as_bytes();
    let offer = request("lease-1", hash, transport.local_addr().to_string(), 10);

    let error = delivery.offer(peer, &offer).await.unwrap_err();
    assert_eq!(error.wire_code(), "library_unavailable", "{error:?}");
    let status = delivery.status(peer, &tuple("lease-1")).await.unwrap();
    assert_eq!(status.state, "not_found");
    assert!(!library.exists());
}

// ── Failure-code classification ─────────────────────────────────────────

#[test]
fn failure_classification_trusts_the_io_error_first_then_the_environment() {
    use std::io::ErrorKind;
    let healthy = Some(100 * GIB);
    for kind in [ErrorKind::StorageFull, ErrorKind::QuotaExceeded] {
        assert_eq!(
            classify_peer_failure(Some(kind), true, healthy),
            PeerFailure::StorageFull
        );
    }
    for kind in [
        ErrorKind::ReadOnlyFilesystem,
        ErrorKind::PermissionDenied,
        ErrorKind::NotFound,
    ] {
        assert_eq!(
            classify_peer_failure(Some(kind), true, healthy),
            PeerFailure::LibraryUnavailable
        );
    }
    // No usable io kind (e.g. a blob-store export error arrives as text):
    // the environment decides.
    assert_eq!(
        classify_peer_failure(None, false, healthy),
        PeerFailure::LibraryUnavailable
    );
    assert_eq!(
        classify_peer_failure(Some(ErrorKind::Other), true, Some(0)),
        PeerFailure::StorageFull
    );
    assert_eq!(
        classify_peer_failure(None, true, healthy),
        PeerFailure::StorageFailed
    );
    assert_eq!(
        classify_peer_failure(None, true, None),
        PeerFailure::StorageFailed,
        "unknown free space is never guessed as full"
    );
    assert_eq!(PeerFailure::StorageFull.code(), "storage_full");
    assert_eq!(
        PeerFailure::LibraryUnavailable.code(),
        "library_unavailable"
    );
    assert_eq!(PeerFailure::StorageFailed.code(), "storage_failed");
}

/// End to end: a materialize failure (the staging folder cannot be created
/// because a regular file sits where it belongs) is pushed with a public
/// code — never the internal `materialize_*` telemetry code.
async fn pushed_failure_code(free: Option<u64>) -> String {
    let root = tempdir().unwrap();
    let library = library(root.path());
    std::fs::write(library.join(".ppf/flow-staging"), b"blocks the staging dir").unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let bytes = b"materialize failure fixture";
    let source = root.path().join("source.jpg");
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let provider_node = provider_transport.node_id();

    let (_t, blobs) = receiver_blobs(root.path()).await;
    let db = paired_db(provider_node).await;
    let (event_bus, mut event_rx) = events::bus();
    let delivery = FlowDelivery::new(db, blobs, &library)
        .with_events_and_window(event_bus, std::time::Duration::from_millis(20))
        .with_free_space_probe(free_space(free));
    delivery
        .offer(provider_node, &request("lease-1", hash, ticket, 0))
        .await
        .unwrap();

    let failed = tokio::time::timeout(std::time::Duration::from_secs(30), async {
        loop {
            let event = event_rx.recv().await.unwrap();
            if event["event"].as_str() == Some(events::FLOW_FAILED) {
                return event;
            }
        }
    })
    .await
    .expect("materialize failure must push flow.failed");
    drop(provider_blobs);
    failed["data"]["code"].as_str().unwrap().to_owned()
}

#[tokio::test(flavor = "multi_thread")]
async fn materialize_failure_is_pushed_as_storage_failed_on_a_healthy_desktop() {
    assert_eq!(pushed_failure_code(Some(100 * GIB)).await, "storage_failed");
}

#[tokio::test(flavor = "multi_thread")]
async fn materialize_failure_is_pushed_as_storage_full_when_the_disk_is_out_of_space() {
    assert_eq!(pushed_failure_code(Some(0)).await, "storage_full");
}

// ── Grant lifecycle: suspend protects, 3-day deadline releases ───────────

fn payload(seed: u64) -> Vec<u8> {
    const PAYLOAD: usize = 24 * 1024 * 1024;
    let mut out = Vec::with_capacity(PAYLOAD);
    let mut s = seed;
    while out.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        out.extend_from_slice(&s.to_le_bytes());
    }
    out.truncate(PAYLOAD);
    out
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
    let mut total = 0;
    walk(dir, &mut total);
    total
}

async fn gc_blobs(transport: &IrohTransport, store: &Path, db: Db) -> Arc<Blobs> {
    Arc::new(
        Blobs::open_with_periodic_gc(
            transport,
            store,
            std::time::Duration::from_millis(20),
            move || {
                let db = db.clone();
                Box::pin(async move {
                    db.active_flow_content_hashes().await.map_err(|error| {
                        transport::TransportError::Io(format!("GC protection query: {error}"))
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
    )
}

/// Everything a lifecycle test needs: a provider serving a 24 MiB payload
/// and a GC-running receiver whose fetch has been caught mid-flight.
struct MidFlight {
    _root: tempfile::TempDir,
    _provider: (IrohTransport, Blobs),
    db: Db,
    blobs: Arc<Blobs>,
    delivery: FlowDelivery,
    clock: Arc<AtomicI64>,
    provider_node: NodeId,
    offer: FlowFetchRequest,
    hash: [u8; 32],
    size: u64,
}

/// Offers the payload and returns once the receiver holds a genuine
/// partial (>= 2 MiB) while the fetch task is still running. Retries with a
/// fresh store when the loopback transfer outruns the threshold.
async fn caught_mid_flight(seed: u64) -> Option<MidFlight> {
    const KILL_THRESHOLD: u64 = 2 * 1024 * 1024;
    let data = payload(seed);
    let root = tempdir().unwrap();
    let library = library(root.path());
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let source = root.path().join("source.bin");
    std::fs::write(&source, &data).unwrap();
    let hash = *blake3::hash(&data).as_bytes();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let provider_node = provider_transport.node_id();
    let db = paired_db(provider_node).await;
    let store = root.path().join("receiver-store");
    let offer = request("lease-1", hash, ticket, data.len() as i64);

    for attempt in 0..8 {
        let _ = std::fs::remove_dir_all(&store);
        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let blobs = gc_blobs(&receiver_transport, &store, db.clone()).await;
        let clock = Arc::new(AtomicI64::new(1_000_000));
        let clock_seen = Arc::clone(&clock);
        let delivery = FlowDelivery::new(db.clone(), blobs.clone(), &library)
            .with_free_space_probe(free_space(Some(100 * GIB)))
            .with_clock(move || clock_seen.load(Ordering::Relaxed));
        delivery.offer(provider_node, &offer).await.unwrap();

        let started = std::time::Instant::now();
        let mut running = true;
        while dir_bytes(&store) < KILL_THRESHOLD {
            let status = delivery
                .status(provider_node, &tuple("lease-1"))
                .await
                .unwrap();
            if status.state != "active" {
                running = false;
                break;
            }
            assert!(started.elapsed() < std::time::Duration::from_secs(60));
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        if !running
            || delivery
                .status(provider_node, &tuple("lease-1"))
                .await
                .unwrap()
                .state
                != "active"
        {
            eprintln!("attempt {attempt}: transfer outran the kill threshold, retrying");
            continue;
        }
        return Some(MidFlight {
            _root: root,
            _provider: (provider_transport, provider_blobs),
            db,
            blobs,
            delivery,
            clock,
            provider_node,
            offer,
            hash,
            size: data.len() as u64,
        });
    }
    None
}

async fn wait_until_not_running(m: &MidFlight) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        // `status` would respawn a stopped task, so observe the registry
        // through a fresh handle over the same state instead: the grant's
        // durable state plus "is anything still pulling bytes".
        let before = m.blobs.local_bytes(m.hash).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        let after = m.blobs.local_bytes(m.hash).await.unwrap();
        if before == after {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "suspended fetch kept pulling bytes"
        );
    }
}

/// `flow.suspend` keeps the grant active, so the partial stays in the GC
/// protection set across many GC cycles; the phone's next `flow.offer` on
/// the same tuple (no `flow.fetch`) resumes and finishes from that partial.
#[tokio::test(flavor = "multi_thread")]
async fn suspended_partial_survives_gc_and_a_reoffer_of_the_same_tuple_resumes_it() {
    let m = caught_mid_flight(0xABCD_1234_9876_0001)
        .await
        .expect("never caught the transfer mid-flight across 8 attempts");
    m.delivery
        .suspend(m.provider_node, &tuple("lease-1"))
        .await
        .unwrap();
    wait_until_not_running(&m).await;
    let partial = m.blobs.local_bytes(m.hash).await.unwrap();
    assert!(
        partial > 0 && partial < m.size,
        "expected a partial, got {partial}"
    );

    // Dozens of 20 ms GC cycles.
    tokio::time::sleep(std::time::Duration::from_millis(600)).await;
    assert_eq!(
        m.blobs.local_bytes(m.hash).await.unwrap(),
        partial,
        "GC must not touch a suspended grant's partial"
    );
    assert!(m
        .db
        .active_flow_content_hashes()
        .await
        .unwrap()
        .contains(&m.hash));

    let reply = m.delivery.offer(m.provider_node, &m.offer).await.unwrap();
    assert_eq!(reply.state, "active");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        let status = m
            .delivery
            .status(m.provider_node, &tuple("lease-1"))
            .await
            .unwrap();
        if status.state == "completed" {
            assert_eq!(status.receipt.unwrap().content_hash, hex::encode(m.hash));
            break;
        }
        assert_eq!(status.state, "active");
        assert!(
            std::time::Instant::now() < deadline,
            "resume never completed"
        );
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    // The blob itself is GC'd once the grant completes (NET-20 contract), so
    // the proof of a whole item is the ingested library copy.
    let asset = m.db.get_asset(&m.hash).await.unwrap().expect("ingested");
    assert_eq!(asset.bytes as u64, m.size);
}

/// The 3-day deadline: a running fetch is never expired; a suspended grant
/// is kept until the deadline passes, then cancelled so GC reclaims its
/// partial.
#[tokio::test(flavor = "multi_thread")]
async fn a_grant_nobody_resumes_for_three_days_is_cancelled_and_its_partial_reclaimed() {
    let m = caught_mid_flight(0x5EAF_00D1_2345_6789)
        .await
        .expect("never caught the transfer mid-flight across 8 attempts");
    let offered_at = m.clock.load(Ordering::Relaxed);

    // Still pulling bytes: even far past the deadline, never expired.
    m.clock
        .store(offered_at + GRANT_RESUME_TTL_MS + 1, Ordering::Relaxed);
    assert_eq!(m.delivery.expire_stale_grants().await.unwrap(), 0);

    m.clock.store(offered_at, Ordering::Relaxed);
    m.delivery
        .suspend(m.provider_node, &tuple("lease-1"))
        .await
        .unwrap();
    wait_until_not_running(&m).await;
    let partial = m.blobs.local_bytes(m.hash).await.unwrap();
    assert!(partial > 0 && partial < m.size);

    // Just before the deadline: kept.
    m.clock
        .store(offered_at + GRANT_RESUME_TTL_MS - 1, Ordering::Relaxed);
    assert_eq!(m.delivery.expire_stale_grants().await.unwrap(), 0);

    // Past the deadline: released.
    m.clock
        .store(offered_at + GRANT_RESUME_TTL_MS + 1, Ordering::Relaxed);
    assert_eq!(m.delivery.expire_stale_grants().await.unwrap(), 1);
    let status = m
        .delivery
        .status(m.provider_node, &tuple("lease-1"))
        .await
        .unwrap();
    assert_eq!(status.state, "cancelled");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while m.blobs.local_bytes(m.hash).await.unwrap() != 0 {
        assert!(
            std::time::Instant::now() < deadline,
            "expired partial was not reclaimed by periodic GC"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}

/// A re-offer is the resume signal: the deadline is measured from the last
/// offer, not the first. The provider serves no such blob, so each offer's
/// fetch fails fast and leaves the grant active with nothing running.
#[tokio::test(flavor = "multi_thread")]
async fn the_resume_deadline_restarts_on_every_reoffer_of_the_tuple() {
    let root = tempdir().unwrap();
    let library = library(root.path());
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let provider_node = provider_transport.node_id();
    let db = paired_db(provider_node).await;
    let (_t, blobs) = receiver_blobs(root.path()).await;
    let (event_bus, mut event_rx) = events::bus();
    let clock = Arc::new(AtomicI64::new(1_000_000));
    let clock_seen = Arc::clone(&clock);
    let delivery = FlowDelivery::new(db, blobs, &library)
        .with_events_and_window(event_bus, std::time::Duration::from_millis(20))
        .with_free_space_probe(free_space(Some(100 * GIB)))
        .with_clock(move || clock_seen.load(Ordering::Relaxed));
    let hash = *blake3::hash(b"the provider never had this").as_bytes();
    let offer = request(
        "lease-1",
        hash,
        provider_transport.local_addr().to_string(),
        10,
    );
    let mut offer_and_wait_for_failure = async || {
        delivery.offer(provider_node, &offer).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(45), async {
            loop {
                let event = event_rx.recv().await.unwrap();
                if event["event"].as_str() == Some(events::FLOW_FAILED) {
                    return;
                }
            }
        })
        .await
        .expect("the fetch of a blob the provider lacks must fail");
    };

    let first = clock.load(Ordering::Relaxed);
    offer_and_wait_for_failure().await;
    clock.store(first + GRANT_RESUME_TTL_MS - 1, Ordering::Relaxed);
    offer_and_wait_for_failure().await;
    clock.store(first + GRANT_RESUME_TTL_MS + 1, Ordering::Relaxed);
    assert_eq!(
        delivery.expire_stale_grants().await.unwrap(),
        0,
        "measured from the last offer, not the first"
    );
    clock.store(first + 2 * GRANT_RESUME_TTL_MS, Ordering::Relaxed);
    assert_eq!(delivery.expire_stale_grants().await.unwrap(), 1);
    drop(provider_blobs);
}

#[test]
fn grant_resume_deadline_is_three_days() {
    assert_eq!(GRANT_RESUME_TTL_MS, 3 * 24 * 60 * 60 * 1000);
}
