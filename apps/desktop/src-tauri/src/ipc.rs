//! Blocking IPC client for the daemon's local socket (T-034 wire:
//! first line = token, then one JSON request per line, one JSON
//! response per line). One fresh connection per call — simple and
//! stateless, plenty for a 3 s poll cadence.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use interprocess::local_socket::traits::Stream as _;
use interprocess::local_socket::{GenericNamespaced, Stream, ToNsName};
use serde_json::{json, Value};

/// Read the `data_dir` value out of a config.toml, if any. Shared by the
/// desktop IPC token discovery and the wizard prefill (one config parser).
pub fn read_config_data_dir(dir: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(dir.join("config.toml")).ok()?;
    for line in raw.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("data_dir") {
            let rest = rest.trim_start();
            if let Some(val) = rest.strip_prefix('=') {
                let val = val.trim().trim_matches('"').trim();
                if !val.is_empty() {
                    return Some(val.to_string());
                }
            }
            break;
        }
    }
    None
}

/// Where to look for a daemon's ipc.token, in order.
///
/// T-042b: the platform data dir comes from `platform::adapter().data_dir()`
/// (macOS: ~/Library/Application Support/P-Pass; Windows: %APPDATA%\P-Pass)
/// instead of a hardcoded macOS-only path — the token discovery fix must
/// work on Windows too.
pub fn token_candidates() -> Vec<PathBuf> {
    use platform::PlatformAdapter as _;
    let data_dir = platform::adapter().data_dir();
    token_candidates_from(&data_dir)
}

/// Testable core: same order, but the platform data dir is injected.
pub fn token_candidates_from(data_dir: &Path) -> Vec<PathBuf> {
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()));
    let mut v = Vec::new();
    if let Ok(dir) = std::env::var("PPF_DATA_DIR") {
        v.push(PathBuf::from(dir).join("ipc.token"));
    }
    v.push(home.join("ppf-library/ipc.token"));
    v.push(data_dir.join("ipc.token"));
    // The wizard writes the user-picked library dir into config.toml's
    // data_dir, and the daemon puts ipc.token *there* — the fixed
    // candidates above miss it. Parse the live config so a daemon
    // launched via the wizard is actually discoverable (T-042 实测:
    // "点了没反应" = daemon 起来了但 token 找不到).
    if let Some(val) = read_config_data_dir(data_dir) {
        v.push(PathBuf::from(val).join("ipc.token"));
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

    /// IPC-02: 长连接事件订阅——连接保持，daemon 事件逐条回调。
    ///
    /// 阻塞直到连接断开（daemon 退出/重启/网络错误），返回 Err 后由
    /// 调用方决定重连。握手失败（老 daemon 无 events.subscribe）也返回
    /// Err——上层据此降级（前端 60s 兜底轮询仍在）。
    pub fn subscribe_events(
        &self,
        mut on_event: impl FnMut(Value),
    ) -> Result<(), String> {
        let name = self
            .socket_name
            .clone()
            .to_ns_name::<GenericNamespaced>()
            .map_err(|e| format!("socket 名不合法: {e}"))?;
        let conn = Stream::connect(name).map_err(|e| format!("连接后台服务失败: {e}"))?;
        let mut reader = BufReader::new(conn);

        let req = json!({ "id": "events.subscribe", "method": "events.subscribe", "params": {} });
        let payload = format!("{token}\n{req}\n", token = self.token);
        reader
            .get_mut()
            .write_all(payload.as_bytes())
            .map_err(|e| format!("发送失败: {e}"))?;

        let mut line = String::new();
        reader
            .read_line(&mut line)
            .map_err(|e| format!("读取握手响应失败: {e}"))?;
        let resp: Value =
            serde_json::from_str(line.trim()).map_err(|e| format!("响应不是 JSON: {e}"))?;
        if resp["ok"].as_bool() != Some(true) {
            return Err(resp["error"]["msg_key"]
                .as_str()
                .unwrap_or("err.unsupported")
                .to_string());
        }

        // 事件循环：newline JSON 事件帧，读到 EOF/错误即返回。
        loop {
            let mut ev_line = String::new();
            match reader.read_line(&mut ev_line) {
                Ok(0) => return Err("订阅连接被服务端关闭".into()),
                Ok(_) => {
                    let ev: Value = serde_json::from_str(ev_line.trim())
                        .map_err(|e| format!("事件不是 JSON: {e}"))?;
                    on_event(ev);
                }
                Err(e) => return Err(format!("读取事件失败: {e}")),
            }
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
    /// T-042b: rewritten against a TEMP dir — the old test wrote the
    /// developer's REAL ~/Library/Application Support/P-Pass/config.toml
    /// and a panic skipped the restore (never touch a real config).
    #[test]
    fn candidates_include_config_data_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg_dir = tmp.path().join("cfg");
        std::fs::create_dir_all(&cfg_dir).unwrap();
        std::fs::write(cfg_dir.join("config.toml"), "data_dir = \"/tmp/ppf-wizard-lib\"\n")
            .unwrap();

        let candidates = token_candidates_from(&cfg_dir);
        assert!(
            candidates.contains(&PathBuf::from("/tmp/ppf-wizard-lib/ipc.token")),
            "candidates must include the config data_dir: {candidates:?}"
        );
        // The platform data dir itself is a candidate (bundled installs).
        assert!(
            candidates.contains(&cfg_dir.join("ipc.token")),
            "candidates must include the platform data dir: {candidates:?}"
        );
    }

    /// T-042b: parse must tolerate a quoted value and ignore other keys.
    #[test]
    fn read_config_data_dir_parses_quoted_value() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(
            tmp.path().join("config.toml"),
            "bind_addr = \"0.0.0.0:41145\"\n\ndata_dir = \"/tmp/ppf-lib\"\n\nrelay_urls = []\n",
        )
        .unwrap();
        assert_eq!(
            read_config_data_dir(tmp.path()),
            Some("/tmp/ppf-lib".to_string())
        );
    }
}
