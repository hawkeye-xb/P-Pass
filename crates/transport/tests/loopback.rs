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
            min_ver: 1,
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
