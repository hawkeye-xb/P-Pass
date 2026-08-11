//! PRES-01 acceptance: hello 轻心跳 → last_seen 刷新 + 三档在线态 +
//! device.connected 审计（同设备 10 分钟去重）。
//!
//! 覆盖卡面验收 1（三档判定纯函数边界，见 presence.rs 单测）与验收 2
//! （hello → device.connected，10 分钟内重复 hello 不重复记；反证：
//! 去掉去重 → 本文件断言必红）。

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use daemon::{presence, DiagAgg, IpcServer, Pairing, Router};
use interprocess::local_socket::tokio::prelude::*;

use proto::{Req, Resp};
use storage::{Db, Device, Role};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use transport::{IrohTransport, Transport, TransportConfig};

const ALPNS: &[&str] = &["ppf/ctrl/1"];

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(
        ALPNS.iter().map(|s| s.to_string()).collect(),
    ))
    .await
    .unwrap()
}

fn hello_req() -> Req {
    Req {
        id: "hello".into(),
        method: "hello".into(),
        params: serde_json::json!({}),
        ..Default::default()
    }
}

/// Router 级 harness：真 transport + 可控时钟（T-070 with_clock seam）。
struct RouterHarnessInner {
    daemon_tp: IrohTransport,
    client_tp: IrohTransport,
    clock: Arc<AtomicI64>,
}

impl RouterHarnessInner {
    async fn call(&self, method: &str, params: serde_json::Value) -> Resp {
        let mut stream = self
            .client_tp
            .connect(self.daemon_tp.node_id(), "ppf/ctrl/1")
            .await
            .unwrap();
        let req = Req {
            id: format!("req-{method}"),
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
}

/// 搭 Router（带时钟 seam）——客户端已作为 Member 配对入库。
async fn router_harness(_dir: &std::path::Path, db: Db, now: i64) -> RouterHarnessInner {
    let daemon_tp = endpoint().await;
    let clock = Arc::new(AtomicI64::new(now));
    let clock2 = Arc::clone(&clock);
    let router =
        Router::new(db.clone(), "storage").with_clock(move || clock2.load(Ordering::Relaxed));
    let tp2 = daemon_tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });

    let client_tp = endpoint().await;
    client_tp.add_peer(daemon_tp.local_addr());
    db.upsert_device(&Device {
        device_hint: None,
        node_id: client_tp.node_id().0.to_vec(),
        name: "小红".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: Some(now - 60_000),
        revoked: false,
    })
    .await
    .unwrap();
    RouterHarnessInner {
        daemon_tp,
        client_tp,
        clock,
    }
}

async fn connected_audits(db: &Db, node: &[u8]) -> Vec<storage::AuditRecord> {
    let all = db.list_audit(1000).await.unwrap();
    all.into_iter()
        .filter(|r| r.entry.action == "device.connected" && r.entry.actor.as_deref() == Some(node))
        .collect()
}

// ── 验收 2：hello → device.connected；10 分钟内去重；去重窗口过后再记 ──

#[tokio::test(flavor = "multi_thread")]
async fn hello_records_connected_once_then_dedupes_then_records_again() {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let now = 1_800_000_000_000;
    let h = router_harness(dir.path(), db.clone(), now).await;
    let node = h.client_tp.node_id().0;

    // 第一次 hello：应答 ok + last_seen 更新 + 1 条 device.connected。
    let resp = h.call("hello", serde_json::json!({})).await;
    assert!(resp.ok, "hello must succeed: {resp:?}");
    let dev = db.get_device(&node).await.unwrap().unwrap();
    assert_eq!(dev.last_seen, Some(now), "hello must refresh last_seen");
    assert_eq!(
        connected_audits(&db, &node).await.len(),
        1,
        "first hello records one device.connected"
    );

    // 第二次 hello（同 10 分钟窗口，时钟走 5 分钟）：不再记。
    h.clock.store(now + 5 * 60 * 1000, Ordering::Relaxed);
    let resp = h.call("hello", serde_json::json!({})).await;
    assert!(resp.ok);
    let dev = db.get_device(&node).await.unwrap().unwrap();
    assert_eq!(
        dev.last_seen,
        Some(now + 5 * 60 * 1000),
        "last_seen keeps refreshing"
    );
    assert_eq!(
        connected_audits(&db, &node).await.len(),
        1,
        "second hello inside the 10-min window must NOT record again"
    );

    // 时钟跨过 10 分钟窗口 → 第三条记录出现（防「永不重记」）。
    h.clock.store(now + 11 * 60 * 1000, Ordering::Relaxed);
    let resp = h.call("hello", serde_json::json!({})).await;
    assert!(resp.ok);
    assert_eq!(
        connected_audits(&db, &node).await.len(),
        2,
        "hello after the dedupe window records a new device.connected"
    );
}

// ── 未配对节点：hello 是能力握手，零副作用 ────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn unpaired_hello_stays_side_effect_free() {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let h = router_harness(dir.path(), db.clone(), 1_800_000_000_000).await;
    // 第二台未配对客户端。
    let stranger = endpoint().await;
    stranger.add_peer(h.daemon_tp.local_addr());

    let mut stream = stranger
        .connect(h.daemon_tp.node_id(), "ppf/ctrl/1")
        .await
        .unwrap();
    stream
        .send_frame(&proto::codec::encode(&hello_req()).unwrap())
        .await
        .unwrap();
    stream.finish().unwrap();
    let frame = stream.recv_frame().await.unwrap().expect("a response");
    let resp: Resp = proto::codec::decode(&frame).unwrap();
    assert!(
        resp.ok,
        "unpaired hello is capability negotiation, must be allowed"
    );

    assert_eq!(
        connected_audits(&db, &h.client_tp.node_id().0).await.len(),
        0,
        "stranger hello must not write anything"
    );
}

// ── revoked 设备：authz 拒绝（连 hello 都不给），零副作用 ─────────────

#[tokio::test(flavor = "multi_thread")]
async fn revoked_hello_is_denied_and_touches_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let now = 1_800_000_000_000;
    let h = router_harness(dir.path(), db.clone(), now).await;
    db.revoke(&h.client_tp.node_id().0).await.unwrap();
    let before = db
        .get_device(&h.client_tp.node_id().0)
        .await
        .unwrap()
        .unwrap()
        .last_seen;

    let resp = h.call("hello", serde_json::json!({})).await;
    assert!(!resp.ok, "revoked device must be denied even hello");
    let after = db
        .get_device(&h.client_tp.node_id().0)
        .await
        .unwrap()
        .unwrap()
        .last_seen;
    assert_eq!(after, before, "denied hello must not refresh last_seen");
    assert_eq!(
        connected_audits(&db, &h.client_tp.node_id().0).await.len(),
        0
    );
}

// ── devices.list presence 三档（IPC 层，conn_status 注入）──────────────

#[tokio::test(flavor = "multi_thread")]
async fn devices_list_presence_three_tiers() {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let (event_bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xCC; 32]), None, None);
    let pairing = pairing.with_events(event_bus.clone());
    let diag = DiagAgg::new(db.clone());
    let mut ipc = IpcServer::new(
        db.clone(),
        pairing,
        diag,
        dir.path().to_path_buf(),
        pending_rx,
        event_bus,
    );
    ipc.set_conn_status_provider(move |node| {
        if node == [0xAA; 32] {
            transport::ConnectionStatus::Direct
        } else {
            transport::ConnectionStatus::Unknown
        }
    });
    let ipc = Arc::new(ipc);

    let socket = format!("ppf-test-{}-presence", std::process::id());
    let token = [0x5B; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    tokio::spawn({
        let ipc = Arc::clone(&ipc);
        let socket = socket.clone();
        async move {
            let _ = ipc.serve(&socket, token).await;
        }
    });
    // 等服务 socket 可连（与 ipc_flow fixture 同法：空探测连接是 no-op）。
    let name = socket
        .clone()
        .to_ns_name::<interprocess::local_socket::GenericNamespaced>()
        .unwrap();
    let mut bound = false;
    for _ in 0..200 {
        if interprocess::local_socket::tokio::Stream::connect(name.clone())
            .await
            .is_ok()
        {
            bound = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(bound, "socket never became connectable");

    let now = now_ms();
    for (node, name, last_seen) in [
        (
            vec![0xAA; 32],
            "直连机".to_string(),
            Some(now - 40 * 24 * 3600 * 1000),
        ), // 有活连接，last_seen 很旧
        (vec![0xBB; 32], "心跳新鲜".to_string(), Some(now - 90_000)), // 无活连接但 <2min
        (
            vec![0xCC; 32],
            "刚刚在线".to_string(),
            Some(now - 3 * 60 * 1000),
        ), // 3 分钟前
        (
            vec![0xDD; 32],
            "哨兵离线".to_string(),
            Some(now - 6 * 24 * 3600 * 1000),
        ), // >5 天
        (vec![0xEE; 32], "从未上报".to_string(), None),
    ] {
        db.upsert_device(&Device {
            device_hint: None,
            node_id: node,
            name,
            role: Role::Member,
            paired_at: 1,
            last_seen,
            revoked: false,
        })
        .await
        .unwrap();
    }

    let mut c = IpcClient::connect(&socket, &token_hex).await;
    let resp = c.call("devices.list", serde_json::json!({})).await;
    assert!(resp.ok, "devices.list must work: {resp:?}");
    let devices = resp.result.unwrap()["devices"].clone();
    let by_node: std::collections::HashMap<String, serde_json::Value> = devices
        .as_array()
        .unwrap()
        .iter()
        .map(|d| (d["node_id"].as_str().unwrap().to_string(), d.clone()))
        .collect();
    let hex = |b: u8| format!("{:02x}", b).repeat(32);
    assert_eq!(
        by_node[&hex(0xAA)]["presence"],
        "online",
        "活跃连接 = 在线（无视旧 last_seen）"
    );
    assert_eq!(
        by_node[&hex(0xBB)]["presence"],
        "online",
        "<2min 心跳 = 在线"
    );
    assert_eq!(
        by_node[&hex(0xCC)]["presence"],
        "recent",
        "2min~5天 = 刚刚在线"
    );
    assert_eq!(
        by_node[&hex(0xDD)]["presence"],
        "offline",
        ">5天 = 离线（哨兵口径）"
    );
    assert_eq!(
        by_node[&hex(0xEE)]["presence"],
        "offline",
        "从未上报 = 离线"
    );
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

// ── IpcClient 最小实现（ipc_flow 同款）────────────────────────────────

struct IpcClient {
    lines: tokio::io::Lines<tokio::io::BufReader<interprocess::local_socket::tokio::RecvHalf>>,
    tx: interprocess::local_socket::tokio::SendHalf,
}

impl IpcClient {
    async fn connect(socket: &str, token: &str) -> IpcClient {
        use interprocess::local_socket::tokio::prelude::*;
        let name = socket
            .to_ns_name::<interprocess::local_socket::GenericNamespaced>()
            .unwrap();
        let conn = interprocess::local_socket::tokio::Stream::connect(name)
            .await
            .unwrap();
        let (rx, mut tx) = conn.split();
        tx.write_all(format!("{token}\n").as_bytes()).await.unwrap();
        IpcClient {
            lines: tokio::io::BufReader::new(rx).lines(),
            tx,
        }
    }

    async fn call(&mut self, method: &str, params: serde_json::Value) -> Resp {
        let req = Req {
            id: method.into(),
            method: method.into(),
            params,
            ..Default::default()
        };
        let mut line = serde_json::to_string(&req).unwrap();
        line.push('\n');
        self.tx.write_all(line.as_bytes()).await.unwrap();
        let resp_line = self.lines.next_line().await.unwrap().expect("a response");
        serde_json::from_str(&resp_line).unwrap()
    }
}

// ── presence 纯函数边界（卡面验收 1 的集成侧双保险）──────────────────

#[test]
fn presence_pure_function_three_tiers() {
    let now = 1_800_000_000_000;
    assert_eq!(
        presence::presence("direct", Some(now - 10_000), now),
        "online"
    );
    assert_eq!(
        presence::presence("unknown", Some(now - 90_000), now),
        "online"
    );
    assert_eq!(
        presence::presence("unknown", Some(now - 3 * 60 * 1000), now),
        "recent"
    );
    assert_eq!(
        presence::presence("unknown", Some(now - 6 * 24 * 3600 * 1000), now),
        "offline"
    );
}
