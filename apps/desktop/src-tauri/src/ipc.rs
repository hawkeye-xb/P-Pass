//! Blocking IPC client for the daemon's local socket (T-034 wire:
//! first line = token, then one JSON request per line, one JSON
//! response per line). One fresh connection per call — simple and
//! stateless, plenty for a 3 s poll cadence.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// NET-11: daemon 挂死检测保险丝——**不是**「预期耗时」预算。
/// 来历：daemon 侧最重的同步路径 `thumb.get` 预算 5s + 一倍余量 = 10s；
/// 本地 socket 上任何合法 handler 都不该让人类等到它。撞上这根线说明
/// daemon 活着但僵了（同族前科 DESK-13 的阻塞盘 IO / 内部锁 / 慢外部
/// 依赖），壳必须断臂报死因，而不是陪着僵死拖垮 Tauri blocking 池。
/// 单一固定值，禁止按方法动态推算（NET-07 红线：启发式=摆钟复发）。
pub const IPC_READ_TIMEOUT: Duration = Duration::from_secs(10);

use interprocess::local_socket::traits::Stream as _;
use interprocess::local_socket::{GenericNamespaced, Stream, ToNsName};
use serde_json::{json, Value};

/// NET-11: socket 读超时在 std::io 里的表现跨平台不统一（TimedOut 是
/// 稳定档；部分平台映射成 WouldBlock——非阻塞语义的超时即此）。只认
/// 这两档，且调用方（BufReader）可能已消耗部分字节，故超时即弃连接。
fn is_timeout_err(e: &std::io::Error) -> bool {
    matches!(
        e.kind(),
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
    )
}

/// 超时错误串：方法名必须进错误（卡期望行为 1——没有死因的超时等于没做）。
fn ipc_timeout_msg(method: &str, timeout: Duration) -> String {
    format!("ipc timeout: {method} > {}s", timeout.as_secs())
}

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
    ///
    /// NET-11：带固定读超时保险丝（[`IPC_READ_TIMEOUT`]）——daemon 活着但
    /// 僵住时，壳必须报「哪个方法超时了」而不是陪着无限等（同步 command
    /// 占 Tauri blocking 池，无上限等待会被 3s 轮询堆满、整壳冻结）。
    pub fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        self.call_with_timeout(method, params, IPC_READ_TIMEOUT)
    }

    /// 实现体拆出来让测试能注入短阈值（NET-11 RED 门禁）；生产路径
    /// 只许经 [`call`] 用统一常量，禁止按方法动态推算（NET-07 红线）。
    pub fn call_with_timeout(
        &self,
        method: &str,
        params: Value,
        read_timeout: Duration,
    ) -> Result<Value, String> {
        let name = self
            .socket_name
            .clone()
            .to_ns_name::<GenericNamespaced>()
            .map_err(|e| format!("socket 名不合法: {e}"))?;
        let conn = Stream::connect(name).map_err(|e| format!("连接后台服务失败: {e}"))?;
        // 保险丝装在 socket 上：超时后连接直接丢弃——「每调一新连接」的
        // 模式天然满足，不回收复用。
        conn.set_recv_timeout(Some(read_timeout))
            .map_err(|e| format!("设置读超时失败: {e}"))?;
        let mut reader = BufReader::new(conn);

        let req = json!({ "id": method, "method": method, "params": params });
        let payload = format!("{token}\n{req}\n", token = self.token);
        reader
            .get_mut()
            .write_all(payload.as_bytes())
            .map_err(|e| format!("发送失败: {e}"))?;

        let mut line = String::new();
        match reader.read_line(&mut line) {
            // 超时即弃连接（BufReader 可能已吞半行，不可复用）；
            // Err 带方法名——死因必须可报告。
            Err(e) if is_timeout_err(&e) => return Err(ipc_timeout_msg(method, read_timeout)),
            Ok(_) => {}
            Err(e) => return Err(format!("读取响应失败: {e}")),
        }
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
    /// NET-11 豁免（刻意不装 [`IPC_READ_TIMEOUT`]）：这条连接的设计语义
    /// 就是「等事件」——事件之间空闲多久都合法（daemon 静默=没事发生），
    /// 装上读超时反而会把正常静默误判成失联。挂死风险已有独立闭环：
    /// 断线 2s 退避重连（lib.rs `start_event_stream`），且壳侧冻结的元凶
    /// 是 3s 轮询的同步 call 堆积，不是这条只读长连接。
    ///
    /// 阻塞直到连接断开（daemon 退出/重启/网络错误），返回 Err 后由
    /// 调用方决定重连。握手失败（老 daemon 无 events.subscribe）也返回
    /// Err——上层据此降级（前端 60s 兜底轮询仍在）。
    pub fn subscribe_events(&self, mut on_event: impl FnMut(Value)) -> Result<(), String> {
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
        std::fs::write(
            cfg_dir.join("config.toml"),
            "data_dir = \"/tmp/ppf-wizard-lib\"\n",
        )
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

    // ── NET-11: IPC 读超时保险丝 ──────────────────────────────────────

    /// 假 IPC 服务端：接受连接、消费请求行，然后**永不回行**——
    /// 复现「daemon 活着但 handler 挂死」的形态（NET-08 普查焊点 D1）。
    /// 唯一名（pid+纳秒）——重跑/并行不撞孤儿 socket 文件。
    fn stub_socket_name(tag: &str) -> String {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("ppf-net11-{tag}-{}-{nanos}", std::process::id())
    }

    fn stub_silent_server() -> String {
        use interprocess::local_socket::traits::Listener as _;
        let name = stub_socket_name("silent");
        let ns = name.clone().to_ns_name::<GenericNamespaced>().unwrap();
        let listener = interprocess::local_socket::ListenerOptions::new()
            .name(ns)
            .create_sync()
            .expect("stub bind");
        std::thread::spawn(move || loop {
            let Ok(conn) = listener.accept() else {
                continue;
            };
            // 读掉 token + 请求行，然后挂着不回——正是保险丝要治的死状。
            let mut reader = BufReader::new(conn);
            let mut junk = String::new();
            let _ = reader.read_line(&mut junk);
            let _ = reader.read_line(&mut junk);
            std::mem::forget(reader);
        });
        name
    }

    fn stub_handle(socket_name: &str) -> DaemonHandle {
        DaemonHandle {
            socket_name: socket_name.to_string(),
            token: "deadbeef".to_string(),
        }
    }

    /// RED 判据：假服务端永不回行 → call 必须在注入的短阈值内返回 Err，
    /// 且错误串带方法名（死因可报告）。若保险丝缺失，本测试会永久挂起
    /// （cargo test 超时即红）——改前真红。
    #[test]
    fn call_times_out_with_method_in_error() {
        let h = stub_handle(&stub_silent_server());
        let t0 = std::time::Instant::now();
        let e = h
            .call_with_timeout(
                "thumb.get",
                json!({"hash": "aa"}),
                Duration::from_millis(300),
            )
            .expect_err("silent server must trip the read fuse");
        assert!(
            e.contains("thumb.get") && e.contains("timeout"),
            "error must name the dead method, got: {e}"
        );
        assert!(
            t0.elapsed() < Duration::from_secs(5),
            "fuse must fire near the injected threshold, took {:?}",
            t0.elapsed()
        );
    }

    /// 反证（正常路径不误伤）：秒回的服务端不得触发超时。
    #[test]
    fn call_completes_normally_under_fuse() {
        use interprocess::local_socket::traits::Listener as _;
        let name = stub_socket_name("ok");
        let ns = name.clone().to_ns_name::<GenericNamespaced>().unwrap();
        let listener = interprocess::local_socket::ListenerOptions::new()
            .name(ns)
            .create_sync()
            .expect("stub bind");
        std::thread::spawn(move || loop {
            let Ok(mut conn) = listener.accept() else {
                continue;
            };
            let mut reader = BufReader::new(&mut conn);
            let mut l = String::new();
            let _ = reader.read_line(&mut l); // token
            let _ = reader.read_line(&mut l); // request
            let _ = conn.write_all(b"{\"ok\":true,\"result\":{\"pong\":true}}\n");
            let _ = conn.flush();
        });
        let h = stub_handle(&name);
        let v = h
            .call_with_timeout("status", json!({}), Duration::from_millis(800))
            .expect("responsive server must not trip the fuse");
        assert_eq!(v["pong"], json!(true));
    }

    /// 生产阈值唯一且为 10s（卡定值；改动必须先过对照表，防摆钟）。
    #[test]
    fn fuse_is_single_fixed_ten_seconds() {
        assert_eq!(IPC_READ_TIMEOUT, Duration::from_secs(10));
    }
}
