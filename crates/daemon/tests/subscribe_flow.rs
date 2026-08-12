//! SYNC-03 acceptance: `timeline.subscribe` on the QUIC ctrl plane —
//! ack + immediate "current state" push (§③), real broadcast relay,
//! and revoke actively closing an open subscription (§⑦).

use daemon::events::TIMELINE_INVALIDATED;
use daemon::subscriptions::SubscriptionRegistry;
use daemon::{BackupEngine, Router};
use proto::msgs::methods;
use proto::{Req, Resp};
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
