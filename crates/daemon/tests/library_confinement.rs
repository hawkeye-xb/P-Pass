//! #1150：读库内文件前限定在库根内。索引里记录的路径含 `..`、是绝对路径、或经符号链接
//! 指到库外时，`original` / `asset_path` / `blob_ticket` / 缩略图生成都不得打开它。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use daemon::query::{QueryEngine, QueryError};
use proto::{ThumbGet, ThumbSize};
use transport::{Blobs, IrohTransport, TransportConfig};

fn jpeg() -> Vec<u8> {
    let img = image::RgbImage::from_fn(24, 16, |x, y| image::Rgb([x as u8, y as u8, 7]));
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85)
        .encode_image(&img)
        .unwrap();
    out
}

struct Fixture {
    q: QueryEngine,
    db: storage::Db,
    hash: [u8; 32],
    root: PathBuf,
    outside: PathBuf,
}

/// 库里入一张真图；再在库外放一份**另一张**真图 `outside.jpg`，用来分辨「读到了谁」。
async fn fixture(base: &Path) -> Fixture {
    let db = storage::Db::open_in_memory().await.unwrap();
    let root = base.join("library");
    let bytes = jpeg();
    let src = base.join("stage.bin");
    std::fs::write(&src, &bytes).unwrap();
    core_index::Ingestor::new(db.clone(), root.clone())
        .ingest(&core_index::IncomingFile {
            src_path: src,
            file_name: "a.jpg".into(),
            media_type: "image/jpeg".into(),
            src_device: vec![9u8; 32],
            capture_at_ms_hint: None,
        })
        .await
        .unwrap();
    let outside = base.join("outside.jpg");
    // 真图：若被读到，缩略图会生成成功（非占位），原图也会返回字节。
    let mut other = jpeg();
    other.push(0);
    std::fs::write(&outside, other).unwrap();
    let transport = IrohTransport::bind(TransportConfig::loopback(vec!["ppf/blobs/1".into()]))
        .await
        .unwrap();
    let blobs = Arc::new(
        Blobs::open(&transport, &base.join("blobs-store"))
            .await
            .unwrap(),
    );
    Fixture {
        q: QueryEngine::new(db.clone(), blobs, root.clone()),
        db,
        hash: *blake3::hash(&bytes).as_bytes(),
        root,
        outside,
    }
}

async fn assert_all_refused(f: &Fixture, why: &str) {
    let h = hex::encode(f.hash);
    assert!(
        matches!(f.q.original(&h).await, Err(QueryError::NotFound)),
        "original：{why}"
    );
    assert!(
        matches!(f.q.asset_path(&h).await, Err(QueryError::NotFound)),
        "asset_path：{why}"
    );
    assert!(
        matches!(f.q.blob_ticket(&h).await, Err(QueryError::NotFound)),
        "blob_ticket：{why}"
    );
    let t =
        f.q.thumb_reply(&ThumbGet {
            hash: h,
            size: ThumbSize::S256,
        })
        .await
        .unwrap();
    assert!(t.placeholder, "thumb：{why}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_recorded_path_inside_the_library_still_works() {
    let base = tempfile::tempdir().unwrap();
    let f = fixture(base.path()).await;
    let h = hex::encode(f.hash);
    assert!(f.q.original(&h).await.is_ok());
    assert!(f
        .q
        .asset_path(&h)
        .await
        .unwrap()
        .starts_with(f.root.canonicalize().unwrap()));
    assert!(f.q.blob_ticket(&h).await.is_ok());
}

/// 反证：`QueryEngine` 退回 `library_root.join(rel_path)` 直接读，下面三条全红。
#[tokio::test(flavor = "multi_thread")]
async fn dot_dot_in_the_recorded_path_is_refused() {
    let base = tempfile::tempdir().unwrap();
    let f = fixture(base.path()).await;
    f.db.update_asset_rel_path(&f.hash, "../outside.jpg")
        .await
        .unwrap();
    assert_all_refused(&f, "..").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_absolute_recorded_path_is_refused() {
    let base = tempfile::tempdir().unwrap();
    let f = fixture(base.path()).await;
    f.db.update_asset_rel_path(&f.hash, f.outside.to_str().unwrap())
        .await
        .unwrap();
    assert_all_refused(&f, "绝对路径").await;
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn a_symlink_leaving_the_library_is_refused() {
    let base = tempfile::tempdir().unwrap();
    let f = fixture(base.path()).await;
    let link = f.root.join("originals/evil.jpg");
    std::os::unix::fs::symlink(&f.outside, &link).unwrap();
    f.db.update_asset_rel_path(&f.hash, "originals/evil.jpg")
        .await
        .unwrap();
    assert_all_refused(&f, "符号链接").await;
}
