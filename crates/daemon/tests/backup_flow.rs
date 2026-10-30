//! T-032 acceptance: 500 mixed files end-to-end (asset count = deduped
//! count), interrupted commit re-runs to a consistent library, and the
//! final index survives the ADR-006 rebuild guard.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use daemon::{BackupEngine, Router};
use proto::{
    BackupCommit, BackupItem, BackupManifest, BackupMissing, BackupPresenceQuery, Req, Resp,
};
use storage::{Db, Pairing, Role};
use transport::{Blobs, IrohTransport, Transport, TransportConfig};

const ALPNS: &[&str] = &["ppf/ctrl/1", "ppf/blobs/1"];

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(
        ALPNS.iter().map(|s| s.to_string()).collect(),
    ))
    .await
    .unwrap()
}

struct StorageSide {
    tp: IrohTransport,
    blobs: std::sync::Arc<Blobs>,
    db: Db,
    backup: BackupEngine,
    #[allow(dead_code)]
    serve_task: tokio::task::JoinHandle<()>,
}

/// Spin up a daemon over `library_root` (db file lives beside it so a
/// "restart" reopens the same index).
async fn start_daemon(dir: &Path) -> StorageSide {
    let db = Db::open(&dir.join("index.sqlite")).await.unwrap();
    let tp = endpoint().await;
    let blobs = std::sync::Arc::new(Blobs::open(&tp, &dir.join("daemon-blobs")).await.unwrap());
    let backup = BackupEngine::new(db.clone(), blobs.clone(), dir.join("library"));
    let router = Router::new(db.clone(), "storage").with_backup(backup.clone());
    let tp2 = tp.clone();
    let serve_task = tokio::spawn(async move { router.serve(&tp2).await });
    StorageSide {
        tp,
        blobs,
        db,
        backup,
        serve_task,
    }
}

/// The "phone": serves its files over blobs and speaks ctrl.
struct Client {
    tp: IrohTransport,
    blobs: Blobs,
    daemon: transport::NodeId,
}

impl Client {
    async fn new(dir: &Path, storage: &StorageSide) -> Client {
        let tp = endpoint().await;
        tp.add_peer(storage.tp.local_addr());
        let mut blobs = Blobs::open(&tp, &dir.join("client-blobs")).await.unwrap();
        blobs.serve();
        Client {
            tp,
            blobs,
            daemon: storage.tp.node_id(),
        }
    }

    async fn call(&self, method: &str, params: serde_json::Value) -> Resp {
        let mut stream = self.tp.connect(self.daemon, "ppf/ctrl/1").await.unwrap();
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

    /// One full backup run over `files`; returns the missing count seen.
    async fn run_backup(&self, files: &HashMap<String, (Vec<u8>, BackupItem)>) -> usize {
        assert!(self.call("backup.begin", serde_json::Value::Null).await.ok);
        let manifest = BackupManifest {
            hashes: vec![],
            items: files.values().map(|(_, item)| item.clone()).collect(),
            provider: Some(self.tp.local_addr().to_string()),
        };
        let resp = self
            .call("backup.manifest", serde_json::to_value(&manifest).unwrap())
            .await;
        assert!(resp.ok, "manifest must succeed: {resp:?}");
        let missing: BackupMissing = serde_json::from_value(resp.result.unwrap()).unwrap();

        let resp = self
            .call(
                "backup.commit",
                serde_json::to_value(&BackupCommit {
                    generation: Some(42),
                })
                .unwrap(),
            )
            .await;
        assert!(resp.ok, "commit must succeed: {resp:?}");
        missing.hashes.len()
    }
}

/// Deterministic mixed corpus: `total` files, `dup_groups` of which share
/// content with another file (dedup must collapse them).
fn corpus(dir: &Path, total: u32, duplicate_every: u32) -> HashMap<String, (Vec<u8>, BackupItem)> {
    let mut files = HashMap::new();
    let mut s: u64 = 0x5EED_2026_0730_0032;
    let mut rng = move || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        s
    };
    for i in 0..total {
        // Every Nth file reuses the previous file's content (a duplicate
        // under a different name — the classic same-photo-two-albums).
        let content: Vec<u8> = if duplicate_every > 0 && i % duplicate_every == 0 && i > 0 {
            let prev = format!("f{:04}", i - 1);
            files
                .iter()
                .find_map(|(_, (c, item)): (&String, &(Vec<u8>, BackupItem))| {
                    (item.file_name.starts_with(&prev)).then(|| c.clone())
                })
                .unwrap()
        } else {
            let len = 64 + (rng() % 2048) as usize;
            let mut v = i.to_le_bytes().to_vec();
            while v.len() < len {
                v.extend_from_slice(&rng().to_le_bytes());
            }
            v
        };
        let hash_hex: String = blake3::hash(&content)
            .as_bytes()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let (name, mime) = if i % 3 == 0 {
            (format!("f{i:04}.mp4"), "video/mp4")
        } else {
            (format!("f{i:04}.jpg"), "image/jpeg")
        };
        let src = dir.join(&name);
        fs::write(&src, &content).unwrap();
        files.insert(
            hash_hex.clone(),
            (
                content,
                BackupItem {
                    hash: hash_hex,
                    file_name: name,
                    media_type: mime.into(),
                },
            ),
        );
    }
    files
}

async fn import_all(client: &Client, files: &HashMap<String, (Vec<u8>, BackupItem)>, dir: &Path) {
    for (hash_hex, (_, item)) in files {
        let mut hash = [0u8; 32];
        for (i, chunk) in hash_hex.as_bytes().as_chunks::<2>().0.iter().enumerate() {
            hash[i] = u8::from_str_radix(std::str::from_utf8(chunk).unwrap(), 16).unwrap();
        }
        client
            .blobs
            .import(hash, &dir.join(&item.file_name))
            .await
            .unwrap();
    }
}

async fn asset_count(db: &Db) -> usize {
    let mut count = 0;
    let mut cursor = None;
    loop {
        let page = db.timeline_page(cursor.as_deref(), 1000).await.unwrap();
        count += page.assets.len();
        match page.next_cursor {
            Some(c) => cursor = Some(c),
            None => break,
        }
    }
    count
}

#[tokio::test(flavor = "multi_thread")]
async fn backup_500_mixed_files_dedups_and_commits() {
    let dir = tempfile::tempdir().unwrap();
    let storage = start_daemon(dir.path()).await;
    let client = Client::new(dir.path(), &storage).await;
    // Paired as member — backup.* requires it (T-030 checkpoint).
    storage
        .db
        .accept_pairing(
            &client.tp.node_id().0,
            "phone",
            &member(&client.tp.node_id()),
        )
        .await
        .unwrap();

    let src_dir = dir.path().join("src");
    fs::create_dir_all(&src_dir).unwrap();
    // 500 named files, every 10th duplicating content → 450 unique.
    let files = corpus(&src_dir, 500, 10);
    let unique = files.len();
    assert!(unique < 500, "corpus must contain duplicate content");

    import_all(&client, &files, &src_dir).await;
    let missing = client.run_backup(&files).await;
    assert_eq!(missing, unique, "first run: everything unique is missing");

    assert_eq!(
        asset_count(&storage.db).await,
        unique,
        "asset count must equal the deduped count"
    );
    // Watermark advanced to the committed generation.
    assert_eq!(
        storage.db.get_watermark(PAIRING_ID).await.unwrap(),
        Some(42)
    );

    // Second run over the same corpus: nothing missing, nothing changes.
    let missing = client.run_backup(&files).await;
    assert_eq!(missing, 0, "second run must be a no-op");
    assert_eq!(asset_count(&storage.db).await, unique);
}

#[tokio::test(flavor = "multi_thread")]
async fn presence_returns_only_missing_hashes_without_changing_committed_backup_facts() {
    let dir = tempfile::tempdir().unwrap();
    let storage = start_daemon(dir.path()).await;
    let client = Client::new(dir.path(), &storage).await;
    storage
        .db
        .accept_pairing(
            &client.tp.node_id().0,
            "phone",
            &member(&client.tp.node_id()),
        )
        .await
        .unwrap();

    let src_dir = dir.path().join("src");
    fs::create_dir_all(&src_dir).unwrap();
    let files = corpus(&src_dir, 1, 0);
    import_all(&client, &files, &src_dir).await;
    client.run_backup(&files).await;
    let known = files.keys().next().unwrap().clone();
    let absent = "f".repeat(64);

    let resp = client
        .call(
            "backup.presence",
            serde_json::to_value(BackupPresenceQuery {
                hashes: vec![known, absent.clone()],
            })
            .unwrap(),
        )
        .await;
    assert!(resp.ok, "presence must be a member-only query: {resp:?}");
    let missing: BackupMissing = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(missing.hashes, vec![absent]);
    assert_eq!(asset_count(&storage.db).await, 1);
    assert_eq!(
        storage.db.get_watermark(PAIRING_ID).await.unwrap(),
        Some(42),
    );
    assert_eq!(
        storage.backup.sweep_sessions(std::time::Duration::ZERO),
        0,
        "presence must not create or touch a backup session",
    );
}

/// 业务规则 §4.4：`backup.presence` 每页 1–500 个 hash（字面量）；空页、501、含非法
/// hash 一律 BadRequest，500 个恰好通过。
/// 反证：`> 500` 改 `>= 500` → 500 那条红；去掉 `is_empty` 判断 → 空页那条红；
/// 去掉上限 → 501 那条红。
#[tokio::test(flavor = "multi_thread")]
async fn presence_accepts_one_to_five_hundred_valid_hashes_only() {
    let dir = tempfile::tempdir().unwrap();
    let storage = start_daemon(dir.path()).await;
    let client = Client::new(dir.path(), &storage).await;
    storage
        .db
        .accept_pairing(
            &client.tp.node_id().0,
            "phone",
            &member(&client.tp.node_id()),
        )
        .await
        .unwrap();

    let page = |n: usize| -> serde_json::Value {
        let hashes: Vec<String> = (0..n).map(|i| format!("{i:064x}")).collect();
        serde_json::to_value(BackupPresenceQuery { hashes }).unwrap()
    };

    let resp = client.call("backup.presence", page(500)).await;
    assert!(resp.ok, "恰好 500 个应通过: {resp:?}");
    let missing: BackupMissing = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(missing.hashes.len(), 500, "库里都没有 ⇒ 全部缺");

    let resp = client.call("backup.presence", page(1)).await;
    assert!(resp.ok, "1 个应通过: {resp:?}");

    for (what, params) in [
        ("空页", page(0)),
        ("501 个", page(501)),
        (
            "含非法 hash",
            serde_json::to_value(BackupPresenceQuery {
                hashes: vec!["f".repeat(64), "zz".into()],
            })
            .unwrap(),
        ),
    ] {
        let resp = client.call("backup.presence", params).await;
        assert!(!resp.ok, "{what}必须被拒");
        assert_eq!(
            resp.error.as_ref().unwrap().reason(),
            &proto::Reason::BadRequest,
            "{what}"
        );
    }
}

/// SYNC-02：一次 commit 里 5 个文件逐条 ingest，节流合并 + 收尾强制
/// flush 应该让订阅者恰好收到 1 次 `timeline.invalidated`（不是 5 次，
/// 也不必等节流窗口——commit 收尾就该立即发出）。
#[tokio::test(flavor = "multi_thread")]
async fn commit_batch_emits_timeline_invalidated_exactly_once() {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open(&dir.path().join("index.sqlite")).await.unwrap();
    let tp = endpoint().await;
    let blobs = std::sync::Arc::new(
        Blobs::open(&tp, &dir.path().join("daemon-blobs"))
            .await
            .unwrap(),
    );
    let (event_bus, mut rx) = daemon::events::bus();
    // 窗口拉到 1 小时：本测试钉的是「commit 收尾立即 flush + 批中信号被
    // 合并」的**接线**，不是 1 秒窗口的墙钟行为（后者由 Throttle 单测钉）。
    // 用默认 1s 窗口时，被打满的 CI runner 上批次中途窗口到点会多 emit
    // 一次，测试薛定谔红（2026-08-22 CI 实例）。
    let backup = BackupEngine::new(db.clone(), blobs.clone(), dir.path().join("library"))
        .with_events_and_window(event_bus, std::time::Duration::from_secs(3600));
    let router = Router::new(db.clone(), "storage").with_backup(backup.clone());
    let tp2 = tp.clone();
    let serve_task = tokio::spawn(async move { router.serve(&tp2).await });
    let storage = StorageSide {
        tp,
        blobs,
        db,
        backup,
        serve_task,
    };

    let client = Client::new(dir.path(), &storage).await;
    storage
        .db
        .accept_pairing(
            &client.tp.node_id().0,
            "phone",
            &member(&client.tp.node_id()),
        )
        .await
        .unwrap();

    let src_dir = dir.path().join("src");
    fs::create_dir_all(&src_dir).unwrap();
    let files = corpus(&src_dir, 5, 0); // 5 个各不相同的文件，一批提交
    import_all(&client, &files, &src_dir).await;
    let missing = client.run_backup(&files).await;
    assert_eq!(missing, 5);

    // commit 收尾会强制 flush 挂起信号——不必等节流窗口，commit 的
    // RPC 响应回到这里时，emit 早已在 bus 上完成（同步调用，非异步排队）。
    let msg = rx.try_recv().expect("commit 收尾必须立即 flush 挂起信号");
    assert_eq!(msg["event"], daemon::events::TIMELINE_INVALIDATED);
    assert!(
        rx.try_recv().is_err(),
        "5 个文件的一次 commit 应合并成 1 次 emit，不是 5 次"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn interrupted_commit_rerun_converges_and_survives_rebuild() {
    let dir = tempfile::tempdir().unwrap();
    let storage = start_daemon(dir.path()).await;
    let client = Client::new(dir.path(), &storage).await;
    storage
        .db
        .accept_pairing(
            &client.tp.node_id().0,
            "phone",
            &member(&client.tp.node_id()),
        )
        .await
        .unwrap();

    let src_dir = dir.path().join("src");
    fs::create_dir_all(&src_dir).unwrap();
    let files = corpus(&src_dir, 60, 0);

    // Interruption model: the client only serves HALF its files, then
    // "dies" mid-batch — the daemon's commit fails partway (some files
    // already ingested, the rest unfetchable). This is what a phone
    // walking out of WiFi looks like to the daemon.
    let half: HashMap<_, _> = files
        .iter()
        .take(30)
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    import_all(&client, &half, &src_dir).await;

    assert!(
        client
            .call("backup.begin", serde_json::Value::Null)
            .await
            .ok
    );
    let manifest = BackupManifest {
        hashes: vec![],
        items: files.values().map(|(_, i)| i.clone()).collect(),
        provider: Some(client.tp.local_addr().to_string()),
    };
    let resp = client
        .call("backup.manifest", serde_json::to_value(&manifest).unwrap())
        .await;
    assert!(resp.ok);
    let resp = client
        .call(
            "backup.commit",
            serde_json::to_value(&BackupCommit { generation: None }).unwrap(),
        )
        .await;
    assert!(!resp.ok, "commit over a half-dead client must fail");
    assert_eq!(resp.error.unwrap().reason(), &proto::Reason::BackupFailed);

    let after_crash = asset_count(&storage.db).await;
    assert!(
        after_crash < files.len(),
        "some files must be stranded ({after_crash})"
    );

    // Recovery: the client comes back with everything and re-runs.
    import_all(&client, &files, &src_dir).await;
    let missing = client.run_backup(&files).await;
    assert_eq!(
        missing,
        files.len() - after_crash,
        "only the stranded remainder"
    );
    assert_eq!(asset_count(&storage.db).await, files.len());

    // 最终一致的最强证明: wipe the index and rebuild from originals/ —
    // the T-012 guard doubles as the backup pipeline's consistency oracle.
    let before: Vec<_> = dump(&storage.db).await;
    let fresh = Db::open_in_memory().await.unwrap();
    core_index::rebuild(&fresh, &dir.path().join("library"), &storage.tp.node_id().0)
        .await
        .unwrap();
    let rebuilt: Vec<_> = dump(&fresh).await;
    assert_eq!(before, rebuilt, "index and originals/ must agree exactly");
}

async fn dump(db: &Db) -> Vec<(Vec<u8>, String, i64, Vec<u8>)> {
    let mut rows = Vec::new();
    let mut cursor = None;
    loop {
        let page = db.timeline_page(cursor.as_deref(), 1000).await.unwrap();
        rows.extend(
            page.assets
                .into_iter()
                .map(|a| (a.hash, a.rel_path, a.bytes, a.src_device)),
        );
        match page.next_cursor {
            Some(c) => cursor = Some(c),
            None => break,
        }
    }
    rows.sort();
    rows
}

const PAIRING_ID: &str = "pairing-backup-1";

fn member(id: &transport::NodeId) -> Pairing {
    Pairing {
        id: PAIRING_ID.into(),
        node_id: id.0.to_vec(),
        role: Role::Member,
        paired_at: 1,
    }
}

/// #1270：已配对的手机 A 在 `backup.manifest` 里把一个假地址写在另一台设备 B 名下：A 自己的
/// 备份照常完成（从 A 拉），电脑之后照样按原来的信息连得上 B。
/// 反证：`commit` 改回把上报地址登记进传输层地址簿（`register_peer` / `add_peer`），B 的地址被
/// 假地址顶掉，最后一条断言变红。
#[tokio::test(flavor = "multi_thread")]
async fn backup_provider_address_for_another_device_leaves_that_device_reachable() {
    let dir = tempfile::tempdir().unwrap();
    let storage = start_daemon(dir.path()).await;
    let client = Client::new(dir.path(), &storage).await;
    storage
        .db
        .accept_pairing(
            &client.tp.node_id().0,
            "phone",
            &member(&client.tp.node_id()),
        )
        .await
        .unwrap();

    // 设备 B：电脑认识它（地址簿里有它的真地址），手里有一份内容。
    let b_dir = dir.path().join("b");
    fs::create_dir_all(&b_dir).unwrap();
    let b_tp = endpoint().await;
    let mut b_blobs = Blobs::open(&b_tp, &b_dir.join("store")).await.unwrap();
    b_blobs.serve();
    let b_bytes = b"device B's photo";
    let b_hash = *blake3::hash(b_bytes).as_bytes();
    fs::write(b_dir.join("b.jpg"), b_bytes).unwrap();
    b_blobs.import(b_hash, &b_dir.join("b.jpg")).await.unwrap();
    storage.tp.add_peer(b_tp.local_addr());

    let src_dir = dir.path().join("src");
    fs::create_dir_all(&src_dir).unwrap();
    let files = corpus(&src_dir, 3, 0);
    import_all(&client, &files, &src_dir).await;

    assert!(
        client
            .call("backup.begin", serde_json::Value::Null)
            .await
            .ok
    );
    let forged = transport::PeerAddr::from_node_relay(b_tp.node_id(), Some("http://127.0.0.1:9"))
        .unwrap()
        .to_string();
    let manifest = BackupManifest {
        hashes: vec![],
        items: files.values().map(|(_, i)| i.clone()).collect(),
        provider: Some(forged),
    };
    assert!(
        client
            .call("backup.manifest", serde_json::to_value(&manifest).unwrap())
            .await
            .ok
    );
    let resp = client
        .call(
            "backup.commit",
            serde_json::to_value(&BackupCommit { generation: None }).unwrap(),
        )
        .await;
    assert!(resp.ok, "A 自己的备份照常完成：{resp:?}");
    assert_eq!(asset_count(&storage.db).await, files.len());

    let fetched = tokio::time::timeout(
        std::time::Duration::from_secs(20),
        storage.blobs.fetch_from(b_tp.node_id(), b_hash),
    )
    .await;
    assert!(
        matches!(fetched, Ok(Ok(()))),
        "B 的地址被别的设备上报的假地址改掉了：{fetched:?}"
    );
}
