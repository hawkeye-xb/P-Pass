//! #563: removing a device on the desktop (`device.revoke`) must stop the
//! daemon pulling from it right away, and a photo from a device that lost
//! authorization must never enter the library.
//!
//! Two independent defenses, each with its own test so neither can hide
//! the other:
//! - the revoke sweep (IPC `device.revoke` → `FlowDelivery::revoke_peer`)
//!   cancels the grant *at revoke time*, before the transfer could finish;
//! - the pre-ingest re-check drops the item when the device was revoked
//!   behind the sweep's back (plain `db.revoke`, no sweep).

use std::path::Path;
use std::sync::Arc;

use daemon::flow_delivery::{DeliveryError, FlowDelivery};
use daemon::{DiagAgg, IpcServer, Pairing};
use interprocess::local_socket::tokio::prelude::*;
use interprocess::local_socket::GenericNamespaced;
use proto::FlowFetchRequest;
use storage::{Db, Device, FlowGrantState, Role};
use tempfile::tempdir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use transport::{Blobs, IrohTransport, NodeId, TransportConfig, ALPN_BLOBS};

const PAYLOAD: usize = 24 * 1024 * 1024;
const KILL_THRESHOLD: u64 = 2 * 1024 * 1024;

fn noise(seed: u64) -> Vec<u8> {
    let mut payload = Vec::with_capacity(PAYLOAD);
    let mut s = seed;
    while payload.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        payload.extend_from_slice(&s.to_le_bytes());
    }
    payload.truncate(PAYLOAD);
    payload
}

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
        size_bytes: 0,
    }
}

async fn pair(db: &Db, peer: NodeId, name: &str, epoch: &str) {
    db.upsert_device(&Device {
        node_id: peer.0.to_vec(),
        name: name.into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
        revoked_at: None,
        revoked_by: None,
    })
    .await
    .unwrap();
    db.set_pairing_epoch(&peer.0, epoch).await.unwrap();
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

async fn grant_state(db: &Db, peer: NodeId, epoch: &str) -> Option<FlowGrantState> {
    db.flow_grant(&peer.0, epoch, 7)
        .await
        .unwrap()
        .map(|g| g.state)
}

// ── IPC client (same shape as ipc_flow.rs / subscribe_flow.rs) ──────────

struct IpcClient {
    lines: tokio::io::Lines<BufReader<interprocess::local_socket::tokio::RecvHalf>>,
    tx: interprocess::local_socket::tokio::SendHalf,
}

impl IpcClient {
    async fn call(&mut self, method: &str, params: serde_json::Value) -> proto::Resp {
        let req = proto::Req {
            id: method.into(),
            method: method.into(),
            params,
            ..Default::default()
        };
        let mut line = serde_json::to_string(&req).unwrap();
        line.push('\n');
        self.tx.write_all(line.as_bytes()).await.unwrap();
        let resp_line = self.lines.next_line().await.unwrap().expect("a response");
        serde_json::from_str(&resp_line).unwrap()
    }
}

/// An IpcServer wired to `delivery` exactly as main.rs does it
/// (`set_flow_delivery`), serving on a real local socket.
async fn ipc_for(db: &Db, delivery: &FlowDelivery, dir: &Path, tag: &str) -> IpcClient {
    let (event_bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), NodeId([0xCC; 32]), None, None);
    let ipc = Arc::new(IpcServer::new(
        db.clone(),
        pairing,
        DiagAgg::new(db.clone()),
        dir.to_path_buf(),
        pending_rx,
        event_bus,
    ));
    ipc.set_flow_delivery(delivery.clone());
    let socket = format!("ppf-rvk-{}-{}", std::process::id(), tag);
    let token = [0x5A; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    tokio::spawn({
        let ipc = Arc::clone(&ipc);
        let socket = socket.clone();
        async move {
            let _ = ipc.serve(&socket, token).await;
        }
    });
    let name = socket.clone().to_ns_name::<GenericNamespaced>().unwrap();
    for _ in 0..200 {
        if let Ok(conn) = interprocess::local_socket::tokio::Stream::connect(name.clone()).await {
            let (rx, mut tx) = conn.split();
            tx.write_all(format!("{token_hex}\n").as_bytes())
                .await
                .unwrap();
            return IpcClient {
                lines: BufReader::new(rx).lines(),
                tx,
            };
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    panic!("ipc socket {socket} never became connectable");
}

/// Test A — the revoke sweep. `device.revoke` over real IPC while phone A's
/// 24 MB transfer is mid-flight: by the time the IPC call returns, A's grant
/// is already `cancelled` and out of the GC protection set (the transfer
/// provably had not finished), A's fetch settles as `Cancelled`, nothing is
/// ingested. Phone B, transferring at the same time from the same daemon,
/// is untouched and completes. Then A re-pairs under a new epoch (#564):
/// the same item completes there, and the old-epoch row stays `cancelled`
/// instead of lingering `active`.
#[tokio::test(flavor = "multi_thread")]
async fn device_revoke_cancels_the_in_flight_fetch_before_it_can_finish() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let payload_a = noise(0x0563_A000_0000_0001);
    let payload_b = noise(0x0563_B000_0000_0002);
    let source_a = root.path().join("a.bin");
    let source_b = root.path().join("b.bin");
    std::fs::write(&source_a, &payload_a).unwrap();
    std::fs::write(&source_b, &payload_b).unwrap();
    let hash_a = *blake3::hash(&payload_a).as_bytes();
    let hash_b = *blake3::hash(&payload_b).as_bytes();
    let ticket_a = provider_blobs.push(hash_a, &source_a).await.unwrap();
    let ticket_b = provider_blobs.push(hash_b, &source_b).await.unwrap();

    let phone_a = NodeId([0xA1; 32]);
    let phone_b = NodeId([0xB2; 32]);
    let receiver_store = root.path().join("receiver-store");
    let offer_a = request("epoch-old", "lease-a", hash_a, ticket_a.clone());
    let offer_b = request("epoch-b", "lease-b", hash_b, ticket_b);

    let mut revoked_mid_flight = false;
    for attempt in 0..8 {
        let _ = std::fs::remove_dir_all(&receiver_store);
        let library = root.path().join(format!("library-{attempt}"));
        std::fs::create_dir_all(&library).unwrap();
        let db = Db::open_in_memory().await.unwrap();
        pair(&db, phone_a, "phone-a", "epoch-old").await;
        pair(&db, phone_b, "phone-b", "epoch-b").await;
        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let receiver_blobs = Arc::new(
            Blobs::open(&receiver_transport, &receiver_store)
                .await
                .unwrap(),
        );
        let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), &library);
        let mut ipc = ipc_for(&db, &delivery, root.path(), &format!("a{attempt}")).await;

        delivery.offer(phone_a, &offer_a).await.unwrap();
        delivery.offer(phone_b, &offer_b).await.unwrap();
        let fetch_a = tokio::spawn({
            let (d, o) = (delivery.clone(), offer_a.clone());
            async move { d.fetch(phone_a, &o).await }
        });
        let fetch_b = tokio::spawn({
            let (d, o) = (delivery.clone(), offer_b.clone());
            async move { d.fetch(phone_b, &o).await }
        });

        let started = std::time::Instant::now();
        while !fetch_a.is_finished() && dir_bytes(&receiver_store) < KILL_THRESHOLD {
            assert!(started.elapsed() < std::time::Duration::from_secs(60));
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        if fetch_a.is_finished() {
            eprintln!("attempt {attempt}: transfer outran the kill threshold, retrying");
            continue;
        }

        let resp = ipc
            .call(
                "device.revoke",
                serde_json::json!({ "node_id": hex::encode(phone_a.0) }),
            )
            .await;
        // Sampled the instant the IPC call returns — before the transfer
        // could have run to completion on its own.
        let state_at_revoke = grant_state(&db, phone_a, "epoch-old").await;
        let protected_at_revoke = db.active_flow_content_hashes().await.unwrap();
        let fetch_a_done_at_revoke = fetch_a.is_finished();
        if fetch_a_done_at_revoke && state_at_revoke == Some(FlowGrantState::Completed) {
            eprintln!("attempt {attempt}: transfer finished during the IPC round trip, retrying");
            continue;
        }
        assert_eq!(resp.result.unwrap()["revoked"], true);
        assert_eq!(
            state_at_revoke,
            Some(FlowGrantState::Cancelled),
            "device.revoke must cancel the removed device's grant itself, at revoke time"
        );
        assert!(
            !protected_at_revoke.contains(&hash_a),
            "the cancelled partial must leave the GC protection set at revoke time"
        );

        let outcome_a = tokio::time::timeout(std::time::Duration::from_secs(2), fetch_a)
            .await
            .expect("the revoked fetch must settle within 2s")
            .expect("fetch task must not panic");
        assert!(
            matches!(outcome_a, Err(DeliveryError::Cancelled)),
            "revoked fetch must end as Cancelled, got {outcome_a:?}"
        );

        // Phone B was never revoked: its transfer completes normally.
        let receipt_b = tokio::time::timeout(std::time::Duration::from_secs(60), fetch_b)
            .await
            .expect("B must complete")
            .expect("fetch task must not panic");
        assert!(
            receipt_b.is_ok(),
            "an unrelated device's transfer must be unaffected, got {receipt_b:?}"
        );
        assert_eq!(
            grant_state(&db, phone_b, "epoch-b").await,
            Some(FlowGrantState::Completed)
        );

        // Give a hypothetical late transfer/ingest time to happen, then
        // look: B (same size, started together) is done, so an A transfer
        // that kept running would be complete by now too.
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        assert!(
            receiver_blobs.local_bytes(hash_a).await.unwrap() < PAYLOAD as u64,
            "the revoked device's fetch task must actually stop pulling bytes"
        );
        assert_eq!(
            db.count_assets_from_device(&phone_a.0).await.unwrap(),
            0,
            "nothing from the revoked device may enter the library"
        );
        assert_eq!(db.count_assets_from_device(&phone_b.0).await.unwrap(), 1);
        assert!(db
            .flow_receipt(&phone_a.0, "epoch-old", 7)
            .await
            .unwrap()
            .is_none());

        // #564: re-pair A under a new epoch; the same item completes there
        // and the old-epoch row stays cancelled, not active.
        db.unrevoke(&phone_a.0).await.unwrap();
        db.set_pairing_epoch(&phone_a.0, "epoch-new").await.unwrap();
        let offer_a_new = request("epoch-new", "lease-a2", hash_a, ticket_a.clone());
        delivery.offer(phone_a, &offer_a_new).await.unwrap();
        delivery.fetch(phone_a, &offer_a_new).await.unwrap();
        assert_eq!(
            grant_state(&db, phone_a, "epoch-new").await,
            Some(FlowGrantState::Completed)
        );
        assert_eq!(
            grant_state(&db, phone_a, "epoch-old").await,
            Some(FlowGrantState::Cancelled),
            "#564: the pre-revoke epoch's row must not linger active"
        );
        assert_eq!(db.count_assets_from_device(&phone_a.0).await.unwrap(), 1);

        revoked_mid_flight = true;
        break;
    }
    assert!(
        revoked_mid_flight,
        "never managed to revoke mid-flight across 8 attempts"
    );
}

/// Test B — the pre-ingest re-check alone. The device is revoked straight
/// in the database while its transfer is mid-flight, so no sweep cancels
/// anything and the bytes arrive in full. The item must still be dropped
/// before ingest: no asset, no receipt, grant `cancelled` (out of GC
/// protection).
#[tokio::test(flavor = "multi_thread")]
async fn revoked_device_is_rechecked_before_ingest_even_without_the_sweep() {
    let root = tempdir().unwrap();
    let provider_transport =
        IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
    let mut provider_blobs = Blobs::open(&provider_transport, &root.path().join("provider-store"))
        .await
        .unwrap();
    provider_blobs.serve();
    let payload = noise(0x0563_C000_0000_0003);
    let source = root.path().join("c.bin");
    std::fs::write(&source, &payload).unwrap();
    let hash = *blake3::hash(&payload).as_bytes();
    let ticket = provider_blobs.push(hash, &source).await.unwrap();
    let phone = NodeId([0xC3; 32]);
    let receiver_store = root.path().join("receiver-store");
    let offer = request("epoch-current", "lease-c", hash, ticket);

    let mut revoked_mid_flight = false;
    for attempt in 0..8 {
        let _ = std::fs::remove_dir_all(&receiver_store);
        let library = root.path().join(format!("library-{attempt}"));
        std::fs::create_dir_all(&library).unwrap();
        let db = Db::open_in_memory().await.unwrap();
        pair(&db, phone, "phone-c", "epoch-current").await;
        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let receiver_blobs = Arc::new(
            Blobs::open(&receiver_transport, &receiver_store)
                .await
                .unwrap(),
        );
        let delivery = FlowDelivery::new(db.clone(), receiver_blobs.clone(), &library);
        delivery.offer(phone, &offer).await.unwrap();
        let fetch = tokio::spawn({
            let (d, o) = (delivery.clone(), offer.clone());
            async move { d.fetch(phone, &o).await }
        });
        let started = std::time::Instant::now();
        while !fetch.is_finished() && dir_bytes(&receiver_store) < KILL_THRESHOLD {
            assert!(started.elapsed() < std::time::Duration::from_secs(60));
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        if fetch.is_finished() {
            eprintln!("attempt {attempt}: transfer outran the kill threshold, retrying");
            continue;
        }
        // Revoke behind FlowDelivery's back: no sweep, the transfer runs on.
        assert!(db
            .revoke(&phone.0, storage::RevokedBy::Owner, 1)
            .await
            .unwrap());

        let outcome = tokio::time::timeout(std::time::Duration::from_secs(60), fetch)
            .await
            .expect("fetch must settle")
            .expect("fetch task must not panic");
        assert!(
            matches!(outcome, Err(DeliveryError::Cancelled)),
            "an item from a revoked device must be dropped before ingest, got {outcome:?}"
        );
        assert_eq!(
            db.count_assets_from_device(&phone.0).await.unwrap(),
            0,
            "nothing from the revoked device may enter the library"
        );
        assert!(db
            .flow_receipt(&phone.0, "epoch-current", 7)
            .await
            .unwrap()
            .is_none());
        assert_eq!(
            grant_state(&db, phone, "epoch-current").await,
            Some(FlowGrantState::Cancelled)
        );
        assert!(!db
            .active_flow_content_hashes()
            .await
            .unwrap()
            .contains(&hash));
        revoked_mid_flight = true;
        break;
    }
    assert!(
        revoked_mid_flight,
        "never managed to revoke mid-flight across 8 attempts"
    );
}
