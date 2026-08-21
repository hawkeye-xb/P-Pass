//! T-032 acceptance: 500 mixed files end-to-end (asset count = deduped
//! count), interrupted commit re-runs to a consistent library, and the
//! final index survives the ADR-006 rebuild guard.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use daemon::{BackupEngine, Router};
use proto::{BackupCommit, BackupItem, BackupManifest, BackupMissing, Req, Resp};
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

struct StorageSide {
    tp: IrohTransport,
    db: Db,
    #[allow(dead_code)]
    serve_task: tokio::task::JoinHandle<()>,
}

/// Spin up a daemon over `library_root` (db file lives beside it so a
/// "restart" reopens the same index).
async fn start_daemon(dir: &Path) -> StorageSide {
    let db = Db::open(&dir.join("index.sqlite")).await.unwrap();
    let tp = endpoint().await;
    let blobs = std::sync::Arc::new(Blobs::open(&tp, &dir.join("daemon-blobs")).await.unwrap());
    let backup = BackupEngine::new(db.clone(), blobs, dir.join("library"));
    let router = Router::new(db.clone(), "storage").with_backup(backup);
    let tp2 = tp.clone();
    let serve_task = tokio::spawn(async move { router.serve(&tp2).await });
    StorageSide { tp, db, serve_task }
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
        .upsert_device(&member(&client.tp.node_id()))
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
        storage
            .db
            .get_watermark(&client.tp.node_id().0)
            .await
            .unwrap(),
        Some(42)
    );

    // Second run over the same corpus: nothing missing, nothing changes.
    let missing = client.run_backup(&files).await;
    assert_eq!(missing, 0, "second run must be a no-op");
    assert_eq!(asset_count(&storage.db).await, unique);
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
    let backup =
        BackupEngine::new(db.clone(), blobs, dir.path().join("library")).with_events(event_bus);
    let router = Router::new(db.clone(), "storage").with_backup(backup);
    let tp2 = tp.clone();
    let serve_task = tokio::spawn(async move { router.serve(&tp2).await });
    let storage = StorageSide { tp, db, serve_task };

    let client = Client::new(dir.path(), &storage).await;
    storage
        .db
        .upsert_device(&member(&client.tp.node_id()))
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
        .upsert_device(&member(&client.tp.node_id()))
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
    assert_eq!(resp.error.unwrap().msg_key, "err.backup_failed");

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

fn member(id: &transport::NodeId) -> Device {
    Device {
        node_id: id.0.to_vec(),
        name: "phone".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
        device_hint: None,
    }
}
