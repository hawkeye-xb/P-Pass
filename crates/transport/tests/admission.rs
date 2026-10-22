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
