//! Local IPC for the tray UI (T-034, ADR-012): local socket / named pipe
//! via `interprocess` (no platform #[cfg] here — rule B.2), guarded by a
//! random per-launch token written into the data dir.
//!
//! Wire format: newline-delimited JSON. First line from the client is the
//! raw token; every following line is a `proto::Req`, answered by one
//! `proto::Resp` line. Wrong token = connection dropped, one diag event.
//!
//! Methods (契约): `status` `pairing.start` `pairing.confirm`
//! `devices.list` `device.revoke` `folder.set` `logs.export`.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use diag::state::DaemonState;
use interprocess::local_socket::tokio::prelude::*;
use interprocess::local_socket::{GenericNamespaced, ListenerOptions};
use proto::{codes, Req, Resp, RespError};
use storage::Db;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::diag_agg::DiagAgg;
use crate::pairing::{Pairing, PendingPair};

/// One IPC server per daemon. Owns the pending-pair queue the UI drains.
pub struct IpcServer {
    db: Db,
    pairing: Pairing,
    diag: DiagAgg,
    data_dir: PathBuf,
    pending: Arc<Mutex<Vec<PendingPair>>>,
}

impl IpcServer {
    /// `pending_rx` is the receiver returned by [`Pairing::new`] — the
    /// IPC layer takes over the owner-confirmation queue.
    pub fn new(
        db: Db,
        pairing: Pairing,
        diag: DiagAgg,
        data_dir: PathBuf,
        mut pending_rx: tokio::sync::mpsc::UnboundedReceiver<PendingPair>,
    ) -> Self {
        let pending: Arc<Mutex<Vec<PendingPair>>> = Arc::default();
        let queue = Arc::clone(&pending);
        let diag2 = diag.clone();
        tokio::spawn(async move {
            while let Some(p) = pending_rx.recv().await {
                diag2.apply(diag::DaemonEvent::PairingStarted);
                queue.lock().expect("pending lock").push(p);
            }
        });
        Self {
            db,
            pairing,
            diag,
            data_dir,
            pending,
        }
    }

    /// Bind the named local socket, write the token file, serve forever.
    /// The socket name is `ppf-<8 hex of a random id>` unless a fixed
    /// name is passed (tests pass one; production derives from data_dir).
    pub async fn serve(self: Arc<Self>, socket_name: &str, token: [u8; 32]) -> anyhow::Result<()> {
        let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
        std::fs::create_dir_all(&self.data_dir)?;
        // The token file is how the UI finds AND authenticates the daemon.
        std::fs::write(
            self.data_dir.join("ipc.token"),
            format!("{socket_name}\n{token_hex}\n"),
        )?;

        // The socket name is stable now (derived from the persistent
        // NodeId) — clear a stale file left by a killed predecessor or
        // bind fails with EADDRINUSE and the whole IPC plane dies
        // (launchd guarantees single instance, so unlink is safe).
        #[cfg(unix)]
        {
            let _ = std::fs::remove_file(format!("/tmp/{socket_name}"));
        }
        let name = socket_name.to_ns_name::<GenericNamespaced>()?;
        let listener = ListenerOptions::new().name(name).create_tokio()?;
        loop {
            let conn = match listener.accept().await {
                Ok(c) => c,
                Err(e) => {
                    tracing::warn!("ipc accept: {e}");
                    continue;
                }
            };
            let server = Arc::clone(&self);
            let expected = token_hex.clone();
            tokio::spawn(async move {
                if let Err(e) = server.handle_conn(conn, &expected).await {
                    tracing::debug!("ipc conn ended: {e}");
                }
            });
        }
    }

    async fn handle_conn(
        &self,
        conn: interprocess::local_socket::tokio::Stream,
        expected_token: &str,
    ) -> anyhow::Result<()> {
        let (rx, mut tx) = conn.split();
        let mut lines = BufReader::new(rx).lines();

        let Some(first) = lines.next_line().await? else {
            return Ok(());
        };
        if first.trim() != expected_token {
            let _ = self
                .db
                .append_diag(&storage::DiagEvent {
                    ts: now_ms(),
                    kind: "ipc.bad_token".into(),
                    detail: None,
                })
                .await;
            return Ok(()); // drop the connection, say nothing
        }

        while let Some(line) = lines.next_line().await? {
            if line.trim().is_empty() {
                continue;
            }
            let resp = match serde_json::from_str::<Req>(&line) {
                Ok(req) => self.dispatch(req).await,
                Err(_) => Resp::err(
                    String::new(),
                    RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                ),
            };
            let mut out = serde_json::to_string(&resp)?;
            out.push('\n');
            tx.write_all(out.as_bytes()).await?;
        }
        Ok(())
    }

    async fn dispatch(&self, req: Req) -> Resp {
        let id = req.id.clone();
        let internal = |id: String| {
            Resp::err(
                id,
                RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
            )
        };
        match req.method.as_str() {
            "status" => match self.status().await {
                Ok(v) => Resp::ok(id, v),
                Err(_) => internal(id),
            },
            "pairing.start" => {
                let mut token = [0u8; 32];
                if getrandom::fill(&mut token).is_err() {
                    return internal(id);
                }
                let qr = self.pairing.start(token, now_ms());
                Resp::ok(id, serde_json::json!({ "qr": qr }))
            }
            "pairing.confirm" => {
                let accept = req
                    .params
                    .get("accept")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let device_name = req
                    .params
                    .get("device_name")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned);
                match self.confirm(device_name.as_deref(), accept) {
                    Some(name) => {
                        Resp::ok(id, serde_json::json!({ "decided": accept, "device": name }))
                    }
                    None => Resp::err(
                        id,
                        RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                    ),
                }
            }
            "devices.list" => match self.db.list_devices().await {
                Ok(devices) => {
                    let list: Vec<_> = devices
                        .iter()
                        .map(|d| {
                            serde_json::json!({
                                "node_id": hex(&d.node_id),
                                "name": d.name,
                                "role": d.role.as_str(),
                                "revoked": d.revoked,
                                "last_seen": d.last_seen,
                            })
                        })
                        .collect();
                    Resp::ok(id, serde_json::json!({ "devices": list }))
                }
                Err(_) => internal(id),
            },
            "device.revoke" => {
                let Some(node_hex) = req.params.get("node_id").and_then(|v| v.as_str()) else {
                    return Resp::err(
                        id,
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                };
                let Some(node_id) = parse_hex32(node_hex) else {
                    return Resp::err(
                        id,
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                };
                match self.db.revoke(&node_id).await {
                    Ok(revoked) => {
                        if revoked {
                            let _ = self
                                .db
                                .append_audit(&storage::AuditEntry {
                                    ts: now_ms(),
                                    actor: None, // 本机 owner 经 IPC 操作
                                    action: "device.revoked".into(),
                                    target_hash: None,
                                    detail: Some(node_hex.into()),
                                })
                                .await;
                        }
                        Resp::ok(id, serde_json::json!({ "revoked": revoked }))
                    }
                    Err(_) => internal(id),
                }
            }
            "folder.set" => {
                // MVP: record the choice; the daemon applies it on next
                // launch (config.toml is the single source, T-004).
                let Some(path) = req.params.get("path").and_then(|v| v.as_str()) else {
                    return Resp::err(
                        id,
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                };
                match self.write_folder_config(path) {
                    Ok(()) => Resp::ok(
                        id,
                        serde_json::json!({ "saved": true, "applies": "on-restart" }),
                    ),
                    Err(_) => internal(id),
                }
            }
            "logs.export" => match self.export_logs().await {
                Ok(zip_path) => {
                    Resp::ok(id, serde_json::json!({ "zip": zip_path.to_string_lossy() }))
                }
                Err(e) => {
                    tracing::warn!("logs.export failed: {e}");
                    internal(id)
                }
            },
            _ => Resp::err(
                id,
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            ),
        }
    }

    /// Decide one pending pairing request: by device name, or the queue
    /// head when `device_name` is None. Returns the decided device's
    /// name. Shared by IPC and the interim console confirmer in main.
    pub fn confirm(&self, device_name: Option<&str>, accept: bool) -> Option<String> {
        let mut queue = self.pending.lock().expect("pending lock");
        let idx = match device_name {
            Some(name) => queue.iter().position(|p| p.device_name == name),
            None => (!queue.is_empty()).then_some(0),
        }?;
        let p = queue.remove(idx);
        if queue.is_empty() {
            self.diag.apply(diag::DaemonEvent::PairingEnded);
        }
        let name = p.device_name.clone();
        p.decide(accept);
        Some(name)
    }

    /// Names of requests waiting for the owner (UI list / console prompt).
    pub fn pending_names(&self) -> Vec<String> {
        self.pending
            .lock()
            .expect("pending lock")
            .iter()
            .map(|p| p.device_name.clone())
            .collect()
    }

    async fn status(&self) -> anyhow::Result<serde_json::Value> {
        let devices = self.db.list_devices().await?;
        let state = self.diag.state();
        let pending = self.pending.lock().expect("pending lock").len();
        Ok(serde_json::json!({
            "state": state_name(&state),
            "msg_key": state.msg_key(),
            "devices": devices.len(),
            "revoked": devices.iter().filter(|d| d.revoked).count(),
            "pending_pairs": pending,
            // Where the photos physically live — the UI's "open the
            // photo folder" needs an answer to "传到哪儿了" (real
            // walkthrough question, 2026-07-31).
            "library_dir": self.data_dir.display().to_string(),
        }))
    }

    fn write_folder_config(&self, path: &str) -> anyhow::Result<()> {
        let config_path = self.data_dir.join("config.toml");
        let doc = std::fs::read_to_string(&config_path).unwrap_or_default();
        // Top-level TOML keys MUST sit before the first [section] header —
        // a bare append lands inside [telemetry] and the daemon refuses
        // to start (real crash-loop, 2026-07-31). Rebuild: strip any old
        // data_dir line, then insert the new one at the very top.
        let body: String = doc
            .lines()
            .filter(|l| !l.trim_start().starts_with("data_dir"))
            .collect::<Vec<_>>()
            .join("\n");
        let updated = format!("data_dir = {path:?}\n{body}\n");
        std::fs::write(&config_path, updated)?;
        Ok(())
    }


    /// Export diagnostics as a zip beside the data dir. Every path-like
    /// string is sanitised: the user's home directory becomes `<DATA>` —
    /// a shared log must never leak a username (契约).
    async fn export_logs(&self) -> anyhow::Result<PathBuf> {
        let events = self.db.list_diag(1000).await?;
        let devices = self.db.list_devices().await?;
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_default();

        let diag_json = serde_json::to_string_pretty(
            &events
                .iter()
                .map(|e| {
                    serde_json::json!({
                        "ts": e.ts,
                        "kind": e.kind,
                        "detail": e.detail.as_deref().map(|d| sanitize(d, &home)),
                    })
                })
                .collect::<Vec<_>>(),
        )?;
        let devices_json = serde_json::to_string_pretty(
            &devices
                .iter()
                .map(|d| {
                    serde_json::json!({
                        // Only a prefix — the full NodeId is not needed to
                        // discuss a support case.
                        "node_id_prefix": hex(&d.node_id[..4.min(d.node_id.len())]),
                        "name": sanitize(&d.name, &home),
                        "role": d.role.as_str(),
                        "revoked": d.revoked,
                    })
                })
                .collect::<Vec<_>>(),
        )?;

        let zip_path = self.data_dir.join("ppf-logs.zip");
        let file = std::fs::File::create(&zip_path)?;
        let mut zip = zip::ZipWriter::new(file);
        let opts = zip::write::SimpleFileOptions::default();
        use std::io::Write as _;
        zip.start_file("diag_events.json", opts)?;
        zip.write_all(diag_json.as_bytes())?;
        zip.start_file("devices.json", opts)?;
        zip.write_all(devices_json.as_bytes())?;
        zip.finish()?;
        Ok(zip_path)
    }
}

/// Replace the user's home directory (and thus their username) in any
/// string destined for an export.
fn sanitize(s: &str, home: &str) -> String {
    if home.is_empty() {
        return s.to_string();
    }
    s.replace(home, "<DATA>")
}

fn state_name(s: &DaemonState) -> &'static str {
    match s {
        DaemonState::OnlineDirect => "ONLINE_DIRECT",
        DaemonState::OnlineRelay => "ONLINE_RELAY",
        DaemonState::StorageOffline { .. } => "STORAGE_OFFLINE",
        DaemonState::Pairing => "PAIRING",
        DaemonState::DiskFull { .. } => "DISK_FULL",
        DaemonState::Indexing { .. } => "INDEXING",
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn parse_hex32(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() != 64 {
        return None;
    }
    let mut out = Vec::with_capacity(32);
    for chunk in s.as_bytes().chunks_exact(2) {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
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
    fn sanitize_replaces_home_with_data_marker() {
        let s = "/Users/alice/Pictures/x.jpg failed";
        assert_eq!(sanitize(s, "/Users/alice"), "<DATA>/Pictures/x.jpg failed");
        assert_eq!(sanitize(s, ""), s, "no home known → unchanged");
    }

    #[test]
    fn hex32_roundtrip_and_rejects() {
        assert!(parse_hex32("xyz").is_none());
        assert_eq!(parse_hex32(&"ab".repeat(32)).unwrap(), vec![0xab; 32]);
    }
}
