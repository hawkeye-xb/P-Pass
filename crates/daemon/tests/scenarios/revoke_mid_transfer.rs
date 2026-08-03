//! T-070 吊销中断会话剧本：owner 在备份会话进行中（manifest 已提交、
//! commit 尚未执行）吊销设备——传输在门禁处被切断：
//! commit 拒 NOT_AUTHORIZED、水位不推进、零入库；后续任何请求全拒；daemon 健康。
//!
//! ⚠️ 命名诚实（T-070b）：本剧本实际覆盖的是 **revoke_before_commit**——
//! 当前实现里 manifest→commit 之间没有字节在途（commit 由存储端拉取），
//! "mid-transfer revoke" 的传输中字节场景尚无真实载体。卡面措辞保持
//! revoke_before_commit，不夸大。若未来 upload 管线引入长传输，再扩展
//! 为真正的 mid-upload 吊销。
//!
//! 架构语义（backup.rs:131 注释）：commit 一旦分发就跑到完、无二次鉴权——
//! 所以"中断"发生在门禁：吊销落在 commit 分发前，整场传输被切且零残留。

use std::path::Path;

use daemon::{BackupEngine, Router};
use proto::{codes, BackupCommit, BackupItem, BackupManifest, BackupMissing, Req, Resp};
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

async fn start_daemon(dir: &Path) -> (IrohTransport, transport::PeerAddr, Db) {
    let db = Db::open(&dir.join("index.sqlite")).await.unwrap();
    let tp = endpoint().await;
    let addr = tp.local_addr();
    let blobs = std::sync::Arc::new(Blobs::open(&tp, &dir.join("daemon-blobs")).await.unwrap());
    let backup = BackupEngine::new(db.clone(), blobs, dir.join("library"));
    let router = Router::new(db.clone(), "存储端").with_backup(backup);
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr, db)
}

struct Client {
    tp: IrohTransport,
    daemon: transport::NodeId,
}

impl Client {
    async fn new(storage: &IrohTransport, daemon: transport::NodeId) -> Client {
        let tp = endpoint().await;
        tp.add_peer(storage.local_addr());
        Client { tp, daemon }
    }

    async fn call(&self, method: &str, params: serde_json::Value) -> Resp {
        let mut stream = self
            .tp
            .connect(self.daemon, transport::ALPN_CTRL)
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

    async fn begin(&self) -> Resp {
        self.call("backup.begin", serde_json::Value::Null).await
    }

    async fn manifest(&self, items: &[BackupItem]) -> Resp {
        let m = BackupManifest {
            hashes: vec![],
            items: items.to_vec(),
            provider: None,
        };
        self.call("backup.manifest", serde_json::to_value(&m).unwrap())
            .await
    }

    async fn commit(&self, generation: i64) -> Resp {
        self.call(
            "backup.commit",
            serde_json::to_value(&BackupCommit {
                generation: Some(generation),
            })
            .unwrap(),
        )
        .await
    }
}

fn item(hash_hex: &str, name: &str) -> BackupItem {
    BackupItem {
        hash: hash_hex.into(),
        file_name: name.into(),
        media_type: "image/jpeg".into(),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn revoke_before_commit_cuts_session_at_the_gate() {
    let dir = tempfile::tempdir().unwrap();
    let (dtp, _daddr, db) = start_daemon(dir.path()).await;
    let client = Client::new(&dtp, dtp.node_id()).await;

    // 预置设备为 member（正常配对后的状态）。
    let node = client.tp.node_id().0;
    db.upsert_device(&Device {
        node_id: node.to_vec(),
        name: "手机".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();

    // 会话开始：begin + manifest（2 个文件，全缺失）。
    assert!(client.begin().await.ok, "begin must pass pre-revoke");
    let items = [
        item(&"ab".repeat(32), "a.jpg"),
        item(&"cd".repeat(32), "b.jpg"),
    ];
    let resp = client.manifest(&items).await;
    assert!(resp.ok, "manifest must pass pre-revoke: {resp:?}");
    let missing: BackupMissing = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(missing.hashes.len(), 2);

    // owner 吊销设备（IPC 路径的等价：直接走 db.revoke）。
    assert!(db.revoke(&node).await.unwrap(), "revoke must affect a row");

    // commit 在门禁处被切断：NOT_AUTHORIZED，而不是 INTERNAL 或成功。
    let resp = client.commit(42).await;
    assert!(!resp.ok, "commit must be cut at the gate");
    let err = resp.error.expect("error payload");
    assert_eq!(err.code, codes::NOT_AUTHORIZED);

    // 水位不推进、零入库——被切断的会话不留下任何半成品。
    assert_eq!(
        db.get_watermark(&node).await.unwrap(),
        None,
        "watermark must not advance"
    );
    let page = db.timeline_page(None, 100).await.unwrap();
    assert!(
        page.assets.is_empty(),
        "no assets may land from a revoked session"
    );

    // 吊销后的任何新请求全拒。
    assert!(
        !client.begin().await.ok,
        "new session must be refused after revoke"
    );
    let resp = client.manifest(&items).await;
    assert!(!resp.ok);

    // daemon 健康：另一个已配对设备 hello 照常。
    let other = Client::new(&dtp, dtp.node_id()).await;
    db.upsert_device(&Device {
        node_id: other.tp.node_id().0.to_vec(),
        name: "客厅电脑".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();
    let hello = other.call("hello", serde_json::Value::Null).await;
    assert!(
        hello.ok,
        "daemon must stay healthy after mid-session revoke: {hello:?}"
    );
}
