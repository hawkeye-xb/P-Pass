//! SYNC-03 acceptance: `timeline.subscribe` on the QUIC ctrl plane —
//! ack + immediate "current state" push (§③), real broadcast relay,
//! and revoke actively closing an open subscription (§⑦).

use std::sync::Arc;

use daemon::events::TIMELINE_INVALIDATED;
use daemon::subscriptions::SubscriptionRegistry;
use daemon::{BackupEngine, DiagAgg, IpcServer, Pairing, Router};
use interprocess::local_socket::tokio::prelude::*;
use interprocess::local_socket::GenericNamespaced;
use proto::msgs::methods;
use proto::{Req, Resp};
use storage::{Db, Device, Role};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use transport::{Blobs, IrohTransport, Transport, TransportConfig};

const ALPNS: &[&str] = &["ppf/ctrl/1", "ppf/blobs/1"];

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(
        ALPNS.iter().map(|s| s.to_string()).collect(),
    ))
    .await
    .unwrap()
}

fn member(id: &transport::NodeId) -> Device {
    Device {
        node_id: id.0.to_vec(),
        name: "phone".into(),
        role: Role::Member,
        paired_at: 0,
        last_seen: None,
        revoked: false,
        device_hint: None,
    }
}

struct Fixture {
    storage_tp: IrohTransport,
    client_tp: IrohTransport,
    db: Db,
    subscriptions: SubscriptionRegistry,
    event_bus: daemon::events::EventBus,
    #[allow(dead_code)]
    serve_task: tokio::task::JoinHandle<()>,
    // 必须把 TempDir 活着存进 Fixture——它若在 setup() 末尾被 drop，临时目录
    // 连带 index.sqlite 一起被删，之后连接池任何一次「新开连接/建 journal」
    // 都会炸 SqliteError code 14 "unable to open database file"（2026-08-22
    // CI ubuntu 实例：revoke 时恰好要开新连接；macOS 本地靠连接复用侥幸通过，
    // 是薛定谔的绿）。
    #[allow(dead_code)]
    dir: tempfile::TempDir,
}

async fn setup() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open(&dir.path().join("index.sqlite")).await.unwrap();
    let storage_tp = endpoint().await;
    let blobs = std::sync::Arc::new(
        Blobs::open(&storage_tp, &dir.path().join("daemon-blobs"))
            .await
            .unwrap(),
    );
    let (event_bus, _probe) = daemon::events::bus();
    let subscriptions = SubscriptionRegistry::new();
    let backup = BackupEngine::new(db.clone(), blobs, dir.path().join("library"))
        .with_events(event_bus.clone());
    let router = Router::new(db.clone(), "storage")
        .with_events(event_bus.clone())
        .with_subscriptions(subscriptions.clone())
        .with_backup(backup);
    let tp2 = storage_tp.clone();
    let serve_task = tokio::spawn(async move { router.serve(&tp2).await });

    let client_tp = endpoint().await;
    client_tp.add_peer(storage_tp.local_addr());
    db.upsert_device(&member(&client_tp.node_id()))
        .await
        .unwrap();

    Fixture {
        storage_tp,
        client_tp,
        db,
        subscriptions,
        event_bus,
        serve_task,
        dir,
    }
}

/// Open a `timeline.subscribe` stream, consume the ack + the initial
/// "current state" push, return the still-open stream.
async fn subscribe(f: &Fixture) -> transport::BiStream {
    let mut stream = f
        .client_tp
        .connect(f.storage_tp.node_id(), transport::ALPN_CTRL)
        .await
        .unwrap();
    let req = Req {
        id: "sub".into(),
        method: methods::TIMELINE_SUBSCRIBE.into(),
        params: serde_json::Value::Null,
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&req).unwrap())
        .await
        .unwrap();
    // §④ 客户端设计：订阅请求发完就半关闭发送方向，数据永远走别的 stream。
    stream.finish().unwrap();

    let ack_frame = stream.recv_frame().await.unwrap().expect("ack frame");
    let ack: Resp = proto::codec::decode(&ack_frame).unwrap();
    assert!(ack.ok, "subscribe 应该被 authz 允许: {ack:?}");

    let initial_frame = stream.recv_frame().await.unwrap().expect("initial push");
    let initial: serde_json::Value = proto::codec::decode(&initial_frame).unwrap();
    assert_eq!(
        initial["event"], TIMELINE_INVALIDATED,
        "§③ 订阅建立必须立刻推一次当前态，不等下一次真实变更"
    );
    stream
}

#[tokio::test(flavor = "multi_thread")]
async fn subscribe_relays_a_real_broadcast_event() {
    let f = setup().await;
    let mut stream = subscribe(&f).await;

    // 模拟一次真实变更（SYNC-02 已经证明 backup/reconcile 会这样 emit）。
    daemon::events::emit(&f.event_bus, TIMELINE_INVALIDATED, serde_json::json!({}));

    let frame = stream.recv_frame().await.unwrap().expect("relayed event");
    let v: serde_json::Value = proto::codec::decode(&frame).unwrap();
    assert_eq!(v["event"], TIMELINE_INVALIDATED);
}

#[tokio::test(flavor = "multi_thread")]
async fn revoke_actively_closes_an_open_subscription() {
    let f = setup().await;
    let mut stream = subscribe(&f).await;

    // `device.revoke` 的两步：改数据库 + 查表主动断连（这里直接复用同
    // 一份 subscriptions handle，跳过 IPC 传输层——被测的是 router.rs
    // 的登记/断连机制本身，不是 IPC 的 JSON 解析）。
    f.db.revoke(&f.client_tp.node_id().0).await.unwrap();
    f.subscriptions.close(f.client_tp.node_id());

    let end = tokio::time::timeout(std::time::Duration::from_secs(3), stream.recv_frame()).await;
    match end {
        Ok(Ok(None)) => {} // 期望：对端（daemon）主动 finish，我方读到 EOF
        Ok(Err(_)) => {}   // 或连接错误——同样算"主动关闭"
        Ok(Ok(Some(_))) => panic!("revoke 之后不该再收到正常事件帧"),
        Err(_) => panic!("revoke 之后连接必须在有限时间内关闭，不能悬着"),
    }
}

// ── REV-01 #3: device.revoke 走真实 IPC JSON 链路 ───────────────────
//
// 上面那条 `revoke_actively_closes_an_open_subscription` 直接调
// `subscriptions.close()`，测的是 router.rs 的登记/断连机制本身，跳过
// 了 `device.revoke`（IPC JSON）→ ipc.rs 查表 → close 这条真实接线——
// 这段最容易在改字段名/参数解析时悄悄断掉却没有测试兜底。这条测试走
// 完整 IPC socket，Router 与 IpcServer 共用同一份 `SubscriptionRegistry`
// （main.rs 生产环境的真实接线方式）。

struct IpcClient {
    lines: tokio::io::Lines<BufReader<interprocess::local_socket::tokio::RecvHalf>>,
    tx: interprocess::local_socket::tokio::SendHalf,
}

impl IpcClient {
    async fn connect(socket: &str, token: &str) -> IpcClient {
        let name = socket.to_ns_name::<GenericNamespaced>().unwrap();
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

fn ipc_socket_name(tag: &str) -> String {
    format!("ppf-test-sub-{}-{}", std::process::id(), tag)
}

fn hex32(bytes: &[u8; 32]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn device_revoke_over_ipc_closes_the_quic_subscription() {
    let f = setup().await;
    let mut stream = subscribe(&f).await;

    // 与 main.rs 同款接线：IpcServer 拿的是 Router 那份 subscriptions
    // 的 clone（同一张表），不是另开一份。
    let (pairing, pending_rx) = Pairing::new(f.db.clone(), f.storage_tp.node_id(), None, None);
    let diag = DiagAgg::new(f.db.clone());
    let ipc_dir = tempfile::tempdir().unwrap();
    let mut ipc = IpcServer::new(
        f.db.clone(),
        pairing,
        diag,
        ipc_dir.path().to_path_buf(),
        pending_rx,
        f.event_bus.clone(),
    );
    ipc.set_subscriptions(f.subscriptions.clone());
    let ipc = Arc::new(ipc);

    let socket = ipc_socket_name("revoke");
    let token = [0x5A; 32];
    let token_hex = hex32(&token);
    tokio::spawn({
        let ipc = Arc::clone(&ipc);
        let socket = socket.clone();
        async move {
            let _ = ipc.serve(&socket, token).await;
        }
    });
    let name = socket.clone().to_ns_name::<GenericNamespaced>().unwrap();
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
    assert!(bound, "ipc socket {socket} never became connectable");

    let mut c = IpcClient::connect(&socket, &token_hex).await;
    let resp = c
        .call(
            "device.revoke",
            serde_json::json!({ "node_id": hex32(&f.client_tp.node_id().0) }),
        )
        .await;
    assert_eq!(resp.result.unwrap()["revoked"], true);

    let end = tokio::time::timeout(std::time::Duration::from_secs(3), stream.recv_frame()).await;
    match end {
        Ok(Ok(None)) => {}
        Ok(Err(_)) => {}
        Ok(Ok(Some(_))) => panic!("device.revoke（真实 IPC 链路）之后不该再收到正常事件帧"),
        Err(_) => panic!("device.revoke（真实 IPC 链路）之后连接必须在有限时间内关闭"),
    }
}
