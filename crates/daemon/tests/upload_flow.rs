//! T-054 acceptance: the phone-push upload plane, end to end over a
//! real loopback iroh connection — header + raw bytes in, BLAKE3
//! verified, blob stored; then commit ingests WITHOUT any reverse
//! dial (the uploader never serves blobs, so a pull would hang).

use daemon::upload::UploadPlane;
use daemon::{BackupEngine, Router};
use proto::msgs::{methods, BackupItem, BackupManifest, UploadHeader};
use proto::{Req, Resp};
use storage::{Db, Device, Role};
use transport::{Blobs, IrohTransport, Transport, TransportConfig};

async fn bind(alpns: Vec<String>) -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(alpns))
        .await
        .unwrap()
}

async fn call(
    tp: &IrohTransport,
    daemon: transport::NodeId,
    method: &str,
    params: serde_json::Value,
) -> Resp {
    let mut stream = tp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
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

/// Push one file over the upload plane, return the response.
async fn upload(
    tp: &IrohTransport,
    daemon: transport::NodeId,
    hash_hex: &str,
    bytes: &[u8],
) -> Resp {
    let mut stream = tp.connect(daemon, transport::ALPN_UPLOAD).await.unwrap();
    let header = Req {
        id: "up".into(),
        method: methods::BACKUP_UPLOAD.into(),
        params: serde_json::to_value(UploadHeader {
            hash: hash_hex.into(),
            bytes: bytes.len() as u64,
            file_name: "IMG_TEST.jpg".into(),
        })
        .unwrap(),
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&header).unwrap())
        .await
        .unwrap();
    // send_frame is a bare write_all — the upload payload is raw
    // bytes, no length header (the UploadHeader declared the size).
    stream.send_frame(bytes).await.unwrap();
    stream.finish().unwrap();
    let frame = stream.recv_frame().await.unwrap().expect("a response");
    proto::codec::decode::<Resp>(&frame).unwrap()
}

struct Fixture {
    daemon_tp: IrohTransport,
    phone_tp: IrohTransport,
    db: Db,
    library: tempfile::TempDir,
}

async fn fixture() -> Fixture {
    let library = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();

    let daemon_tp = bind(vec![
        transport::ALPN_CTRL.into(),
        transport::ALPN_BLOBS.into(),
        transport::ALPN_UPLOAD.into(),
        transport::ALPN_DOWNLOAD.into(),
    ])
    .await;
    let blobs = std::sync::Arc::new(
        Blobs::open(&daemon_tp, &library.path().join(".ppf/blobs"))
            .await
            .unwrap(),
    );
    blobs.attach_to_listener();
    let backup = BackupEngine::new(db.clone(), blobs.clone(), library.path());
    let upload = UploadPlane::new(db.clone(), blobs, library.path().join(".ppf/staging"));
    let download = daemon::download::DownloadPlane::new(db.clone(), library.path().to_path_buf());
    let router = Router::new(db.clone(), "test-daemon")
        .with_backup(backup)
        .with_upload(upload)
        .with_download(download);
    let tp2 = daemon_tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });

    let phone_tp = bind(vec![transport::ALPN_CTRL.into()]).await;
    phone_tp.add_peer(daemon_tp.local_addr());
    db.upsert_device(&Device {
        node_id: phone_tp.node_id().0.to_vec(),
        name: "phone".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();

    Fixture {
        daemon_tp,
        phone_tp,
        db,
        library,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn pushed_files_commit_without_reverse_dial() {
    let f = fixture().await;
    let daemon_id = f.daemon_tp.node_id();

    // Three distinct "photos".
    let files: Vec<Vec<u8>> = (0u8..3)
        .map(|i| {
            let mut v = vec![i; 100_000 + i as usize];
            v.extend_from_slice(format!("tail-{i}").as_bytes());
            v
        })
        .collect();
    let hashes: Vec<String> = files
        .iter()
        .map(|d| blake3::hash(d).to_hex().to_string())
        .collect();

    // begin + manifest (NO provider — the phone can't serve blobs).
    call(
        &f.phone_tp,
        daemon_id,
        methods::BACKUP_BEGIN,
        serde_json::json!({}),
    )
    .await;
    let manifest = BackupManifest {
        hashes: hashes.clone(),
        items: hashes
            .iter()
            .enumerate()
            .map(|(i, h)| BackupItem {
                hash: h.clone(),
                file_name: format!("IMG_{i}.jpg"),
                media_type: "image/jpeg".into(),
            })
            .collect(),
        provider: None,
    };
    let resp = call(
        &f.phone_tp,
        daemon_id,
        methods::BACKUP_MANIFEST,
        serde_json::to_value(&manifest).unwrap(),
    )
    .await;
    assert!(resp.ok, "{:?}", resp.error);

    // Push each missing file over the upload plane.
    for (h, data) in hashes.iter().zip(&files) {
        let resp = upload(&f.phone_tp, daemon_id, h, data).await;
        assert!(resp.ok, "upload {h}: {:?}", resp.error);
    }

    // Commit: everything is already local — no reverse dial happens
    // (the phone serves nothing; a pull attempt would error/hang).
    let resp = call(
        &f.phone_tp,
        daemon_id,
        methods::BACKUP_COMMIT,
        serde_json::json!({"generation": 7}),
    )
    .await;
    assert!(resp.ok, "{:?}", resp.error);
    let result = resp.result.unwrap();
    assert_eq!(result["ingested"], 3, "all three photos land: {result}");

    // The files are real on disk, content-addressed and bit-identical.
    for (h, data) in hashes.iter().zip(&files) {
        let asset = f.db.get_asset(&parse_hash(h)).await.unwrap();
        let asset = asset.unwrap_or_else(|| panic!("asset {h} indexed"));
        let on_disk = f.library.path().join(&asset.rel_path);
        assert_eq!(&std::fs::read(&on_disk).unwrap(), data, "{h} bit-identical");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn lying_hash_is_rejected_and_not_stored() {
    let f = fixture().await;
    let daemon_id = f.daemon_tp.node_id();

    let data = vec![7u8; 50_000];
    let wrong = "ab".repeat(32); // valid shape, wrong content hash
    let resp = upload(&f.phone_tp, daemon_id, &wrong, &data).await;
    assert!(!resp.ok, "a lying hash must be rejected");

    // And nothing snuck into the library.
    assert!(f.db.get_asset(&parse_hash(&wrong)).await.unwrap().is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn unpaired_uploader_is_shut_out() {
    let f = fixture().await;
    let daemon_id = f.daemon_tp.node_id();

    let stranger = bind(vec![transport::ALPN_CTRL.into()]).await;
    stranger.add_peer(f.daemon_tp.local_addr());

    let data = vec![9u8; 10_000];
    let h = blake3::hash(&data).to_hex().to_string();
    let resp = upload(&stranger, daemon_id, &h, &data).await;
    assert!(!resp.ok, "stranger must be denied");
    assert_eq!(resp.error.unwrap().code, proto::codes::NOT_AUTHORIZED);
}

fn parse_hash(hex: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap();
    }
    out
}

/// T-056: what goes up must come down — download returns bit-identical
/// original bytes, and a viewer (browse-only role) may download too.
#[tokio::test(flavor = "multi_thread")]
async fn download_returns_bit_identical_bytes() {
    let f = fixture().await;
    let daemon_id = f.daemon_tp.node_id();

    let data: Vec<u8> = (0..500_000u32).flat_map(|i| i.to_le_bytes()).collect();
    let hash = blake3::hash(&data).to_hex().to_string();

    // Upload + commit so the asset is indexed on disk.
    call(
        &f.phone_tp,
        daemon_id,
        methods::BACKUP_BEGIN,
        serde_json::json!({}),
    )
    .await;
    let manifest = BackupManifest {
        hashes: vec![hash.clone()],
        items: vec![BackupItem {
            hash: hash.clone(),
            file_name: "VID_0001.mp4".into(),
            media_type: "video/mp4".into(),
        }],
        provider: None,
    };
    call(
        &f.phone_tp,
        daemon_id,
        methods::BACKUP_MANIFEST,
        serde_json::to_value(&manifest).unwrap(),
    )
    .await;
    assert!(upload(&f.phone_tp, daemon_id, &hash, &data).await.ok);
    assert!(
        call(
            &f.phone_tp,
            daemon_id,
            methods::BACKUP_COMMIT,
            serde_json::json!({})
        )
        .await
        .ok
    );

    // Download over the download plane.
    let mut stream = f
        .phone_tp
        .connect(daemon_id, transport::ALPN_DOWNLOAD)
        .await
        .unwrap();
    let req = Req {
        id: "dl".into(),
        method: methods::ASSET_DOWNLOAD.into(),
        params: serde_json::json!({ "hash": hash }),
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&req).unwrap())
        .await
        .unwrap();
    stream.finish().unwrap();

    let head = stream.recv_frame().await.unwrap().expect("header resp");
    let head: Resp = proto::codec::decode(&head).unwrap();
    assert!(head.ok, "{:?}", head.error);
    assert_eq!(head.result.unwrap()["bytes"], data.len() as u64);

    let mut got = Vec::new();
    while let Some(chunk) = stream.recv_chunk(256 * 1024).await.unwrap() {
        got.extend_from_slice(&chunk);
    }
    assert_eq!(got.len(), data.len());
    assert_eq!(got, data, "bit-identical original");
}

#[tokio::test(flavor = "multi_thread")]
async fn stranger_cannot_download() {
    let f = fixture().await;
    let daemon_id = f.daemon_tp.node_id();

    let stranger = bind(vec![transport::ALPN_CTRL.into()]).await;
    stranger.add_peer(f.daemon_tp.local_addr());
    let mut stream = stranger
        .connect(daemon_id, transport::ALPN_DOWNLOAD)
        .await
        .unwrap();
    let req = Req {
        id: "dl".into(),
        method: methods::ASSET_DOWNLOAD.into(),
        params: serde_json::json!({ "hash": "ab".repeat(32) }),
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&req).unwrap())
        .await
        .unwrap();
    stream.finish().unwrap();
    let head = stream.recv_frame().await.unwrap().expect("resp");
    let head: Resp = proto::codec::decode(&head).unwrap();
    assert!(!head.ok);
    assert_eq!(head.error.unwrap().code, proto::codes::NOT_AUTHORIZED);
}
