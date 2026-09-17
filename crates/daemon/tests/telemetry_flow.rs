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
        ms: 210,
        fail_stage: None,
    });
    t.record(TelemetryEvent::FlowItem {
        bytes: 123_456,
        dur_s: 42,
        resumed: true,
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
    t.record(TelemetryEvent::Error {
        code: "fetch_failed",
        stage: "fetch",
    });
    assert_eq!(t.flush_now().await, 5);

    // One POST, body = array of 5, every item schema-complete.
    assert_eq!(hits.load(Ordering::SeqCst), 1);
    let first_body = bodies.lock().unwrap()[0].clone();
    let batch = first_body.as_array().expect("batch is a JSON array");
    assert_eq!(batch.len(), 5);
    let names: Vec<&str> = batch.iter().map(|e| e["event"].as_str().unwrap()).collect();
    assert_eq!(
        names,
        ["conn", "flow_item", "first_byte", "daemon_alive", "error"]
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
    assert_eq!(batch[4]["code"], "fetch_failed");

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

/// TEL-05 RED proof: a half-dead endpoint (TCP accepted, NEVER responds)
/// must not park `flush_now` forever. Pre-TEL-05 this test hangs until the
/// outer 5s watchdog fires (reqwest had no total timeout) — that hang is
/// exactly the bug: the periodic loop parks here and the queue grows
/// unbounded. Post-fix the client's injected 100ms budget must surface as
/// a returned 0, letting the next scheduled flush proceed.
#[tokio::test(flavor = "multi_thread")]
async fn half_dead_endpoint_returns_within_timeout_not_forever() {
    // Black-hole server: accept, keep the socket, never write a response.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/telemetry", listener.local_addr().unwrap());
    tokio::spawn(async move {
        let mut held = Vec::new();
        loop {
            let Ok((sock, _)) = listener.accept().await else {
                return;
            };
            held.push(sock); // never read, never answer — half-dead endpoint
        }
    });

    let dir = tempfile::tempdir().unwrap();
    let t = Telemetry::with_timeout(true, url, dir.path(), std::time::Duration::from_millis(100));
    t.record(TelemetryEvent::FirstByte {
        ms: 1,
        kind: "thumb",
    });

    let outcome = tokio::time::timeout(std::time::Duration::from_secs(5), t.flush_now()).await;
    match outcome {
        // flush_now returns the batch size LEAVING the queue, not the count
        // accepted — timeout shares the TEL-02 drop-not-requeue semantics
        // (1 event was discarded, nothing re-queued). The point of this
        // test is that the call RETURNS at all within the budget.
        Ok(n) => assert_eq!(
            n, 1,
            "timed-out batch is discarded, not parked or re-queued"
        ),
        Err(_) => panic!("flush_now parked on a non-responding endpoint — TEL-05 bug"),
    }

    // The loop is not dead: a second flush still proceeds (returns 0 events
    // quickly — the batch was dropped, not re-queued, best-effort unchanged).
    let again = tokio::time::timeout(std::time::Duration::from_secs(5), t.flush_now())
        .await
        .expect("second flush must not park either");
    assert_eq!(again, 0);
}

/// TEL-05: bounded queue. Overflow drops the OLDEST events; the newest
/// must survive. 600 distinct events in ⇒ exactly QUEUE_CAP (500) out,
/// and the batch starts at event #100, not #0.
#[tokio::test(flavor = "multi_thread")]
async fn queue_cap_drops_oldest_and_bounds_memory() {
    let dir = tempfile::tempdir().unwrap();
    let (url, _hits, bodies) = mock_server().await;
    let t = Telemetry::new(true, url, dir.path());

    for i in 0..600u64 {
        t.record(TelemetryEvent::FirstByte {
            ms: i,
            kind: "thumb",
        });
    }
    let sent = t.flush_now().await;
    assert_eq!(sent, daemon::telemetry::QUEUE_CAP, "batch capped at 500");

    let batch = bodies.lock().unwrap()[0].clone();
    let events = batch.as_array().unwrap();
    assert_eq!(events.len(), daemon::telemetry::QUEUE_CAP);
    assert_eq!(
        events[0]["ms"].as_u64().unwrap(),
        100,
        "the 100 oldest events were dropped, not the newest"
    );
    assert_eq!(events.last().unwrap()["ms"].as_u64().unwrap(), 599);
}
