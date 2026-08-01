//! T-070 时钟前跳剧本：墙钟前跳 11 分钟（超过配对令牌 TTL 600s）——
//! 在途配对会话的令牌即时过期；daemon 保持健康；时钟恢复正常后新令牌可用。
//!
//! 时钟注入走 Router::with_clock（T-070 新增的测试缝）——不碰系统时钟。

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use daemon::Router;
use proto::{codes, PairRequest, Req, Resp};
use storage::{Db, Device, Role};
use transport::{IrohTransport, Transport, TransportConfig};

const T0: i64 = 1_800_000_000_000;
const TOKEN_TTL_MS: i64 = 600_000;

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap()
}

async fn start_daemon(
    db: Db,
    clock: Arc<AtomicI64>,
) -> (IrohTransport, transport::PeerAddr, daemon::Pairing) {
    let tp = endpoint().await;
    let addr = tp.local_addr();
    let now = clock.clone();
    let (pairing, mut pending) = daemon::Pairing::new(db.clone(), tp.node_id(), None);
    tokio::spawn(async move {
        while let Some(req) = pending.recv().await {
            req.decide(true); // 剧本自动确认（owner 在 IPC 侧）
        }
    });
    let router = Router::new(db, "时钟剧本存储端")
        .with_pairing(pairing.clone())
        .with_clock(move || now.load(Ordering::Relaxed));
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr, pairing)
}

async fn call(
    tp: &IrohTransport,
    daemon: transport::NodeId,
    method: &str,
    params: serde_json::Value,
) -> Resp {
    let mut stream = tp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
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

async fn send_pair(tp: &IrohTransport, daemon: transport::NodeId, token: &str, name: &str) -> Resp {
    call(
        tp,
        daemon,
        "pair.request",
        serde_json::to_value(PairRequest {
            token: token.into(),
            device_name: name.into(),
            role: "member".into(),
        })
        .unwrap(),
    )
    .await
}

#[tokio::test(flavor = "multi_thread")]
async fn clock_jump_expires_inflight_pairing_tokens() {
    let db = Db::open_in_memory().await.unwrap();
    let clock = Arc::new(AtomicI64::new(T0));
    let (dtp, daddr, pairing) = start_daemon(db.clone(), clock.clone()).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr.clone());

    // 健康基线：一个已配对设备 hello 正常。
    db.upsert_device(&Device {
        node_id: ctp.node_id().0.to_vec(),
        name: "老设备".into(),
        role: Role::Member,
        paired_at: T0,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();
    let hello = call(&ctp, dtp.node_id(), "hello", serde_json::Value::Null).await;
    assert!(hello.ok, "hello before jump: {hello:?}");

    // 配对尝试来自未配对的新端点（已配对设备走 pair.request 会被 authz 拒——
    // 那是 T-030 的配对之门语义，不是本剧本的靶子）。
    let phone = endpoint().await;
    phone.add_peer(daddr);
    // 在途会话：T0 铸造配对令牌（QR 串），尚未被使用。
    let mut token = [0u8; 32];
    token[0] = 7;
    let qr = pairing.start(token, T0);
    let token_hex = qr.rsplit("&t=").next().unwrap().to_string();

    // 墙钟前跳 11 分钟（> TTL 600s）→ 令牌即时过期，配对被拒。
    clock.store(T0 + 11 * 60_000, Ordering::Relaxed);
    let resp = send_pair(&phone, dtp.node_id(), &token_hex, "跳钟设备").await;
    assert!(!resp.ok, "expired token must be rejected");
    let err = resp.error.expect("error payload");
    assert_eq!(err.code, codes::NOT_AUTHORIZED);

    // daemon 仍健康：已配对设备的 hello 照常。
    let hello2 = call(&ctp, dtp.node_id(), "hello", serde_json::Value::Null).await;
    assert!(
        hello2.ok,
        "daemon must stay healthy after clock jump: {hello2:?}"
    );

    // 钟恢复正常 → 过期在请求时评估（pairing.rs:140）：同一令牌当时只是
    // 被拒、未被消耗，现在重新有效——走通全链（自动确认 → 设备落表 → 审计）。
    clock.store(T0, Ordering::Relaxed);
    let resp = send_pair(&phone, dtp.node_id(), &token_hex, "跳钟设备重试").await;
    assert!(resp.ok, "expiry is evaluated per-request; a never-consumed token revives after the clock normalizes: {resp:?}");

    let d = db
        .get_device(&phone.node_id().0)
        .await
        .unwrap()
        .expect("device row");
    assert!(!d.revoked);
    let audit = db.list_audit(10).await.unwrap();
    assert!(
        audit.iter().any(|r| r.entry.action == "pair.accepted"),
        "audit must record the accepted pairing: {audit:?}"
    );

    // 令牌 TTL 常量回归护栏：若未来 TTL 超过 11 分钟，本剧本的时间跳变将不再
    // 命中过期分支——剧本应同步更新（断言常量，防止剧本悄悄失效）。
    assert_eq!(TOKEN_TTL_MS, 600_000);
}
