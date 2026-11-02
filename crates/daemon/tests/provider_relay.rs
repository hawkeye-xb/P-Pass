//! 手机在 offer 里上报自己的传输地址（`provider`）。这里用真 daemon 交付组件 + 真 iroh
//! 端点，检查电脑怎么用这个地址：
//!
//! - #1268 / #1270：地址里的中继，电脑只接受自己配置的那几个。
//!   「中继」用本机 TCP 监听代替：iroh 连中继的第一步就是对该 URL 建 TCP 连接，所以
//!   监听端有没有收到连接，就是电脑有没有去连它。电脑端点必须开着中继传输（配一个
//!   中继 A），否则它对任何中继 URL 都无从连起，测试会白白通过；A 收到连接就是
//!   「中继传输是活的」的对照。
//! - #1270：上报的地址只用于这台设备自己的这次拉取，不改电脑对别的设备的连接信息。

mod common;

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

fn offer(epoch: &str, seq: u64, hash: [u8; 32], provider: String) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: seq,
        pairing_id: epoch.into(),
        lease_token: format!("lease-{seq}"),
        content_hash: hex::encode(hash),
        file_name: format!("IMG_{seq:04}.jpg"),
        media_type: "image/jpeg".into(),
        provider,
        capture_at_ms: 0,
        size_bytes: 0,
        source: Default::default(),
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

/// 一个提供方端点，手里有一份内容；返回端点、它的 Blobs、内容的 hash 和 ticket。
async fn provider_with(
    dir: &std::path::Path,
    name: &str,
    bytes: &[u8],
) -> (IrohTransport, Blobs, [u8; 32], String) {
    let tp = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
        .await
        .unwrap();
    let mut blobs = Blobs::open(&tp, &dir.join(format!("{name}-store")))
        .await
        .unwrap();
    blobs.serve();
    let source = dir.join(format!("{name}.jpg"));
    std::fs::write(&source, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let ticket = blobs.push(hash, &source).await.unwrap();
    (tp, blobs, hash, ticket)
}

/// #1268 核实了改之前：电脑会连手机上报地址里的任何中继（iroh 对收到的中继 URL 一律建连接）。
/// #1270 之后：不在电脑配置里的中继，电脑不连。
/// 反证：`transport::iroh_impl::scoped` 不过滤中继（`Relay(_) => true`），B 收到连接，本条变红。
#[tokio::test(flavor = "multi_thread")]
async fn desktop_never_dials_a_reported_relay_outside_its_own_config() {
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
        .offer(phone, &offer("epoch-relay", 1, hash, token))
        .await
        .unwrap();

    assert!(
        wait_for(&configured_hits, Duration::from_secs(10)).await,
        "对照：电脑的中继传输是活的（连了自己配置的中继）"
    );
    // 改之前 B 在 0.3 秒内就收到连接（#1268 实测）；这里给 5 秒。
    assert!(
        !wait_for(&reported_hits, Duration::from_secs(5)).await,
        "电脑连了手机上报的、不在自己配置里的中继"
    );
}

/// #1270：已配对的手机 A 在 offer 里把一个假地址写在另一台设备 B 名下，电脑之后照样按原来的
/// 信息连得上 B；A 自己的拉取照常完成。
/// 反证：`provider_for` 改回把上报地址登记进传输层地址簿（`add_peer`），B 的地址被假地址
/// 顶掉，最后一条断言变红。
#[tokio::test(flavor = "multi_thread")]
async fn reported_address_for_another_device_leaves_that_device_reachable() {
    let root = tempdir().unwrap();
    let (desktop_tp, desktop) = {
        let tp = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        let blobs = Arc::new(
            Blobs::open(&tp, &root.path().join("desktop-store"))
                .await
                .unwrap(),
        );
        (tp, blobs)
    };

    // 设备 B：电脑认识它（地址簿里有它的真地址）。
    let (b_tp, _b_blobs, b_hash, _) = provider_with(root.path(), "b", b"device B's photo").await;
    desktop_tp.add_peer(b_tp.local_addr());

    // 手机 A：已配对，自己的提供方端点手里有一张照片。
    let phone = transport::node_id_from_secret_key(&[0x51; 32]);
    let (_a_tp, _a_blobs, a_hash, a_ticket) =
        provider_with(root.path(), "a", b"phone A's photo").await;
    let db = paired_db("epoch-a", phone).await;
    let delivery = FlowDelivery::new(db.clone(), desktop.clone(), root.path());

    // A 上报：B 的 NodeId + 一个假地址（中继 URL，没有人在那儿）。
    let forged = PeerAddr::from_node_relay(b_tp.node_id(), Some("http://127.0.0.1:9"))
        .unwrap()
        .to_string();
    let missing = *blake3::hash(b"nobody has this").as_bytes();
    delivery
        .offer(phone, &offer("epoch-a", 1, missing, forged))
        .await
        .unwrap();

    // A 自己的拉取照常完成。
    let own = offer("epoch-a", 2, a_hash, a_ticket);
    delivery.offer(phone, &own).await.unwrap();
    let receipt = common::await_receipt(&delivery, phone, &own).await.unwrap();
    assert_eq!(receipt.content_hash, hex::encode(a_hash));

    // 电脑对 B 的连接信息不变：按原来的地址照样拉得到 B 的内容。
    let fetched = tokio::time::timeout(
        Duration::from_secs(20),
        desktop.fetch_from(b_tp.node_id(), b_hash),
    )
    .await;
    assert!(
        matches!(fetched, Ok(Ok(()))),
        "B 的地址被别的设备上报的假地址改掉了：{fetched:?}"
    );
}
