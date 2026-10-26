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

/// 造文件符号链接；没特权（Windows 无开发者模式）就跳过并说明，其他失败判红。
fn link_or_skip(target: &Path, link: &Path) -> bool {
    match platform::test_support::file_symlink(target, link) {
        Ok(()) => true,
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            eprintln!("跳过：没有建符号链接的权限（{e}）");
            false
        }
        Err(e) => panic!("建符号链接失败：{e}"),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_symlink_leaving_the_library_is_refused() {
    let base = tempfile::tempdir().unwrap();
    let f = fixture(base.path()).await;
    let link = f.root.join("originals/evil.jpg");
    if !link_or_skip(&f.outside, &link) {
        return;
    }
    f.db.update_asset_rel_path(&f.hash, "originals/evil.jpg")
        .await
        .unwrap();
    assert_all_refused(&f, "符号链接").await;
}

/// 解析函数本身：目录符号链接、悬空链接、库根是链接。
#[test]
fn resolver_handles_directory_dangling_and_root_links() {
    let base = tempfile::tempdir().unwrap();
    let root = base.path().join("lib");
    std::fs::create_dir_all(root.join("originals/d")).unwrap();
    std::fs::write(root.join("originals/d/a.jpg"), b"x").unwrap();
    let outside = base.path().join("out");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("secret.jpg"), b"s").unwrap();

    // 库根自己是链接：仍可用。库根是目录，要用目录链接（Windows 上文件符号链接指向目录无法穿越）。
    for kind in platform::test_support::dir_link_kinds() {
        let root_link = base.path().join(format!("root-link-{}", kind.name));
        match kind.make(&root, &root_link) {
            Ok(()) => assert!(
                core_index::resolve_in_library(&root_link, "originals/d/a.jpg").is_ok(),
                "库根是 {} 时应可解析",
                kind.name
            ),
            Err(e)
                if kind.may_need_privilege && e.kind() == std::io::ErrorKind::PermissionDenied =>
            {
                eprintln!("跳过 {}：没有建链接的权限（{e}）", kind.name);
            }
            Err(e) => panic!("建 {} 失败：{e}", kind.name),
        }
    }
    // 悬空链接：连「缺失宽容」版本也拒绝。
    let dangle = root.join("originals/d/dangle.jpg");
    if link_or_skip(&base.path().join("not-yet.jpg"), &dangle) {
        assert!(core_index::resolve_in_library(&root, "originals/d/dangle.jpg").is_err());
        assert!(
            core_index::resolve_in_library_or_missing(&root, "originals/d/dangle.jpg").is_err()
        );
    }
    // 链到库外文件。
    let link = root.join("originals/d/out.jpg");
    if link_or_skip(&outside.join("secret.jpg"), &link) {
        assert_eq!(
            core_index::resolve_in_library(&root, "originals/d/out.jpg"),
            Err(core_index::ConfineError::Escapes)
        );
    }
}
