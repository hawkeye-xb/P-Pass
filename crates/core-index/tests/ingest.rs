//! T-011 acceptance: ingest lands files, dedups by content, audits, and
//! reports errors that name the failing path.

use std::fs;
use std::path::Path;

use core_index::{IncomingFile, IngestOutcome, Ingestor};
use storage::Db;
use time::{Date, Month, PrimitiveDateTime, Time};

const DEV_A: [u8; 32] = [0xaa; 32];
// Full NodeId as hex (§4.2 <deviceId>) — rebuild (T-012) must recover the
// complete 32-byte src_device from the directory name alone (ADR-006).
const DEV_DIR_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

mod common;
use common::jpeg_with_exif;

fn incoming(dir: &Path, name: &str, content: &[u8]) -> IncomingFile {
    let src = dir.join(format!("staging-{}", name.replace(['/', '\\'], "_")));
    fs::write(&src, content).unwrap();
    IncomingFile {
        src_path: src,
        file_name: name.into(),
        media_type: "image/jpeg".into(),
        src_device: DEV_A.to_vec(),
    }
}

async fn setup() -> (tempfile::TempDir, Db, Ingestor) {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let ing = Ingestor::new(db.clone(), dir.path().join("library"));
    (dir, db, ing)
}

#[tokio::test]
async fn new_file_lands_moved_and_indexed() {
    let (dir, db, ing) = setup().await;
    let content = jpeg_with_exif("2024:05:06 07:08:09");
    let f = incoming(dir.path(), "IMG_1.jpg", &content);

    let outcome = ing.ingest(&f).await.unwrap();
    let IngestOutcome::New(rel) = outcome else {
        panic!("expected New, got {outcome:?}");
    };
    assert_eq!(rel, format!("originals/{DEV_DIR_A}/2024/05/IMG_1.jpg"));

    // Moved, not copied — staging file is gone, library file is identical.
    assert!(!f.src_path.exists(), "source must be moved away");
    let landed = fs::read(dir.path().join("library").join(&rel)).unwrap();
    assert_eq!(landed, content);

    let hash = blake3_of(&content);
    let asset = db.get_asset(&hash).await.unwrap().expect("indexed");
    assert_eq!(asset.rel_path, rel);
    assert_eq!(asset.bytes, content.len() as i64);
    assert_eq!(asset.thumb_state, 0, "thumbs are pending until T-013");
    assert_eq!(asset.src_device, DEV_A.to_vec());
}

#[tokio::test]
async fn exif_datetime_original_becomes_taken_at() {
    let (dir, db, ing) = setup().await;
    let content = jpeg_with_exif("2024:05:06 07:08:09");
    let f = incoming(dir.path(), "IMG_2.jpg", &content);
    ing.ingest(&f).await.unwrap();

    let expected = PrimitiveDateTime::new(
        Date::from_calendar_date(2024, Month::May, 6).unwrap(),
        Time::from_hms(7, 8, 9).unwrap(),
    )
    .assume_utc()
    .unix_timestamp()
        * 1000;
    let asset = db.get_asset(&blake3_of(&content)).await.unwrap().unwrap();
    assert_eq!(asset.taken_at, Some(expected), "EXIF wins over mtime");
}

#[tokio::test]
async fn no_exif_falls_back_to_mtime() {
    let (dir, db, ing) = setup().await;
    let content = b"plain bytes, no exif".to_vec();
    let f = incoming(dir.path(), "note.bin", &content);
    let mtime = fs::metadata(&f.src_path).unwrap().modified().unwrap();
    let mtime_ms = mtime
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;

    ing.ingest(&f).await.unwrap();
    let asset = db.get_asset(&blake3_of(&content)).await.unwrap().unwrap();
    assert_eq!(asset.taken_at, Some(mtime_ms));
}

#[tokio::test]
async fn same_content_different_name_is_duplicate_and_leaves_source() {
    let (dir, db, ing) = setup().await;
    let content = jpeg_with_exif("2023:01:02 03:04:05");
    let f1 = incoming(dir.path(), "a.jpg", &content);
    let f2 = incoming(dir.path(), "totally-different-name.jpg", &content);

    assert!(matches!(
        ing.ingest(&f1).await.unwrap(),
        IngestOutcome::New(_)
    ));
    assert_eq!(ing.ingest(&f2).await.unwrap(), IngestOutcome::Duplicate);

    // Duplicate writes nothing and leaves the caller's file alone.
    assert!(f2.src_path.exists(), "duplicate source must be untouched");
    let page = core_index::timeline_page(&db, None, 100).await.unwrap();
    assert_eq!(page.assets.len(), 1, "one content, one row");
}

#[tokio::test]
async fn name_conflicts_get_dash_suffixes() {
    let (dir, _db, ing) = setup().await;
    // Three different contents, same file name, no EXIF (all land in the
    // mtime month — the same directory).
    let mut rels = Vec::new();
    for n in 0..3u8 {
        let f = incoming(dir.path(), &format!("v{n}/IMG_9.jpg"), &[n; 100]);
        let IngestOutcome::New(rel) = ing.ingest(&f).await.unwrap() else {
            panic!("distinct contents must all be New");
        };
        rels.push(rel);
    }
    let names: Vec<&str> = rels.iter().map(|r| r.rsplit('/').next().unwrap()).collect();
    assert_eq!(names, ["IMG_9.jpg", "IMG_9-1.jpg", "IMG_9-2.jpg"]);
}

#[tokio::test]
async fn ingest_is_audited_to_device_granularity() {
    let (dir, db, ing) = setup().await;
    let content = b"audited content".to_vec();
    ing.ingest(&incoming(dir.path(), "x.jpg", &content))
        .await
        .unwrap();
    ing.ingest(&incoming(dir.path(), "y.jpg", &content))
        .await
        .unwrap();

    let log = db.list_audit(10).await.unwrap();
    let actions: Vec<&str> = log.iter().map(|r| r.entry.action.as_str()).collect();
    assert!(actions.contains(&"ingest.new"), "got {actions:?}");
    assert!(actions.contains(&"ingest.duplicate"), "got {actions:?}");
    for r in &log {
        assert_eq!(
            r.entry.actor,
            Some(DEV_A.to_vec()),
            "product-path ops are attributed to the device"
        );
        assert_eq!(r.entry.target_hash, Some(blake3_of(&content).to_vec()));
    }
}

#[tokio::test]
async fn missing_source_error_names_the_path() {
    let (dir, _db, ing) = setup().await;
    let f = IncomingFile {
        src_path: dir.path().join("does-not-exist.jpg"),
        file_name: "does-not-exist.jpg".into(),
        media_type: "image/jpeg".into(),
        src_device: DEV_A.to_vec(),
    };
    let msg = ing.ingest(&f).await.unwrap_err().to_string();
    assert!(
        msg.contains("does-not-exist.jpg"),
        "human-readable error must name the file: {msg}"
    );
}

#[tokio::test]
async fn traversal_file_name_cannot_escape_library() {
    let (dir, _db, ing) = setup().await;
    let f = incoming(dir.path(), "../../escape.jpg", b"traversal attempt");
    let IngestOutcome::New(rel) = ing.ingest(&f).await.unwrap() else {
        panic!("expected New");
    };
    assert!(
        rel.ends_with("/escape.jpg") && !rel.contains(".."),
        "sanitized rel_path: {rel}"
    );
    assert!(dir.path().join("library").join(&rel).exists());
}

fn blake3_of(content: &[u8]) -> [u8; 32] {
    *blake3::hash(content).as_bytes()
}
