//! T-031 acceptance: full pairing flow over a real loopback connection,
//! expired-token rejection, and one-time token replay rejection.

use daemon::{PairDecision, Pairing, Router};
mod common;

use proto::{codes, methods, Req, Resp};
use storage::{Db, Role};
use transport::{IrohTransport, Transport, TransportConfig};

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap()
}

/// Daemon with pairing attached; owner decisions scripted by `accept`.
async fn start_daemon(db: Db, accept: bool) -> (IrohTransport, transport::PeerAddr, Pairing) {
    start_daemon_with_clock(db, accept, now).await
}

async fn start_daemon_with_clock(
    db: Db,
    accept: bool,
    clock: impl Fn() -> i64 + Send + Sync + 'static,
) -> (IrohTransport, transport::PeerAddr, Pairing) {
    let tp = endpoint().await;
    let addr = tp.local_addr();
    let (pairing, mut pending) = Pairing::new(db.clone(), tp.node_id(), None);
    tokio::spawn(async move {
        while let Some(req) = pending.recv().await {
            let _ = req.decide(if accept {
                common::allow()
            } else {
                PairDecision::Reject
            });
        }
    });
    let router = Router::new(db, "客厅的电脑")
        .with_pairing(pairing.clone())
        .with_clock(clock);
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr, pairing)
}

/// #1055: 设备自断开的 `departed_at` 与审计时间都取注入的时钟。
#[tokio::test]
async fn unpair_stamps_departed_at_from_the_injected_clock() {
    const FAKE_NOW: i64 = 1_999_000_000_000;
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon_with_clock(db.clone(), true, || FAKE_NOW).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);
    let qr = pairing.start([0x70; 12], FAKE_NOW);
    assert!(
        send_pair(&ctp, dtp.node_id(), &token_of(&qr), "手机")
            .await
            .ok
    );

    let resp = send_method(
        &ctp,
        dtp.node_id(),
        methods::DEVICE_UNPAIR,
        serde_json::json!({}),
    )
    .await;
    assert!(resp.ok, "{resp:?}");
    let d = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert_eq!(d.profile.departed_at, Some(FAKE_NOW));
    assert_eq!(d.profile.departed_by, Some(storage::DepartedBy::Device));
    assert!(d.pairing.is_none());
    let audit = db.list_audit(20).await.unwrap();
    let unpaired = audit
        .iter()
        .find(|r| r.entry.kind == "device.unpaired")
        .expect("unpair audit row");
    assert_eq!(unpaired.entry.ts, FAKE_NOW);
}

async fn send_pair(
    ctp: &IrohTransport,
    daemon: transport::NodeId,
    token: &str,
    name: &str,
) -> Resp {
    common::pair_settled(ctp, daemon, token, name).await
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
    // The daemon's own link parses with the shared parser the iOS binding and
    // testclient use (IOS pairing, #313): same node, and its token pairs.
    let link = transport::parse_pair_link(&qr).expect("daemon link parses");
    assert_eq!(link.node_id, dtp.node_id());
    assert_eq!(link.peer_addr.node_id(), dtp.node_id());
    assert_eq!(link.token, token_of(&qr));

    let resp = send_pair(&ctp, dtp.node_id(), &link.token, "妈妈的手机").await;
    assert!(resp.ok, "pairing must succeed: {resp:?}");
    let accepted: proto::PairAccepted = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(accepted.storage_device_name, "客厅的电脑");
    assert_eq!(
        accepted.pairing_id.len(),
        32,
        "accepted pairing must carry a fresh epoch"
    );
    assert_eq!(
        db.active_pairing(&ctp.node_id().0)
            .as_ref()
            .map(|p| p.id.as_str()),
        Some(accepted.pairing_id.as_str()),
        "the returned epoch must already be durable before Flow can use it"
    );

    // The whitelist row is real — the same client is now authorized.
    let device = db
        .get_device(&ctp.node_id().0)
        .await
        .unwrap()
        .expect("device row written");
    assert_eq!(device.profile.name, "妈妈的手机");
    assert_eq!(device.pairing.expect("paired").role, Role::Member);

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
        response.pairing_id.as_deref(),
        Some(accepted.pairing_id.as_str())
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
    assert_eq!(err.code(), codes::NOT_AUTHORIZED);
    assert_eq!(err.reason(), &proto::Reason::PairTokenInvalid);
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
    assert_eq!(err.code(), codes::NOT_AUTHORIZED);
    assert_eq!(err.reason(), &proto::Reason::PairTokenInvalid);
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
    assert_eq!(err.code(), codes::NOT_AUTHORIZED);
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
    let old_id = db.active_pairing(&ctp.node_id().0).expect("paired").id;
    // DEV-02: 水位挂在配对记录上。#1117：撤销 = 配对记录物理删除，旧 id 下的
    // 水位随之级联删除（不再是「同一身份回来接着用旧水位」）；回来的是新配对，
    // 拿新 id，从零开始记账——档案（名字、首次出现）才是跨配对保留的东西。
    db.set_watermark(&old_id, 300, now()).await.unwrap();
    let first_seen = db
        .get_device(&ctp.node_id().0)
        .await
        .unwrap()
        .unwrap()
        .profile
        .first_seen_at;
    assert!(db
        .remove_pairing(
            &ctp.node_id().0,
            None,
            storage::DepartedBy::Owner,
            1_700_000_000_000
        )
        .await
        .unwrap()
        .is_some());
    let gone = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert!(gone.pairing.is_none());
    assert_eq!(gone.profile.departed_by, Some(storage::DepartedBy::Owner));
    assert_eq!(
        db.get_watermark(&old_id).await.unwrap(),
        None,
        "旧配对记录的水位随记录级联删除"
    );

    // A fresh owner-issued token lets the SAME identity rejoin…
    let qr2 = pairing.start([0x51; 12], now());
    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr2), "家人手机").await;
    assert!(
        resp.ok,
        "mistakenly removed devices must be able to rejoin: {resp:?}"
    );
    let d = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    let new_pairing = d.pairing.expect("owner confirmation reinstates the device");
    assert_ne!(new_pairing.id, old_id, "重新配对拿新 id");
    assert_eq!(d.profile.departed_by, None);

    // DEV-02 的正面证据：一对密钥 = 一台设备。同一个 NodeId 重新配对
    // **不得**生出第二份档案，且复用原档案。
    let all = db.list_devices().await.unwrap();
    assert_eq!(all.len(), 1, "同一个 NodeId 不得生出第二行：{all:?}");
    assert_eq!(d.profile.first_seen_at, first_seen, "复用同一份档案");
    assert_eq!(
        db.get_watermark(&new_pairing.id).await.unwrap(),
        None,
        "新配对从零记账，旧 id 的水位不被继承",
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
async fn unpair_removes_pairing_and_data_is_denied_then_fresh_token_rejoins() {
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
    let first_id = db.active_pairing(&ctp.node_id().0).expect("paired").id;

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
    assert!(
        d.pairing.is_none(),
        "pairing record must be gone after unpair"
    );
    assert_eq!(d.profile.departed_by, Some(storage::DepartedBy::Device));

    // #1117: 没有配对记录 ⇒ 数据方法被拒（NotPaired；桌面不再发 Revoked）。
    // hello 只剩能力握手：不带 pairing_id。
    let denied = send_method(
        &ctp,
        dtp.node_id(),
        methods::TIMELINE_PAGE,
        serde_json::json!({}),
    )
    .await;
    let err = denied.error.expect("unpaired device must be denied");
    assert_eq!(err.code(), codes::NOT_AUTHORIZED);
    assert_eq!(err.reason(), &proto::Reason::NotPaired);
    let hello = send_method(&ctp, dtp.node_id(), methods::HELLO, serde_json::json!({})).await;
    assert!(hello.ok, "{hello:?}");
    let hello: proto::Hello = serde_json::from_value(hello.result.unwrap()).unwrap();
    assert_eq!(hello.pairing_id, None);

    // …but a fresh owner-issued token lets the SAME identity rejoin.
    let qr2 = pairing.start([0x61; 12], now());
    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr2), "要断开的手机").await;
    assert!(
        resp.ok,
        "unpaired device must rejoin with fresh token: {resp:?}"
    );
    let d = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    let second = d.pairing.expect("paired again");
    assert_ne!(second.id, first_id, "rejoin gets a fresh pairing id");
    assert_eq!(d.profile.departed_by, None);

    // Audit names the self-revocation.
    let audit = db.list_audit(20).await.unwrap();
    assert!(audit.iter().any(|r| r.entry.kind == "device.unpaired"));
}

/// #565：断开通知带着它要结束的配对纪元。同一台手机重新配对后，迟到的旧通知
/// 不许把新配对吊销（条件更新）；带当前纪元的通知照常吊销。
/// 反证：handler 忽略 `pairing_id`、总是无条件删除配对记录 ⇒ 第一段的「当前配对仍在」红。
#[tokio::test(flavor = "multi_thread")]
async fn unpair_only_ends_the_pairing_id_it_names() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr, pairing) = start_daemon(db.clone(), true).await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    let qr = pairing.start([0x62; 12], now());
    assert!(
        send_pair(&ctp, dtp.node_id(), &token_of(&qr), "重新配对的手机")
            .await
            .ok
    );
    let current = db
        .active_pairing(&ctp.node_id().0)
        .expect("an approved pairing has an id")
        .id;

    // 迟到的旧通知（上一次配对的纪元）：答 ok，但什么都不吊销。
    let stale = send_method(
        &ctp,
        dtp.node_id(),
        methods::DEVICE_UNPAIR,
        serde_json::json!({ "pairing_id": "an-earlier-pairing" }),
    )
    .await;
    assert!(
        stale.ok,
        "a stale notice is answered (that pairing is already over): {stale:?}"
    );
    assert_eq!(stale.result.unwrap()["unpaired"], false);
    let still = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert_eq!(
        still.pairing.as_ref().map(|p| p.id.as_str()),
        Some(current.as_str()),
        "a stale unpair notice must not remove the current pairing"
    );
    assert_eq!(still.profile.departed_by, None);

    // 带当前纪元：照常吊销。
    let resp = send_method(
        &ctp,
        dtp.node_id(),
        methods::DEVICE_UNPAIR,
        serde_json::json!({ "pairing_id": current }),
    )
    .await;
    assert!(resp.ok, "{resp:?}");
    assert_eq!(resp.result.unwrap()["unpaired"], true);
    let ended = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert!(ended.pairing.is_none());
    assert_eq!(ended.profile.departed_by, Some(storage::DepartedBy::Device));
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
    assert_eq!(resp.error.unwrap().code(), codes::NOT_AUTHORIZED);
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
    let (pairing, mut pending) = Pairing::new(db.clone(), tp.node_id(), None);
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
    assert_eq!(resp.error.unwrap().code(), codes::NOT_AUTHORIZED);
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
        db.active_pairing(&ctp.node_id().0).is_none(),
        "no epoch rotation for a request nobody approved"
    );

    // 验收标准 4 for the DENY path (简报六: denied shares the same bug):
    // the no-verdict ending lands at the expiry moment, not the request
    // moment. #552: that ending is `pair.expired` (it used to share
    // `pair.denied` with the owner's No).
    let audit = db.list_audit(20).await.unwrap();
    let requested = audit
        .iter()
        .find(|r| r.entry.kind == "pair.requested")
        .expect("pair.requested recorded")
        .entry
        .ts;
    let denied = audit
        .iter()
        .find(|r| r.entry.kind == "pair.expired")
        .expect("pair.expired recorded")
        .entry
        .ts;
    assert!(
        !audit.iter().any(|r| r.entry.kind == "pair.denied"),
        "a timeout is not the owner's No"
    );
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
    let (pairing, mut pending) = Pairing::new(db.clone(), tp.node_id(), None);
    tokio::spawn(async move {
        while let Some(req) = pending.recv().await {
            tokio::time::sleep(std::time::Duration::from_millis(owner_delay_ms)).await;
            let _ = req.decide(common::allow());
        }
    });
    let router = Router::new(db, "客厅的电脑").with_pairing(pairing.clone());
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr, pairing)
}
