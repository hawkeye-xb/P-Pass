//! TEL-04 / #949: `QueryEngine::original()` (and, by the same
//! `record_first_byte` helper, `thumb()`) writes one local `first_byte`
//! stats line per successful request — into the daemon log, never the
//! network. Only `original()` is exercised here — it does not depend on
//! media-codec's thumbnail generation, keeping the fixture to a single real
//! ingested JPEG.

use std::io::Write;
use std::sync::{Arc, Mutex};

use daemon::QueryEngine;
use transport::{Blobs, IrohTransport, TransportConfig};

/// In-memory log sink for a thread-local test subscriber.
#[derive(Clone, Default)]
struct Capture(Arc<Mutex<Vec<u8>>>);

impl Write for Capture {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Capture {
    type Writer = Capture;
    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

impl Capture {
    /// Stats lines captured so far (target `ppf::stats` only).
    fn stats_lines(&self) -> Vec<String> {
        String::from_utf8(self.0.lock().unwrap().clone())
            .unwrap()
            .lines()
            .filter(|l| l.contains(daemon::stats::TARGET))
            .map(str::to_string)
            .collect()
    }
}

/// A multi-thread runtime whose every worker / blocking thread (and the
/// calling thread) logs into `cap` through the daemon's production default
/// filter. Ingest uses `block_in_place`, so a current-thread runtime is not
/// an option; a thread-local default per runtime thread keeps parallel tests
/// in this binary from seeing each other's lines (a global subscriber would
/// mix them).
fn captured_runtime(cap: &Capture) -> (tokio::runtime::Runtime, tracing::subscriber::DefaultGuard) {
    let dispatch = tracing::Dispatch::new(
        tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::new(format!(
                "info,{}",
                transport::QUIET_LOG_DIRECTIVES
            )))
            .with_ansi(false)
            .with_writer(cap.clone())
            .finish(),
    );
    let for_threads = dispatch.clone();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .on_thread_start(move || {
            // The guard lives as long as the runtime thread itself.
            std::mem::forget(tracing::dispatcher::set_default(&for_threads));
        })
        .build()
        .unwrap();
    let guard = tracing::dispatcher::set_default(&dispatch);
    (rt, guard)
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

async fn seeded_query(root: &std::path::Path) -> (QueryEngine, [u8; 32]) {
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
    (QueryEngine::new(db, blobs, library_root), hash)
}

#[test]
fn original_logs_one_first_byte_stats_line_on_success() {
    let cap = Capture::default();
    let (rt, _guard) = captured_runtime(&cap);
    rt.block_on(original_logs_one_first_byte_stats_line_on_success_body(
        &cap,
    ));
}

async fn original_logs_one_first_byte_stats_line_on_success_body(cap: &Capture) {
    let root = tempfile::tempdir().unwrap();
    let (query, hash) = seeded_query(root.path()).await;
    let bytes = query
        .original(&hex::encode(hash))
        .await
        .expect("seeded asset must be readable");
    assert!(!bytes.is_empty());

    let lines = cap.stats_lines();
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].contains("event=\"first_byte\""), "{}", lines[0]);
    assert!(lines[0].contains("kind=\"blob\""), "{}", lines[0]);
    assert!(lines[0].contains(" ms="), "{}", lines[0]);
}

#[test]
fn not_found_asset_never_logs_a_first_byte_line() {
    let cap = Capture::default();
    let (rt, _guard) = captured_runtime(&cap);
    rt.block_on(not_found_asset_never_logs_a_first_byte_line_body(&cap));
}

async fn not_found_asset_never_logs_a_first_byte_line_body(cap: &Capture) {
    let root = tempfile::tempdir().unwrap();
    let (query, _hash) = seeded_query(root.path()).await;
    let missing = [0x42u8; 32];
    assert!(query.original(&hex::encode(missing)).await.is_err());

    assert!(
        cap.stats_lines().is_empty(),
        "a request that never delivers bytes must not claim a first byte: {:?}",
        cap.stats_lines()
    );
}
