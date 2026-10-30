//! #1269：配对窗口里，持有二维码令牌的手机不被其他连接挤掉。
//!
//! 真 daemon（Router + 准入钩子 + 窗口复核，与 main 同样接线）+ 真 iroh 端点。攻击方是
//! 一组身份各不相同、手里没有令牌的连接：占满还没出示令牌的那 8 个名额，并在各自连接上
//! 不停发请求，把未配对对端共用的那份额度一直打空。
//!
//! 攻击方被断开后不再回来：连接被挤掉后立即重连、反复互相挤，这种情况下手机第一条
//! 请求能否赶在被挤掉之前送到，取决于时序，令牌之外没有可区分的东西，本文件不覆盖。

mod common;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use daemon::{Pairing, Router};
use proto::{methods, PairRequest, PairStatusRequest, PairSubmitted, Req, Resp};
use storage::Db;
use transport::{ConnInfo, IrohTransport, NodeId, PeerAddr, Transport, TransportConfig, ALPN_CTRL};

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![ALPN_CTRL.into()]))
        .await
        .unwrap()
}

struct Desk {
    node: NodeId,
    addr: PeerAddr,
    pairing: Pairing,
    _tp: IrohTransport,
    _pending: tokio::sync::mpsc::UnboundedReceiver<daemon::PendingPair>,
}

/// 与 main 一样：准入钩子 + 窗口复核。`unproven_ttl` 是还没出示令牌的连接的存活期。
async fn desk(unproven_ttl: Duration) -> Desk {
    let db = Db::open_in_memory().await.unwrap();
    let tp = endpoint().await;
    let (pairing, pending) = Pairing::new(db.clone(), tp.node_id(), None);
    tp.set_admission(daemon::admission::predicate(
        db.clone(),
        pairing.clone(),
        now,
    ));
    let router = Router::new(db, "客厅的电脑")
        .with_pairing(pairing.clone())
        .with_window_enforced()
        .with_unproven_ttl(unproven_ttl);
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    Desk {
        node: tp.node_id(),
        addr: tp.local_addr(),
        pairing,
        _tp: tp,
        _pending: pending,
    }
}

async fn client(d: &Desk) -> IrohTransport {
    let tp = endpoint().await;
    tp.add_peer(d.addr.clone());
    tp
}

/// 一次请求。手机每个请求单独建一条连接（Android `DaemonClient.call`、iOS #963）：`fresh`
/// 时先关掉缓存的连接再拨。连不上、流被丢弃或超时都返回 `None`。
async fn call(
    tp: &IrohTransport,
    daemon: NodeId,
    method: &str,
    params: serde_json::Value,
    fresh: bool,
) -> Option<Resp> {
    if fresh {
        tp.close_peer(daemon);
    }
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut stream = tp.connect(daemon, ALPN_CTRL).await.ok()?;
        let req = Req {
            id: format!("p-{method}"),
            method: method.into(),
            params,
            ..Default::default()
        };
        stream
            .send_frame(&proto::codec::encode(&req).unwrap())
            .await
            .ok()?;
        stream.finish().ok()?;
        let frame = stream.recv_frame().await.ok()??;
        proto::codec::decode::<Resp>(&frame).ok()
    })
    .await
    .ok()?
}

/// 攻击方：在自己那条连接上不停发 `hello`；连接被 daemon 断开后就不再回来。
fn flood(
    tp: IrohTransport,
    daemon: NodeId,
    stop: Arc<AtomicBool>,
    sent: Arc<AtomicUsize>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut connected = false;
        while !stop.load(Ordering::SeqCst) {
            if connected && tp.conn_info(daemon) == ConnInfo::NONE {
                return;
            }
            let Ok(mut stream) = tp.connect(daemon, ALPN_CTRL).await else {
                return;
            };
            connected = true;
            let req = Req {
                id: "flood".into(),
                method: methods::HELLO.into(),
                ..Default::default()
            };
            if stream
                .send_frame(&proto::codec::encode(&req).unwrap())
                .await
                .is_err()
            {
                continue;
            }
            let _ = stream.finish();
            let _ = stream.recv_frame().await;
            sent.fetch_add(1, Ordering::SeqCst);
        }
    })
}

fn pair_request(token: &str, phone: NodeId, desk: NodeId) -> serde_json::Value {
    let (req, _start) = common::with_pake(
        &PairRequest {
            token: token.into(),
            device_name: "我的手机".into(),
            role: "member".into(),
            ack_then_poll: true,
            ..Default::default()
        },
        phone,
        desk,
    );
    serde_json::to_value(req).unwrap()
}

/// 一波攻击方：`UNPAIRED_CONN_MAX` 个各不相同的身份同时开打，直到它们合计发出 `n` 个请求
/// （名额占满、总额度（突发 40）早已打空）。
async fn wave(d: &Desk, stop: &Arc<AtomicBool>, n: usize) -> Vec<tokio::task::JoinHandle<()>> {
    let sent = Arc::new(AtomicUsize::new(0));
    let mut attackers = Vec::new();
    for _ in 0..daemon::frame_limits::UNPAIRED_CONN_MAX {
        let tp = client(d).await;
        attackers.push(flood(tp, d.node, stop.clone(), sent.clone()));
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while sent.load(Ordering::SeqCst) < n {
        assert!(
            tokio::time::Instant::now() < deadline,
            "攻击方没跑起来：{}",
            sent.load(Ordering::SeqCst)
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    attackers
}

/// #1269 完成标准：多个身份各不相同、不持令牌的连接占满名额并持续发请求时，持令牌的手机
/// 仍能完成 `pair.request`，之后的 `pair.status` 也不被限速。
///
/// 手机提交后令牌用掉、窗口关闭，第一波攻击方随即被收回（#1149）；`pair.status` 要在
/// 窗口重新打开（业主接着给下一台手机显示二维码）、第二波攻击方又占满打空时仍然畅通。
///
/// 反证（各自单独改坏，本条都变红）：
/// - 名额满了改成拒绝新来的（`UnprovenConns::admit` 不淘汰最早来的）：手机连不进来；
/// - 去掉令牌通道（`Router::serve_stream` 里总额度打空时不再看令牌）：`pair.request` 被丢；
/// - 去掉预留通道（`Router::holds_ticket` 恒为 false）：`pair.status` 和第二波抢那份打空的额度。
#[tokio::test(flavor = "multi_thread")]
async fn ticket_holding_phone_pairs_while_strangers_fill_the_slots_and_drain_the_budget() {
    // 存活期放长：本条钉的是名额与额度；存活期有自己的测试。
    let d = desk(Duration::from_secs(60)).await;
    let qr = d.pairing.start([0x26; 12], now());
    let token = qr.split("&t=").nth(1).unwrap().split('&').next().unwrap();

    let stop = Arc::new(AtomicBool::new(false));
    let _first = wave(&d, &stop, 400).await;

    let phone = client(&d).await;
    let submit = call(
        &phone,
        d.node,
        methods::PAIR_REQUEST,
        pair_request(token, phone.node_id(), d.node),
        true,
    )
    .await;
    let submit = submit.expect("持令牌的手机的 pair.request 必须送到并得到回复");
    assert!(submit.ok, "pair.request: {submit:?}");
    let submitted: PairSubmitted = serde_json::from_value(submit.result.unwrap()).unwrap();

    // 业主接着给下一台手机显示二维码：窗口重新打开，第二波攻击方占满名额、打空额度。
    d.pairing.start([0x29; 12], now());
    let second = wave(&d, &stop, 400).await;

    // 输入核对码期间手机轮询 pair.status：每次一条新连接。
    for i in 0..20 {
        let status = call(
            &phone,
            d.node,
            methods::PAIR_STATUS,
            serde_json::to_value(PairStatusRequest {
                request_id: submitted.request_id.clone(),
            })
            .unwrap(),
            true,
        )
        .await;
        assert!(
            status.as_ref().is_some_and(|r| r.ok),
            "第 {i} 次 pair.status 被挡：{status:?}"
        );
    }
    assert!(
        second.iter().any(|a| !a.is_finished()),
        "第二波全程都在（否则额度没被打空，本条不说明问题）"
    );
    stop.store(true, Ordering::SeqCst);
}

/// #1269：还没出示令牌的连接，存活期一到就被断开。
/// 反证：去掉 `Router::serve_conn` 里的存活期分支，连接一直开着，本条变红。
#[tokio::test(flavor = "multi_thread")]
async fn connection_without_a_token_is_closed_when_its_lifetime_ends() {
    let d = desk(Duration::from_millis(300)).await;
    d.pairing.start([0x27; 12], now());
    let stranger = client(&d).await;
    let hello = call(
        &stranger,
        d.node,
        methods::HELLO,
        serde_json::Value::Null,
        false,
    )
    .await;
    assert!(hello.is_some_and(|r| r.ok), "窗口开着时可以 hello");
    assert_ne!(stranger.conn_info(d.node), ConnInfo::NONE);

    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(
        stranger.conn_info(d.node),
        ConnInfo::NONE,
        "存活期过了，连接被断开"
    );
}

/// #1269：`pair.request` 的令牌不对，回复照常送达（手机能显示原因），随后整条连接被断开。
/// 反证：去掉 `StreamEnd::CloseConnection` 那一支，连接一直开着，本条变红。
#[tokio::test(flavor = "multi_thread")]
async fn wrong_token_reply_arrives_then_the_connection_is_closed() {
    let d = desk(Duration::from_secs(60)).await;
    d.pairing.start([0x28; 12], now());
    let stranger = client(&d).await;
    let wrong = "00".repeat(12);
    let reply = call(
        &stranger,
        d.node,
        methods::PAIR_REQUEST,
        pair_request(&wrong, stranger.node_id(), d.node),
        false,
    )
    .await
    .expect("拒绝的原因必须送达");
    assert_eq!(
        reply.error.as_ref().map(|e| e.reason()),
        Some(&proto::Reason::PairTokenInvalid)
    );

    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while stranger.conn_info(d.node) != ConnInfo::NONE {
        assert!(
            tokio::time::Instant::now() < deadline,
            "令牌不对，连接应被断开"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
