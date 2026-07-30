//! T-033 acceptance: browse 500 assets — pagination without gaps or
//! repeats, every 256 px thumbnail a decodable JPEG, and 3 sampled
//! originals pulled over blobs verify BLAKE3.

use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::sync::Arc;

use daemon::{QueryEngine, Router};
use proto::{Req, Resp, ThumbData, ThumbGet, ThumbSize, TimelineQuery};
use storage::{Db, Device, Role};
use transport::{Blobs, IrohTransport, Transport, TransportConfig};

const ALPNS: &[&str] = &["ppf/ctrl/1", "ppf/blobs/1"];

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(
        ALPNS.iter().map(|s| s.to_string()).collect(),
    ))
    .await
    .unwrap()
}

/// Library with `n` small JPEGs ingested directly (browse is the unit
/// under test, not backup). Returns their (hash, bytes) pairs.
async fn seed_library(dir: &Path, db: &Db, n: u32) -> Vec<([u8; 32], Vec<u8>)> {
    let ing = core_index::Ingestor::new(db.clone(), dir.join("library"));
    let mut out = Vec::new();
    for i in 0..n {
        // Tiny real JPEGs (decodability matters for the thumb assertion).
        let img = image_bytes(i);
        let src = dir.join(format!("stage-{i}.jpg"));
        fs::write(&src, &img).unwrap();
        let hash = *blake3::hash(&img).as_bytes();
        ing.ingest(&core_index::IncomingFile {
            src_path: src,
            file_name: format!("IMG_{i:04}.jpg"),
            media_type: "image/jpeg".into(),
            src_device: vec![9u8; 32],
        })
        .await
        .unwrap();
        out.push((hash, img));
    }
    out
}

/// A real, tiny, per-index-unique JPEG via media-codec's encoder path.
fn image_bytes(i: u32) -> Vec<u8> {
    let img = image::RgbImage::from_fn(24 + (i % 5), 16, |x, y| {
        image::Rgb([(x + i) as u8, (y * 3) as u8, (i % 251) as u8])
    });
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85);
    enc.encode_image(&img).unwrap();
    out
}

struct Harness {
    daemon_tp: IrohTransport,
    client_tp: IrohTransport,
    client_blobs: Blobs,
}

impl Harness {
    async fn call(&self, method: &str, params: serde_json::Value) -> Resp {
        let mut stream = self
            .client_tp
            .connect(self.daemon_tp.node_id(), "ppf/ctrl/1")
            .await
            .unwrap();
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
}

async fn harness(dir: &Path, db: Db) -> Harness {
    let daemon_tp = endpoint().await;
    let blobs = Arc::new(
        Blobs::open(&daemon_tp, &dir.join("daemon-blobs"))
            .await
            .unwrap(),
    );
    blobs.attach_to_listener();
    let query = QueryEngine::new(db.clone(), blobs, dir.join("library"));
    let router = Router::new(db.clone(), "storage").with_query(query);
    let tp2 = daemon_tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });

    let client_tp = endpoint().await;
    client_tp.add_peer(daemon_tp.local_addr());
    let client_blobs = Blobs::open(&client_tp, &dir.join("client-blobs"))
        .await
        .unwrap();
    db.upsert_device(&Device {
        node_id: client_tp.node_id().0.to_vec(),
        name: "viewer".into(),
        role: Role::Viewer, // browse is exactly the viewer's power
        paired_at: 1,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();
    Harness {
        daemon_tp,
        client_tp,
        client_blobs,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn browse_500_assets_paginate_thumbs_and_originals() {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let seeded = seed_library(dir.path(), &db, 500).await;
    let h = harness(dir.path(), db).await;

    // 1) Pagination: walk with limit 37 (uneven on purpose) — no gaps,
    //    no repeats, exact total.
    let mut seen = HashSet::new();
    let mut cursor: Option<String> = None;
    loop {
        let q = TimelineQuery { cursor, limit: 37 };
        let resp = h
            .call("timeline.page", serde_json::to_value(&q).unwrap())
            .await;
        assert!(resp.ok, "timeline.page must work for a viewer: {resp:?}");
        let page: proto::TimelinePage = serde_json::from_value(resp.result.unwrap()).unwrap();
        for item in &page.items {
            assert!(
                seen.insert(item.hash.clone()),
                "repeat in pagination: {}",
                item.hash
            );
            assert_eq!(item.media_type, "photo");
        }
        match page.next {
            Some(c) => cursor = Some(c),
            None => break,
        }
    }
    assert_eq!(
        seen.len(),
        500,
        "pagination must cover every asset exactly once"
    );

    // 2) Thumbnails: every 256px thumb decodes as a real JPEG.
    use base64::Engine as _;
    for hash_hex in seen.iter() {
        let t = ThumbGet {
            hash: hash_hex.clone(),
            size: ThumbSize::S256,
        };
        let resp = h.call("thumb.get", serde_json::to_value(&t).unwrap()).await;
        assert!(resp.ok, "thumb.get failed for {hash_hex}");
        let data: ThumbData = serde_json::from_value(resp.result.unwrap()).unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&data.jpeg_base64)
            .unwrap();
        let img = image::load_from_memory_with_format(&bytes, image::ImageFormat::Jpeg)
            .unwrap_or_else(|e| panic!("thumb for {hash_hex} must be valid JPEG: {e}"));
        assert!(img.width().max(img.height()) <= 256);
    }

    // 3) Originals: sample 3, get tickets, pull over blobs, verify hash.
    for (hash, content) in seeded.iter().step_by(199).take(3) {
        let hash_hex: String = hash.iter().map(|b| format!("{b:02x}")).collect();
        let resp = h
            .call("asset.blob_ticket", serde_json::json!({ "hash": hash_hex }))
            .await;
        assert!(resp.ok, "blob_ticket failed: {resp:?}");
        let ticket: proto::BlobTicketResponse =
            serde_json::from_value(resp.result.unwrap()).unwrap();
        let dest = dir.path().join(format!("pulled-{hash_hex}.jpg"));
        let got = h.client_blobs.pull(&ticket.ticket, &dest).await.unwrap();
        assert_eq!(&got, hash, "pulled original must verify");
        assert_eq!(&fs::read(&dest).unwrap(), content, "bit-identical original");
    }
}

/// The 5 s thumb budget: an unknown hash answers the placeholder JPEG
/// immediately, never an error and never a hang.
#[tokio::test(flavor = "multi_thread")]
async fn unknown_thumb_answers_placeholder() {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let h = harness(dir.path(), db).await;

    let t = ThumbGet {
        hash: "ff".repeat(32),
        size: ThumbSize::S256,
    };
    let resp = h.call("thumb.get", serde_json::to_value(&t).unwrap()).await;
    assert!(resp.ok);
    use base64::Engine as _;
    let data: ThumbData = serde_json::from_value(resp.result.unwrap()).unwrap();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&data.jpeg_base64)
        .unwrap();
    let img = image::load_from_memory_with_format(&bytes, image::ImageFormat::Jpeg).unwrap();
    assert_eq!(
        (img.width(), img.height()),
        (256, 256),
        "the built-in placeholder"
    );
}
