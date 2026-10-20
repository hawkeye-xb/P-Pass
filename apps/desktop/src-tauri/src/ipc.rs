//! Blocking IPC client for the daemon's local socket (T-034 wire:
//! first line = token, then one JSON request per line, one JSON
//! response per line). One fresh connection per call — simple and
//! stateless, plenty for the 60 s fallback poll plus event-driven refreshes.

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

/// I18N-03 (#492)：会经 `invoke` 回到前端展示的错误，一律是「key + 参数」，
/// 由前端 `t()`（`apps/desktop/src/lib/i18n.js` 的 `errText`）按系统语言渲染；
/// 文案只在 `assets/i18n/{en,zh}.json`。线上格式是 JSON 字符串
/// `{"key":"ui.err_…","params":{…}}`——`Result<_, String>` 签名、事件 payload
/// 类型都不用动。参数值原样透传、不翻译（底层 `{e}` 细节是给人排查用的）；
/// 参数值本身也可以是另一条 keyed 错误（壳错误包 IPC 错误），前端递归渲染。
pub(crate) fn ui_err(key: &str, params: &[(&str, &dyn std::fmt::Display)]) -> String {
    let params: serde_json::Map<String, Value> = params
        .iter()
        .map(|(k, v)| ((*k).to_string(), Value::String(v.to_string())))
        .collect();
    json!({ "key": key, "params": params }).to_string()
}

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

/// NET-27：一次完整往返（连接 → 发送 → 读一行），设计上跑在工作线程里。
///
/// socket 级读超时仍然**尽力设置**，但失败不再致命：它只是让本线程在撞线后
/// 能自我了结（unix 可用），真正的保险丝是调用方的通道超时。
///
/// 撞线后本线程被弃置——连接归它所有，线程结束即 drop。若对端真僵住且平台
/// 不支持 socket 超时（Windows 命名管道），该线程会一直阻塞在 read 上直到
/// 进程退出：**已知代价**，换来「保险丝一定生效」。每调用一个短命线程，与
/// 本模块既有的「每调一新连接」同阶。
fn one_round_trip(
    socket_name: String,
    payload: String,
    method: String,
    read_timeout: Duration,
) -> Result<String, String> {
    let name = socket_name
        .to_ns_name::<GenericNamespaced>()
        .map_err(|e| ui_err("ui.err_socket_name", &[("err", &e)]))?;
    let conn = Stream::connect(name).map_err(|e| ui_err("ui.err_connect", &[("err", &e)]))?;
    let _ = conn.set_recv_timeout(Some(read_timeout));
    let mut reader = BufReader::new(conn);
    reader
        .get_mut()
        .write_all(payload.as_bytes())
        .map_err(|e| ui_err("ui.err_send", &[("err", &e)]))?;
    let mut line = String::new();
    match reader.read_line(&mut line) {
        // socket 超时先于通道触发时（unix 上会），也要报成同一句：死因
        // 必须带方法名（NET-11 判据）。
        Err(e) if is_timeout_err(&e) => Err(ipc_timeout_msg(&method, read_timeout)),
        Ok(_) => Ok(line),
        Err(e) => Err(ui_err("ui.err_read_response", &[("err", &e)])),
    }
}
/// 壳里**唯一**的 config.toml 读者：读 `data_dir`（库目录），按 TOML 解析取值。
/// 令牌发现（本模块）、向导预填、诊断包落点共用这一条（#1045）。
///
/// 为什么只许一份、且必须是真 TOML 解析：以前壳里有两个读者——这里逐行手写
/// 解析（要自己反转义），诊断包那边另用 toml 解析——格式的任何细节都得两边同时
/// 对上，DESK-26 / DESK-27 / DESK-40 三次事故都出在这里。写入方现在是 daemon
/// （真 TOML 序列化），读取方就该用同一套语义。
///
/// 解析不了 / 没设 `data_dir` / 值是空串 = `None`（daemon 对这样的 config 也会
/// 拒绝启动或回落到平台目录，壳不替它猜）。
pub fn read_config_data_dir(dir: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(dir.join("config.toml")).ok()?;
    data_dir_of(&raw)
}

/// [`read_config_data_dir`] 的纯函数部分（便于单测，不碰盘）。
fn data_dir_of(raw: &str) -> Option<String> {
    raw.parse::<toml::Table>()
        .ok()?
        .get("data_dir")?
        .as_str()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

/// Where to look for a daemon's ipc.token, in order.
///
/// T-042b: the platform data dir comes from `platform::adapter().data_dir()`
/// (macOS: ~/Library/Application Support/P-Pass; Windows:
/// %LOCALAPPDATA%\com.p-pass.desktop — DESK-24 #173 moved it off roaming
/// %APPDATA%, and the adapter keeps returning the old location until the
/// move actually succeeds) instead of a hardcoded macOS-only path — the
/// token discovery fix must work on Windows too.
pub fn token_candidates() -> Vec<PathBuf> {
    use platform::PlatformAdapter as _;
    let adapter = platform::adapter();
    // #1043：家目录由平台适配器回答，壳不读 HOME；读不到退回 `.`（同改前）。
    let home = adapter.home_dir().unwrap_or_else(|| PathBuf::from("."));
    token_candidates_from(&adapter.data_dir(), &home)
}

/// Testable core: same order, but the platform data dir and home are injected.
pub fn token_candidates_from(data_dir: &Path, home: &Path) -> Vec<PathBuf> {
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
        let mut last_err = ui_err("ui.err_no_daemon", &[]);
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
                    last_err = ui_err(
                        "ui.err_daemon_unresponsive",
                        &[("path", &path.display()), ("err", &e)],
                    );
                }
            }
        }
        Err(last_err)
    }

    /// One request/response round trip.
    ///
    /// NET-11：带固定读超时保险丝（[`IPC_READ_TIMEOUT`]）——daemon 活着但
    /// 僵住时，壳必须报「哪个方法超时了」而不是陪着无限等（同步 command
    /// 占 Tauri blocking 池，无上限等待会被轮询与事件触发的刷新堆满、整壳冻结）。
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
        // NET-27：保险丝**不能**装在 socket 上。Windows 的命名管道不支持
        // I/O 超时（`set_recv_timeout` → "named pipes do not support I/O
        // timeouts"），NET-11 的实现用 `?` 把它当硬失败，于是 Windows 上
        // 每次调用在请求发出**之前**就 Err —— 桌面壳一个 daemon 数据都拿
        // 不到（lib.rs 里 7 个调用点全废，含 status / asset.path /
        // logs.export 与前端万能通道 daemon_call）。
        //
        // 改成在**通道**上掐表：整个往返跑在工作线程里，本函数用
        // `recv_timeout` 计时。保险丝于是与平台能力无关，而 NET-11 的语义
        // （撞线即断臂、错误带方法名、单一固定阈值）一字未改。
        let (tx, rx) = std::sync::mpsc::channel::<Result<String, String>>();
        let socket_name = self.socket_name.clone();
        let req = json!({ "id": method, "method": method, "params": params });
        let payload = format!("{token}\n{req}\n", token = self.token);
        let method_owned = method.to_string();
        std::thread::Builder::new()
            .name(format!("ipc-{method}"))
            .spawn(move || {
                let _ = tx.send(one_round_trip(
                    socket_name,
                    payload,
                    method_owned,
                    read_timeout,
                ));
            })
            .map_err(|e| ui_err("ui.err_ipc_thread_spawn", &[("err", &e)]))?;

        let line = match rx.recv_timeout(read_timeout) {
            Ok(Ok(line)) => line,
            Ok(Err(msg)) => return Err(msg),
            // 撞线：弃连接（它归那个线程，线程结束即 drop）。
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                return Err(ipc_timeout_msg(method, read_timeout))
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return Err(ui_err("ui.err_ipc_thread_exit", &[("method", &method)]))
            }
        };
        let resp: Value = serde_json::from_str(line.trim())
            .map_err(|e| ui_err("ui.err_not_json", &[("err", &e)]))?;
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
    /// 是轮询与刷新的同步 call 堆积，不是这条只读长连接。
    ///
    /// 阻塞直到连接断开（daemon 退出/重启/网络错误），返回 Err 后由
    /// 调用方决定重连。握手失败（老 daemon 无 events.subscribe）也返回
    /// Err——上层据此降级（前端 60s 兜底轮询仍在）。
    ///
    /// DESK-63 (#946)：`on_open` 在**握手成功之后、读取第一条事件之前**
    /// 调用。服务状态管理器用它把「订阅已建立」当成 daemon 就绪信号——
    /// 这是壳能拿到的、最接近「服务已启动完成」的本地事实，不依赖
    /// 定时 status 轮询。
    pub fn subscribe_events_with_open(
        &self,
        mut on_open: impl FnMut(),
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
        // DESK-63 (#946): the handshake is the readiness signal. Call back
        // before the first event read so a daemon that is alive but silent
        // still counts as ready.
        on_open();

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

        let home = tmp.path().join("home");
        let candidates = token_candidates_from(&cfg_dir, &home);
        // 家目录由调用方注入（#1043：壳不读 HOME），dev 库候选跟着它走。
        assert!(
            candidates.contains(&home.join("ppf-library/ipc.token")),
            "candidates must include the injected home's dev library: {candidates:?}"
        );
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

    /// DESK-26 (#209) / #1045：config 里写的值，读回来必须**原样**——不论写成
    /// basic string（双引号，反斜杠转义）还是 literal string（单引号，不转义）。
    /// 两种都是 daemon 的 TOML 序列化器会选的写法（Windows 路径选 literal）。
    #[test]
    fn reader_returns_the_value_for_both_toml_string_styles() {
        // basic：双引号，每个反斜杠写成两个；literal：单引号，原样。
        let basic = "data_dir = \"C:\\\\Users\\\\ethan\"\n";
        let literal = "data_dir = 'C:\\Users\\ethan'\n";
        // 前提自检：两段确实是两种不同的字面形状，否则这条就是恒真式。
        assert_ne!(basic, literal);
        assert!(basic.contains(r"C:\\Users"), "{basic}");
        assert!(
            literal.contains(r"C:\Users") && !literal.contains(r"\\"),
            "{literal}"
        );
        assert_eq!(data_dir_of(basic).as_deref(), Some(r"C:\Users\ethan"));
        assert_eq!(data_dir_of(literal).as_deref(), Some(r"C:\Users\ethan"));
    }

    /// 单引号 literal 里的两个反斜杠就是两个反斜杠（TOML 定义：不转义）。
    #[test]
    fn literal_string_value_is_not_unescaped() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(
            tmp.path().join("config.toml"),
            "data_dir = 'C:\\\\Users\\\\ethan'\n",
        )
        .unwrap();
        assert_eq!(
            read_config_data_dir(tmp.path()).as_deref(),
            Some(r"C:\\Users\\ethan")
        );
    }

    /// 读不出来的形态一律 None，不 panic、不猜：空值、没设、不是字符串、
    /// 整份 TOML 解析不了、文件不存在。
    #[test]
    fn reader_gives_none_for_every_unreadable_shape() {
        for raw in [
            "",
            "bind_addr = \"0.0.0.0:41145\"\n",
            "data_dir = \"\"\n",
            "data_dir = \"   \"\n",
            "data_dir = 5\n",
            "data_dir = \"/x\"\n[broken",
        ] {
            assert_eq!(data_dir_of(raw), None, "{raw:?}");
        }
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(read_config_data_dir(tmp.path()), None);
    }

    /// 首个 `[section]` 之后的同名键不是顶层 `data_dir`（真 TOML 解析才分得清，
    /// 逐行读会把它当成库目录）。
    #[test]
    fn a_data_dir_inside_a_section_is_not_the_library() {
        assert_eq!(
            data_dir_of("data_dir = \"/top\"\n[other]\ndata_dir = \"/nested\"\n").as_deref(),
            Some("/top")
        );
        assert_eq!(data_dir_of("[other]\ndata_dir = \"/nested\"\n"), None);
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
