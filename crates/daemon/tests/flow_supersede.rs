//! #851 `flow.supersede` 端到端：真 iroh 环回传输，「手机」提供原图，桌面库里是同一台手机早先传的
//! 抹过地点的副本。样本是三星 Android 15 真机取的 HEIC（core-media/tests/fixtures/redaction）。

use std::path::Path;
use std::sync::Arc;

use core_index::{IncomingFile, IngestOutcome, Ingestor};
use daemon::backup::BackupEngine;
use daemon::flow_delivery::FlowDelivery;
use proto::FlowSupersedeRequest;
use storage::{Db, Device, Role};
use tempfile::tempdir;
use transport::{Blobs, IrohTransport, TransportConfig, ALPN_BLOBS};

fn fixture(kind: &str) -> Vec<u8> {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../core-media/tests/fixtures/redaction/heic.{kind}.heic"
    ));
    std::fs::read(p).unwrap()
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
        revoked_at: None,
        revoked_by: None,
    })
    .await
    .unwrap();
    db.set_pairing_epoch(&peer.0, epoch).await.unwrap();
    db
}

#[tokio::test(flavor = "multi_thread")]
async fn supersede_fetches_only_the_metadata_and_replaces_in_place() {
    let root = tempdir().unwrap();
    let (original, redacted) = (fixture("original"), fixture("redacted"));
    let (a, b) = (
        *blake3::hash(&redacted).as_bytes(),
        *blake3::hash(&original).as_bytes(),
    );

    // 「手机」：提供原图 B。
    let phone_tp = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let mut phone_blobs = Blobs::open(&phone_tp, &root.path().join("phone-store"))
        .await
        .unwrap();
    phone_blobs.serve();
    let src = root.path().join("original.heic");
    std::fs::write(&src, &original).unwrap();
    let ticket = phone_blobs.push(b, &src).await.unwrap();
    let control = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let peer = control.node_id();

    // 桌面：库里是这台手机早先传的抹过地点的副本 A。
    let desk_tp = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let desk_blobs = Arc::new(
        Blobs::open(&desk_tp, &root.path().join("desk-store"))
            .await
            .unwrap(),
    );
    let library = root.path().join("library");
    let db = paired_db("epoch-1", peer).await;
    let staged = root.path().join("incoming.heic");
    std::fs::write(&staged, &redacted).unwrap();
    let IngestOutcome::New(rel) = Ingestor::new(db.clone(), &library)
        .ingest(&IncomingFile {
            src_path: staged,
            file_name: "IMG_0001.HEIC".into(),
            media_type: "image/heic".into(),
            src_device: peer.0.to_vec(),
            capture_at_ms_hint: None,
        })
        .await
        .unwrap()
    else {
        panic!()
    };
    let delivery = FlowDelivery::new(db.clone(), desk_blobs.clone(), &library);
    let req = FlowSupersedeRequest {
        pairing_epoch: "epoch-1".into(),
        old_hash: hex::encode(a),
        new_hash: hex::encode(b),
        provider: ticket,
    };

    let reply = delivery.supersede(peer, &req).await.unwrap();
    assert_eq!(
        (reply.outcome.as_str(), reply.reason.as_str()),
        ("replaced", "")
    );
    assert_eq!(
        std::fs::read(library.join(&rel)).unwrap(),
        original,
        "库里那份 = 原图，路径不变"
    );
    assert!(db.get_asset(&a).await.unwrap().is_none());
    assert_eq!(db.count_assets().await.unwrap(), 1, "仍是一张");
    let local = desk_blobs.local_bytes(b).await.unwrap();
    assert!(
        local < original.len() as u64 / 2,
        "只取了元数据那几块（本地 {local} / {}）",
        original.len()
    );

    // 重放：直接成功。
    assert_eq!(
        delivery.supersede(peer, &req).await.unwrap().outcome,
        "replaced"
    );

    // 对账问旧指纹：按替换后的那份回答「在」，手机不会把抹过的副本再传一遍。
    let backup = BackupEngine::new(db.clone(), desk_blobs.clone(), &library);
    let missing = backup
        .presence(&[hex::encode(a), hex::encode([9u8; 32])])
        .await
        .unwrap();
    assert_eq!(missing.hashes, vec![hex::encode([9u8; 32])]);
}

#[tokio::test(flavor = "multi_thread")]
async fn supersede_refuses_a_stale_epoch_without_touching_the_library() {
    let root = tempdir().unwrap();
    let control = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let desk_tp = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let desk_blobs = Arc::new(
        Blobs::open(&desk_tp, &root.path().join("desk-store"))
            .await
            .unwrap(),
    );
    let db = paired_db("epoch-2", control.node_id()).await;
    let delivery = FlowDelivery::new(db, desk_blobs, root.path().join("library"));
    let reply = delivery
        .supersede(
            control.node_id(),
            &FlowSupersedeRequest {
                pairing_epoch: "epoch-1".into(),
                old_hash: hex::encode([1u8; 32]),
                new_hash: hex::encode([2u8; 32]),
                provider: String::new(),
            },
        )
        .await
        .unwrap();
    assert_eq!(
        (reply.outcome.as_str(), reply.reason.as_str()),
        ("refused", "epoch_mismatch")
    );
}
