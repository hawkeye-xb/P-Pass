//! #1268：手机在 offer 里上报自己的传输地址（`provider`），地址里可以带中继 URL。
//! 这里用真 daemon 交付组件 + 真 iroh 端点，观察电脑收到地址以后会不会主动连其中的中继。
//!
//! 「中继」用本机 TCP 监听代替：iroh 连中继的第一步就是对该 URL 建 TCP 连接，
//! 所以监听端有没有收到连接，就是电脑有没有去连它。
//!
//! 电脑端点必须开着中继传输（配一个中继 A），否则它对任何中继 URL 都无从连起，
//! 测试会白白通过；A 收到连接就是「中继传输是活的」的对照。

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use daemon::flow_delivery::FlowDelivery;
use proto::FlowFetchRequest;
use storage::{Db, Pairing, Role};
use tempfile::tempdir;
use transport::{Blobs, IrohTransport, PeerAddr, TransportConfig, ALPN_BLOBS};

/// 本机 TCP 监听，数收到了几条连接。
async fn counting_listener() -> (String, Arc<AtomicUsize>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let hits = Arc::new(AtomicUsize::new(0));
    let count = hits.clone();
    tokio::spawn(async move {
        while let Ok((sock, _)) = listener.accept().await {
            count.fetch_add(1, Ordering::SeqCst);
            drop(sock);
        }
    });
    (url, hits)
}

async fn wait_for(hits: &AtomicUsize, within: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + within;
    while tokio::time::Instant::now() < deadline {
        if hits.load(Ordering::SeqCst) > 0 {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    hits.load(Ordering::SeqCst) > 0
}

fn offer(epoch: &str, hash: [u8; 32], provider: String) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: 1,
        pairing_id: epoch.into(),
        lease_token: "lease-relay".into(),
        content_hash: hex::encode(hash),
        file_name: "IMG_0001.jpg".into(),
        media_type: "image/jpeg".into(),
        provider,
        capture_at_ms: 0,
        size_bytes: 0,
    }
}

async fn paired_db(epoch: &str, peer: transport::NodeId) -> Db {
    let db = Db::open_in_memory().await.unwrap();
    db.accept_pairing(
        &peer.0,
        "phone",
        &Pairing {
            id: epoch.into(),
            node_id: peer.0.to_vec(),
            role: Role::Member,
            paired_at: 1,
        },
    )
    .await
    .unwrap();
    db
}

/// #1268 结论：电脑会主动连接手机上报地址里的中继，哪怕它不在电脑配置的中继里。
/// 反证：上报地址里不带中继（`from_node_relay(.., None)`），B 收不到连接，本条变红。
#[tokio::test(flavor = "multi_thread")]
async fn desktop_dials_the_relay_named_in_a_phone_reported_address() {
    let (configured, configured_hits) = counting_listener().await;
    let (reported, reported_hits) = counting_listener().await;

    let root = tempdir().unwrap();
    let transport = IrohTransport::bind(TransportConfig {
        relay_urls: vec![configured],
        n0_services: false,
        secret_key: None,
        alpns: vec![ALPN_BLOBS.into()],
        bind_addr: None,
    })
    .await
    .unwrap();
    let blobs = Arc::new(
        Blobs::open(&transport, &root.path().join("store"))
            .await
            .unwrap(),
    );

    let phone = transport::node_id_from_secret_key(&[0x31; 32]);
    let provider = transport::node_id_from_secret_key(&[0x32; 32]);
    let db = paired_db("epoch-relay", phone).await;
    let delivery = FlowDelivery::new(db, blobs, root.path());
    let token = PeerAddr::from_node_relay(provider, Some(&reported))
        .unwrap()
        .to_string();
    let hash = *blake3::hash(b"#1268 relay fixture").as_bytes();

    delivery
        .offer(phone, &offer("epoch-relay", hash, token))
        .await
        .unwrap();

    assert!(
        wait_for(&configured_hits, Duration::from_secs(10)).await,
        "对照：电脑的中继传输是活的（连了自己配置的中继）"
    );
    assert!(
        wait_for(&reported_hits, Duration::from_secs(10)).await,
        "电脑连了手机上报的中继"
    );
}
