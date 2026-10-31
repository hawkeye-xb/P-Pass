//! T-030 acceptance: the authz checkpoint over a real (loopback) iroh
//! connection — unpaired NodeId gets `NOT_AUTHORIZED`, paired devices get
//! exactly their role's methods, revocation slams the door, and every
//! denial leaves a diag event.

use daemon::Router;
use proto::{codes, Req, Resp};
use storage::{Db, DepartedBy, Pairing, Role};
use transport::{IrohTransport, Transport, TransportConfig};

async fn start_daemon(db: Db) -> (IrohTransport, transport::PeerAddr) {
    let tp = IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap();
    let addr = tp.local_addr();
    let router = Router::new(db, "test-daemon");
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });
    (tp, addr)
}

async fn client() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap()
}

/// One request over a fresh stream; returns the response.
async fn call(tp: &IrohTransport, daemon: transport::NodeId, method: &str) -> Resp {
    let mut stream = tp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
    let req = Req {
        id: format!("req-{method}"),
        method: method.into(),
        params: serde_json::Value::Null,
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

async fn pair(db: &Db, node: &[u8; 32], role: Role) {
    db.accept_pairing(
        node,
        "test-device",
        &Pairing {
            id: "pairing-1".into(),
            node_id: node.to_vec(),
            role,
            paired_at: 1_700_000_000_000,
        },
    )
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn unpaired_node_gets_not_authorized() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let ctp = client().await;
    ctp.add_peer(daddr);

    let resp = call(&ctp, dtp.node_id(), "timeline.page").await;
    assert!(!resp.ok);
    let err = resp.error.expect("error payload");
    assert_eq!(err.code(), codes::NOT_AUTHORIZED);
    assert_eq!(err.reason(), &proto::Reason::NotPaired);

    // The denial is on the diagnostic record (§2.3: 记诊断事件).
    let events = db.list_diag(10).await.unwrap();
    assert!(
        events.iter().any(|e| e.kind == "authz.denied"
            && e.detail.as_deref().unwrap_or("").contains("timeline.page")),
        "denial must be recorded: {events:?}"
    );
}

/// QA-17 detector: the denial's diag event must be committed *before* the
/// error response reaches the client — the original test only asserted it
/// once, which let a send-before-record race hide under full-suite load.
/// Hammer the path and check visibility after every single call, no retry.
#[tokio::test(flavor = "multi_thread")]
async fn denial_diag_is_visible_immediately_every_time() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let ctp = client().await;
    ctp.add_peer(daddr);
    // #1122：未配对的对端共用一份请求额度，连发 300 次会被限速丢流（不回应答）。
    // 用已配对的 viewer 调它无权的方法——同样每次都写诊断、回拒绝，竞态检测不变。
    db.accept_pairing(
        &ctp.node_id().0,
        "viewer",
        &Pairing {
            id: "v".into(),
            node_id: ctp.node_id().0.to_vec(),
            role: Role::Viewer,
            paired_at: 1,
        },
    )
    .await
    .unwrap();
    let baseline = db.list_diag(1000).await.unwrap().len();

    for i in 0..300 {
        let resp = call(&ctp, dtp.node_id(), "backup.begin").await;
        assert!(!resp.ok, "iter {i}: still denied");
        let events = db.list_diag(1000).await.unwrap();
        assert_eq!(
            events.len(),
            baseline + i + 1,
            "iter {i}: denial #{n} must be committed before response {n} returns",
            n = i + 1
        );
        let newest = &events[0];
        assert!(
            newest.kind == "authz.denied"
                && newest
                    .detail
                    .as_deref()
                    .unwrap_or("")
                    .contains("backup.begin"),
            "iter {i}: newest event must be this denial: {newest:?}"
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn unpaired_node_may_still_say_hello() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db).await;
    let ctp = client().await;
    ctp.add_peer(daddr);

    let resp = call(&ctp, dtp.node_id(), "hello").await;
    assert!(resp.ok, "hello is the capability handshake: {resp:?}");
    let hello: proto::Hello = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(hello.proto_ver, proto::PROTO_VER);
    assert!(hello.capabilities.contains(&"thumbnail.v1".to_string()));
}

#[tokio::test(flavor = "multi_thread")]
async fn viewer_browses_but_backup_is_denied() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let ctp = client().await;
    ctp.add_peer(daddr);
    pair(&db, &ctp.node_id().0, Role::Viewer).await;

    // Browsing methods reach dispatch (no query engine in this harness →
    // unsupported_method, but crucially NOT an authorization denial).
    let resp = call(&ctp, dtp.node_id(), "timeline.page").await;
    let err = resp.error.expect("unimplemented for now");
    assert_eq!(err.code(), codes::INVALID_REQUEST);
    assert_eq!(err.reason(), &proto::Reason::UnsupportedMethod);

    // backup.* is cut off at the checkpoint.
    let resp = call(&ctp, dtp.node_id(), "backup.begin").await;
    let err = resp.error.expect("denied");
    assert_eq!(err.code(), codes::NOT_AUTHORIZED);
    assert_eq!(err.reason(), &proto::Reason::RoleForbidden);
}

#[tokio::test(flavor = "multi_thread")]
async fn revoked_device_is_shut_out_at_once() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let ctp = client().await;
    ctp.add_peer(daddr);
    pair(&db, &ctp.node_id().0, Role::Member).await;

    // While paired: allowed through the checkpoint.
    let resp = call(&ctp, dtp.node_id(), "hello").await;
    assert!(resp.ok);

    let before = call(&ctp, dtp.node_id(), "timeline.page").await;
    assert_ne!(
        before.error.expect("no query engine").code(),
        codes::NOT_AUTHORIZED
    );

    // 撤销 = 配对记录物理删除 → 数据方法立刻被拒。
    assert!(db
        .remove_pairing(&ctp.node_id().0, None, DepartedBy::Owner, 1_700_000_000_000)
        .await
        .unwrap()
        .is_some());
    let resp = call(&ctp, dtp.node_id(), "timeline.page").await;
    let err = resp.error.expect("denied after revocation");
    assert_eq!(err.code(), codes::NOT_AUTHORIZED);
    // #1117: 没有配对记录 ⇒ 与从未配对同一结果（桌面不再发 Reason::Revoked）。
    assert_eq!(err.reason(), &proto::Reason::NotPaired);

    // #1117: hello 对无配对记录的节点只是能力握手（不再「连 hello 都拒」），
    // 但不带 pairing_id、也不刷新 last_seen。
    let resp = call(&ctp, dtp.node_id(), "hello").await;
    assert!(resp.ok);
    let hello: proto::Hello = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(hello.pairing_id, None);
}

/// #1119：手机断开（`device.unpair`）经统一入口删配对记录后，桌面主动关掉与它的
/// 连接（iroh `Connection::close`），手机那一端很快看到连接已关；之后它重新连进来
/// 只剩配对那扇门。
/// 反证：统一入口不调 `connections`（或 Router 不注入 peer closer），手机端缓存的
/// 连接一直活着 ⇒ 等待超时变红。
#[tokio::test(flavor = "multi_thread")]
async fn unpair_closes_the_phones_connections() {
    let db = Db::open_in_memory().await.unwrap();
    let dtp = IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap();
    let closer: daemon::unpair::PeerCloser = {
        let t = dtp.clone();
        std::sync::Arc::new(move |peer| t.close_peer(peer))
    };
    let router = Router::new(db.clone(), "test-daemon").with_peer_closer(closer);
    let served = dtp.clone();
    tokio::spawn(async move { router.serve(&served).await });

    let ctp = client().await;
    ctp.add_peer(dtp.local_addr());
    let phone = ctp.node_id();
    db.accept_pairing(
        &phone.0,
        "phone",
        &Pairing {
            id: "p-1119".into(),
            node_id: phone.0.to_vec(),
            role: Role::Member,
            paired_at: 1,
        },
    )
    .await
    .unwrap();
    let hello = call(&ctp, dtp.node_id(), "hello").await;
    assert_eq!(hello.result.unwrap()["pairing_id"], "p-1119");
    assert!(
        ctp.path_of(dtp.node_id(), transport::ALPN_CTRL).is_some(),
        "手机缓存着这条连接"
    );

    let mut stream = ctp
        .connect(dtp.node_id(), transport::ALPN_CTRL)
        .await
        .unwrap();
    let req = Req {
        id: "unpair".into(),
        method: proto::msgs::methods::DEVICE_UNPAIR.into(),
        params: serde_json::json!({ "pairing_id": "p-1119" }),
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&req).unwrap())
        .await
        .unwrap();
    stream.finish().unwrap();
    let resp: Resp = proto::codec::decode(&stream.recv_frame().await.unwrap().unwrap()).unwrap();
    assert_eq!(resp.result.unwrap()["unpaired"], true);

    let mut closed = false;
    for _ in 0..100 {
        if ctp.path_of(dtp.node_id(), transport::ALPN_CTRL).is_none() {
            closed = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(closed, "桌面删了配对记录后必须主动关掉与手机的连接");
    assert!(dtp.path_of(phone, transport::ALPN_CTRL).is_none());

    // 手机重新连进来：连得上，但业务方法一律 not_paired。
    let again = call(&ctp, dtp.node_id(), "timeline.page").await;
    assert_eq!(again.error.unwrap().reason(), &proto::Reason::NotPaired);
}

/// #1119：电脑撤销（IPC `device.revoke` 走的统一入口）删完配对记录立即关掉与
/// 那台手机的连接，不依赖手机知道。
/// 反证：`unpair::release` 不调 `connections`，手机端连接一直活着 ⇒ 变红。
#[tokio::test(flavor = "multi_thread")]
async fn owner_revoke_through_the_single_entry_closes_the_phones_connections() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let ctp = client().await;
    ctp.add_peer(daddr);
    let phone = ctp.node_id();
    db.accept_pairing(
        &phone.0,
        "phone",
        &Pairing {
            id: "p-owner".into(),
            node_id: phone.0.to_vec(),
            role: Role::Member,
            paired_at: 1,
        },
    )
    .await
    .unwrap();
    assert!(call(&ctp, dtp.node_id(), "hello").await.ok);
    assert!(ctp.path_of(dtp.node_id(), transport::ALPN_CTRL).is_some());

    let closer: daemon::unpair::PeerCloser = {
        let t = dtp.clone();
        std::sync::Arc::new(move |peer| t.close_peer(peer))
    };
    let removed = daemon::unpair::remove_pairing(
        &db,
        daemon::unpair::Holders {
            connections: Some(&closer),
            ..Default::default()
        },
        phone,
        None,
        DepartedBy::Owner,
        2,
    )
    .await
    .unwrap();
    assert!(removed.is_some());

    let mut closed = false;
    for _ in 0..100 {
        if ctp.path_of(dtp.node_id(), transport::ALPN_CTRL).is_none() {
            closed = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(closed, "撤销后必须主动关掉与手机的连接");
}

/// #1122：配对入口按需开放（真实 iroh 端点 + 准入钩子）。
/// - 平时：未配对的手机连 hello 都发不出去（握手后即被拒，服务端不读请求）。
/// - 二维码显示（pairing.start）期间：放行，能 hello。
/// - 二维码关闭（pairing.stop）：立即关上。
/// - 已配对的设备任何时候都放行。
/// 反证：main 不装判据（或判据恒放行），第一段「拿不到应答」变红；`stop` 不收回
/// 令牌，最后一段变红。
#[tokio::test(flavor = "multi_thread")]
async fn the_pairing_door_opens_only_while_the_qr_code_is_shown() {
    let db = Db::open_in_memory().await.unwrap();
    let dtp = IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap();
    let (pairing, _rx) = daemon::Pairing::new(db.clone(), dtp.node_id(), None);
    dtp.set_admission(daemon::admission::predicate(
        db.clone(),
        pairing.clone(),
        || 1_000,
    ));
    // 路由与准入判据用同一个时钟（#1149：路由会复核窗口是否还开着）。
    let router = Router::new(db.clone(), "test-daemon")
        .with_pairing(pairing.clone())
        .with_window_enforced()
        .with_clock(|| 1_000);
    let served = dtp.clone();
    tokio::spawn(async move { router.serve(&served).await });

    let try_hello = |tp: IrohTransport, daemon: transport::NodeId| async move {
        tokio::time::timeout(std::time::Duration::from_secs(5), async move {
            let mut s = tp.connect(daemon, transport::ALPN_CTRL).await.ok()?;
            let req = Req {
                id: "h".into(),
                method: "hello".into(),
                ..Default::default()
            };
            s.send_frame(&proto::codec::encode(&req).ok()?).await.ok()?;
            s.finish().ok()?;
            let frame = s.recv_frame().await.ok()??;
            proto::codec::decode::<Resp>(&frame).ok()
        })
        .await
        .expect("must not hang")
    };

    // 平时：拿不到任何应答。
    let stranger = client().await;
    stranger.add_peer(dtp.local_addr());
    assert!(
        try_hello(stranger.clone(), dtp.node_id()).await.is_none(),
        "窗口外未配对：连 hello 都不行"
    );

    // 二维码显示期间：能 hello（新端点，避免复用刚被拒的连接）。
    pairing.start([0x33; 12], 1_000);
    let phone = client().await;
    phone.add_peer(dtp.local_addr());
    let r = try_hello(phone.clone(), dtp.node_id())
        .await
        .expect("窗口内放行");
    assert!(r.ok);

    // 二维码关闭：立即关上。
    assert_eq!(pairing.stop(), 1);
    let late = client().await;
    late.add_peer(dtp.local_addr());
    assert!(
        try_hello(late, dtp.node_id()).await.is_none(),
        "关闭后又拒绝"
    );

    // 已配对：任何时候都放行。
    db.accept_pairing(
        &phone.node_id().0,
        "phone",
        &Pairing {
            id: "p".into(),
            node_id: phone.node_id().0.to_vec(),
            role: Role::Member,
            paired_at: 1,
        },
    )
    .await
    .unwrap();
    let again = client().await; // 同一身份需要新连接；用原 phone 端点重连
    drop(again);
    phone.close_peer(dtp.node_id());
    let r = try_hello(phone, dtp.node_id()).await.expect("已配对放行");
    assert_eq!(r.result.unwrap()["pairing_id"], "p");
}

/// #1122：配对窗口内，所有未配对的对端共用一个限速额度——两个不同身份交替连发
/// 远超配额的请求，超出的流不读、不答；已配对设备不受这个限速。
/// 反证：路由不调 unpaired_limiter、限速恒放行，或改回按身份分桶（两个身份各得一份
/// 额度）⇒ 应答数超过总额度 ⇒ 变红。
#[tokio::test(flavor = "multi_thread")]
async fn unpaired_requests_are_rate_limited_in_the_router() {
    let db = Db::open_in_memory().await.unwrap();
    let (dtp, daddr) = start_daemon(db.clone()).await;
    let strangers = [client().await, client().await];
    for s in &strangers {
        s.add_peer(daddr.clone());
    }
    let mut answered = 0;
    for i in 0..100 {
        let stranger = &strangers[i % 2];
        let attempt = async {
            let mut s = stranger
                .connect(dtp.node_id(), transport::ALPN_CTRL)
                .await
                .ok()?;
            let req = Req {
                id: "h".into(),
                method: "hello".into(),
                ..Default::default()
            };
            s.send_frame(&proto::codec::encode(&req).ok()?).await.ok()?;
            s.finish().ok()?;
            s.recv_frame().await.ok()?
        };
        if tokio::time::timeout(std::time::Duration::from_secs(2), attempt)
            .await
            .ok()
            .flatten()
            .is_some()
        {
            answered += 1;
        }
    }
    // 总额度：突发 40 + 期间按每秒 20 回补；两个身份共用，超出即丢。
    assert!(
        answered <= 70,
        "超出总额度的请求必须被丢（换身份不增加额度）：answered={answered}"
    );
    assert!(answered >= 5, "配额内的照常应答：answered={answered}");

    // 已配对设备不受限速。
    let member = client().await;
    member.add_peer(daddr);
    db.accept_pairing(
        &member.node_id().0,
        "m",
        &Pairing {
            id: "m".into(),
            node_id: member.node_id().0.to_vec(),
            role: Role::Member,
            paired_at: 1,
        },
    )
    .await
    .unwrap();
    for _ in 0..30 {
        assert!(call(&member, dtp.node_id(), "hello").await.ok);
    }
}

/// #1149：配对窗口关闭（二维码关闭）时，在场的未配对连接 1 秒内被收回，名额还给新来的设备。
/// 8 台设备在窗口内连上并占满未配对名额，二维码关闭后它们的连接被关掉；重新出码后
/// 第 9 台设备能拿到名额。
/// 反证：不复核窗口（连接一直占着名额）⇒ 第 9 台连上即被断开、拿不到应答 ⇒ 变红。
#[tokio::test(flavor = "multi_thread")]
async fn closing_the_pairing_window_frees_the_unpaired_slots() {
    let db = Db::open_in_memory().await.unwrap();
    let dtp = IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap();
    let (pairing, _rx) = daemon::Pairing::new(db.clone(), dtp.node_id(), None);
    dtp.set_admission(daemon::admission::predicate(
        db.clone(),
        pairing.clone(),
        || 1_000,
    ));
    let router = Router::new(db.clone(), "test-daemon")
        .with_pairing(pairing.clone())
        .with_window_enforced()
        .with_clock(|| 1_000);
    let served = dtp.clone();
    tokio::spawn(async move { router.serve(&served).await });

    let try_hello = |tp: IrohTransport, daemon: transport::NodeId| async move {
        tokio::time::timeout(std::time::Duration::from_secs(5), async move {
            let mut s = tp.connect(daemon, transport::ALPN_CTRL).await.ok()?;
            let req = Req {
                id: "h".into(),
                method: "hello".into(),
                ..Default::default()
            };
            s.send_frame(&proto::codec::encode(&req).ok()?).await.ok()?;
            s.finish().ok()?;
            let frame = s.recv_frame().await.ok()??;
            proto::codec::decode::<Resp>(&frame).ok()
        })
        .await
        .expect("must not hang")
    };

    pairing.start([0x44; 12], 1_000);
    let mut holders = Vec::new();
    for _ in 0..daemon::frame_limits::UNPAIRED_CONN_MAX {
        let c = client().await;
        c.add_peer(dtp.local_addr());
        assert!(try_hello(c.clone(), dtp.node_id()).await.is_some());
        holders.push(c); // 端点与缓存的连接都留着：名额一直被占
    }

    assert_eq!(pairing.stop(), 1);
    tokio::time::sleep(std::time::Duration::from_millis(1_000)).await;

    pairing.start([0x45; 12], 1_000);
    let newcomer = client().await;
    newcomer.add_peer(dtp.local_addr());
    assert!(
        try_hello(newcomer, dtp.node_id()).await.is_some(),
        "窗口关闭后在场连接被收回，新设备拿得到名额"
    );
    drop(holders);
}
