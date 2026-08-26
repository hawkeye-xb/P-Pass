//! T-034 acceptance: IPC round-trips over a real local socket (token
//! gate, status, device management, pairing confirmation) and the
//! logs.export zip carries no real user paths.

use std::sync::Arc;

use daemon::{DiagAgg, IpcServer, Pairing};
use interprocess::local_socket::tokio::prelude::*;
use interprocess::local_socket::GenericNamespaced;
use storage::{Db, Device, Role};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

struct IpcClient {
    lines: tokio::io::Lines<BufReader<interprocess::local_socket::tokio::RecvHalf>>,
    tx: interprocess::local_socket::tokio::SendHalf,
}

impl IpcClient {
    async fn connect(socket: &str, token: &str) -> IpcClient {
        let name = socket.to_ns_name::<GenericNamespaced>().unwrap();
        let conn = interprocess::local_socket::tokio::Stream::connect(name)
            .await
            .unwrap();
        let (rx, mut tx) = conn.split();
        tx.write_all(format!("{token}\n").as_bytes()).await.unwrap();
        IpcClient {
            lines: BufReader::new(rx).lines(),
            tx,
        }
    }

    async fn call(&mut self, method: &str, params: serde_json::Value) -> proto::Resp {
        let req = proto::Req {
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

    /// IPC-02: events.subscribe——握手应答后连接转为事件流。
    async fn subscribe(&mut self, types: Option<Vec<&str>>) -> proto::Resp {
        let params = match types {
            Some(t) => serde_json::json!({ "types": t }),
            None => serde_json::json!({}),
        };
        self.call("events.subscribe", params).await
    }

    /// 读一条事件帧 `{"event":"...","data":{...}}`。
    async fn next_event(&mut self) -> serde_json::Value {
        let line = self
            .lines
            .next_line()
            .await
            .unwrap()
            .expect("an event line");
        serde_json::from_str(&line).unwrap()
    }

    /// 显式退订——连接应被服务端关闭（再读返回 None）。
    async fn unsubscribe(&mut self) {
        let req = proto::Req {
            id: "events.unsubscribe".into(),
            method: "events.unsubscribe".into(),
            params: serde_json::json!({}),
            ..Default::default()
        };
        let mut line = serde_json::to_string(&req).unwrap();
        line.push('\n');
        self.tx.write_all(line.as_bytes()).await.unwrap();
    }
}

/// Unique socket name per test (namespaced sockets are machine-global).
fn socket_name(tag: &str) -> String {
    format!("ppf-test-{}-{}", std::process::id(), tag)
}

async fn start(dir: &std::path::Path, tag: &str) -> (Db, Pairing, String, String) {
    let db = Db::open_in_memory().await.unwrap();
    let (event_bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xCC; 32]), None, None);
    let pairing = pairing.with_events(event_bus.clone());
    let diag = DiagAgg::new(db.clone());
    let ipc = Arc::new(IpcServer::new(
        db.clone(),
        pairing.clone(),
        diag,
        dir.to_path_buf(),
        pending_rx,
        event_bus,
    ));
    let socket = socket_name(tag);
    let token = [0x5A; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    tokio::spawn({
        let ipc = Arc::clone(&ipc);
        let socket = socket.clone();
        async move {
            let _ = ipc.serve(&socket, token).await;
        }
    });
    // Wait for the socket to accept connections. serve() writes the
    // token file BEFORE binding the socket (ipc.rs), so waiting on the
    // file alone can race the bind — a fast connect then hits ENOENT
    // under parallel load. Poll the connect itself; an empty probe
    // connection is a no-op for the server (read EOF → drop).
    let name = socket.clone().to_ns_name::<GenericNamespaced>().unwrap();
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
    assert!(bound, "socket {socket} never became connectable");
    let _ = ipc;
    (db, pairing, socket, token_hex)
}

#[tokio::test(flavor = "multi_thread")]
async fn status_devices_and_revoke_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "roundtrip").await;
    db.upsert_device(&Device {
        device_hint: None,
        node_id: vec![0xAA; 32],
        name: "妈妈的手机".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();

    let mut c = IpcClient::connect(&socket, &token).await;

    let resp = c.call("status", serde_json::Value::Null).await;
    assert!(resp.ok);
    let status = resp.result.unwrap();
    assert_eq!(status["devices"], 1);
    assert_eq!(status["state"], "ONLINE_DIRECT");

    let resp = c.call("devices.list", serde_json::Value::Null).await;
    let devices = resp.result.unwrap();
    assert_eq!(devices["devices"][0]["name"], "妈妈的手机");

    let resp = c
        .call(
            "device.revoke",
            serde_json::json!({ "node_id": "aa".repeat(32) }),
        )
        .await;
    assert_eq!(resp.result.unwrap()["revoked"], true);
    assert!(db.get_device(&[0xAA; 32]).await.unwrap().unwrap().revoked);
}

// ── NAME-01: device.rename（ID 与显示名分离，decisions ②）──────────

#[tokio::test(flavor = "multi_thread")]
async fn device_rename_updates_list_and_appends_audit() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "rename").await;
    db.upsert_device(&Device {
        device_hint: None,
        node_id: vec![0xBB; 32],
        name: "默认名字".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();

    let mut c = IpcClient::connect(&socket, &token).await;

    // 改名成功：返回旧名/新名，devices.list 出新名，ID 不变。
    let resp = c
        .call(
            "device.rename",
            serde_json::json!({ "node_id": "bb".repeat(32), "name": "爸爸的手机" }),
        )
        .await;
    assert!(resp.ok, "rename should succeed: {resp:?}");
    let r = resp.result.unwrap();
    assert_eq!(r["renamed"], true);
    assert_eq!(r["old_name"], "默认名字");
    assert_eq!(r["name"], "爸爸的手机");

    let resp = c.call("devices.list", serde_json::Value::Null).await;
    let devices = resp.result.unwrap();
    assert_eq!(devices["devices"][0]["name"], "爸爸的手机");
    assert_eq!(devices["devices"][0]["node_id"], "bb".repeat(32));

    // 审计有记录（device.renamed 旧名→新名+node_id）。
    let resp = c.call("audit.list", serde_json::Value::Null).await;
    let audits = resp.result.unwrap();
    let renamed: Vec<_> = audits["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|a| a["action"] == "device.renamed")
        .collect();
    assert_eq!(renamed.len(), 1, "audit 必须有 device.renamed 记录");
    let detail = renamed[0]["detail"].as_str().unwrap();
    assert!(
        detail.contains("默认名字 -> 爸爸的手机") && detail.contains(&"bb".repeat(32)),
        "detail 应含旧名→新名+node_id, got: {detail}",
    );

    // 反证：audit 断言删掉必红——改名没审计 = 本测试第一个 assert 挂。
    //（验收要求显式反证；此处通过上面 renamed.len()==1 锁死。）
}

#[tokio::test(flavor = "multi_thread")]
async fn device_rename_rejects_bad_input_and_unknown_device() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "rename-bad").await;
    db.upsert_device(&Device {
        device_hint: None,
        node_id: vec![0xCC; 32],
        name: "A".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();

    let mut c = IpcClient::connect(&socket, &token).await;

    // 空名 = 非法请求。
    let resp = c
        .call(
            "device.rename",
            serde_json::json!({ "node_id": "cc".repeat(32), "name": "   " }),
        )
        .await;
    assert!(!resp.ok, "blank name must be rejected");

    // 缺 node_id / 缺 name = 非法请求。
    let resp = c
        .call("device.rename", serde_json::json!({ "name": "X" }))
        .await;
    assert!(!resp.ok);
    let resp = c
        .call(
            "device.rename",
            serde_json::json!({ "node_id": "cc".repeat(32) }),
        )
        .await;
    assert!(!resp.ok);

    // 未知设备 = NOT_FOUND 语义。
    let resp = c
        .call(
            "device.rename",
            serde_json::json!({ "node_id": "ee".repeat(32), "name": "幽灵" }),
        )
        .await;
    assert!(!resp.ok, "unknown device must fail");
    assert_eq!(
        resp.error.as_ref().unwrap().code,
        "NOT_FOUND",
        "unknown device must be NOT_FOUND",
    );
}

// ── T-090: data-plane extensions (status / activity.list / connection) ──

/// Seed helper: one asset from `src` added at `added_at` (unix ms).
fn seeded_asset(src: u8, hash_byte: u8, added_at: i64) -> storage::Asset {
    storage::Asset {
        hash: {
            let mut h = vec![0u8; 32];
            h[0] = src;
            h[1] = hash_byte;
            h
        },
        rel_path: format!("originals/{src:02x}/{hash_byte:02x}.jpg"),
        media_type: "image/jpeg".into(),
        bytes: 1000,
        taken_at: Some(added_at),
        width: None,
        height: None,
        src_device: vec![src; 32],
        added_at,
        thumb_state: 1,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn status_reports_photo_count_and_disk_watermarks() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "t090status").await;
    for n in 0..3u8 {
        db.insert_asset(&seeded_asset(0xA1, n, 1_700_000_000_000 + i64::from(n)))
            .await
            .unwrap();
    }

    let mut c = IpcClient::connect(&socket, &token).await;
    let resp = c.call("status", serde_json::Value::Null).await;
    assert!(resp.ok);
    let status = resp.result.unwrap();

    // 三个新字段在场；photo_count == 种子数。
    assert_eq!(status["photo_count"], 3, "photo_count must equal seeds");
    let free = status["disk_free_bytes"]
        .as_u64()
        .expect("disk_free_bytes present and numeric on unix");
    let total = status["disk_total_bytes"]
        .as_u64()
        .expect("disk_total_bytes present and numeric on unix");
    assert!(total > 0, "library volume has a size");
    assert!(free <= total, "free space cannot exceed the volume size");
}

#[tokio::test(flavor = "multi_thread")]
async fn activity_list_aggregates_backup_batches() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "t090activity").await;
    db.upsert_device(&Device {
        device_hint: None,
        node_id: vec![0xA1; 32],
        name: "妈妈的手机".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
    })
    .await
    .unwrap();

    let t0 = 1_700_000_000_000i64;
    let min = 60_000i64;
    // Device A1: burst of 3 (1 min apart) + burst of 2 after a 30-min
    // silence → two batches. Device B2: single asset → one batch.
    for (n, at) in [(1, t0), (2, t0 + min), (3, t0 + 2 * min)] {
        db.insert_asset(&seeded_asset(0xA1, n, at)).await.unwrap();
    }
    for (n, at) in [(4, t0 + 32 * min), (5, t0 + 33 * min)] {
        db.insert_asset(&seeded_asset(0xA1, n, at)).await.unwrap();
    }
    db.insert_asset(&seeded_asset(0xB2, 6, t0 + min))
        .await
        .unwrap();

    let mut c = IpcClient::connect(&socket, &token).await;
    let resp = c.call("activity.list", serde_json::Value::Null).await;
    assert!(resp.ok, "{resp:?}");
    let batches = resp.result.unwrap()["batches"].clone();
    let batches = batches.as_array().expect("batches array");

    // 10 分钟窗聚合：正确批次数 = 3（A1 两批 + B2 一批），倒序。
    assert_eq!(batches.len(), 3, "expected 3 aggregated batches");
    assert_eq!(batches[0]["node_id"], "a1".repeat(32));
    assert_eq!(batches[0]["at"], t0 + 33 * min);
    assert_eq!(batches[0]["asset_count"], 2);
    assert_eq!(batches[0]["name"], "妈妈的手机");
    assert_eq!(batches[1]["node_id"], "a1".repeat(32));
    assert_eq!(batches[1]["at"], t0 + 2 * min);
    assert_eq!(batches[1]["asset_count"], 3);
    assert_eq!(batches[2]["node_id"], "b2".repeat(32));
    assert_eq!(batches[2]["asset_count"], 1);
    assert_eq!(
        batches[2]["name"],
        serde_json::Value::Null,
        "非名册设备名为 null"
    );

    // limit param truncates from the newest end.
    let resp = c
        .call("activity.list", serde_json::json!({ "limit": 1 }))
        .await;
    let top = resp.result.unwrap()["batches"].clone();
    assert_eq!(top.as_array().unwrap().len(), 1);
    assert_eq!(top[0]["at"], t0 + 33 * min);
}

#[tokio::test(flavor = "multi_thread")]
async fn devices_list_reports_connection_unknown_without_transport() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "t090conn").await;
    db.upsert_device(&Device {
        device_hint: None,
        node_id: vec![0xAB; 32],
        name: "test-device".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: Some(now()), // 有 last_seen 也不许推断在线
        revoked: false,
    })
    .await
    .unwrap();

    let mut c = IpcClient::connect(&socket, &token).await;
    let resp = c.call("devices.list", serde_json::Value::Null).await;
    let devices = resp.result.unwrap();
    // No transport injected (this harness) → the honest answer is
    // "unknown" — never "direct"/"offline" guessed from last_seen.
    assert_eq!(devices["devices"][0]["connection"], "unknown");
}

#[tokio::test(flavor = "multi_thread")]
async fn wrong_token_is_dropped_silently() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, _token) = start(dir.path(), "badtoken").await;

    let name = socket.to_ns_name::<GenericNamespaced>().unwrap();
    let conn = interprocess::local_socket::tokio::Stream::connect(name)
        .await
        .unwrap();
    let (rx, mut tx) = conn.split();
    tx.write_all(b"not-the-token\n").await.unwrap();
    tx.write_all(b"{\"id\":\"x\",\"method\":\"status\"}\n")
        .await
        .unwrap();
    let mut lines = BufReader::new(rx).lines();
    // The server hangs up without answering.
    let got = tokio::time::timeout(std::time::Duration::from_secs(2), lines.next_line())
        .await
        .expect("connection must be closed, not hang");
    assert!(
        matches!(got, Ok(None) | Err(_)),
        "no answer for a bad token"
    );
    // And the attempt is on the diagnostic record.
    let events = db.list_diag(10).await.unwrap();
    assert!(events.iter().any(|e| e.kind == "ipc.bad_token"));
}

#[tokio::test(flavor = "multi_thread")]
async fn pairing_start_and_confirm_over_ipc() {
    let dir = tempfile::tempdir().unwrap();
    let (db, pairing, socket, token) = start(dir.path(), "pairing").await;
    let mut c = IpcClient::connect(&socket, &token).await;

    let resp = c.call("pairing.start", serde_json::Value::Null).await;
    let qr = resp.result.unwrap()["qr"].as_str().unwrap().to_string();
    assert!(qr.starts_with("ppf://pair?node="));

    // A device knocks (directly through the engine — the network leg is
    // T-031's tests). The request parks in the IPC pending queue.
    let pairing_token = qr.rsplit("&t=").next().unwrap().to_string();
    let handle = {
        let pairing = pairing.clone();
        tokio::spawn(async move {
            pairing
                .handle_request(
                    transport::NodeId([0xDD; 32]),
                    &proto::PairRequest {
                        token: pairing_token,
                        device_name: "IPC 测试机".into(),
                        role: "member".into(),
                        device_hint: None,
                    },
                    now(),
                )
                .await
        })
    };
    // Wait until it shows up in status.
    for _ in 0..100 {
        let resp = c.call("status", serde_json::Value::Null).await;
        if resp.result.unwrap()["pending_pairs"] == 1 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    let resp = c
        .call(
            "pairing.confirm",
            serde_json::json!({ "device_name": "IPC 测试机", "accept": true }),
        )
        .await;
    assert!(resp.ok, "{resp:?}");
    assert!(handle.await.unwrap().is_ok(), "device side sees acceptance");
    let device = db.get_device(&[0xDD; 32]).await.unwrap().expect("row");
    assert_eq!(device.name, "IPC 测试机");
}

#[tokio::test(flavor = "multi_thread")]
async fn pairing_pending_lists_all_waiting_then_confirm_by_name() {
    // UX-08: 多台同时扫码 → pairing.pending 全量列出，逐行按名确认——
    // 不弹挤牙膏式顺序弹窗。三台入队 → 列表三行 → 按名确认中间那台 →
    // 剩两台 → 全清后列表空、status.pending_pairs = 0。
    let dir = tempfile::tempdir().unwrap();
    let (db, pairing, socket, token) = start(dir.path(), "pending").await;
    let mut c = IpcClient::connect(&socket, &token).await;

    let resp = c.call("pairing.start", serde_json::Value::Null).await;
    let qr = resp.result.unwrap()["qr"].as_str().unwrap().to_string();
    assert!(qr.starts_with("ppf://pair?node="));

    // 三台设备同时敲门——每台一枚独立一次性 token（Pairing::start 铸新
    // token，多枚共存；同一 token 只能被一台用，共用会被引擎拒）。
    let pairing = pairing.clone();
    let tokens: Vec<String> = (0..3)
        .map(|i| {
            let qr = pairing.start([0x11 + i as u8; 12], now());
            qr.rsplit("&t=").next().unwrap().to_string()
        })
        .collect();
    let names = ["设备A", "设备B", "设备C"];
    for (i, name) in names.iter().enumerate() {
        let pairing = pairing.clone();
        let token = tokens[i].clone();
        let name = name.to_string();
        tokio::spawn(async move {
            pairing
                .handle_request(
                    transport::NodeId([0xE0 + i as u8; 32]),
                    &proto::PairRequest {
                        token,
                        device_name: name,
                        role: "member".into(),
                        device_hint: None,
                    },
                    now(),
                )
                .await
        });
    }

    // 轮询直到三台都在 pending 列表里（一屏三行）。
    // DEV-01: pending 项是 {name, hint_match} 对象（兼容老 daemon 字符串）。
    let mut list: Vec<String> = Vec::new();
    for _ in 0..200 {
        let resp = c.call("pairing.pending", serde_json::Value::Null).await;
        let arr = resp.result.unwrap()["pending"].as_array().unwrap().clone();
        list = arr
            .iter()
            .map(|v| {
                v["name"]
                    .as_str()
                    .unwrap_or_else(|| v.as_str().unwrap())
                    .to_string()
            })
            .collect();
        if list.len() == 3 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert_eq!(list.len(), 3, "pending 必须全量列出三台: {list:?}");

    // 按名确认中间那台 → 列表剩两台（其余不受影响）。
    let resp = c
        .call(
            "pairing.confirm",
            serde_json::json!({ "device_name": "设备B", "accept": true }),
        )
        .await;
    assert!(resp.ok, "{resp:?}");
    assert_eq!(resp.result.unwrap()["device"], "设备B");
    let resp = c.call("pairing.pending", serde_json::Value::Null).await;
    let mut list: Vec<String> = resp.result.unwrap()["pending"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| {
            v["name"]
                .as_str()
                .unwrap_or_else(|| v.as_str().unwrap())
                .to_string()
        })
        .collect();
    // 并发入队顺序不保证——排序后断言集合等价。
    list.sort();
    assert_eq!(list, vec!["设备A".to_string(), "设备C".to_string()]);

    // 剩下两台按名拒绝 → 全清 → 列表空 + status.pending_pairs = 0。
    for name in ["设备A", "设备C"] {
        let resp = c
            .call(
                "pairing.confirm",
                serde_json::json!({ "device_name": name, "accept": false }),
            )
            .await;
        assert!(resp.ok, "{resp:?}");
    }
    let resp = c.call("pairing.pending", serde_json::Value::Null).await;
    assert_eq!(
        resp.result.unwrap()["pending"].as_array().unwrap().len(),
        0,
        "全清后列表必须为空（无残留状态）"
    );
    let resp = c.call("status", serde_json::Value::Null).await;
    assert_eq!(resp.result.unwrap()["pending_pairs"], 0);
    // B 已被允许——设备表里有它。
    let device = db.get_device(&[0xE1; 32]).await.unwrap().expect("row");
    assert_eq!(device.name, "设备B");
}

#[tokio::test(flavor = "multi_thread")]
async fn logs_export_zip_leaks_no_username() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "logs").await;
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/testuser".into());

    // A diag event that embeds a real user path — the classic leak.
    db.append_diag(&storage::DiagEvent {
        ts: 1,
        kind: "ingest.error".into(),
        detail: Some(format!("file {home}/Pictures/secret.jpg: denied")),
    })
    .await
    .unwrap();
    // DESK-10 补漏：diag 的 detail 是同一个洞的另一半——它也只过
    // 家目录替换，嵌在里面的全长 NodeId 会原样进包。
    db.append_diag(&storage::DiagEvent {
        ts: 2,
        kind: "backup.commit".into(),
        detail: Some(format!(
            "rel_path originals/{}/2026/08/a.jpg",
            "d7".repeat(32)
        )),
    })
    .await
    .unwrap();

    let mut c = IpcClient::connect(&socket, &token).await;
    let resp = c.call("logs.export", serde_json::Value::Null).await;
    assert!(resp.ok, "{resp:?}");
    let zip_path = resp.result.unwrap()["zip"].as_str().unwrap().to_string();

    let file = std::fs::File::open(&zip_path).unwrap();
    let mut zip = zip::ZipArchive::new(file).unwrap();
    let mut all_text = String::new();
    for i in 0..zip.len() {
        use std::io::Read as _;
        let mut f = zip.by_index(i).unwrap();
        let mut s = String::new();
        f.read_to_string(&mut s).unwrap();
        all_text.push_str(&s);
    }
    assert!(
        !all_text.contains(&home),
        "the export must not contain the real home path"
    );
    assert!(
        all_text.contains("<DATA>/Pictures/secret.jpg"),
        "the path must be present but sanitised: {all_text}"
    );
    assert!(
        !all_text.contains(&"d7".repeat(32)),
        "diag detail 里的全长 NodeId 也不许进包: {all_text}"
    );
    assert!(
        all_text.contains("d7d7d7d7…<masked>"),
        "长 hex 应掩到前 8 位: {all_text}"
    );
}

/// DESK-10: 导出包里必须有 audit.json（审计事件——配对/吊销/外部删除
/// 都在这条流里）。桌面壳把 daemon 这三份 JSON 原样搬进它本地组装的
/// bundle，少一份就等于支持案子里少一段时间线。actor 只出前缀。
#[tokio::test(flavor = "multi_thread")]
async fn logs_export_zip_carries_audit_events() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "logs-audit").await;
    db.append_audit(&storage::AuditEntry {
        ts: 42,
        actor: Some(vec![0xAB; 32]),
        action: "device.revoked".into(),
        target_hash: None,
        // DESK-10 真机验收暴露的漏：库的布局是
        // `originals/<nodeid>/YYYY/MM/<file>`，所以 detail 里嵌的
        // rel_path 本身就以全长 NodeId 开头——脱敏必须按「值的形状」
        // 做，不能只给 actor 这个字段名做前缀掩码。
        detail: Some(format!(
            "外部删除 originals/{}/2026/08/IMG_0042.jpg",
            "c4".repeat(32)
        )),
    })
    .await
    .unwrap();

    let mut c = IpcClient::connect(&socket, &token).await;
    let resp = c.call("logs.export", serde_json::Value::Null).await;
    assert!(resp.ok, "{resp:?}");
    let zip_path = resp.result.unwrap()["zip"].as_str().unwrap().to_string();

    let file = std::fs::File::open(&zip_path).unwrap();
    let mut zip = zip::ZipArchive::new(file).unwrap();
    let names: Vec<String> = (0..zip.len())
        .map(|i| zip.by_index(i).unwrap().name().to_string())
        .collect();
    assert!(
        names.iter().any(|n| n == "audit.json"),
        "audit.json must be in the export: {names:?}"
    );
    let mut audit = String::new();
    {
        use std::io::Read as _;
        zip.by_name("audit.json")
            .unwrap()
            .read_to_string(&mut audit)
            .unwrap();
    }
    assert!(audit.contains("device.revoked"), "{audit}");
    assert!(audit.contains("\"actor_prefix\": \"abababab\""), "{audit}");
    // 全量 NodeId（64 hex）绝不进包——actor 字段。
    assert!(!audit.contains(&"ab".repeat(32)), "{audit}");
    // …也不许从 detail 里的路径漏出去（这条就是真机验收抓到的漏）。
    // 判据加强：不看单个字段，而是扫整个包里有没有 ≥24 位连续 hex。
    let mut all_text = String::new();
    for i in 0..zip.len() {
        use std::io::Read as _;
        let mut f = zip.by_index(i).unwrap();
        let mut s = String::new();
        if f.read_to_string(&mut s).is_ok() {
            all_text.push_str(&s);
        }
    }
    assert!(
        !all_text.contains(&"c4".repeat(32)),
        "detail 里的全长 NodeId 泄漏了: {all_text}"
    );
    assert!(
        all_text.contains("c4c4c4c4…<masked>"),
        "路径应保留前 8 位便于对话: {all_text}"
    );
    if let Some(run) = longest_hex_run(&all_text) {
        assert!(
            run.len() < 24,
            "包里还有 {} 位连续 hex，脱敏不按值的形状做就会漏: {run}",
            run.len()
        );
    }
}

/// 扫出字符串里最长的一段连续 hex——导出包的脱敏判据用它，
/// 而不是「某个字段名不含某个已知常量」（后者会因为漏掉的字段
/// 而空转，DESK-10 真机验收就是这么漏的）。
fn longest_hex_run(s: &str) -> Option<String> {
    let mut best: Option<String> = None;
    let mut cur = String::new();
    for ch in s.chars() {
        if ch.is_ascii_hexdigit() {
            cur.push(ch);
        } else {
            if best.as_ref().is_none_or(|b| cur.len() > b.len()) {
                best = Some(std::mem::take(&mut cur));
            }
            cur.clear();
        }
    }
    if best.as_ref().is_none_or(|b| cur.len() > b.len()) {
        best = Some(cur);
    }
    best.filter(|b| !b.is_empty())
}

// ── IPC-02: events.subscribe——事件订阅通道（桌面壳告别 3s 轮询）──

/// 验收 1：订阅后注入配对请求 → pending_changed 事件帧 <100ms 到达
/// （对照轮询 3s 延迟）。走真实 pending 入队链路（Pairing 引擎 →
/// pending_tx → IpcServer 队列）。
#[tokio::test(flavor = "multi_thread")]
async fn subscription_delivers_pending_change_under_100ms() {
    let dir = tempfile::tempdir().unwrap();
    let (db, pairing, socket, token) = start(dir.path(), "sub-fast").await;

    // 订阅客户端：全量事件。
    let mut sub = IpcClient::connect(&socket, &token).await;
    let resp = sub.subscribe(None).await;
    assert!(resp.ok, "{resp:?}");
    assert_eq!(resp.result.unwrap()["subscribed"], true);

    // 注入配对请求：真实 pending 入队链路（handle_request 在 owner
    // 决策前入队——spawn 后挂住在 decision 上，confirm 才收尾）。
    let qr = pairing.start([0x11; 12], now() + 60_000);
    assert!(qr.contains("t=111111111111111111111111"));
    let pair_req = proto::PairRequest {
        token: "11".repeat(12),
        device_name: "事件测试机".into(),
        role: "member".into(),
        device_hint: None,
    };
    let peer = transport::NodeId([0xBB; 32]);
    let pairing2 = pairing.clone();
    let handle = tokio::spawn(async move {
        let _ = pairing2.handle_request(peer, &pair_req, now() + 1).await;
    });

    let t0 = std::time::Instant::now();
    let ev = sub.next_event().await;
    let elapsed = t0.elapsed();
    assert_eq!(ev["event"], "pairing.pending_changed", "{ev}");
    assert!(
        elapsed < std::time::Duration::from_millis(100),
        "事件延迟 {elapsed:?} 应 <100ms（对照轮询 3s）"
    );

    // 收尾：confirm 让 handle_request 结束，避免悬空 task。
    let mut c2 = IpcClient::connect(&socket, &token).await;
    let resp = c2
        .call(
            "pairing.confirm",
            serde_json::json!({ "accept": true, "device_name": "事件测试机" }),
        )
        .await;
    assert!(resp.ok, "{resp:?}");
    handle.await.unwrap();
    // confirm 处理掉 pending → 队列减（pending_changed），随后 accept
    // 落定 → device.changed（配对成功即时反映到桌面设备行）。
    let ev2 = sub.next_event().await;
    assert_eq!(ev2["event"], "pairing.pending_changed", "{ev2}");
    let ev3 = sub.next_event().await;
    assert_eq!(ev3["event"], "device.changed", "{ev3}");
    let device = db.get_device(&[0xBB; 32]).await.unwrap().expect("row");
    assert_eq!(device.name, "事件测试机");
}

/// 反证①：类型过滤——只订阅 status.changed 的连接收不到 pending 事件。
#[tokio::test(flavor = "multi_thread")]
async fn subscription_filter_blocks_unwanted_event_types() {
    let dir = tempfile::tempdir().unwrap();
    let (_db, pairing, socket, token) = start(dir.path(), "sub-filter").await;

    let mut sub = IpcClient::connect(&socket, &token).await;
    let resp = sub.subscribe(Some(vec!["status.changed"])).await;
    assert!(resp.ok, "{resp:?}");

    // 注入配对请求（pending 变化）。
    let _ = pairing.start([0x22; 12], now() + 60_000);
    let pair_req = proto::PairRequest {
        token: "22".repeat(12),
        device_name: "过滤测试机".into(),
        role: "member".into(),
        device_hint: None,
    };
    let pairing2 = pairing.clone();
    let handle = tokio::spawn(async move {
        let _ = pairing2
            .handle_request(transport::NodeId([0xBC; 32]), &pair_req, now() + 1)
            .await;
    });

    // 过滤连接：200ms 内必须没有任何事件行。
    let nothing =
        tokio::time::timeout(std::time::Duration::from_millis(200), sub.next_event()).await;
    assert!(nothing.is_err(), "过滤订阅收到了不该收的事件: {nothing:?}");

    // 收尾：confirm 结束挂起 task。
    let mut c2 = IpcClient::connect(&socket, &token).await;
    let resp = c2
        .call(
            "pairing.confirm",
            serde_json::json!({ "accept": true, "device_name": "过滤测试机" }),
        )
        .await;
    assert!(resp.ok, "{resp:?}");
    handle.await.unwrap();
}

/// 反证②：events.unsubscribe → 连接被服务端关闭（再读 = EOF）。
/// 客户端退订后依赖 60s 兜底轮询仍可用（降级路径）。
#[tokio::test(flavor = "multi_thread")]
async fn unsubscribe_closes_subscription_connection() {
    let dir = tempfile::tempdir().unwrap();
    let (_db, pairing, socket, token) = start(dir.path(), "sub-unsub").await;

    let mut sub = IpcClient::connect(&socket, &token).await;
    let resp = sub.subscribe(None).await;
    assert!(resp.ok, "{resp:?}");

    sub.unsubscribe().await;
    // 服务端应关闭连接——next_line 返回 None（EOF）。
    let eof =
        tokio::time::timeout(std::time::Duration::from_millis(500), sub.lines.next_line()).await;
    assert!(matches!(eof, Ok(Ok(None))), "退订后连接应被关闭: {eof:?}");

    // 退订后再发事件——没有连接接收，事件静默丢弃（不报错不阻塞）。
    let _ = pairing.start([0x33; 12], now() + 60_000);
    let pair_req = proto::PairRequest {
        token: "33".repeat(12),
        device_name: "退订测试机".into(),
        role: "member".into(),
        device_hint: None,
    };
    let pairing2 = pairing.clone();
    let handle = tokio::spawn(async move {
        let _ = pairing2
            .handle_request(transport::NodeId([0xBD; 32]), &pair_req, now() + 1)
            .await;
    });
    // 让事件发送路径跑完（sleep 后 handle_request 仍在等 decision——无妨）。
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let mut c2 = IpcClient::connect(&socket, &token).await;
    let resp = c2
        .call(
            "pairing.confirm",
            serde_json::json!({ "accept": true, "device_name": "退订测试机" }),
        )
        .await;
    assert!(resp.ok, "{resp:?}");
    handle.await.unwrap();
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// DESK-08：同一毫秒写进去的 N 条审计，`audit.list` 必须给出 **N 个互不相同
/// 的 id**。
///
/// 现场：WATCH-02 一次删 5 张照片 → 5 条 `asset.removed_external` 全落在
/// `ts=1787292449250`。桌面端活动流的 `#each` 用 `ts + ":" + action` 当 key，
/// 撞键 → Svelte 抛 `each_key_duplicate` → **整个活动流挂掉**。
/// 时间戳不是身份，主键才是。
#[tokio::test(flavor = "multi_thread")]
async fn audit_rows_in_the_same_millisecond_get_distinct_ids() {
    let dir = tempfile::tempdir().unwrap();
    let (db, _pairing, socket, token) = start(dir.path(), "audit-ids").await;
    let mut c = IpcClient::connect(&socket, &token).await;

    // 五条一模一样的动作、一模一样的时间戳——就是用户撞到的那个形状。
    const SAME_MS: i64 = 1_787_292_449_250;
    for i in 0..5 {
        db.append_audit(&storage::AuditEntry {
            ts: SAME_MS,
            actor: None,
            action: "asset.removed_external".into(),
            target_hash: None,
            detail: Some(format!("originals missing: originals/x/{i}.jpg")),
        })
        .await
        .unwrap();
    }

    let resp = c.call("audit.list", serde_json::Value::Null).await;
    assert!(resp.ok, "{resp:?}");
    let events = resp.result.unwrap()["events"].as_array().unwrap().clone();
    let removed: Vec<_> = events
        .iter()
        .filter(|e| e["action"] == "asset.removed_external")
        .collect();
    assert_eq!(removed.len(), 5, "五条都该回来");

    let mut ids: Vec<i64> = removed
        .iter()
        .map(|e| {
            e["id"]
                .as_i64()
                .expect("每条审计都必须带 id——前端拿它做 each key")
        })
        .collect();
    let before = ids.len();
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(
        ids.len(),
        before,
        "同毫秒的审计行 id 必须互不相同，否则前端 each key 撞键、活动流整块挂掉",
    );

    // 顺带钉死：ts 确实全都一样——否则这个测试根本没测到撞键的前提。
    assert!(
        removed.iter().all(|e| e["ts"].as_i64() == Some(SAME_MS)),
        "前提失效：五条的 ts 必须相同，测试才在测撞键",
    );
}
