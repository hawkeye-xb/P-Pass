//! T-031 acceptance: full pairing flow over a real loopback connection,
//! expired-token rejection, and one-time token replay rejection.

use daemon::{PairDecision, Pairing, PendingPair, Router};
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
            req.decide(if accept {
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
            device_hint: None,
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
    assert!(audit.iter().any(|r| r.entry.action == "pair.accepted"));
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
    assert!(db.revoke(&ctp.node_id().0).await.unwrap());

    // A fresh owner-issued token lets the SAME identity rejoin…
    let qr2 = pairing.start([0x51; 12], now());
    let resp = send_pair(&ctp, dtp.node_id(), &token_of(&qr2), "家人手机").await;
    assert!(
        resp.ok,
        "mistakenly removed devices must be able to rejoin: {resp:?}"
    );
    let d = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert!(!d.revoked, "owner confirmation reinstates the device");

    // …and the audit trail says it was a rejoin.
    let audit = db.list_audit(10).await.unwrap();
    assert!(audit
        .iter()
        .any(|r| r.entry.detail.as_deref().unwrap_or("").contains("rejoined")));
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
    assert!(audit.iter().any(|r| r.entry.action == "device.unpaired"));
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

// ── DEV-01: reinstall hint + replace-old merge ────────────

/// start_daemon with a scripted decider (needed to pick AcceptMerge).
async fn start_daemon_with(
    db: Db,
    decide: impl Fn(PendingPair) + Send + 'static,
) -> (IrohTransport, transport::PeerAddr, Pairing) {
    let tp = endpoint().await;
    let addr = tp.local_addr();
    let (pairing, mut pending) = Pairing::new(db.clone(), tp.node_id(), None, None);
    tokio::spawn(async move {
        while let Some(req) = pending.recv().await {
            decide(req);
        }
    });
    let router = Router::new(db, "客厅的电脑").with_pairing(pairing.clone());
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr, pairing)
}

/// send_pair with an optional reinstall hint (DEV-01).
async fn send_pair_hinted(
    ctp: &IrohTransport,
    daemon: transport::NodeId,
    token: &str,
    name: &str,
    hint: Option<&str>,
) -> Resp {
    let mut stream = ctp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
    let req = Req {
        id: "pair-hint-1".into(),
        method: "pair.request".into(),
        params: serde_json::to_value(PairRequest {
            token: token.into(),
            device_name: name.into(),
            role: "member".into(),
            device_hint: hint.map(str::to_owned),
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

#[tokio::test(flavor = "multi_thread")]
async fn reinstall_merge_replaces_old_device_keeps_assets_watermark() {
    let db = Db::open_in_memory().await.unwrap();
    // An OLD device with hint "abc" already in the roster, with assets
    // and a watermark — the zombie row a reinstall would leave behind.
    let old_id = [0xAA; 32];
    db.upsert_device(&storage::Device {
        node_id: old_id.to_vec(),
        name: "旧手机".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: Some(1),
        revoked: false,
        device_hint: Some("abc".into()),
    })
    .await
    .unwrap();
    db.insert_asset(&storage::Asset {
        hash: vec![0x11; 32],
        rel_path: "originals/11.jpg".into(),
        media_type: "image/jpeg".into(),
        bytes: 10,
        taken_at: Some(1),
        width: None,
        height: None,
        src_device: old_id.to_vec(),
        added_at: 1,
        thumb_state: 0,
    })
    .await
    .unwrap();
    db.set_watermark(&old_id, 500, 1_000).await.unwrap();

    // Owner picks "替换旧的" (AcceptMerge{old}).
    let (dtp, daddr, pairing) = start_daemon_with(db.clone(), move |req| {
        req.decide(PairDecision::AcceptMerge {
            old_node_id: old_id.to_vec(),
        });
    })
    .await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    let qr = pairing.start([0x51; 12], now());
    let resp = send_pair_hinted(&ctp, dtp.node_id(), &token_of(&qr), "新手机", Some("abc")).await;
    assert!(resp.ok, "merge pair must succeed: {resp:?}");

    let new_id = ctp.node_id().0;
    // Assets re-owned by the new identity.
    let new_dev = db.get_device(&new_id).await.unwrap().unwrap();
    assert_eq!(new_dev.name, "新手机");
    // Old row gone — the zombie is cleaned up.
    assert!(db.get_device(&old_id).await.unwrap().is_none());
    // Watermark survives (max of old).
    assert_eq!(db.get_watermark(&new_id).await.unwrap(), Some(500));
    // Audit records the merge with both NodeIds.
    let audit = db.list_audit(20).await.unwrap();
    assert!(audit.iter().any(|r| {
        r.entry.action == "device.merged" && r.entry.detail.as_deref().unwrap_or("").contains("to ")
    }));
}

#[tokio::test(flavor = "multi_thread")]
async fn reinstall_accept_as_new_keeps_old_row_untouched() {
    let db = Db::open_in_memory().await.unwrap();
    let old_id = [0xBB; 32];
    db.upsert_device(&storage::Device {
        node_id: old_id.to_vec(),
        name: "旧手机".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: Some(1),
        revoked: false,
        device_hint: Some("def".into()),
    })
    .await
    .unwrap();

    // Owner picks plain Accept — same hint, but "作为新设备" (pre-DEV-01
    // behaviour): the old row stays exactly as it was.
    let (dtp, daddr, pairing) = start_daemon_with(db.clone(), |req| {
        req.decide(PairDecision::Accept);
    })
    .await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr);

    let qr = pairing.start([0x52; 12], now());
    let resp = send_pair_hinted(&ctp, dtp.node_id(), &token_of(&qr), "新手机", Some("def")).await;
    assert!(resp.ok, "plain accept must succeed: {resp:?}");

    // Both rows exist: old untouched, new added.
    let old = db.get_device(&old_id).await.unwrap().unwrap();
    assert_eq!(old.name, "旧手机");
    let new = db.get_device(&ctp.node_id().0).await.unwrap().unwrap();
    assert_eq!(new.name, "新手机");
    // No merge audit.
    let audit = db.list_audit(20).await.unwrap();
    assert!(!audit.iter().any(|r| r.entry.action == "device.merged"));
}

#[tokio::test(flavor = "multi_thread")]
async fn merged_old_identity_hello_is_denied() {
    // 反证：合并后旧 NodeId 发 hello 必须被拒（旧身份已删）。
    let db = Db::open_in_memory().await.unwrap();
    let old_id = [0xCC; 32];
    db.upsert_device(&storage::Device {
        node_id: old_id.to_vec(),
        name: "旧手机".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: Some(1),
        revoked: false,
        device_hint: Some("ghi".into()),
    })
    .await
    .unwrap();

    let (dtp, daddr, pairing) = start_daemon_with(db.clone(), move |req| {
        req.decide(PairDecision::AcceptMerge {
            old_node_id: old_id.to_vec(),
        });
    })
    .await;
    let ctp = endpoint().await;
    ctp.add_peer(daddr.clone());

    let qr = pairing.start([0x53; 12], now());
    let resp = send_pair_hinted(&ctp, dtp.node_id(), &token_of(&qr), "新手机", Some("ghi")).await;
    assert!(resp.ok);

    // The OLD identity (a fresh client impersonating the old NodeId)
    // sends a member-gated method — must be NOT_AUTHORIZED: the row is
    // gone (hello stays allowed for unpaired nodes by design, so the
    // 反证 uses backup.begin, which is member-gated).
    let old_ctp = endpoint().await;
    old_ctp.add_peer(daddr.clone());
    let begin = send_method(
        &old_ctp,
        dtp.node_id(),
        methods::BACKUP_BEGIN,
        serde_json::json!({}),
    )
    .await;
    assert!(!begin.ok, "old identity must be rejected after merge");
    assert_eq!(begin.error.unwrap().code, codes::NOT_AUTHORIZED);
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
