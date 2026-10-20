//! #1054：`QueryEngine::original()` 的格式分流——所有静态图片（含 HEIC/RAW/
//! TIFF）都返回原图并带真实 MIME，能不能解码交给渲染端，解不了由壳回退缩略图；
//! 视频一律 NotFound。daemon 不维护「浏览器能显示哪些格式」的白名单。

use std::sync::Arc;

use daemon::QueryEngine;
use transport::{Blobs, IrohTransport, TransportConfig};

async fn engine_with(
    root: &std::path::Path,
    file_name: &str,
    media_type: &str,
    bytes: &[u8],
) -> (QueryEngine, [u8; 32]) {
    let db = storage::Db::open_in_memory().await.unwrap();
    let library_root = root.join("library");
    let ing = core_index::Ingestor::new(db.clone(), library_root.clone());
    let src = root.join("stage.bin");
    std::fs::write(&src, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    ing.ingest(&core_index::IncomingFile {
        src_path: src,
        file_name: file_name.into(),
        media_type: media_type.into(),
        src_device: vec![9u8; 32],
        capture_at_ms_hint: None,
    })
    .await
    .unwrap();
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

#[tokio::test(flavor = "multi_thread")]
async fn original_serves_every_still_image_with_its_real_mime() {
    // (文件名, 入库 MIME, 是否应返回原图)
    let cases: &[(&str, &str, bool)] = &[
        ("a.jpg", "image/jpeg", true),
        ("a.png", "image/png", true),
        ("a.gif", "image/gif", true),
        ("a.webp", "image/webp", true),
        ("a.heic", "image/heic", true),
        ("a.heif", "image/heif", true),
        ("a.dng", "image/x-adobe-dng", true),
        ("a.cr2", "image/x-canon-cr2", true),
        ("a.tif", "image/tiff", true),
        ("a.mp4", "video/mp4", false),
    ];
    for (i, (name, mime, served)) in cases.iter().enumerate() {
        let root = tempfile::tempdir().unwrap();
        // 内容各不相同（不同 hash），内容本身与分流无关。
        let body = format!("fake-{i}-{name}").into_bytes();
        let (q, hash) = engine_with(root.path(), name, mime, &body).await;
        let got = q.original(&hex::encode(hash)).await;
        if *served {
            let (media_type, bytes) = got.unwrap_or_else(|e| panic!("{mime} 应返回原图: {e:?}"));
            assert_eq!(&media_type, mime, "返回的 media_type 必须是真实 MIME");
            assert_eq!(bytes, body);
        } else {
            assert!(got.is_err(), "{mime} 不应返回原图字节");
        }
    }
}
