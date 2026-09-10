//! TEL-04 acceptance: `QueryEngine::original()` (and, by the same
//! `record_first_byte` helper, `thumb()`) record one anonymized
//! `first_byte` event per successful request. Only `original()` is
//! exercised here — it does not depend on media-codec's thumbnail
//! generation, keeping the fixture to a single real ingested JPEG.

use std::sync::Arc;

use daemon::{QueryEngine, Telemetry};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use transport::{Blobs, IrohTransport, TransportConfig};

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

/// A real, tiny, decodable JPEG (media type must be image/* and under the
/// 12 MiB original cap; content does not matter beyond that).
fn tiny_jpeg() -> Vec<u8> {
    let img = image::RgbImage::from_fn(8, 8, |x, y| image::Rgb([x as u8, y as u8, 0]));
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85);
    enc.encode_image(&img).unwrap();
    out
}

async fn seeded_query(root: &std::path::Path, telemetry: Telemetry) -> (QueryEngine, [u8; 32]) {
    let db = storage::Db::open_in_memory().await.unwrap();
    let library_root = root.join("library");
    let ing = core_index::Ingestor::new(db.clone(), library_root.clone());
    let bytes = tiny_jpeg();
    let src = root.join("stage.jpg");
    std::fs::write(&src, &bytes).unwrap();
    let hash = *blake3::hash(&bytes).as_bytes();
    ing.ingest(&core_index::IncomingFile {
        src_path: src,
        file_name: "IMG_0001.jpg".into(),
        media_type: "image/jpeg".into(),
        src_device: vec![9u8; 32],
        capture_at_ms_hint: None,
    })
    .await
    .unwrap();

    // original() never touches blobs — a Blobs instance is only required
    // by QueryEngine::new's signature.
    let transport = IrohTransport::bind(TransportConfig::loopback(vec!["ppf/blobs/1".into()]))
        .await
        .unwrap();
    let blobs = Arc::new(
        Blobs::open(&transport, &root.join("blobs-store"))
            .await
            .unwrap(),
    );
    let query = QueryEngine::new(db, blobs, library_root).with_telemetry(telemetry);
    (query, hash)
}

#[tokio::test(flavor = "multi_thread")]
async fn original_records_one_first_byte_event_on_success() {
    let root = tempfile::tempdir().unwrap();
    let (telemetry_url, hits, bodies) = mock_telemetry_server().await;
    let telemetry_dir = tempfile::tempdir().unwrap();
    let telemetry = Telemetry::new(true, telemetry_url, telemetry_dir.path());
    let (query, hash) = seeded_query(root.path(), telemetry.clone()).await;

    let bytes = query
        .original(&hex::encode(hash))
        .await
        .expect("seeded asset must be readable");
    assert!(!bytes.is_empty());

    assert_eq!(telemetry.flush_now().await, 1);
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
    let batch = bodies.lock().unwrap()[0].clone();
    let events = batch.as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["event"], "first_byte");
    assert_eq!(events[0]["kind"], "blob");
    assert!(events[0]["ms"].as_u64().is_some());
}

#[tokio::test(flavor = "multi_thread")]
async fn not_found_asset_never_emits_a_first_byte_event() {
    let root = tempfile::tempdir().unwrap();
    let (telemetry_url, hits, _bodies) = mock_telemetry_server().await;
    let telemetry_dir = tempfile::tempdir().unwrap();
    let telemetry = Telemetry::new(true, telemetry_url, telemetry_dir.path());
    let (query, _hash) = seeded_query(root.path(), telemetry.clone()).await;

    let missing = [0x42u8; 32];
    assert!(query.original(&hex::encode(missing)).await.is_err());

    assert_eq!(
        telemetry.flush_now().await,
        0,
        "a request that never delivers bytes must not claim a first byte"
    );
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn disabled_telemetry_means_zero_network_calls_from_query_engine() {
    let root = tempfile::tempdir().unwrap();
    let (telemetry_url, hits, _bodies) = mock_telemetry_server().await;
    let telemetry_dir = tempfile::tempdir().unwrap();
    let telemetry = Telemetry::new(false, telemetry_url, telemetry_dir.path());
    let (query, hash) = seeded_query(root.path(), telemetry.clone()).await;

    query.original(&hex::encode(hash)).await.unwrap();

    assert_eq!(telemetry.flush_now().await, 0);
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert_eq!(
        hits.load(std::sync::atomic::Ordering::SeqCst),
        0,
        "disabled telemetry must mean ZERO network calls even through QueryEngine"
    );
}
