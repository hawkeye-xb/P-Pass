//! #1122：入站连接准入（iroh after_handshake 钩子）与读帧内存安全。

use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_core::Stream;
use transport::{IrohTransport, NodeId, Transport, TransportConfig, TransportError, ALPN_CTRL};

async fn next<S: Stream + Unpin>(s: &mut S) -> Option<S::Item> {
    std::future::poll_fn(|cx| Pin::new(&mut *s).poll_next(cx)).await
}

async fn bind() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![ALPN_CTRL.to_string()]))
        .await
        .expect("bind")
}

/// 服务端：把收到的每条流的第一帧回显回去；返回连进来的连接数计数器。
fn echo_server(server: &IrohTransport) -> Arc<std::sync::atomic::AtomicUsize> {
    let seen = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let s = server.clone();
    let seen2 = seen.clone();
    tokio::spawn(async move {
        let mut incoming = s.listen().await;
        while let Some(inc) = next(&mut incoming).await {
            seen2.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(async move {
                while let Ok(mut bi) = inc.accept_bi().await {
                    if let Ok(Some(frame)) = bi.recv_frame().await {
                        let _ = bi.send_frame(&frame).await;
                        let _ = bi.finish();
                    }
                }
            });
        }
    });
    seen
}

fn frame(payload: &[u8]) -> Vec<u8> {
    let mut f = (payload.len() as u32).to_le_bytes().to_vec();
    f.extend_from_slice(payload);
    f
}

/// 未准入的对端：握手后即被拒，服务端 listen 一条都看不到、什么都不读；
/// 准入的对端照常。我方出站连接不受自己的准入判据影响。
/// 反证：钩子恒放行（或 set_admission 不生效），第一段断言变红。
#[tokio::test]
async fn unadmitted_inbound_is_refused_before_any_read() {
    let server = bind().await;
    let seen = echo_server(&server);
    let allowed = bind().await;
    let stranger = bind().await;
    let allowed_id = allowed.node_id();
    server.set_admission(Arc::new(move |peer: NodeId, alpn: &[u8]| {
        peer == allowed_id && alpn == ALPN_CTRL.as_bytes()
    }));
    let server_id = stranger.add_peer(server.local_addr());
    allowed.add_peer(server.local_addr());

    // 陌生对端：连得上握手，但随即被关；读不到回显。
    let outcome = async {
        let mut bi = stranger.connect(server_id, ALPN_CTRL).await?;
        bi.send_frame(&frame(b"hello")).await?;
        bi.recv_frame().await
    };
    let r = tokio::time::timeout(Duration::from_secs(5), outcome)
        .await
        .expect("refusal must be prompt");
    assert!(
        !matches!(r, Ok(Some(_))),
        "stranger must get nothing back: {r:?}"
    );
    assert_eq!(seen.load(Ordering::SeqCst), 0, "被拒的连接不进 listen");

    // 准入的对端：照常回显。
    let mut bi = allowed
        .connect(server_id, ALPN_CTRL)
        .await
        .expect("allowed connects");
    bi.send_frame(&frame(b"hi")).await.unwrap();
    assert_eq!(bi.recv_frame().await.unwrap().unwrap(), frame(b"hi"));
    assert_eq!(seen.load(Ordering::SeqCst), 1);

    // 出站不受影响：服务端主动连一个「陌生」对端照常成功。
    let stranger_server_seen = echo_server(&stranger);
    let stranger_id = server.add_peer(stranger.local_addr());
    let mut out = server
        .connect(stranger_id, ALPN_CTRL)
        .await
        .expect("outbound unaffected");
    out.send_frame(&frame(b"x")).await.unwrap();
    assert_eq!(out.recv_frame().await.unwrap().unwrap(), frame(b"x"));
    assert_eq!(stranger_server_seen.load(Ordering::SeqCst), 1);
}

/// 声明长度超过上限：直接拒绝，不等、不读正文。
#[tokio::test]
async fn an_oversized_declared_frame_is_refused_without_reading_it() {
    let server = bind().await;
    let client = bind().await;
    let server_id = client.add_peer(server.local_addr());
    let got = Arc::new(tokio::sync::Mutex::new(None));
    let got2 = got.clone();
    let s = server.clone();
    tokio::spawn(async move {
        let mut incoming = s.listen().await;
        let inc = next(&mut incoming).await.unwrap();
        let mut bi = inc.accept_bi().await.unwrap();
        *got2.lock().await = Some(bi.recv_frame_max(8 * 1024).await);
    });
    let mut bi = client.connect(server_id, ALPN_CTRL).await.unwrap();
    // 声明 1 MiB，只发 4 字节头。
    bi.send_frame(&(1024u32 * 1024).to_le_bytes())
        .await
        .unwrap();
    for _ in 0..100 {
        if got.lock().await.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let r = got.lock().await.take().expect("server answered promptly");
    assert!(
        matches!(
            r,
            Err(TransportError::FrameTooLarge {
                len: 1_048_576,
                max: 8192
            })
        ),
        "{r:?}"
    );
}

/// 慢速发送者：正文在时限内没发完 ⇒ FrameTimeout，流被放弃。
/// 反证：去掉 recv_frame_within 的 timeout，读取一直挂着 ⇒ 外层等待超时变红。
#[tokio::test]
async fn a_slow_sender_times_out() {
    let server = bind().await;
    let client = bind().await;
    let server_id = client.add_peer(server.local_addr());
    let done = Arc::new(AtomicBool::new(false));
    let result = Arc::new(tokio::sync::Mutex::new(None));
    let (d2, r2) = (done.clone(), result.clone());
    let s = server.clone();
    tokio::spawn(async move {
        let mut incoming = s.listen().await;
        let inc = next(&mut incoming).await.unwrap();
        let mut bi = inc.accept_bi().await.unwrap();
        let r = bi
            .recv_frame_within(64 * 1024, Duration::from_millis(500))
            .await;
        *r2.lock().await = Some(r);
        d2.store(true, Ordering::SeqCst);
    });
    let mut bi = client.connect(server_id, ALPN_CTRL).await.unwrap();
    // 声明 1000 字节，只发 10 字节，然后停住不发。
    let mut partial = 1000u32.to_le_bytes().to_vec();
    partial.extend_from_slice(&[0u8; 10]);
    bi.send_frame(&partial).await.unwrap();
    for _ in 0..100 {
        if done.load(Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        done.load(Ordering::SeqCst),
        "slow sender must not hold the read forever"
    );
    let r = result.lock().await.take().unwrap();
    assert!(matches!(r, Err(TransportError::FrameTimeout(_))), "{r:?}");
    drop(bi);
}

/// #1122 方案 A：未准入的入站连接被拒时，拨号方拿到有类型的
/// `PeerClosed { peer: 拨号对象, code: 401 }`——它是经 TLS 认证的对端发来的
/// 明确「未配对」。手机据此清理，前提是 `peer` 就是它记录的那台电脑。
/// 反证：dial / 流错误不看 close_reason（一律 Io），这里拿到 Io ⇒ 变红。
#[tokio::test]
async fn a_refused_dialer_learns_not_paired_from_the_close_code() {
    let server = bind().await;
    let _seen = echo_server(&server);
    server.set_admission(Arc::new(|_: NodeId, _: &[u8]| false));
    let phone = bind().await;
    let server_id = phone.add_peer(server.local_addr());
    let attempt = async {
        let mut bi = phone.connect(server_id, ALPN_CTRL).await?;
        bi.send_frame(&frame(b"hello")).await?;
        bi.recv_frame().await
    };
    let err = tokio::time::timeout(Duration::from_secs(5), attempt)
        .await
        .expect("prompt")
        .expect_err("refused");
    match err {
        TransportError::PeerClosed { peer, code } => {
            assert_eq!(peer, server_id, "关闭帧来自拨号对象");
            assert_eq!(code, u64::from(proto::close_codes::NOT_PAIRED));
            assert!(proto::close_codes::means_not_paired(code));
        }
        other => panic!("expected PeerClosed 401, got {other:?}"),
    }
}

/// #1119 + #1122：桌面删配对后 `close_peer`，手机在这条连接上拿到 `PeerClosed{410}`。
#[tokio::test]
async fn close_peer_tells_the_phone_unpaired() {
    let server = bind().await;
    let s = server.clone();
    tokio::spawn(async move {
        let mut incoming = s.listen().await;
        while let Some(inc) = next(&mut incoming).await {
            tokio::spawn(async move {
                while let Ok(mut bi) = inc.accept_bi().await {
                    tokio::spawn(async move { while let Ok(Some(_)) = bi.recv_frame().await {} });
                }
            });
        }
    });
    let phone = bind().await;
    let server_id = phone.add_peer(server.local_addr());
    let mut bi = phone.connect(server_id, ALPN_CTRL).await.unwrap();
    bi.send_frame(&frame(b"subscribe")).await.unwrap();
    for _ in 0..50 {
        if server.path_of(phone.node_id(), ALPN_CTRL).is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(server.close_peer(phone.node_id()) >= 1);
    let err = tokio::time::timeout(Duration::from_secs(5), bi.recv_frame())
        .await
        .expect("prompt")
        .expect_err("closed");
    assert!(
        matches!(err, TransportError::PeerClosed { peer, code } if peer == server_id && code == u64::from(proto::close_codes::UNPAIRED)),
        "{err:?}"
    );
}

/// 其它失败不是 PeerClosed：对端没回、读超时 ⇒ FrameTimeout / Io，绝不被当成「未配对」。
#[tokio::test]
async fn timeouts_and_local_closes_are_not_peer_closed() {
    let server = bind().await;
    let phone = bind().await;
    let server_id = phone.add_peer(server.local_addr());
    let s = server.clone();
    tokio::spawn(async move {
        let mut incoming = s.listen().await;
        let inc = next(&mut incoming).await.unwrap();
        let _bi = inc.accept_bi().await.unwrap();
        tokio::time::sleep(Duration::from_secs(2)).await; // 不回
    });
    let mut bi = phone.connect(server_id, ALPN_CTRL).await.unwrap();
    bi.send_frame(&frame(b"x")).await.unwrap();
    // 声明了长度却不发完 ⇒ 超时，不是 PeerClosed。
    let err = bi.recv_frame_within(1024, Duration::from_millis(300)).await;
    assert!(
        !matches!(err, Err(TransportError::PeerClosed { .. })),
        "{err:?}"
    );
    // 本地主动关 ⇒ 也不是 PeerClosed。
    phone.close_peer(server_id);
    let err = bi.send_frame(&frame(b"y")).await;
    assert!(
        !matches!(err, Err(TransportError::PeerClosed { .. })),
        "{err:?}"
    );
}
