//! T-035 acceptance: a mock HTTP server receives the batch and validates
//! the schema (手册 §8); with the switch off, ZERO requests arrive.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use daemon::{Telemetry, TelemetryEvent};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Minimal HTTP/1.1 server: counts requests, captures JSON bodies.
async fn mock_server() -> (
    String,
    Arc<AtomicUsize>,
    Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/telemetry", listener.local_addr().unwrap());
    let hits = Arc::new(AtomicUsize::new(0));
    let bodies: Arc<std::sync::Mutex<Vec<serde_json::Value>>> = Arc::default();
    let (h, b) = (Arc::clone(&hits), Arc::clone(&bodies));
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            h.fetch_add(1, Ordering::SeqCst);
            let b = Arc::clone(&b);
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut tmp = [0u8; 4096];
                // Read until headers + declared body length are in.
                loop {
                    let Ok(n) = sock.read(&mut tmp).await else {
                        return;
                    };
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                    if let Some(pos) = find_body(&buf) {
                        let headers = String::from_utf8_lossy(&buf[..pos]);
                        let len = headers
                            .lines()
                            .find_map(|l| {
                                l.to_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().ok())
                            })
                            .flatten()
                            .unwrap_or(0);
                        if buf.len() >= pos + len {
                            if let Ok(v) = serde_json::from_slice(&buf[pos..pos + len]) {
                                b.lock().unwrap().push(v);
                            }
                            break;
                        }
                    }
                }
                let _ = sock
                    .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
                    .await;
            });
        }
    });
    (url, hits, bodies)
}

fn find_body(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
}

#[tokio::test(flavor = "multi_thread")]
async fn batch_arrives_and_schema_is_valid() {
    let dir = tempfile::tempdir().unwrap();
    let (url, hits, bodies) = mock_server().await;
    let t = Telemetry::new(true, url, dir.path());

    t.record(TelemetryEvent::Conn {
        path: "direct",
        ipver: "v6",
        ms: 210,
        fail_stage: None,
        country: None,
        isp_hash: None,
    });
    t.record(TelemetryEvent::BackupSession {
        files: 500,
        bytes: 123_456,
        dur_s: 42,
        resumed: true,
        trigger: "periodic",
    });
    t.record(TelemetryEvent::FirstByte {
        ms: 90,
        kind: "thumb",
    });
    t.record(TelemetryEvent::DaemonAlive {
        uptime_h: 24,
        os: "macos".into(),
        ver: "0.1.0".into(),
    });
    assert_eq!(t.flush_now().await, 4);

    // One POST, body = array of 4, every item schema-complete.
    assert_eq!(hits.load(Ordering::SeqCst), 1);
    let first_body = bodies.lock().unwrap()[0].clone();
    let batch = first_body.as_array().expect("batch is a JSON array");
    assert_eq!(batch.len(), 4);
    let names: Vec<&str> = batch.iter().map(|e| e["event"].as_str().unwrap()).collect();
    assert_eq!(
        names,
        ["conn", "backup_session", "first_byte", "daemon_alive"]
    );
    for e in batch {
        // 公共字段 (手册 §8): anon_id + ver + ts on every event.
        assert_eq!(e["anon_id"].as_str().unwrap().len(), 32);
        assert!(e["ver"].as_str().is_some());
        assert!(e["ts"].as_i64().unwrap() > 0);
        // 隐私红线: no path-ish strings anywhere.
        let raw = e.to_string();
        assert!(
            !raw.contains('/') || raw.contains("\"/\""),
            "no paths: {raw}"
        );
    }
    // Field spot-checks per dictionary.
    assert_eq!(batch[0]["path"], "direct");
    assert_eq!(batch[1]["resumed"], true);
    assert_eq!(batch[2]["kind"], "thumb");
    assert_eq!(batch[3]["uptime_h"], 24);

    // Queue drained: nothing further goes out.
    assert_eq!(t.flush_now().await, 0);
    assert_eq!(hits.load(Ordering::SeqCst), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn disabled_switch_means_zero_requests() {
    let dir = tempfile::tempdir().unwrap();
    let (url, hits, _bodies) = mock_server().await;
    let t = Telemetry::new(false, url, dir.path());

    t.record(TelemetryEvent::FirstByte {
        ms: 1,
        kind: "thumb",
    });
    t.record(TelemetryEvent::DaemonAlive {
        uptime_h: 1,
        os: "macos".into(),
        ver: "0.1.0".into(),
    });
    assert_eq!(t.flush_now().await, 0);
    // Give any stray socket work a moment to surface, then assert silence.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(
        hits.load(Ordering::SeqCst),
        0,
        "enabled=false must mean ZERO network calls"
    );
}
