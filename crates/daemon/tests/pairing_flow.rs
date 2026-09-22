//! T-031 acceptance: full pairing flow over a real loopback connection,
//! expired-token rejection, and one-time token replay rejection.

use daemon::{PairDecision, Pairing, Router};
use proto::{codes, methods, PairRequest, Req, Resp};
use storage::{Db, Role};
use transport::{IrohTransport, Transport, TransportConfig};

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap()
}

/// Daemon with pairing attached; owner decisions scripted by `accept`.
async fn start_daemon(db: Db, accept: bool) -> (IrohTransport, transport::PeerAddr, Pairing) {
    let tp = endpoint().await;
    let addr = tp.local_addr();
    let (pairing, mut pending) = Pairing::new(db.clone(), tp.node_id(), None, None);
    tokio::spawn(async move {
        while let Some(req) = pending.recv().await {
            let _ = req.decide(if accept {
                PairDecision::Accept
            } else {
                PairDecision::Reject
            });
        }
    });
    let router = Router::new(db, "客厅的电脑").with_pairing(pairing.clone());
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr, pairing)
}

async fn send_pair(
    ctp: &IrohTransport,
    daemon: transport::NodeId,
    token: &str,
    name: &str,
) -> Resp {
    let mut stream = ctp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
    let req = Req {
        id: "pair-1".into(),
        method: "pair.request".into(),
        params: serde_json::to_value(PairRequest {
            token: token.into(),
            device_name: name.into(),
            role: "member".into(),
        })
        .unwrap(),
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

fn token_of(qr: &str) -> String {
    qr.rsplit("&t=").next().unwrap().to_string()
}

#[tokio::test(flavor = "multi_thread")]
async fn full_flow_pairs_the_device() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon(db.clone(), true).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    let qr = pairing.start([0x42; 12], now());
    assert!(qr.starts_with(&format!("ppf://pair?node={}", dtp.node_id())));

    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr), "妈妈的手机").await;
    assert!(resp.ok, "pairing must succeed: {resp:?}");
    let accepted: proto::PairAccepted = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(accepted.storage_device_name, "客厅的电脑");
    assert_eq!(
        accepted.pairing_epoch.len(),
        32,
        "accepted pairing must carry a fresh epoch"
    );
    assert_eq!(
        db.pairing_epoch(&ctp.node_id().0).await.unwrap().as_deref(),
        Some(accepted.pairing_epoch.as_str()),
        "the returned epoch must already be durable before Flow can use it"
    );

    // The whitelist row is real — the same client is now authorized.
    let device = db
        .get_device(&ctp.node_id().0)
        .await
        .unwrap()
        .expect("device row written");
    assert_eq!(device.name, "妈妈的手机");
    assert_eq!(device.role, Role::Member);
    assert!(!device.revoked);

    // And the audit trail names the pairing (审计裁决).
    let audit = db.list_audit(10).await.unwrap();
    assert!(audit.iter().any(|r| r.entry.kind == "pair.accepted"));
}

#[tokio::test(flavor = "multi_thread")]
async fn paired_member_hello_returns_its_current_flow_epoch() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon(db, true).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    let qr = pairing.start([0x46; 12], now());
    let paired = send_pair(&ctp, dtp.node_id(), &token_of(&qr), "恢复中的手机").await;
    let accepted: proto::PairAccepted = serde_json::from_value(paired.result.unwrap()).unwrap();

    let hello = send_method(&ctp, dtp.node_id(), methods::HELLO, serde_json::json!({})).await;
    assert!(hello.ok, "paired member hello must succeed: {hello:?}");
    let response: proto::Hello = serde_json::from_value(hello.result.unwrap()).unwrap();
    assert_eq!(
        response.pairing_epoch.as_deref(),
        Some(accepted.pairing_epoch.as_str())
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn expired_token_is_rejected() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon(db.clone(), true).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    // Issued 11 minutes in the past — beyond the 600 s TTL.
    let qr = pairing.start([0x43; 12], now() - 11 * 60 * 1000);
    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr), "过期设备").await;
    let err = resp.error.expect("expired token must be rejected");
    assert_eq!(err.code, codes::NOT_AUTHORIZED);
    assert!(db.get_device(&ctp.node_id().0).await.unwrap().is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn token_replay_is_rejected() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon(db.clone(), true).await;
    let first = endpoint().await;
    first.add_peer(daddr.clone());
    let second = endpoint().await;
    second.add_peer(daddr);

    let qr = pairing.start([0x44; 12], now());
    let token = token_of(&qr);

    let resp = send_pair(&first, dtp.node_id(), &token, "第一台").await;
    assert!(resp.ok, "first use must pass: {resp:?}");

    // Same token again from a different device: one-time means one time.
    let resp = send_pair(&second, dtp.node_id(), &token, "重放攻击者").await;
    let err = resp.error.expect("replay must be rejected");
    assert_eq!(err.code, codes::NOT_AUTHORIZED);
    assert!(db.get_device(&second.node_id().0).await.unwrap().is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn owner_decline_writes_nothing() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon(db.clone(), false).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    let qr = pairing.start([0x45; 12], now());
    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr), "被拒绝的设备").await;
    let err = resp.error.expect("owner said no");
    assert_eq!(err.code, codes::NOT_AUTHORIZED);
    assert!(db.get_device(&ctp.node_id().0).await.unwrap().is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn revoked_device_rejoins_with_fresh_token() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon(db.clone(), true).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    // Pair, then the owner removes the device.
    let qr = pairing.start([0x50; 12], now());
    assert!(
        send_pair(&ctp, dtp.node_id(), &token_of(&qr), "家人手机")
            .await
            .ok
    );
    assert!(db
        .revoke(
            &ctp.node_id().0,
            storage::RevokedBy::Owner,
            1_700_000_000_000
        )
        .await
        .unwrap());
    // DEV-02: 水位是"已经备份到哪儿"的记账。同一个身份回来必须接着用它，
    // 否则照片会重传——这正是 DEV-01 的 merge 想解决、而 1:1 下本来就
    // 成立的那件事。
    db.set_watermark(&ctp.node_id().0, 300, now())
        .await
        .unwrap();

    // A fresh owner-issued token lets the SAME identity rejoin…
    let qr2 = pairing.start([0x51; 12], now());
    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr2), "家人手机").await;
    assert!(
        resp.ok,
        "mistakenly removed devices must be able to rejoin: {resp:?}"
    );
    let d = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert!(!d.revoked, "owner confirmation reinstates the device");

    // DEV-02 的正面证据：一对密钥 = 一台设备。同一个 NodeId 重新配对
    // **不得**生出第二行，水位留在原处。
    let all = db.list_devices(true).await.unwrap();
    assert_eq!(all.len(), 1, "同一个 NodeId 不得生出第二行：{all:?}");
    assert_eq!(
        db.get_watermark(&ctp.node_id().0).await.unwrap(),
        Some(300),
        "水位留在原处 = 照片不重传",
    );

    // …and the audit trail says it was a rejoin.
    let audit = db.list_audit(10).await.unwrap();
    assert!(audit.iter().any(|r| r
        .entry
        .payload
        .as_deref()
        .unwrap_or("")
        .contains("rejoined")));
}

// ── UX-06: device.unpair — unilateral stop ────────────────

async fn send_method(
    ctp: &IrohTransport,
    daemon: transport::NodeId,
    method: &str,
    params: serde_json::Value,
) -> Resp {
    let mut stream = ctp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
    let req = Req {
        id: format!("m-{method}"),
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

#[tokio::test(flavor = "multi_thread")]
async fn unpair_revokes_self_and_hello_is_denied_then_fresh_token_rejoins() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon(db.clone(), true).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    // Pair normally.
    let qr = pairing.start([0x60; 12], now());
    assert!(
        send_pair(&ctp, dtp.node_id(), &token_of(&qr), "要断开的手机")
            .await
            .ok
    );
    assert!(
        !db.get_device(&ctp.node_id().0)
            .await
            .unwrap()
            .unwrap()
            .revoked
    );

    // Unilateral stop: the device revokes itself — no owner action.
    let resp = send_method(
        &ctp,
        dtp.node_id(),
        methods::DEVICE_UNPAIR,
        serde_json::json!({}),
    )
    .await;
    assert!(resp.ok, "self-unpair must succeed: {resp:?}");
    let d = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert!(d.revoked, "device row must be revoked after unpair");

    // hello is now denied (revoked ⇒ not even hello).
    let hello = send_method(&ctp, dtp.node_id(), methods::HELLO, serde_json::json!({})).await;
    assert!(!hello.ok, "revoked device must not reach hello");
    assert_eq!(hello.error.unwrap().code, codes::NOT_AUTHORIZED);

    // …but a fresh owner-issued token lets the SAME identity rejoin.
    let qr2 = pairing.start([0x61; 12], now());
    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr2), "要断开的手机").await;
    assert!(
        resp.ok,
        "unpaired device must rejoin with fresh token: {resp:?}"
    );
    let d = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert!(!d.revoked);

    // Audit names the self-revocation.
    let audit = db.list_audit(20).await.unwrap();
    assert!(audit.iter().any(|r| r.entry.kind == "device.unpaired"));
}

#[tokio::test(flavor = "multi_thread")]
async fn unpair_by_unpaired_device_is_denied() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, _pairing) = start_daemon(db.clone(), true).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    // Never paired: device.unpair is outside the pairing door.
    let resp = send_method(
        &ctp,
        dtp.node_id(),
        methods::DEVICE_UNPAIR,
        serde_json::json!({}),
    )
    .await;
    assert!(!resp.ok, "unpaired device must not unpair");
    assert_eq!(resp.error.unwrap().code, codes::NOT_AUTHORIZED);
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ── DEV-05 (#276): pending requests expire on BOTH sides ──────────
//
// Card: 手机早放弃了，业主后点的「允许」照样生效. These tests pin the
// request-side half (pairing.rs); the queue-side half lives in
// ipc_flow.rs (the queue is IpcServer's state).

/// Daemon whose owner queue DRAINS but never decides — requests park
/// until their own TTL expires (the real-world "owner never clicks").
/// `request_ttl_ms` shortens the wait so the test need not sleep 110 s.
async fn park_daemon(db: Db, request_ttl_ms: u64) -> (IrohTransport, transport::PeerAddr, Pairing) {
    let tp = endpoint().await;
    let addr = tp.local_addr();
    let (pairing, mut pending) = Pairing::new(db.clone(), tp.node_id(), None, None);
    let pairing = pairing.with_pending_ttl(request_ttl_ms as i64);
    tokio::spawn(async move {
        // Keep the received PendingPairs ALIVE (holding them keeps their
        // oneshot senders open → the request waits for a verdict that
        // never comes, until its own timeout). Dropping here would fake
        // an owner-decision channel close.
        let mut parked = Vec::new();
        while let Some(p) = pending.recv().await {
            parked.push(p);
        }
    });
    let router = Router::new(db, "客厅的电脑").with_pairing(pairing.clone());
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr, pairing)
}

/// 验收标准 1（请求侧）+ 4（拒绝也要能答"隔了多久"）：一条没人决策的
/// pending 到期后，手机收到明确拒绝，且库里什么都不写。
/// 反证靶子：去掉 handle_request 的 timeout，本用例在 5s 处变红。
#[tokio::test(flavor = "multi_thread")]
async fn stale_pending_times_out_denied_with_no_writes() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = park_daemon(db.clone(), 300).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    let qr = pairing.start([0x77; 12], now());
    let t0 = std::time::Instant::now();
    let resp = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        send_pair(&ctp, dtp.node_id(), &token_of(&qr), "没人点的手机"),
    )
    .await
    .expect("daemon must answer within 5s once the pending TTL expires (无 TTL 时此反证变红)");
    let waited = t0.elapsed();

    assert!(!resp.ok, "expired pending must be denied: {resp:?}");
    assert_eq!(resp.error.unwrap().code, codes::NOT_AUTHORIZED);
    assert!(
        waited >= std::time::Duration::from_millis(250),
        "denied before the TTL is up = instant-fail, not expiry: {waited:?}"
    );
    assert!(
        waited <= std::time::Duration::from_secs(2),
        "TTL fired far too late: {waited:?}"
    );
    assert!(
        db.get_device(&ctp.node_id().0).await.unwrap().is_none(),
        "no device row"
    );
    assert!(
        db.pairing_epoch(&ctp.node_id().0).await.unwrap().is_none(),
        "no epoch rotation for a request nobody approved"
    );

    // 验收标准 4 for the DENY path (简报六: denied shares the same bug):
    // pair.denied lands at the expiry moment, not the request moment.
    let audit = db.list_audit(20).await.unwrap();
    let requested = audit
        .iter()
        .find(|r| r.entry.kind == "pair.requested")
        .expect("pair.requested recorded")
        .entry
        .ts;
    let denied = audit
        .iter()
        .find(|r| r.entry.kind == "pair.denied")
        .expect("pair.denied recorded")
        .entry
        .ts;
    assert!(
        denied - requested >= 250,
        "审计要答得出'业主隔了多久（这里是超时多久）'：requested={requested} denied={denied}"
    );
}

/// 验收标准 3 + 4（允许路径）：扫码后正常批准仍成功；且
/// `pair.accepted` 的时间戳 = 业主点下的时刻，不再是 `pair.requested`
/// 的入参快照。反证靶子：accepted 落回 now_ms 时差值断言变红。
#[tokio::test(flavor = "multi_thread")]
async fn accepted_audit_carries_decision_time_not_request_time() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon_slow_owner(db.clone(), 700).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    let qr = pairing.start([0x78; 12], now());
    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr), "隔了一会儿才点的手机").await;
    assert!(resp.ok, "normal path stays unaffected: {resp:?}");

    let audit = db.list_audit(20).await.unwrap();
    let requested = audit
        .iter()
        .find(|r| r.entry.kind == "pair.requested")
        .expect("pair.requested")
        .entry
        .ts;
    let accepted = audit
        .iter()
        .find(|r| r.entry.kind == "pair.accepted")
        .expect("pair.accepted")
        .entry
        .ts;
    assert!(
        accepted - requested >= 500,
        "业主隔了 700ms 才点，审计两条必须分得开：requested={requested} accepted={accepted}"
    );
    assert!(db.get_device(&ctp.node_id().0).await.unwrap().is_some());
}

/// Daemon with an owner that takes `owner_delay_ms` to say Accept —
/// simulating "业主隔了一会儿才点". The request side keeps the default
/// 110 s TTL, so the slow click still lands inside it.
async fn start_daemon_slow_owner(
    db: Db,
    owner_delay_ms: u64,
) -> (IrohTransport, transport::PeerAddr, Pairing) {
    let tp = endpoint().await;
    let addr = tp.local_addr();
    let (pairing, mut pending) = Pairing::new(db.clone(), tp.node_id(), None, None);
    tokio::spawn(async move {
        while let Some(req) = pending.recv().await {
            tokio::time::sleep(std::time::Duration::from_millis(owner_delay_ms)).await;
            let _ = req.decide(PairDecision::Accept);
        }
    });
    let router = Router::new(db, "客厅的电脑").with_pairing(pairing.clone());
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr, pairing)
}
