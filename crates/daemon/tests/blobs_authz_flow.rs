//! #546 / #547 end to end: "every data channel only answers paired devices",
//! and the first-pairing journey still works — scan (QR token) → pair.request
//! → owner accepts → the phone's photo is delivered over the gated data
//! planes.
//!
//! Desktop side: the daemon's `.ppf/blobs` store is attached with the
//! production gate (`blobs_gate::gate`, i.e. `authz::check` on the device
//! table). Phone side: the Android provider only serves the NodeId the
//! pairing record names — here taken from the QR code, as the app stores it.

use std::path::Path;
use std::sync::Arc;

use daemon::flow_delivery::FlowDelivery;
use daemon::{PairDecision, Pairing, Router};
use proto::{FlowFetchRequest, PairRequest, Req, Resp};
use storage::{Db, RevokedBy};
use transport::{AndroidBlobsProvider, Blobs, IrohTransport, NodeId, Transport, TransportConfig};

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

async fn bind(alpns: &[&str]) -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(
        alpns.iter().map(|a| (*a).to_string()).collect(),
    ))
    .await
    .unwrap()
}

struct Daemon {
    tp: IrohTransport,
    db: Db,
    pairing: Pairing,
    /// `.ppf/blobs` — what `asset.blob_ticket` / backup fallback use.
    blobs: Arc<Blobs>,
    delivery: FlowDelivery,
}

/// The daemon wiring from `main.rs`, trimmed to what this journey touches.
async fn start_daemon(root: &Path) -> Daemon {
    let db = Db::open_in_memory().await.unwrap();
    let tp = bind(&[transport::ALPN_CTRL, transport::ALPN_BLOBS]).await;
    let (pairing, mut pending) = Pairing::new(db.clone(), tp.node_id(), None, None);
    // The owner taps "allow" on the desktop.
    tokio::spawn(async move {
        while let Some(req) = pending.recv().await {
            let _ = req.decide(PairDecision::Accept);
        }
    });
    let blobs = Arc::new(Blobs::open(&tp, &root.join(".ppf/blobs")).await.unwrap());
    blobs.attach_to_listener(daemon::blobs_gate::gate(db.clone()));
    let flow_blobs = Arc::new(
        Blobs::open(&tp, &root.join(".ppf/flow-blobs"))
            .await
            .unwrap(),
    );
    let delivery = FlowDelivery::new(db.clone(), flow_blobs, root);
    let router = Router::new(db.clone(), "客厅的电脑").with_pairing(pairing.clone());
    let serving = tp.clone();
    tokio::spawn(async move { router.serve(&serving).await });
    Daemon {
        tp,
        db,
        pairing,
        blobs,
        delivery,
    }
}

async fn pair(phone: &IrohTransport, daemon: NodeId, token: &str) -> proto::PairAccepted {
    let mut stream = phone.connect(daemon, transport::ALPN_CTRL).await.unwrap();
    let req = Req {
        id: "pair-1".into(),
        method: "pair.request".into(),
        params: serde_json::to_value(PairRequest {
            token: token.into(),
            device_name: "妈妈的手机".into(),
            role: "member".into(),
            ..Default::default()
        })
        .unwrap(),
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&req).unwrap())
        .await
        .unwrap();
    stream.finish().unwrap();
    let frame = stream.recv_frame().await.unwrap().expect("a response");
    let resp: Resp = proto::codec::decode(&frame).unwrap();
    assert!(resp.ok, "first pairing must succeed: {resp:?}");
    serde_json::from_value(resp.result.unwrap()).unwrap()
}

fn qr_param<'a>(qr: &'a str, key: &str) -> &'a str {
    qr.split(['?', '&'])
        .find_map(|kv| kv.strip_prefix(&format!("{key}=")))
        .expect("QR parameter present")
}

async fn seed_daemon_blob(root: &Path, d: &Daemon, name: &str, bytes: &[u8]) -> [u8; 32] {
    let src = root.join(name);
    std::fs::write(&src, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    d.blobs.push(hash, &src).await.unwrap();
    hash
}

fn flow_request(epoch: &str, hash: [u8; 32], ticket: String) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: 1,
        pairing_epoch: epoch.into(),
        lease_token: "lease-1".into(),
        content_hash: hex::encode(hash),
        file_name: "IMG_0001.jpg".into(),
        media_type: "image/jpeg".into(),
        provider: ticket,
        capture_at_ms: 0,
        size_bytes: 0,
    }
}

async fn denial_details(db: &Db) -> Vec<String> {
    db.list_diag(100)
        .await
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "authz.denied")
        .filter_map(|e| e.detail)
        .filter(|d| d.contains("blobs.fetch"))
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn first_pairing_then_photo_delivery_over_gated_data_planes() {
    let root = tempfile::tempdir().unwrap();
    let d = start_daemon(root.path()).await;
    let original = seed_daemon_blob(root.path(), &d, "desk.jpg", b"a desktop original").await;

    // The phone, before pairing: knows the address and a hash, gets nothing.
    let phone = bind(&[transport::ALPN_CTRL, transport::ALPN_BLOBS]).await;
    phone.add_peer(d.tp.local_addr());
    let phone_blobs = Blobs::open(&phone, &root.path().join("phone-pull"))
        .await
        .unwrap();
    assert!(
        phone_blobs
            .fetch_from(d.tp.node_id(), original)
            .await
            .is_err(),
        "an unpaired phone must not pull a daemon blob"
    );
    assert_eq!(phone_blobs.local_bytes(original).await.unwrap(), 0);

    // Scan → token → pair.request → owner accepts.
    let qr = d.pairing.start([0x42; 12], now());
    let daemon_node_id = qr_param(&qr, "node").to_string();
    let accepted = pair(&phone, d.tp.node_id(), qr_param(&qr, "t")).await;
    assert_eq!(accepted.pairing_epoch.len(), 32);

    // Paired: the same phone now reads the desktop's data plane.
    phone_blobs
        .fetch_from(d.tp.node_id(), original)
        .await
        .expect("a paired phone pulls the daemon blob");
    assert_eq!(
        phone_blobs.local_bytes(original).await.unwrap(),
        b"a desktop original".len() as u64
    );

    // The phone serves a photo from its native provider, allowed peer taken
    // from the pairing record (the QR's node id), and the desktop pulls it.
    let photo = b"the photo from the phone".to_vec();
    let photo_hash = *blake3::hash(&photo).as_bytes();
    let photo_src = root.path().join("IMG_0001.jpg");
    std::fs::write(&photo_src, &photo).unwrap();
    let provider_root = root.path().join("phone-files");
    let (provider, ticket) = {
        let photo_src = photo_src.clone();
        let daemon_node_id = daemon_node_id.clone();
        tokio::task::spawn_blocking(move || {
            let provider = AndroidBlobsProvider::new_loopback(&provider_root).unwrap();
            provider.set_allowed_peer(Some(daemon_node_id.parse().unwrap()));
            let ticket = provider.register_path(photo_hash, &photo_src).unwrap();
            (provider, ticket)
        })
        .await
        .unwrap()
    };

    // A stranger holding the very same ticket gets nothing from the phone.
    let stranger = bind(&[transport::ALPN_BLOBS]).await;
    let stranger_blobs = Blobs::open(&stranger, &root.path().join("stranger"))
        .await
        .unwrap();
    assert!(stranger_blobs
        .pull(&ticket, &root.path().join("leaked.jpg"))
        .await
        .is_err());
    assert_eq!(stranger_blobs.local_bytes(photo_hash).await.unwrap(), 0);

    let offer = flow_request(&accepted.pairing_epoch, photo_hash, ticket);
    d.delivery.offer(phone.node_id(), &offer).await.unwrap();
    let receipt = d
        .delivery
        .fetch(phone.node_id(), &offer)
        .await
        .expect("the paired desktop receives the phone's photo");
    assert_eq!(receipt.content_hash, hex::encode(photo_hash));
    assert!(d.db.get_asset(&photo_hash).await.unwrap().is_some());

    // Owner removes the phone: its very next data-plane request is refused.
    let later = seed_daemon_blob(root.path(), &d, "later.jpg", b"added after revoke").await;
    assert!(d
        .db
        .revoke(&phone.node_id().0, RevokedBy::Owner, now())
        .await
        .unwrap());
    assert!(
        phone_blobs.fetch_from(d.tp.node_id(), later).await.is_err(),
        "a revoked phone must not pull anything more"
    );
    assert_eq!(phone_blobs.local_bytes(later).await.unwrap(), 0);

    // Denials are on record — 8-hex NodeId prefix only.
    let denials = denial_details(&d.db).await;
    assert!(!denials.is_empty(), "blobs denials are recorded");
    let full = phone.node_id().to_string();
    for detail in &denials {
        assert!(!detail.contains(&full), "no full NodeId in diag: {detail}");
    }
    assert!(denials
        .iter()
        .any(|detail| detail.contains(&format!("\"peer\":\"{}\"", &full[..8]))));

    tokio::task::spawn_blocking(move || drop(provider))
        .await
        .unwrap();
}
