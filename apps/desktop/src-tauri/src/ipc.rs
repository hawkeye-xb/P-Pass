//! Blocking IPC client for the daemon's local socket (T-034 wire:
//! first line = token, then one JSON request per line, one JSON
//! response per line). One fresh connection per call — simple and
//! stateless, plenty for a 3 s poll cadence.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;

use interprocess::local_socket::traits::Stream as _;
use interprocess::local_socket::{GenericNamespaced, Stream, ToNsName};
use serde_json::{json, Value};

/// Where to look for a daemon's ipc.token, in order.
pub fn token_candidates() -> Vec<PathBuf> {
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()));
    let mut v = Vec::new();
    if let Ok(dir) = std::env::var("PPF_DATA_DIR") {
        v.push(PathBuf::from(dir).join("ipc.token"));
    }
    v.push(home.join("ppf-library/ipc.token"));
    v.push(home.join("Library/Application Support/P-Pass/ipc.token"));
    // The wizard writes the user-picked library dir into config.toml's
    // data_dir, and the daemon puts ipc.token *there* — the fixed
    // candidates above miss it. Parse the live config so a daemon
    // launched via the wizard is actually discoverable (T-042 实测:
    // "点了没反应" = daemon 起来了但 token 找不到).
    if let Ok(raw) =
        std::fs::read_to_string(home.join("Library/Application Support/P-Pass/config.toml"))
    {
        for line in raw.lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("data_dir") {
                let rest = rest.trim_start();
                if let Some(val) = rest.strip_prefix('=') {
                    let val = val.trim().trim_matches('"').trim();
                    if !val.is_empty() {
                        v.push(PathBuf::from(val).join("ipc.token"));
                    }
                }
                break;
            }
        }
    }
    v
}

pub struct DaemonHandle {
    socket_name: String,
    token: String,
}

impl DaemonHandle {
    /// Find a RUNNING daemon: candidates are probed with a live status
    /// call — a stale token file from a dead daemon must never hijack
    /// discovery (real-world bug: leftover dogfood token).
    pub fn discover() -> Result<Self, String> {
        let mut last_err = "找不到运行中的 P-Pass 后台服务（ipc.token 不存在）".to_string();
        for path in token_candidates() {
            let Ok(content) = std::fs::read_to_string(&path) else {
                continue;
            };
            let mut lines = content.lines();
            let (Some(name), Some(token)) = (lines.next(), lines.next()) else {
                continue;
            };
            let handle = Self {
                socket_name: name.trim().to_string(),
                token: token.trim().to_string(),
            };
            match handle.call("status", serde_json::json!({})) {
                Ok(_) => return Ok(handle),
                Err(e) => {
                    // Stale token (dead daemon) — try the next candidate.
                    last_err = format!("{} 指向的服务无响应：{e}", path.display());
                }
            }
        }
        Err(last_err)
    }

    /// One request/response round trip.
    pub fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let name = self
            .socket_name
            .clone()
            .to_ns_name::<GenericNamespaced>()
            .map_err(|e| format!("socket 名不合法: {e}"))?;
        let conn = Stream::connect(name).map_err(|e| format!("连接后台服务失败: {e}"))?;
        let mut reader = BufReader::new(conn);

        let req = json!({ "id": method, "method": method, "params": params });
        let payload = format!("{token}\n{req}\n", token = self.token);
        reader
            .get_mut()
            .write_all(payload.as_bytes())
            .map_err(|e| format!("发送失败: {e}"))?;

        let mut line = String::new();
        reader
            .read_line(&mut line)
            .map_err(|e| format!("读取响应失败: {e}"))?;
        let resp: Value =
            serde_json::from_str(line.trim()).map_err(|e| format!("响应不是 JSON: {e}"))?;
        if resp["ok"].as_bool() == Some(true) {
            Ok(resp["result"].clone())
        } else {
            Err(resp["error"]["msg_key"]
                .as_str()
                .unwrap_or("err.unsupported")
                .to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The wizard writes the user-picked library dir into config.toml's
    /// data_dir, and the daemon puts ipc.token there. token_candidates
    /// must include that path or a wizard-launched daemon is invisible
    /// (T-042 实测: "点了没反应" = daemon 起来了但 token 找不到).
    #[test]
    fn candidates_include_config_data_dir() {
        let home = std::env::var("HOME").unwrap();
        let cfg_dir = PathBuf::from(&home).join("Library/Application Support/P-Pass");
        let cfg = cfg_dir.join("config.toml");
        let _ = std::fs::create_dir_all(&cfg_dir);
        let original = std::fs::read_to_string(&cfg).ok();
        std::fs::write(&cfg, "data_dir = \"/tmp/ppf-wizard-lib\"\n").unwrap();

        let candidates = token_candidates();
        assert!(
            candidates.contains(&PathBuf::from("/tmp/ppf-wizard-lib/ipc.token")),
            "candidates must include the config data_dir: {candidates:?}"
        );

        match original {
            Some(s) => std::fs::write(&cfg, s).unwrap(),
            None => {
                let _ = std::fs::remove_file(&cfg);
                let _ = std::fs::remove_dir(&cfg_dir);
            }
        }
    }
}
