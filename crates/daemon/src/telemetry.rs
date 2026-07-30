//! Telemetry client (T-035, 手册 §8 事件字典 v1 原样实施).
//!
//! Four events, common fields `anon_id`/`ver`/`ts` on every one. The
//! anon_id is random at first launch and persisted — never derived from
//! anything identifying. **`enabled = false` means ZERO network calls**
//! (契约): events are dropped at the door, not queued, not sent.
//! No IPs stored server-side, no paths, no file names in any field.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};

/// Batch flush cadence (契约: 每 5min).
pub const FLUSH_INTERVAL: Duration = Duration::from_secs(300);

/// 手册 §8 的四个事件——字段逐字典实施.
#[derive(Debug, Clone)]
pub enum Event {
    Conn {
        path: &'static str, // lan | direct | relay
        ipver: &'static str,
        ms: u64,
        fail_stage: Option<&'static str>,
        country: Option<String>,
        isp_hash: Option<String>,
    },
    BackupSession {
        files: u32,
        bytes: u64,
        dur_s: u64,
        resumed: bool,
        trigger: &'static str, // periodic | uidt
    },
    FirstByte {
        ms: u64,
        kind: &'static str, // thumb | blob
    },
    DaemonAlive {
        uptime_h: u64,
        os: String,
        ver: String,
    },
}

impl Event {
    fn into_value(self, anon_id: &str, ver: &str, ts: i64) -> Value {
        let (event, mut fields) = match self {
            Event::Conn {
                path,
                ipver,
                ms,
                fail_stage,
                country,
                isp_hash,
            } => (
                "conn",
                json!({ "path": path, "ipver": ipver, "ms": ms,
                        "fail_stage": fail_stage, "country": country,
                        "isp_hash": isp_hash }),
            ),
            Event::BackupSession {
                files,
                bytes,
                dur_s,
                resumed,
                trigger,
            } => (
                "backup_session",
                json!({ "files": files, "bytes": bytes, "dur_s": dur_s,
                        "resumed": resumed, "trigger": trigger }),
            ),
            Event::FirstByte { ms, kind } => ("first_byte", json!({ "ms": ms, "kind": kind })),
            Event::DaemonAlive { uptime_h, os, ver } => (
                "daemon_alive",
                json!({ "uptime_h": uptime_h, "os": os, "ver": ver }),
            ),
        };
        let obj = fields.as_object_mut().expect("built as object");
        obj.insert("event".into(), json!(event));
        obj.insert("anon_id".into(), json!(anon_id));
        obj.insert("ver".into(), json!(ver));
        obj.insert("ts".into(), json!(ts));
        fields
    }
}

/// The client. Cloneable; subsystems call [`Telemetry::record`].
#[derive(Clone)]
pub struct Telemetry {
    enabled: bool,
    url: String,
    anon_id: String,
    ver: String,
    queue: Arc<Mutex<Vec<Value>>>,
    http: reqwest::Client,
}

impl Telemetry {
    /// `enabled=false` builds a no-op client: `record` drops events at
    /// the door and no flush task should be spawned.
    pub fn new(enabled: bool, url: String, data_dir: &Path) -> Self {
        Self {
            enabled,
            url,
            anon_id: if enabled {
                load_or_create_anon_id(data_dir)
            } else {
                String::new() // never even minted when telemetry is off
            },
            ver: env!("CARGO_PKG_VERSION").to_string(),
            queue: Arc::default(),
            http: reqwest::Client::new(),
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// Queue one event (dropped unless enabled).
    pub fn record(&self, event: Event) {
        if !self.enabled {
            return;
        }
        let value = event.into_value(&self.anon_id, &self.ver, now_ms());
        self.queue.lock().expect("telemetry queue").push(value);
    }

    /// Send the queued batch now. Returns how many events went out.
    /// 契约: enabled=false ⇒ 零网络调用 — this returns 0 without touching
    /// the socket layer at all.
    pub async fn flush_now(&self) -> usize {
        if !self.enabled {
            return 0;
        }
        let batch: Vec<Value> = {
            let mut q = self.queue.lock().expect("telemetry queue");
            std::mem::take(&mut *q)
        };
        if batch.is_empty() {
            return 0;
        }
        let n = batch.len();
        match self.http.post(&self.url).json(&batch).send().await {
            Ok(resp) if resp.status().is_success() => n,
            Ok(resp) => {
                tracing::debug!("telemetry endpoint answered {}", resp.status());
                // Dropped, not re-queued: telemetry is best-effort and must
                // never grow unbounded on a broken endpoint.
                n
            }
            Err(e) => {
                tracing::debug!("telemetry send failed: {e}");
                n
            }
        }
    }

    /// The periodic flush loop (production; tests call `flush_now`).
    pub async fn run(self) {
        if !self.enabled {
            return; // zero network calls, zero timers
        }
        loop {
            tokio::time::sleep(FLUSH_INTERVAL).await;
            let _ = self.flush_now().await;
        }
    }
}

/// First launch mints a random id and persists it; every later launch
/// reuses it. Random = no linkage to hardware, user, or install path.
fn load_or_create_anon_id(data_dir: &Path) -> String {
    let path = data_dir.join("anon_id");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let trimmed = existing.trim();
        if trimmed.len() == 32 {
            return trimmed.to_string();
        }
    }
    let mut bytes = [0u8; 16];
    let _ = getrandom::fill(&mut bytes);
    let id: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let _ = std::fs::create_dir_all(data_dir);
    let _ = std::fs::write(&path, &id);
    id
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anon_id_is_stable_across_launches() {
        let dir = tempfile::tempdir().unwrap();
        let a = load_or_create_anon_id(dir.path());
        let b = load_or_create_anon_id(dir.path());
        assert_eq!(a, b);
        assert_eq!(a.len(), 32);
    }

    #[test]
    fn every_event_carries_the_common_fields() {
        let events = [
            Event::Conn {
                path: "direct",
                ipver: "v6",
                ms: 120,
                fail_stage: None,
                country: None,
                isp_hash: None,
            },
            Event::BackupSession {
                files: 10,
                bytes: 1024,
                dur_s: 5,
                resumed: false,
                trigger: "periodic",
            },
            Event::FirstByte {
                ms: 80,
                kind: "thumb",
            },
            Event::DaemonAlive {
                uptime_h: 24,
                os: "macos".into(),
                ver: "0.1.0".into(),
            },
        ];
        for (event, name) in
            events
                .into_iter()
                .zip(["conn", "backup_session", "first_byte", "daemon_alive"])
        {
            let v = event.into_value("cafebabe", "0.1.0", 42);
            assert_eq!(v["event"], name);
            assert_eq!(v["anon_id"], "cafebabe");
            assert_eq!(v["ver"], "0.1.0");
            assert_eq!(v["ts"], 42);
        }
    }

    #[test]
    fn disabled_never_mints_an_anon_id() {
        let dir = tempfile::tempdir().unwrap();
        let t = Telemetry::new(false, "http://127.0.0.1:1/x".into(), dir.path());
        assert!(!t.enabled());
        assert!(
            !dir.path().join("anon_id").exists(),
            "disabled telemetry must not even create an id"
        );
    }
}
