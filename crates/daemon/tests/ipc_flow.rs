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
}

/// Unique socket name per test (namespaced sockets are machine-global).
fn socket_name(tag: &str) -> String {
    format!("ppf-test-{}-{}", std::process::id(), tag)
}

async fn start(dir: &std::path::Path, tag: &str) -> (Db, Pairing, String, String) {
    let db = Db::open_in_memory().await.unwrap();
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xCC; 32]), None, None);
    let diag = DiagAgg::new(db.clone());
    let ipc = Arc::new(IpcServer::new(
        db.clone(),
        pairing.clone(),
        diag,
        dir.to_path_buf(),
        pending_rx,
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
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
