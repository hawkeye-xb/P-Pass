//! T-020 acceptance: two in-process endpoints exchange 1000 proto messages
//! over the ctrl ALPN and the connection classifies as `PathKind::Lan`.
//! Runs fully offline (no relays, no address lookup).

use std::pin::Pin;
use std::time::Duration;

use futures_core::Stream;
use transport::{ConnInfo, IrohTransport, NodeId, PathKind, Transport, TransportConfig, ALPN_CTRL};

/// Minimal `StreamExt::next` stand-in — saves a futures-util dependency.
async fn next<S: Stream + Unpin>(s: &mut S) -> Option<S::Item> {
    std::future::poll_fn(|cx| Pin::new(&mut *s).poll_next(cx)).await
}

#[tokio::test]
async fn ctrl_loopback_1000_proto_messages() {
    let alpns = vec![ALPN_CTRL.to_string()];
    let server = IrohTransport::bind(TransportConfig::loopback(alpns.clone()))
        .await
        .expect("bind server");
    let client = IrohTransport::bind(TransportConfig::loopback(alpns))
        .await
        .expect("bind client");

    let server_id = client.add_peer(server.local_addr());
    assert_eq!(server_id, server.node_id());

    // listen()'s returned stream borrows the transport (§3.1 signature), so
    // the serving task owns its own clone.
    let server_for_task = server.clone();
    let server_task = tokio::spawn(async move {
        let mut incoming = server_for_task.listen().await;
        let inc = next(&mut incoming).await.expect("one inbound connection");
        assert_eq!(inc.alpn(), ALPN_CTRL);
        let mut bi = inc.accept_bi().await.expect("accept bi");
        let mut count = 0u32;
        while let Some(frame) = bi.recv_frame().await.expect("recv frame") {
            let req: proto::Req = proto::codec::decode(&frame).expect("decode req");
            let resp = proto::Resp::ok(req.id, serde_json::json!({ "echo": req.params }));
            let out = proto::codec::encode(&resp).expect("encode resp");
            bi.send_frame(&out).await.expect("send resp");
            count += 1;
        }
        bi.finish().expect("finish server side");
        count
    });

    let mut bi = client
        .connect(server_id, ALPN_CTRL)
        .await
        .expect("connect over ctrl ALPN");

    for i in 0..1000u32 {
        let req = proto::Req {
            id: format!("req-{i}"),
            method: "diag.status".into(),
            params: serde_json::json!({ "seq": i }),
            ..Default::default()
        };
        let out = proto::codec::encode(&req).expect("encode req");
        bi.send_frame(&out).await.expect("send req");

        let frame = bi
            .recv_frame()
            .await
            .expect("recv resp")
            .expect("stream still open");
        let resp: proto::Resp = proto::codec::decode(&frame).expect("decode resp");
        assert!(resp.ok, "resp #{i} not ok: {resp:?}");
        assert_eq!(resp.id, format!("req-{i}"), "id correlation broken at #{i}");
        assert_eq!(
            resp.result.as_ref().and_then(|r| r["echo"]["seq"].as_u64()),
            Some(u64::from(i)),
            "payload mismatch at #{i}"
        );
    }

    // Path classification while the connection is still alive: both
    // endpoints sit on this machine, so the selected path must be Lan.
    let info = client.conn_info(server_id);
    assert_eq!(
        info.path,
        Some(PathKind::Lan),
        "loopback must classify as Lan, got {info:?}"
    );

    bi.finish().expect("finish client side");
    let served = server_task.await.expect("server task");
    assert_eq!(served, 1000, "server must see all 1000 messages");

    client.close().await;
    server.close().await;
}

#[tokio::test]
async fn conn_info_for_unknown_peer_is_none() {
    let t = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_CTRL.to_string()]))
        .await
        .expect("bind");
    assert_eq!(t.conn_info(NodeId([7u8; 32])), ConnInfo::NONE);
    t.close().await
}

#[tokio::test]
async fn connection_cache_reuses_a_key_but_keeps_alpns_separate() {
    let alpns = vec![ALPN_CTRL.to_string(), transport::ALPN_BLOBS.to_string()];
    let server = IrohTransport::bind(TransportConfig::loopback(alpns.clone()))
        .await
        .expect("bind server");
    let client = IrohTransport::bind(TransportConfig::loopback(alpns))
        .await
        .expect("bind client");
    let server_id = client.add_peer(server.local_addr());
    let server_for_task = server.clone();
    let server_task = tokio::spawn(async move {
        let mut incoming = server_for_task.listen().await;
        let ctrl = next(&mut incoming).await.expect("ctrl connection");
        assert_eq!(ctrl.alpn(), ALPN_CTRL);
        let _first_stream = ctrl.accept_bi().await.expect("first ctrl stream");
        tokio::time::timeout(Duration::from_secs(1), ctrl.accept_bi()).await
    });

    let mut first = client
        .connect(server_id, ALPN_CTRL)
        .await
        .expect("first ctrl stream");
    first
        .send_frame(&[0, 0, 0, 0])
        .await
        .expect("start first stream");
    let mut second = client
        .connect(server_id, ALPN_CTRL)
        .await
        .expect("second ctrl stream");
    second
        .send_frame(&[0, 0, 0, 0])
        .await
        .expect("start second stream");
    let _blobs = client
        .connect(server_id, transport::ALPN_BLOBS)
        .await
        .expect("blobs stream");

    assert!(
        server_task.await.expect("server task").is_ok(),
        "a second stream on the same (peer, ALPN) must arrive on the original connection"
    );
    let ctrl_path = client.path_of(server_id, ALPN_CTRL).expect("ctrl path");
    let blobs_path = client
        .path_of(server_id, transport::ALPN_BLOBS)
        .expect("blobs path");
    assert_eq!(ctrl_path.path, Some(PathKind::Lan));
    assert_eq!(blobs_path.path, Some(PathKind::Lan));

    client.close().await;
    server.close().await;
}

/// #1119：桌面删掉一台设备的配对记录后，`close_peer` 立即关掉与它的全部连接
/// （不等空闲回收），对端看到 UNPAIRED_CLOSE_CODE；别的设备的连接不受影响。
/// 反证：close_peer 不关连接（只从缓存里摘掉），对端读不到关闭 ⇒ 超时变红。
#[tokio::test]
async fn close_peer_closes_every_connection_of_that_peer_only() {
    let alpns = vec![ALPN_CTRL.to_string()];
    let server = IrohTransport::bind(TransportConfig::loopback(alpns.clone()))
        .await
        .expect("bind server");
    let phone_a = IrohTransport::bind(TransportConfig::loopback(alpns.clone()))
        .await
        .expect("bind a");
    let phone_b = IrohTransport::bind(TransportConfig::loopback(alpns))
        .await
        .expect("bind b");
    let server_id = phone_a.add_peer(server.local_addr());
    phone_b.add_peer(server.local_addr());

    // 服务端只接受连接、在每条连接上收一个流，保持连接存活。
    let server_for_task = server.clone();
    tokio::spawn(async move {
        let mut incoming = server_for_task.listen().await;
        while let Some(inc) = next(&mut incoming).await {
            tokio::spawn(async move {
                if let Ok(mut bi) = inc.accept_bi().await {
                    while let Ok(Some(_)) = bi.recv_frame().await {}
                }
            });
        }
    });

    let mut a = phone_a
        .connect(server_id, ALPN_CTRL)
        .await
        .expect("a connects");
    let mut b = phone_b
        .connect(server_id, ALPN_CTRL)
        .await
        .expect("b connects");
    a.send_frame(b"hi").await.expect("a sends");
    b.send_frame(b"hi").await.expect("b sends");
    // 等服务端登记两条连接。
    for _ in 0..50 {
        if server.path_of(phone_a.node_id(), ALPN_CTRL).is_some()
            && server.path_of(phone_b.node_id(), ALPN_CTRL).is_some()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    assert_eq!(server.close_peer(phone_a.node_id()), 1);
    assert!(server.path_of(phone_a.node_id(), ALPN_CTRL).is_none());

    // A 那一端很快读到连接被关（不是挂着等超时）。
    let closed = tokio::time::timeout(Duration::from_secs(5), a.recv_frame())
        .await
        .expect("phone A must observe the close promptly");
    assert!(closed.is_err() || matches!(closed, Ok(None)), "{closed:?}");
    // B 不受影响。
    assert!(server.path_of(phone_b.node_id(), ALPN_CTRL).is_some());
    b.send_frame(b"still here")
        .await
        .expect("b keeps its connection");
    assert_eq!(
        server.close_peer(NodeId([9; 32])),
        0,
        "未知设备：什么都不关"
    );
}

/// #1119 真机回归（三星 E3）：手机客户端每次请求新开一条连接。缓存按
/// (设备, ALPN) 只记一条，长连接（订阅）的登记会被后来的短连接覆盖、又随短连接
/// 关闭被摘掉——长连接还活着，却不在缓存里。`close_peer` 必须照样把它关掉。
/// 反证：close_peer 只看连接缓存，长连接活下来 ⇒ 超时变红。
#[tokio::test]
async fn close_peer_closes_a_long_lived_connection_shadowed_by_a_later_short_one() {
    let alpns = vec![ALPN_CTRL.to_string()];
    let server = IrohTransport::bind(TransportConfig::loopback(alpns.clone()))
        .await
        .expect("bind server");
    // 同一身份的两个端点 = 服务端眼里同一台设备的两条连接（模拟手机每次请求新开连接）。
    let key = [7u8; 32];
    let with_key = |alpns: Vec<String>| {
        let mut cfg = TransportConfig::loopback(alpns);
        cfg.secret_key = Some(key);
        cfg
    };
    let phone = IrohTransport::bind(with_key(alpns.clone()))
        .await
        .expect("bind phone");
    let phone_again = IrohTransport::bind(with_key(alpns.clone()))
        .await
        .expect("bind phone #2");
    assert_eq!(phone.node_id(), phone_again.node_id());
    let server_id = phone.add_peer(server.local_addr());
    phone_again.add_peer(server.local_addr());

    let server_for_task = server.clone();
    tokio::spawn(async move {
        let mut incoming = server_for_task.listen().await;
        while let Some(inc) = next(&mut incoming).await {
            tokio::spawn(async move {
                while let Ok(mut bi) = inc.accept_bi().await {
                    tokio::spawn(async move { while let Ok(Some(_)) = bi.recv_frame().await {} });
                }
            });
        }
    });

    // 长连接：手机侧这条留在它自己的缓存里。
    let mut long = phone
        .connect(server_id, ALPN_CTRL)
        .await
        .expect("long-lived");
    long.send_frame(b"subscribe").await.expect("send");
    tokio::time::sleep(Duration::from_millis(200)).await;
    // 短连接：同一台设备的第二条连接，发一次就整体关掉。
    let mut short = phone_again
        .connect(server_id, ALPN_CTRL)
        .await
        .expect("short");
    short.send_frame(b"hello").await.expect("send");
    short.finish().expect("finish");
    tokio::time::sleep(Duration::from_millis(200)).await;
    drop(short);
    phone_again.close_peer(server_id);
    for _ in 0..50 {
        if server.path_of(phone.node_id(), ALPN_CTRL).is_none() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        server.path_of(phone.node_id(), ALPN_CTRL).is_none(),
        "前提：长连接的缓存登记已被短连接覆盖并摘掉"
    );

    assert!(
        server.close_peer(phone.node_id()) >= 1,
        "长连接必须被找到并关闭"
    );
    let closed = tokio::time::timeout(Duration::from_secs(5), long.recv_frame())
        .await
        .expect("phone must observe the close of its long-lived connection");
    assert!(closed.is_err() || matches!(closed, Ok(None)), "{closed:?}");
}
