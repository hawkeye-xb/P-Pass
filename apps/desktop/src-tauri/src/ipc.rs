//! Blocking IPC client for the daemon's local socket (T-034 wire: one JSON
//! request per line, one JSON response per line; in token mode the first
//! line is the token). One fresh connection per call — simple and
//! stateless, plenty for the 60 s fallback poll plus event-driven refreshes.
//!
//! #1115：常驻 daemon 怎么连由平台决定（`platform::ResidentIpc`）。macOS：固定路径的签名
//! socket，连上后**先反向校验服务端是签名 daemon**，不是就断开、什么都不发；没有令牌。
//! Windows（#1167）：命名管道，按 Windows 用户 SID 认人，连上后先核对管道是 P-Pass 后台服务
//! 建的；同样没有令牌文件。连测试沙盒（令牌）只在 debug 构建里存在（[`sandbox_candidates`]）。

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
use interprocess::local_socket::{GenericFilePath, GenericNamespaced, Stream, ToFsName, ToNsName};
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

/// 协议 v2（#1071）：daemon 应答错误 `{code, reason, params}` 里，线上只传机器码
/// `reason`，不传文案 key；壳自己决定这个 reason 在界面上说什么。
/// 下表对 `crates/proto` 的 `reasons_registry` 快照里**每个** reason 给出显式去向
/// （穷举测试 `every_registry_reason_has_an_explicit_mapping` 卡死漏项）：
/// 要么是一条具体文案 key，要么显式归入 [`UI_ERR_GENERIC`]。
pub(crate) const UI_ERR_GENERIC: &str = "ui.err_generic";
const REASON_UI_KEYS: &[(&str, &str)] = &[
    ("not_paired", "err.not_paired"),
    ("role_forbidden", "err.not_authorized"),
    ("pair_token_invalid", "err.not_authorized"),
    // #1118：验证码对不上，这次配对已作废。
    ("pair_code_wrong", "ui.err_pair_code_wrong"),
    ("phone_outdated", "ui.err_phone_outdated"),
    ("desktop_outdated", "ui.err_desktop_outdated"),
    ("unsupported_method", "err.unsupported"),
    ("backup_failed", "err.backup_failed"),
    ("storage_full", "err.disk_full"),
    // 以下显式归入通用：对用户没有比「出错了」更有用的话可说。
    ("bad_request", UI_ERR_GENERIC),
    ("not_found", UI_ERR_GENERIC),
    ("internal", UI_ERR_GENERIC),
    ("library_unavailable", UI_ERR_GENERIC),
    ("storage_failed", UI_ERR_GENERIC),
    ("fetch_failed", UI_ERR_GENERIC),
    ("pairing_mismatch", UI_ERR_GENERIC),
    ("grant_not_found", UI_ERR_GENERIC),
    ("grant_conflict", UI_ERR_GENERIC),
    ("cancelled", UI_ERR_GENERIC),
];

/// reason → 壳文案 key；表外（含老 daemon 没带 reason、将来新增的值）一律通用。
pub(crate) fn reason_ui_key(reason: &str) -> &'static str {
    REASON_UI_KEYS
        .iter()
        .find(|(r, _)| *r == reason)
        .map_or(UI_ERR_GENERIC, |(_, k)| k)
}

/// daemon 应答的 `error` 对象 → 壳的 keyed 错误串（与 [`ui_err`] 同形）。
/// 原 `reason` 放进 `params.reason` 只供排查，通用文案不引用它，永不进界面；
/// 表外的 reason 另写一行 stderr 日志。
///
/// #1115：daemon 已经给出 keyed 文案（`params.ui_error`，如 `config.set_library` 的
/// 库目录校验失败）时原样交出——那是给用户看的具体原因，不能被通用错误盖掉。
pub(crate) fn daemon_error(error: &Value) -> String {
    if let Some(ui_error) = error["params"]["ui_error"].as_str() {
        return ui_error.to_string();
    }
    let reason = error["reason"].as_str().unwrap_or("");
    let key = reason_ui_key(reason);
    if key == UI_ERR_GENERIC && !REASON_UI_KEYS.iter().any(|(r, _)| *r == reason) {
        eprintln!(
            "daemon 回了壳不认识的 reason {reason:?}（code={}），显示通用错误",
            error["code"]
        );
    }
    ui_err(key, &[("reason", &reason)])
}

/// 壳是否收到了「daemon 不认识这个方法」。`daemon_error` 的产物是 keyed JSON，
/// 不能再拿整串和裸 key 比。
pub(crate) fn is_unsupported_error(e: &str) -> bool {
    serde_json::from_str::<Value>(e).is_ok_and(|v| v["key"] == "err.unsupported")
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
    endpoint: Endpoint,
    payload: String,
    method: String,
    read_timeout: Duration,
) -> Result<String, String> {
    let conn = endpoint.connect()?;
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

/// #1115：一个候选 daemon 端点。
#[derive(Debug, Clone)]
enum Endpoint {
    /// 签名 socket：连上后反向校验服务端是签名 daemon，不发令牌。
    Signed(PathBuf),
    /// #1167：Windows 命名管道：连上后反向核对服务端，不发令牌。
    Pipe(String),
    /// 命名空间端点 + 令牌（只剩 debug 构建下的测试沙盒；release 里构造不出来）。
    #[cfg_attr(not(debug_assertions), allow(dead_code))]
    Token { socket_name: String, token: String },
}

impl Endpoint {
    /// 连上并完成认证前的准备。签名模式下服务端校验不过 ⇒ `Err`，此时一个字节都没发。
    fn connect(&self) -> Result<Stream, String> {
        match self {
            Endpoint::Signed(path) => {
                let name = path
                    .as_path()
                    .to_fs_name::<GenericFilePath>()
                    .map_err(|e| ui_err("ui.err_socket_name", &[("err", &e)]))?;
                let conn =
                    Stream::connect(name).map_err(|e| ui_err("ui.err_connect", &[("err", &e)]))?;
                match platform::verify_local_peer(&conn, &[platform::PeerRole::Daemon]) {
                    platform::PeerCheck::Verified(_) => Ok(conn),
                    platform::PeerCheck::Rejected(why) => Err(ui_err(
                        "ui.err_daemon_not_ours",
                        &[("path", &path.display()), ("reason", &why)],
                    )),
                    platform::PeerCheck::NotSupported(why) => {
                        Err(ui_err("ui.err_connect", &[("err", &why)]))
                    }
                }
            }
            Endpoint::Pipe(pipe) => {
                let name = pipe
                    .clone()
                    .to_ns_name::<GenericNamespaced>()
                    .map_err(|e| ui_err("ui.err_socket_name", &[("err", &e)]))?;
                let conn = Stream::connect(name).map_err(|e| pipe_connect_error(&e))?;
                match platform::verify_local_peer(&conn, &[platform::PeerRole::Daemon]) {
                    platform::PeerCheck::Verified(_) => Ok(conn),
                    platform::PeerCheck::Rejected(why) => Err(ui_err(
                        "ui.err_daemon_not_ours",
                        &[("path", pipe), ("reason", &why)],
                    )),
                    platform::PeerCheck::NotSupported(why) => {
                        Err(ui_err("ui.err_connect", &[("err", &why)]))
                    }
                }
            }
            Endpoint::Token { socket_name, .. } => {
                let name = socket_name
                    .clone()
                    .to_ns_name::<GenericNamespaced>()
                    .map_err(|e| ui_err("ui.err_socket_name", &[("err", &e)]))?;
                Stream::connect(name).map_err(|e| ui_err("ui.err_connect", &[("err", &e)]))
            }
        }
    }

    /// 线上第一段：令牌模式是令牌行，签名模式没有。
    fn preamble(&self) -> String {
        match self {
            Endpoint::Signed(_) | Endpoint::Pipe(_) => String::new(),
            Endpoint::Token { token, .. } => format!("{token}\n"),
        }
    }

    fn label(&self) -> String {
        match self {
            Endpoint::Signed(path) => path.display().to_string(),
            Endpoint::Pipe(pipe) => pipe.clone(),
            Endpoint::Token { socket_name, .. } => socket_name.clone(),
        }
    }
}

/// #1167 / D3：管道连接失败的说法。被拒绝访问 = 管道 DACL 里没有你——这台电脑的 P-Pass
/// 已经由另一个 Windows 账户使用（主人模型）。这句话必须和「服务没在跑」分开说，否则用户
/// 会去反复重启一个其实好好的服务。
fn pipe_connect_error(e: &std::io::Error) -> String {
    if e.kind() == std::io::ErrorKind::PermissionDenied {
        ui_err("ui.err_daemon_other_account", &[])
    } else {
        ui_err("ui.err_connect", &[("err", e)])
    }
}

/// 令牌文件 → 端点（第一行 socket 名，第二行令牌）。只有 debug 构建的测试沙盒还用令牌。
#[cfg(debug_assertions)]
fn token_endpoint(path: &Path) -> Option<Endpoint> {
    let content = std::fs::read_to_string(path).ok()?;
    let mut lines = content.lines();
    let (name, token) = (lines.next()?, lines.next()?);
    Some(Endpoint::Token {
        socket_name: name.trim().to_string(),
        token: token.trim().to_string(),
    })
}

/// #1115：测试沙盒（`daemon --ephemeral`，令牌认证）——**只在 debug 构建里存在**。
/// 开发时 `PPF_SANDBOX_DIR=<daemon stdout 上 SANDBOX: 那一行>` 启动 `tauri dev`。
/// release 构建里这条路径不存在（下面那个空实现），release 壳只认签名 daemon；
/// `tests::sandbox_path_only_in_debug_builds` 守着这一点。
#[cfg(debug_assertions)]
fn sandbox_candidates() -> Vec<Endpoint> {
    std::env::var_os("PPF_SANDBOX_DIR")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .and_then(|dir| token_endpoint(&dir.join("ipc.token")))
        .into_iter()
        .collect()
}

#[cfg(not(debug_assertions))]
fn sandbox_candidates() -> Vec<Endpoint> {
    Vec::new()
}

/// 候选端点，按顺序：（debug 构建）测试沙盒 → 常驻 daemon。
fn endpoint_candidates() -> Vec<Endpoint> {
    use platform::PlatformAdapter as _;
    let mut v = sandbox_candidates();
    match platform::adapter().resident_ipc() {
        platform::ResidentIpc::SignedSocket(path) => v.push(Endpoint::Signed(path)),
        platform::ResidentIpc::UserPipe(pipe) => v.push(Endpoint::Pipe(pipe)),
        // 令牌模式只剩 headless 平台（没有窗口程序）与测试沙盒（上面 debug 那条）：
        // 常驻 daemon 不再按令牌文件找（#1167）。
        platform::ResidentIpc::NamespacedWithToken => {}
    }
    v
}

pub struct DaemonHandle {
    endpoint: Endpoint,
}

impl DaemonHandle {
    /// Find a RUNNING daemon: candidates are probed with a live status
    /// call — a stale token file from a dead daemon must never hijack
    /// discovery (real-world bug: leftover dogfood token).
    pub fn discover() -> Result<Self, String> {
        let mut last_err = ui_err("ui.err_no_daemon", &[]);
        for endpoint in endpoint_candidates() {
            let label = endpoint.label();
            let handle = Self { endpoint };
            match handle.call("status", serde_json::json!({})) {
                Ok(_) => return Ok(handle),
                Err(e) => {
                    // Stale token (dead daemon) / not our daemon — try the next candidate.
                    last_err = ui_err(
                        "ui.err_daemon_unresponsive",
                        &[("path", &label), ("err", &e)],
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
        // logs.export 与当时的前端万能通道 daemon_call，#1120 起拆成具名命令）。
        //
        // 改成在**通道**上掐表：整个往返跑在工作线程里，本函数用
        // `recv_timeout` 计时。保险丝于是与平台能力无关，而 NET-11 的语义
        // （撞线即断臂、错误带方法名、单一固定阈值）一字未改。
        let (tx, rx) = std::sync::mpsc::channel::<Result<String, String>>();
        let endpoint = self.endpoint.clone();
        let req = json!({ "id": method, "method": method, "params": params });
        let payload = format!("{}{req}\n", self.endpoint.preamble());
        let method_owned = method.to_string();
        std::thread::Builder::new()
            .name(format!("ipc-{method}"))
            .spawn(move || {
                let _ = tx.send(one_round_trip(
                    endpoint,
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
            Err(daemon_error(&resp["error"]))
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
        let conn = self.endpoint.connect()?;
        let mut reader = BufReader::new(conn);

        let req = json!({ "id": "events.subscribe", "method": "events.subscribe", "params": {} });
        let payload = format!("{}{req}\n", self.endpoint.preamble());
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
            return Err(daemon_error(&resp["error"]));
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

    /// #1167：管道被拒绝访问必须说成「被另一个 Windows 账户使用」，其余连接错误照旧。
    /// 反证：把 PermissionDenied 也归成 ui.err_connect ⇒ 红。
    #[test]
    fn a_denied_pipe_means_another_account_owns_this_pc() {
        let denied =
            pipe_connect_error(&std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        assert!(denied.contains("ui.err_daemon_other_account"), "{denied}");
        let missing = pipe_connect_error(&std::io::Error::from(std::io::ErrorKind::NotFound));
        assert!(missing.contains("ui.err_connect"), "{missing}");
    }

    /// #1167：窗口程序不再按令牌文件找常驻 daemon——源码里不许再出现令牌候选。
    /// 反证：把 `token_candidates` 加回来 ⇒ 红。
    #[test]
    fn the_shell_no_longer_looks_for_ipc_token_files() {
        let src = include_str!("ipc.rs").replace("\r\n", "\n");
        let body = &src[..src.find("#[cfg(test)]").expect("tests")];
        assert!(!body.contains("fn token_candidates"), "令牌候选又回来了");
        assert!(!body.contains("ppf-library/ipc.token"), "令牌候选又回来了");
    }

    /// #1115：连测试沙盒（令牌、不校验服务端签名）的路径只在 debug 构建里存在；release
    /// 构建里 `sandbox_candidates` 是空实现，`PPF_SANDBOX_DIR` 一个字都不出现在它的路径上。
    /// 反证：去掉 `#[cfg(debug_assertions)]`、或在 release 实现里读这个变量 ⇒ 红。
    #[test]
    fn sandbox_path_only_in_debug_builds() {
        let src = include_str!("ipc.rs").replace("\r\n", "\n");
        let debug_fn = "#[cfg(debug_assertions)]\nfn sandbox_candidates() -> Vec<Endpoint> {";
        let release_fn =
            "#[cfg(not(debug_assertions))]\nfn sandbox_candidates() -> Vec<Endpoint> {\n    Vec::new()\n}";
        let at = src
            .find(debug_fn)
            .expect("debug 实现必须挂 #[cfg(debug_assertions)]");
        assert!(src.contains(release_fn), "release 实现必须是空的");
        let body_end = at + src[at..].find("\n}\n").expect("函数体");
        let uses: Vec<usize> = src
            .match_indices("std::env::var_os(\"PPF_SANDBOX_DIR\")")
            .map(|(i, _)| i)
            .collect();
        assert_eq!(uses.len(), 1, "只许 debug 实现读这个变量");
        assert!(
            uses[0] > at && uses[0] < body_end,
            "读变量的地方必须在 debug 实现里"
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
            endpoint: Endpoint::Token {
                socket_name: socket_name.to_string(),
                token: "deadbeef".to_string(),
            },
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

    /// #1071 验收 1：proto 快照里每个 reason 都必须在映射表里有显式一行；
    /// 表里也不许留快照没有的陈旧 reason。
    fn registry_reasons() -> Vec<String> {
        let snap = include_str!(
            "../../../../crates/proto/tests/snapshots/snapshots__reasons_registry.snap"
        );
        let json = &snap[snap.find('[').expect("snapshot has a JSON array")..];
        let v: Value = serde_json::from_str(json).expect("snapshot body is JSON");
        v.as_array()
            .unwrap()
            .iter()
            .map(|e| e["reason"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn every_registry_reason_has_an_explicit_mapping() {
        let reasons = registry_reasons();
        assert!(reasons.len() >= 18, "快照读空了？{reasons:?}");
        for r in &reasons {
            assert!(
                REASON_UI_KEYS.iter().any(|(k, _)| k == r),
                "reason {r} 没有显式映射（具体文案或显式归入 UI_ERR_GENERIC）"
            );
        }
        for (k, _) in REASON_UI_KEYS {
            assert!(
                reasons.iter().any(|r| r == k),
                "映射表里有快照没有的 reason: {k}"
            );
        }
    }

    #[test]
    fn unknown_or_missing_reason_is_generic_and_never_leaks_raw() {
        let e = daemon_error(&json!({"code": "INTERNAL", "reason": "brand_new_reason"}));
        let v: Value = serde_json::from_str(&e).unwrap();
        assert_eq!(v["key"], UI_ERR_GENERIC);
        let none = daemon_error(&json!({"code": "X"}));
        assert_eq!(
            serde_json::from_str::<Value>(&none).unwrap()["key"],
            UI_ERR_GENERIC
        );
        // 旧形状的 msg_key 不再被读。
        let old = daemon_error(&json!({"msg_key": "storage_full"}));
        assert_eq!(
            serde_json::from_str::<Value>(&old).unwrap()["key"],
            UI_ERR_GENERIC
        );
        assert!(!is_unsupported_error(&old));
    }

    #[test]
    fn known_reasons_map_and_unsupported_is_detectable() {
        let e = daemon_error(&json!({"code": "INVALID_REQUEST", "reason": "unsupported_method"}));
        assert!(is_unsupported_error(&e));
        let v: Value =
            serde_json::from_str(&daemon_error(&json!({"reason": "storage_full"}))).unwrap();
        assert_eq!(v["key"], "err.disk_full");
        assert_eq!(v["params"]["reason"], "storage_full");
    }

    /// #1115：daemon 给了具体文案（`params.ui_error`）就原样交出；没给的照旧走 reason 映射。
    #[test]
    fn a_keyed_ui_error_from_the_daemon_is_handed_through() {
        let keyed = ui_err("ui.err_library_nested", &[]);
        let e = daemon_error(&json!({
            "code": "INVALID_REQUEST",
            "reason": "bad_request",
            "params": { "ui_error": keyed },
        }));
        assert_eq!(e, keyed);
        let plain = daemon_error(&json!({"code": "INVALID_REQUEST", "reason": "bad_request"}));
        assert_ne!(plain, keyed);
        assert!(serde_json::from_str::<Value>(&plain).is_ok());
    }

    /// 生产阈值唯一且为 10s（卡定值；改动必须先过对照表，防摆钟）。
    #[test]
    fn fuse_is_single_fixed_ten_seconds() {
        assert_eq!(IPC_READ_TIMEOUT, Duration::from_secs(10));
    }
}
