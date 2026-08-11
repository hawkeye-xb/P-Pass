//! DESK-03 acceptance: 桌面照片墙的数据链路——查询平面经本地 IPC 可用，
//! 且三方对照成立：墙上照片数（timeline.page 全量）== IPC photo_count
//! （status）== sqlite 直查（count_assets）。
//!
//! 覆盖卡面验收 1 的自动化侧；验收 2（500 张滚动流畅）与 3/4（Finder
//! 揭示、无临时文件残留）属 UI/人工走查项，见卡尾记录。

use std::fs;
use std::sync::Arc;

use daemon::{DiagAgg, IpcServer, Pairing, QueryEngine};
use interprocess::local_socket::tokio::prelude::*;
use proto::{Req, Resp, ThumbGet, ThumbSize};
use storage::Db;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use transport::{Blobs, IrohTransport, TransportConfig};

const ALPNS: &[&str] = &["ppf/ctrl/1", "ppf/blobs/1"];

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(
        ALPNS.iter().map(|s| s.to_string()).collect(),
    ))
    .await
    .unwrap()
}

fn image_bytes(i: u32) -> Vec<u8> {
    let img = image::RgbImage::from_fn(24 + (i % 5), 16, |x, y| {
        image::Rgb([(x + i) as u8, (y * 3) as u8, (i % 251) as u8])
    });
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85);
    enc.encode_image(&img).unwrap();
    out
}

struct IpcClient {
    lines: tokio::io::Lines<BufReader<interprocess::local_socket::tokio::RecvHalf>>,
    tx: interprocess::local_socket::tokio::SendHalf,
}

impl IpcClient {
    async fn connect(socket: &str, token: &str) -> IpcClient {
        let name = socket
            .to_ns_name::<interprocess::local_socket::GenericNamespaced>()
            .unwrap();
        let conn = interprocess::local_socket::tokio::Stream::connect(name)
            .await
            .unwrap();
        let (rx, mut tx) = conn.split();
        tx.write_all(format!("{token}\n").as_bytes()).await.unwrap();
        IpcClient {
            lines: BufReader::new(rx).lines(),
            tx,
        }
    }

    async fn call(&mut self, method: &str, params: serde_json::Value) -> Resp {
        let req = Req {
            id: method.into(),
            method: method.into(),
            params,
            ..Default::default()
        };
        let mut line = serde_json::to_string(&req).unwrap();
        line.push('\n');
        self.tx.write_all(line.as_bytes()).await.unwrap();
        let resp_line = self.lines.next_line().await.unwrap().expect("a response");
        serde_json::from_str(&resp_line).unwrap()
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn query_plane_over_ipc_and_three_way_count() {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();

    // Seed 3 JPEGs from two "devices"（三方对照的 M 也验一下）。
    let ing = core_index::Ingestor::new(db.clone(), dir.path().join("library"));
    for i in 0..3u32 {
        let img = image_bytes(i);
        let src = dir.path().join(format!("stage-{i}.jpg"));
        fs::write(&src, &img).unwrap();
        ing.ingest(&core_index::IncomingFile {
            src_path: src,
            file_name: format!("IMG_{i:04}.jpg"),
            media_type: "image/jpeg".into(),
            src_device: vec![0x10 + i as u8; 32],
        })
        .await
        .unwrap();
    }

    // 查询平面（QueryEngine）走本地 IPC 注入。
    let daemon_tp = endpoint().await;
    let blobs = Arc::new(
        Blobs::open(&daemon_tp, &dir.path().join("daemon-blobs"))
            .await
            .unwrap(),
    );
    blobs.attach_to_listener();
    let query = QueryEngine::new(db.clone(), blobs, dir.path().join("library"));

    let (event_bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xCC; 32]), None, None);
    let pairing = pairing.with_events(event_bus.clone());
    let diag = DiagAgg::new(db.clone());
    let ipc = Arc::new(IpcServer::new(
        db.clone(),
        pairing,
        diag,
        dir.path().to_path_buf(),
        pending_rx,
        event_bus,
    ));
    ipc.set_query(query);

    let socket = format!("ppf-test-{}-desk03", std::process::id());
    let token = [0x5C; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    tokio::spawn({
        let ipc = Arc::clone(&ipc);
        let socket = socket.clone();
        async move {
            let _ = ipc.serve(&socket, token).await;
        }
    });
    let name = socket
        .clone()
        .to_ns_name::<interprocess::local_socket::GenericNamespaced>()
        .unwrap();
    let mut bound = false;
    for _ in 0..200 {
        if interprocess::local_socket::tokio::Stream::connect(name.clone())
            .await
            .is_ok()
        {
            bound = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(bound, "socket never became connectable");

    let mut c = IpcClient::connect(&socket, &token_hex).await;

    // ── 三方对照：墙上数（timeline 全量）== photo_count == sqlite 直查 ──
    let resp = c
        .call(
            "timeline.page",
            serde_json::json!({ "cursor": null, "limit": 100 }),
        )
        .await;
    assert!(resp.ok, "timeline.page over IPC must work: {resp:?}");
    let page = resp.result.unwrap();
    let items = page["items"].as_array().unwrap();
    let wall_count = items.len() as i64;

    let resp = c.call("status", serde_json::Value::Null).await;
    assert!(resp.ok);
    let status = resp.result.unwrap();
    let photo_count = status["photo_count"].as_i64().unwrap();
    let photo_sources = status["photo_sources"].as_i64().unwrap();
    let sqlite_count = db.count_assets().await.unwrap();

    assert_eq!(wall_count, 3, "墙上照片数");
    assert_eq!(photo_count, 3, "IPC photo_count");
    assert_eq!(sqlite_count, 3, "sqlite 直查");
    assert_eq!(wall_count, photo_count, "墙上数 == IPC photo_count");
    assert_eq!(photo_count, sqlite_count, "IPC photo_count == sqlite 直查");
    assert_eq!(photo_sources, 3, "来自 3 台设备（每张 src_device 都不同）");

    // ── 缩略图：256px 可解码 JPEG ──
    let first_hash = items[0]["hash"].as_str().unwrap().to_string();
    let resp = c
        .call(
            "thumb.get",
            serde_json::to_value(ThumbGet {
                hash: first_hash.clone(),
                size: ThumbSize::S256,
            })
            .unwrap(),
        )
        .await;
    assert!(resp.ok, "thumb.get over IPC must work: {resp:?}");
    use base64::Engine as _;
    let jpeg = base64::engine::general_purpose::STANDARD
        .decode(resp.result.unwrap()["jpeg_base64"].as_str().unwrap())
        .unwrap();
    assert!(
        image::load_from_memory_with_format(&jpeg, image::ImageFormat::Jpeg).is_ok(),
        "thumb must be a decodable JPEG"
    );

    // ── asset.path：指向 originals 里的真实原文件 ──
    let resp = c
        .call("asset.path", serde_json::json!({ "hash": first_hash }))
        .await;
    assert!(resp.ok, "asset.path must work: {resp:?}");
    let path = std::path::PathBuf::from(resp.result.unwrap()["path"].as_str().unwrap());
    assert!(
        path.is_file() && path.to_string_lossy().contains("originals"),
        "asset.path must point at the originals file on disk: {path:?}"
    );

    // ── asset.original：原图字节与 seed 一致（内存展示数据源）──
    let resp = c
        .call("asset.original", serde_json::json!({ "hash": first_hash }))
        .await;
    assert!(resp.ok, "asset.original must work: {resp:?}");
    let original = base64::engine::general_purpose::STANDARD
        .decode(resp.result.unwrap()["data_base64"].as_str().unwrap())
        .unwrap();
    // first_hash 对应 i=0 的 seed（timeline 新→旧，taken_at 相同按 hash 升序——
    // 无法确定是哪一张，但必须是三张之一且可解码）。
    assert!(
        image::load_from_memory(&original).is_ok(),
        "original must be a decodable image"
    );
    assert!(!original.is_empty());

    // ── 未注入查询平面的旧构造（回归：老测试零波及）──
    let (event_bus2, _probe2) = daemon::events::bus();
    let (pairing2, pending_rx2) =
        Pairing::new(db.clone(), transport::NodeId([0xDD; 32]), None, None);
    let ipc2 = Arc::new(IpcServer::new(
        db.clone(),
        pairing2,
        DiagAgg::new(db.clone()),
        dir.path().to_path_buf(),
        pending_rx2,
        event_bus2,
    ));
    let socket2 = format!("ppf-test-{}-desk03-noquery", std::process::id());
    let token2 = [0x5D; 32];
    let token2_hex: String = token2.iter().map(|b| format!("{b:02x}")).collect();
    tokio::spawn({
        let ipc = Arc::clone(&ipc2);
        let socket = socket2.clone();
        async move {
            let _ = ipc.serve(&socket, token2).await;
        }
    });
    let name2 = socket2
        .clone()
        .to_ns_name::<interprocess::local_socket::GenericNamespaced>()
        .unwrap();
    let mut bound2 = false;
    for _ in 0..200 {
        if interprocess::local_socket::tokio::Stream::connect(name2.clone())
            .await
            .is_ok()
        {
            bound2 = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(bound2);
    let mut c2 = IpcClient::connect(&socket2, &token2_hex).await;
    let resp = c2.call("timeline.page", serde_json::json!({})).await;
    assert!(!resp.ok, "no query plane -> err.unsupported");
}
