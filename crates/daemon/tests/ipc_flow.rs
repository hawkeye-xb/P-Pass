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
    let (pairing, pending_rx) = Pairing::new(db.clone(), transport::NodeId([0xCC; 32]), None);
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
    // Wait for the socket to exist (serve binds asynchronously).
    for _ in 0..100 {
        if dir.join("ipc.token").exists() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
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
