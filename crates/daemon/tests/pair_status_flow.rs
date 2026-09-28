//! NET-10 (#128): pairing split into "submit ≠ wait for a human".
//!
//! `pair.request{ack_then_poll}` answers as soon as the request is queued;
//! the owner's verdict is read through `pair.status(request_id)`. Every
//! client RPC in this file runs under [`CONTROL_TIER`] — the same 15 s cap
//! the phone's `DaemonClient.call` puts around one whole round trip
//! (`DaemonClient.kt` `CONNECT_TIMEOUT_MS`). That cap is why the phone
//! used to fail whenever the owner took longer than ~15 s to click Allow:
//! the blocking `pair.request` could not outlive it.
//!
//! The owner side is the real `IpcServer` queue (the desktop's), driven
//! through `confirm` exactly as the IPC `pairing.confirm` method does.

use std::sync::Arc;
use std::time::Duration;

use daemon::{DiagAgg, IpcServer, Pairing, Router, PENDING_TTL_MS, TOKEN_TTL_MS};
use proto::{
    codes, methods, PairRequest, PairStatusReply, PairStatusRequest, PairSubmitted, Req, Resp,
};
use storage::Db;
use transport::{IrohTransport, Transport, TransportConfig};

/// The phone's control-tier cap on one RPC round trip.
const CONTROL_TIER: Duration = Duration::from_secs(15);

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap()
}

struct Desk {
    tp: IrohTransport,
    addr: transport::PeerAddr,
    pairing: Pairing,
    ipc: Arc<IpcServer>,
    db: Db,
    _dir: tempfile::TempDir,
}

/// Daemon = Router (network side) + IpcServer (owner queue), sharing one
/// `Pairing`, like `main.rs` wires them. `ttl_ms` overrides both pending
/// TTL seams (None = production value).
async fn desk(db: Db, ttl_ms: Option<i64>) -> Desk {
    let dir = tempfile::tempdir().unwrap();
    let tp = endpoint().await;
    let addr = tp.local_addr();
    let (bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), tp.node_id(), None, None);
    let mut pairing = pairing.with_events(bus.clone());
    if let Some(ttl) = ttl_ms {
        pairing = pairing.with_pending_ttl(ttl);
    }
    let mut ipc = IpcServer::new(
        db.clone(),
        pairing.clone(),
        DiagAgg::new(db.clone()),
        dir.path().to_path_buf(),
        pending_rx,
        bus,
    );
    if let Some(ttl) = ttl_ms {
        ipc.set_pending_ttl_for_test(ttl);
    }
    let router = Router::new(db.clone(), "客厅的电脑").with_pairing(pairing.clone());
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    Desk {
        tp,
        addr,
        pairing,
        ipc: Arc::new(ipc),
        db,
        _dir: dir,
    }
}

async fn phone(d: &Desk) -> IrohTransport {
    let ctp = endpoint().await;
    ctp.add_peer(d.addr.clone());
    ctp
}

/// One RPC under the phone's control-tier cap. Panics (= red) when the
/// daemon holds the stream open longer than the cap.
async fn rpc(
    ctp: &IrohTransport,
    daemon: transport::NodeId,
    method: &str,
    params: serde_json::Value,
) -> Resp {
    tokio::time::timeout(CONTROL_TIER, async {
        let mut stream = ctp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
        let req = Req {
            id: format!("net10-{method}"),
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
    })
    .await
    .unwrap_or_else(|_| {
        panic!("{method}: no answer within the phone's {CONTROL_TIER:?} control-tier cap")
    })
}

fn token_of(qr: &str) -> String {
    qr.rsplit("&t=").next().unwrap().to_string()
}

async fn submit(ctp: &IrohTransport, d: &Desk, token: &str, name: &str) -> Resp {
    rpc(
        ctp,
        d.tp.node_id(),
        methods::PAIR_REQUEST,
        serde_json::to_value(PairRequest {
            token: token.into(),
            device_name: name.into(),
            ack_then_poll: true,
            ..Default::default()
        })
        .unwrap(),
    )
    .await
}

fn submitted(resp: Resp) -> PairSubmitted {
    assert!(resp.ok, "submit must be accepted at once: {resp:?}");
    let s: PairSubmitted = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(s.accepted);
    assert!(!s.request_id.is_empty(), "{s:?}");
    s
}

async fn status(ctp: &IrohTransport, d: &Desk, request_id: &str) -> PairStatusReply {
    let resp = rpc(
        ctp,
        d.tp.node_id(),
        methods::PAIR_STATUS,
        serde_json::to_value(PairStatusRequest {
            request_id: request_id.into(),
        })
        .unwrap(),
    )
    .await;
    assert!(resp.ok, "pair.status must answer ok: {resp:?}");
    serde_json::from_value(resp.result.unwrap()).unwrap()
}

/// Poll until the state leaves `pending`; returns (final reply, pending polls seen).
async fn poll_until_settled(
    ctp: &IrohTransport,
    d: &Desk,
    request_id: &str,
    every: Duration,
    max: Duration,
) -> (PairStatusReply, usize) {
    let started = std::time::Instant::now();
    let mut pending_seen = 0;
    loop {
        let r = status(ctp, d, request_id).await;
        if r.state != "pending" {
            return (r, pending_seen);
        }
        pending_seen += 1;
        assert!(started.elapsed() < max, "still pending after {max:?}");
        tokio::time::sleep(every).await;
    }
}

async fn wait_queue(ipc: &IpcServer, want: usize) {
    for _ in 0..500 {
        if ipc.pending_names().len() == want {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!(
        "owner queue never reached {want}: {:?}",
        ipc.pending_names()
    );
}

/// 验收 RED：主人 20 s 后才点 Allow。新形状手机状态机：submit 秒回 →
/// status 轮询经过 pending → accepted（含 PairAccepted 载荷）。
/// 改前：pair.request 忽略 ack_then_poll，同步挂到主人点击（20 s），
/// 在 15 s 控制档处变红。
#[tokio::test(flavor = "multi_thread")]
async fn owner_clicks_allow_after_20s_and_phone_reaches_accepted_via_status() {
    let d = desk(Db::open_in_memory().await.unwrap(), None).await;
    let ctp = phone(&d).await;
    let qr = d.pairing.start([0x10; 12], now());

    let t0 = std::time::Instant::now();
    let s = submitted(submit(&ctp, &d, &token_of(&qr), "慢慢等主人的手机").await);
    assert!(
        t0.elapsed() < Duration::from_secs(5),
        "受理即回，不许等人: {:?}",
        t0.elapsed()
    );
    assert_eq!(
        s.ttl_ms, PENDING_TTL_MS,
        "phone deadline comes from the daemon"
    );
    assert_eq!(
        PENDING_TTL_MS, TOKEN_TTL_MS,
        "单一来源：pending 上限 = token TTL"
    );

    wait_queue(&d.ipc, 1).await;
    let ipc = Arc::clone(&d.ipc);
    let phone_id = ctp.node_id().0;
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(20)).await;
        let _ = ipc.confirm(Some(&phone_id), None, true);
    });

    let (r, pending_seen) = poll_until_settled(
        &ctp,
        &d,
        &s.request_id,
        Duration::from_secs(1),
        Duration::from_secs(40),
    )
    .await;
    assert_eq!(r.state, "accepted", "{r:?}");
    assert!(
        pending_seen >= 10,
        "the wait must be spent in pending polls: {pending_seen}"
    );
    let accepted = r.accepted.clone().expect("accepted carries PairAccepted");
    assert_eq!(accepted.storage_device_name, "客厅的电脑");
    assert_eq!(
        d.db.pairing_epoch(&ctp.node_id().0)
            .await
            .unwrap()
            .as_deref(),
        Some(accepted.pairing_epoch.as_str()),
        "the replayed epoch is the durable one"
    );

    // 幂等重放：accepted 之后重复查询，同一载荷（此时调用方已是 member）。
    for _ in 0..2 {
        assert_eq!(status(&ctp, &d, &s.request_id).await, r);
    }
    assert!(d.db.get_device(&ctp.node_id().0).await.unwrap().is_some());
}

/// 去重：同一手机拿同一 token 重发 → 同一个 request_id，主人队列仍是一行，
/// 第一次提交不会被顶成 expired；换一台设备拿同一 token → 立即拒绝。
#[tokio::test(flavor = "multi_thread")]
async fn resubmitting_the_same_token_reuses_the_request_and_the_queue_stays_one_row() {
    let d = desk(Db::open_in_memory().await.unwrap(), None).await;
    let ctp = phone(&d).await;
    let qr = d.pairing.start([0x11; 12], now());
    let token = token_of(&qr);

    let first = submitted(submit(&ctp, &d, &token, "重发的手机").await);
    wait_queue(&d.ipc, 1).await;
    let again = submitted(submit(&ctp, &d, &token, "重发的手机").await);
    assert_eq!(
        again.request_id, first.request_id,
        "同 token 同手机 = 同一个请求"
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        d.ipc.pending_names().len(),
        1,
        "不堆重复 pending: {:?}",
        d.ipc.pending_names()
    );
    assert_eq!(status(&ctp, &d, &first.request_id).await.state, "pending");

    let stranger = phone(&d).await;
    let replay = submit(&stranger, &d, &token, "重放者").await;
    assert_eq!(
        replay.error.expect("replay rejected").code,
        codes::NOT_AUTHORIZED
    );
    assert_eq!(d.ipc.pending_names().len(), 1);

    assert!(matches!(
        d.ipc.confirm(Some(&ctp.node_id().0), None, true),
        daemon::ConfirmOutcome::Decided(_)
    ));
    let (r, _) = poll_until_settled(
        &ctp,
        &d,
        &first.request_id,
        Duration::from_millis(50),
        Duration::from_secs(5),
    )
    .await;
    assert_eq!(r.state, "accepted");
}

/// authz 口径：request_id 只对提交它的 NodeId 可见；别人查 = not_found，
/// accepted 之后也不泄露 PairAccepted（带 pairing_epoch）。
#[tokio::test(flavor = "multi_thread")]
async fn status_is_visible_only_to_the_submitting_device() {
    let d = desk(Db::open_in_memory().await.unwrap(), None).await;
    let ctp = phone(&d).await;
    let other = phone(&d).await;
    let qr = d.pairing.start([0x12; 12], now());
    let s = submitted(submit(&ctp, &d, &token_of(&qr), "本人").await);

    assert_eq!(status(&other, &d, &s.request_id).await.state, "not_found");
    wait_queue(&d.ipc, 1).await;
    d.ipc.confirm(Some(&ctp.node_id().0), None, true);
    let (mine, _) = poll_until_settled(
        &ctp,
        &d,
        &s.request_id,
        Duration::from_millis(50),
        Duration::from_secs(5),
    )
    .await;
    assert_eq!(mine.state, "accepted");
    let theirs = status(&other, &d, &s.request_id).await;
    assert_eq!(theirs.state, "not_found", "{theirs:?}");
    assert!(theirs.accepted.is_none());
}

/// 死因：主人点拒绝 → status 立刻 denied（带拒绝码），不写设备行。
#[tokio::test(flavor = "multi_thread")]
async fn owner_deny_surfaces_as_denied_with_a_reason_key() {
    let d = desk(Db::open_in_memory().await.unwrap(), None).await;
    let ctp = phone(&d).await;
    let qr = d.pairing.start([0x13; 12], now());
    let s = submitted(submit(&ctp, &d, &token_of(&qr), "被拒的手机").await);
    wait_queue(&d.ipc, 1).await;
    d.ipc.confirm(Some(&ctp.node_id().0), None, false);
    let (r, _) = poll_until_settled(
        &ctp,
        &d,
        &s.request_id,
        Duration::from_millis(50),
        Duration::from_secs(5),
    )
    .await;
    assert_eq!(r.state, "denied");
    assert_eq!(r.msg_key.as_deref(), Some(diag::keys::ERR_NOT_AUTHORIZED));
    assert!(r.accepted.is_none());
    assert!(d.db.get_device(&ctp.node_id().0).await.unwrap().is_none());
}

/// 死因：主人一直不点 → pending TTL 到 → expired（不是 denied），不写库。
#[tokio::test(flavor = "multi_thread")]
async fn owner_never_clicks_surfaces_as_expired() {
    let d = desk(Db::open_in_memory().await.unwrap(), Some(300)).await;
    let ctp = phone(&d).await;
    let qr = d.pairing.start([0x14; 12], now());
    let s = submitted(submit(&ctp, &d, &token_of(&qr), "没人理的手机").await);
    assert_eq!(s.ttl_ms, 300);
    let (r, _) = poll_until_settled(
        &ctp,
        &d,
        &s.request_id,
        Duration::from_millis(50),
        Duration::from_secs(5),
    )
    .await;
    assert_eq!(r.state, "expired", "{r:?}");
    assert!(d.db.get_device(&ctp.node_id().0).await.unwrap().is_none());
    assert!(d
        .db
        .pairing_epoch(&ctp.node_id().0)
        .await
        .unwrap()
        .is_none());
}

/// 死因：daemon 重启 → 内存账本没了 → not_found（手机据此提示重新生成配对码）。
#[tokio::test(flavor = "multi_thread")]
async fn daemon_restart_loses_the_ledger_and_status_says_not_found() {
    let db = Db::open_in_memory().await.unwrap();
    let before = desk(db.clone(), None).await;
    let ctp = phone(&before).await;
    let qr = before.pairing.start([0x15; 12], now());
    let s = submitted(submit(&ctp, &before, &token_of(&qr), "赶上重启的手机").await);
    assert_eq!(status(&ctp, &before, &s.request_id).await.state, "pending");

    // "Restart": a fresh Pairing/Router/IpcServer over the same database.
    let after = desk(db, None).await;
    let ctp2 = phone(&after).await;
    let r = status(&ctp2, &after, &s.request_id).await;
    assert_eq!(r.state, "not_found", "{r:?}");
}

/// token 无效 → 立即明确拒绝，不进队列。
#[tokio::test(flavor = "multi_thread")]
async fn bad_token_is_refused_at_once() {
    let d = desk(Db::open_in_memory().await.unwrap(), None).await;
    let ctp = phone(&d).await;
    let t0 = std::time::Instant::now();
    let resp = submit(&ctp, &d, &"ee".repeat(12), "拿错码的手机").await;
    assert_eq!(resp.error.expect("refused").code, codes::NOT_AUTHORIZED);
    assert!(t0.elapsed() < Duration::from_secs(5));
    assert!(d.ipc.pending_names().is_empty());
}

/// 被移除过的设备（revoked）重新配对：轮询期间它仍是 revoked，pair.status
/// 必须对它放行；批准后它恢复为 member，重复查询仍放行。
#[tokio::test(flavor = "multi_thread")]
async fn revoked_device_can_poll_its_own_rejoin() {
    let d = desk(Db::open_in_memory().await.unwrap(), None).await;
    let ctp = phone(&d).await;
    let qr = d.pairing.start([0x16; 12], now());
    let s = submitted(submit(&ctp, &d, &token_of(&qr), "回来的手机").await);
    wait_queue(&d.ipc, 1).await;
    d.ipc.confirm(Some(&ctp.node_id().0), None, true);
    let (r, _) = poll_until_settled(
        &ctp,
        &d,
        &s.request_id,
        Duration::from_millis(50),
        Duration::from_secs(5),
    )
    .await;
    assert_eq!(r.state, "accepted");

    d.db.revoke(&ctp.node_id().0, storage::RevokedBy::Owner, now())
        .await
        .unwrap();
    let qr2 = d.pairing.start([0x17; 12], now());
    let s2 = submitted(submit(&ctp, &d, &token_of(&qr2), "回来的手机").await);
    assert_eq!(status(&ctp, &d, &s2.request_id).await.state, "pending");
    wait_queue(&d.ipc, 1).await;
    d.ipc.confirm(Some(&ctp.node_id().0), None, true);
    let (r2, _) = poll_until_settled(
        &ctp,
        &d,
        &s2.request_id,
        Duration::from_millis(50),
        Duration::from_secs(5),
    )
    .await;
    assert_eq!(r2.state, "accepted");
    assert!(
        !d.db
            .get_device(&ctp.node_id().0)
            .await
            .unwrap()
            .unwrap()
            .revoked
    );
}

/// 新手机据 hello 能力判断桌面是否认识 pair.status（旧桌面没有这个能力 →
/// 手机明确报「桌面版本过旧」）。未配对节点的 hello 也要带上它。
#[tokio::test(flavor = "multi_thread")]
async fn hello_advertises_the_pair_status_capability_to_unpaired_peers() {
    let d = desk(Db::open_in_memory().await.unwrap(), None).await;
    let ctp = phone(&d).await;
    let resp = rpc(&ctp, d.tp.node_id(), methods::HELLO, serde_json::json!({})).await;
    let hello: proto::Hello = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(
        hello.capabilities.iter().any(|c| c == "pair.status.v1"),
        "{:?}",
        hello.capabilities
    );
}
