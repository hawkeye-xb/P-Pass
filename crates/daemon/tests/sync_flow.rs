//! SYNC-01 acceptance: external deletion reconcile — disk ↔ index diff.
//!
//! 5 photos in via the real upload plane → 2 originals deleted on disk
//! (Finder-style external deletion) → reconcile runs → timeline has 3,
//! the deleted pair's thumb files are gone (not-found on request), and
//! the audit log carries 2 `asset.removed_external` rows with actor=NULL.
//!
//! Reverse-proof is inlined: the assertion right after the disk deletions
//! ("still 5 indexed") only passes while reconcile has NOT run — comment
//! out the `Reconcile::run_once` call below and the "timeline has 3"
//! assertion must go red.

use daemon::reconcile::Reconcile;
use daemon::{BackupEngine, QueryEngine, Router};
use proto::msgs::{methods, BackupItem, BackupManifest, TimelineQuery, UploadHeader};
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
    stream.send_frame(bytes).await.unwrap();
    stream.finish().unwrap();
    let frame = stream.recv_frame().await.unwrap().expect("a response");
    proto::codec::decode::<Resp>(&frame).unwrap()
}

fn parse_hash(hex: &str) -> [u8; 32] {
    let mut h = [0u8; 32];
    for (i, b) in hex.as_bytes().chunks(2).enumerate() {
        h[i] = (hex_val(b[0]) << 4) | hex_val(b[1]);
    }
    h
}

fn hex_val(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => panic!("bad hex"),
    }
}

struct Fixture {
    daemon_tp: IrohTransport,
    phone_tp: IrohTransport,
    db: Db,
    blobs: std::sync::Arc<Blobs>,
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
    let query = QueryEngine::new(db.clone(), blobs.clone(), library.path());
    let upload = daemon::upload::UploadPlane::new(db.clone(), library.path().join(".ppf/staging"));
    let download = daemon::download::DownloadPlane::new(db.clone(), library.path().to_path_buf());
    let router = Router::new(db.clone(), "test-daemon")
        .with_backup(backup)
        .with_query(query)
        .with_upload(upload)
        .with_download(download);
    let tp2 = daemon_tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });

    let phone_tp = bind(vec![transport::ALPN_CTRL.into()]).await;
    phone_tp.add_peer(daemon_tp.local_addr());
    db.upsert_device(&Device {
        device_hint: None,
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
        blobs,
        library,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn external_deletion_reconciles_index_thumbs_and_audit() {
    let f = fixture().await;
    let daemon_id = f.daemon_tp.node_id();

    // 5 distinct "photos".
    let files: Vec<Vec<u8>> = (0u8..5)
        .map(|i| {
            let mut v = vec![i; 50_000 + i as usize];
            v.extend_from_slice(format!("sync-tail-{i}").as_bytes());
            v
        })
        .collect();
    let hashes: Vec<String> = files
        .iter()
        .map(|d| blake3::hash(d).to_hex().to_string())
        .collect();

    // begin + manifest + upload ×5 + commit — the real ingest path.
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
    for (h, data) in hashes.iter().zip(&files) {
        let resp = upload(&f.phone_tp, daemon_id, h, data).await;
        assert!(resp.ok, "upload {h}: {:?}", resp.error);
    }
    let resp = call(
        &f.phone_tp,
        daemon_id,
        methods::BACKUP_COMMIT,
        serde_json::json!({"generation": 7}),
    )
    .await;
    assert!(resp.ok, "{:?}", resp.error);
    assert_eq!(resp.result.unwrap()["ingested"], 5);

    // Real files on disk + thumbnails materialized (as the query engine
    // would on first request).
    let thumbs_root = f.library.path().join(".ppf/thumbs");
    let mut disk_paths = Vec::new();
    for (h, data) in hashes.iter().zip(&files) {
        let asset =
            f.db.get_asset(&parse_hash(h))
                .await
                .unwrap()
                .unwrap_or_else(|| panic!("asset {h} indexed"));
        let abs = f.library.path().join(&asset.rel_path);
        assert_eq!(&std::fs::read(&abs).unwrap(), data, "{h} bit-identical");
        media_codec::make_thumbs(&parse_hash(h), &abs, &thumbs_root);
        disk_paths.push((parse_hash(h), abs));
    }

    // Reverse-proof half (a): on a CLEAN disk reconcile is a no-op —
    // nothing deleted yet, nothing removed, index stays 5. (Comment out
    // the run_once calls and the later "3" assertions go red instead.)
    let reconcile = Reconcile::new(f.db.clone(), f.library.path());
    assert_eq!(reconcile.run_once().await.removed, 0, "no-op on clean disk");
    assert_eq!(f.db.list_asset_paths().await.unwrap().len(), 5);

    // ── External deletion: 2 originals vanish (Finder-style, no daemon
    // involvement). The phone never learns — index/thumb still reference
    // them.
    let deleted: Vec<[u8; 32]> = disk_paths[0..2].iter().map(|(h, _)| *h).collect();
    for (_, abs) in &disk_paths[0..2] {
        std::fs::remove_file(abs).unwrap();
    }

    // Reverse-proof half (b): with the files gone but reconcile not yet
    // run, the index must still carry all 5.
    assert_eq!(f.db.list_asset_paths().await.unwrap().len(), 5);

    // ── Now make the phantom deletions real: run the reconcile.
    let report = reconcile.run_once().await;
    assert_eq!(report.removed, 2, "exactly the 2 disk-missing assets go");

    // 1. Index converged: 3 rows left, deleted pair absent.
    let remaining = f.db.list_asset_paths().await.unwrap();
    assert_eq!(remaining.len(), 3, "timeline source now 3");
    for (h, _) in &remaining {
        assert!(
            !deleted.iter().any(|d| d.as_slice() == h.as_slice()),
            "deleted hash {h:?} must not remain indexed"
        );
    }

    // 2. Thumb files: deleted pair gone (request would 404), survivors intact.
    for h in &deleted {
        let tp = media_codec::thumb_paths(&thumbs_root, h);
        assert!(
            std::fs::metadata(&tp.t256).is_err(),
            "deleted asset thumb 256 must be gone"
        );
        assert!(
            std::fs::metadata(&tp.t1024).is_err(),
            "deleted asset thumb 1024 must be gone"
        );
    }
    for (h, _) in &disk_paths[2..] {
        let tp = media_codec::thumb_paths(&thumbs_root, h);
        assert!(
            std::fs::metadata(&tp.t256).is_ok(),
            "surviving asset thumb 256 stays"
        );
    }

    // 3. Audit: 2 `asset.removed_external` rows, actor=NULL, hashes match.
    let audit = f.db.list_audit(100).await.unwrap();
    let external: Vec<_> = audit
        .iter()
        .filter(|r| r.entry.action == "asset.removed_external")
        .collect();
    assert_eq!(external.len(), 2, "two audit rows: {audit:?}");
    for r in &external {
        assert!(r.entry.actor.is_none(), "external deletion has no actor");
        let target = r.entry.target_hash.as_ref().expect("target hash set");
        assert!(
            deleted.contains(&target.as_slice().try_into().unwrap()),
            "audit target matches a deleted hash"
        );
    }

    // 4. Timeline (the phone's view) shows exactly the 3 survivors. The
    // blobs handle is a clone of the router's — same open store, no
    // second redb lock; timeline reads the index, never the store.
    let query = QueryEngine::new(f.db.clone(), f.blobs.clone(), f.library.path());
    let page = query
        .timeline(&TimelineQuery {
            cursor: None,
            limit: 100,
        })
        .await
        .unwrap();
    assert_eq!(page.items.len(), 3, "timeline converged: {page:?}");
}
