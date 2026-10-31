//! Local IPC for the tray UI (T-034, ADR-012): local socket / named pipe
//! via `interprocess` (no platform #[cfg] here — rule B.2).
//!
//! #1115：两种认证，由启动方式决定（`platform::ResidentIpc`）：
//! - **按签名**（macOS 常驻 daemon）：socket 在仅本用户可访问的目录里，accept 后按对端
//!   audit token 校验代码签名，认出是窗口程序还是 daemon 自身；没有令牌。客户端（壳、
//!   单实例交接、诊断导出）连上后先反向校验服务端是签名 daemon，不是就断开、什么都不发。
//! - **按用户**（#1167，Windows 常驻 daemon）：命名管道的 DACL 只放白名单 SID，accept 后
//!   服务端按连接取客户端的 Windows 用户 SID（服务账户 ⇒ daemon 自身，主人 ⇒ 窗口程序）；
//!   客户端连上后先反向核对管道是 P-Pass 后台服务建的。同样没有令牌文件。
//! - **按令牌**（测试沙盒、无桌面的 Linux）：每次启动随机令牌写进令牌文件（仅属主可读写），
//!   客户端第一行发令牌。
//!
//! 能调哪些方法按连接方身份定（[`IpcClient`]）：窗口程序全部；daemon 自身只有单实例交接
//! 与诊断导出要用的 [`DAEMON_CLIENT_METHODS`]——签名的 daemon 谁都能带参数运行，不能让它
//! 成为能调配对、授权类方法的代理。
//!
//! Wire format: newline-delimited JSON. Token mode: first line from the
//! client is the raw token; every following line is a `proto::Req`, answered
//! by one `proto::Resp` line. Wrong token / unsigned peer = connection
//! dropped, one diag event.
//!
//! Methods (契约): `status` `pairing.start` `pairing.confirm`
//! `devices.list` `device.revoke` `device.watermarks`
//! `logs.export` `activity.list` (T-090) — plus DAE-01
//! `daemon.step_down` (newest-wins takeover, added 2026-08-04) and
//! NAME-01 `device.rename` (display-name only, ID 不变, added 2026-08-12).
//!
//! DESK-46 (#638): `folder.set` 已移除。它把新库路径写进**当前库目录**
//! 的孤儿 config.toml（读写不对称，自定义库下静默无效）；库位置现在由
//! 桌面壳 set_library_dir 直接读写平台目录的 config.toml（唯一真相源）。

use std::cmp::Ordering;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use diag::state::DaemonState;
use interprocess::local_socket::tokio::prelude::*;
use interprocess::local_socket::{GenericFilePath, GenericNamespaced, ListenerOptions};
use proto::{Reason, Req, Resp, RespError};
use storage::Db;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::diag_agg::DiagAgg;
use crate::events::{self, EventBus};
use crate::pairing::{
    warn_if_audit_failed, PairDecision, Pairing, PendingPair, MAX_DEVICE_NAME_CHARS, PENDING_TTL_MS,
};
use crate::subscriptions::SubscriptionRegistry;

/// #1118: how long `pairing.confirm` waits for the phone's key confirmation before answering
/// "verifying" (the phone polls every second while it shows the code). Must stay below the
/// desktop shell's `IPC_READ_TIMEOUT` (10 s, apps/desktop/src-tauri/src/ipc.rs), or the owner
/// would see a timeout for a pairing that went through.
pub const CONFIRM_WAIT_MS: u64 = 8_000;

/// Outcome of an owner decision on one pending pairing request
/// (DEV-05 #276). The old return type (`Option<String>`) could not tell
/// "no such row" apart from "row found, but the phone had already
/// walked away" — and it let the second case report success.
#[derive(Debug, PartialEq, Eq)]
pub enum ConfirmOutcome {
    /// The row was live; the decision reached the waiting request.
    Decided(String),
    /// The row matched, but its other end was gone — the owner's click
    /// acted on a dead request. The desktop MUST show failure, not
    /// "已允许". Carries the device name for the failure message.
    Expired(String),
    /// Nothing in the queue matched the lookup.
    NotFound,
}

/// #1115：IPC 连接方是谁——决定能调哪些方法。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IpcClient {
    /// 窗口程序（按签名认出），或持令牌的客户端（测试沙盒、Windows / Linux）：全部方法。
    Shell,
    /// daemon 自身（单实例交接、`diag export` 子命令）：只有 [`DAEMON_CLIENT_METHODS`]。
    Daemon,
}

/// #1115：daemon 自身作为客户端时能调的方法——单实例交接（`status`、`daemon.step_down`）
/// 与诊断导出（`status`、`logs.export`）。配对、授权、改名、撤销一律不行。
pub const DAEMON_CLIENT_METHODS: &[&str] = &["status", "daemon.step_down", "logs.export"];

impl IpcClient {
    pub fn may_call(self, method: &str) -> bool {
        match self {
            IpcClient::Shell => true,
            IpcClient::Daemon => DAEMON_CLIENT_METHODS.contains(&method),
        }
    }
}

/// #1115：作为客户端连常驻 daemon 时用哪种端点 + 认证。
#[derive(Debug, Clone)]
pub enum PeerEndpoint {
    /// 签名 socket：连上后先反向校验服务端是签名 daemon，不发令牌。
    Signed(PathBuf),
    /// #1167：Windows 命名管道：连上后先反向核对服务端（管道属主 / 会话），不发令牌。
    Pipe(String),
    /// 命名空间端点 + 令牌。
    Token {
        socket_name: String,
        token_hex: String,
    },
}

impl PeerEndpoint {
    /// 连上并完成认证前的准备：签名模式下反向校验服务端（不是签名 daemon 就报错、
    /// 什么都没发）；令牌模式下返回要先发的那一行。
    pub async fn connect(
        &self,
    ) -> Result<(interprocess::local_socket::tokio::Stream, Option<String>), String> {
        match self {
            PeerEndpoint::Signed(path) => {
                let name = path
                    .as_path()
                    .to_fs_name::<GenericFilePath>()
                    .map_err(|e| format!("socket 路径不合法：{e}"))?;
                let conn = interprocess::local_socket::tokio::Stream::connect(name)
                    .await
                    .map_err(|e| format!("连不上 {}：{e}", path.display()))?;
                let (conn, check) = tokio::task::spawn_blocking(move || {
                    let check = platform::verify_local_peer(&conn, &[platform::PeerRole::Daemon]);
                    (conn, check)
                })
                .await
                .map_err(|e| format!("校验线程失败：{e}"))?;
                match check {
                    platform::PeerCheck::Verified(_) => Ok((conn, None)),
                    platform::PeerCheck::Rejected(why) => Err(format!(
                        "{} 上的服务端不是签名 daemon：{why}",
                        path.display()
                    )),
                    platform::PeerCheck::NotSupported(why) => Err(why.to_string()),
                }
            }
            PeerEndpoint::Pipe(pipe) => {
                // 与壳一致：只允许服务端识别本客户端，不允许以本客户端身份行事。
                let conn = platform::connect_resident_pipe_tokio(pipe)
                    .await
                    .map_err(|e| format!("连不上 {pipe}：{e}"))?;
                let (conn, check) = tokio::task::spawn_blocking(move || {
                    let check = platform::verify_local_peer(&conn, &[platform::PeerRole::Daemon]);
                    (conn, check)
                })
                .await
                .map_err(|e| format!("校验线程失败：{e}"))?;
                match check {
                    platform::PeerCheck::Verified(_) => Ok((conn, None)),
                    platform::PeerCheck::Rejected(why) => {
                        Err(format!("{pipe} 上的服务端不是 P-Pass 后台服务：{why}"))
                    }
                    platform::PeerCheck::NotSupported(why) => Err(why.to_string()),
                }
            }
            PeerEndpoint::Token {
                socket_name,
                token_hex,
            } => {
                let name = socket_name
                    .as_str()
                    .to_ns_name::<GenericNamespaced>()
                    .map_err(|e| format!("socket 名不合法：{e}"))?;
                let conn = interprocess::local_socket::tokio::Stream::connect(name)
                    .await
                    .map_err(|e| format!("连不上 {socket_name}：{e}"))?;
                Ok((conn, Some(token_hex.clone())))
            }
        }
    }

    /// 给人看的端点名（日志、错误说明），不含令牌。
    pub fn label(&self) -> String {
        self.describe()
    }

    fn describe(&self) -> String {
        match self {
            PeerEndpoint::Signed(path) => path.display().to_string(),
            PeerEndpoint::Pipe(name) => name.clone(),
            PeerEndpoint::Token { socket_name, .. } => socket_name.clone(),
        }
    }

    /// 有没有东西在监听（只做一次连接，不认证）。见 [`socket_is_live`]。
    async fn is_live(&self) -> bool {
        match self {
            PeerEndpoint::Signed(path) => {
                let Ok(name) = path.as_path().to_fs_name::<GenericFilePath>() else {
                    return false;
                };
                connect_is_live(name).await
            }
            PeerEndpoint::Pipe(name) => socket_is_live(name).await,
            PeerEndpoint::Token { socket_name, .. } => socket_is_live(socket_name).await,
        }
    }

    fn clean_stale(&self) {
        match self {
            // 只在「没人监听」时调用：父目录仅本用户可访问，残留的就是被杀的前任留下的。
            PeerEndpoint::Signed(path) => {
                let _ = std::fs::remove_file(path);
            }
            // 命名管道是内核对象，没有残留可清（适配器答 NotApplicable）。
            PeerEndpoint::Pipe(name)
            | PeerEndpoint::Token {
                socket_name: name, ..
            } => clean_stale_socket(name),
        }
    }
}

/// 一条连接上的请求行。前缀是认证前已经读掉的第一行（#1167：Windows 的服务端要先读到
/// 客户端的数据才能模拟它取身份），读掉的字节原样接回请求流，会话看不出区别。
pub(crate) type ReqLines = tokio::io::Lines<
    BufReader<
        tokio::io::Chain<std::io::Cursor<Vec<u8>>, interprocess::local_socket::tokio::RecvHalf>,
    >,
>;

fn req_lines(prefix: Vec<u8>, rx: interprocess::local_socket::tokio::RecvHalf) -> ReqLines {
    use tokio::io::AsyncReadExt as _;
    BufReader::new(std::io::Cursor::new(prefix).chain(rx)).lines()
}

/// 认证前最多读这么多字节的第一行（请求行远小于它）；超了 / 超时 / 断开 ⇒ 丢掉连接。
const FIRST_LINE_MAX: usize = 1 << 20;
const FIRST_LINE_TIMEOUT: Duration = Duration::from_secs(10);

/// #1167：平台要求「先读到客户端数据再认人」时（Windows 的 `ImpersonateNamedPipeClient`
/// 在读到数据前答 ERROR_CANNOT_IMPERSONATE，真机实测），在认证前读出第一行（含换行）。
/// 逐字节读，绝不多读——多读的字节会落进一个即将丢弃的缓冲。别的平台不读，返回空前缀。
/// 读到的内容在认证通过前**不解析、不应答**。
async fn read_first_line_if_needed(
    conn: &interprocess::local_socket::tokio::Stream,
) -> Option<Vec<u8>> {
    use tokio::io::AsyncReadExt as _;
    if !platform::peer_check_needs_first_message() {
        return Some(Vec::new());
    }
    let read = async {
        let mut reader = conn;
        let mut line = Vec::new();
        let mut byte = [0u8; 1];
        loop {
            match reader.read(&mut byte).await {
                Ok(1) => {
                    line.push(byte[0]);
                    if byte[0] == b'\n' {
                        return Some(line);
                    }
                    if line.len() >= FIRST_LINE_MAX {
                        return None;
                    }
                }
                _ => return None,
            }
        }
    };
    tokio::time::timeout(FIRST_LINE_TIMEOUT, read)
        .await
        .ok()
        .flatten()
}

/// One IPC server per daemon. Owns the pending-pair queue the UI drains.
pub struct IpcServer {
    db: Db,
    pairing: Pairing,
    diag: DiagAgg,
    data_dir: PathBuf,
    pending: Arc<Mutex<Vec<PendingPair>>>,
    /// IPC-02: 事件总线——`events.subscribe` 连接的推送源（见 events.rs）。
    events: EventBus,
    /// Process start time (unix ms) — surfaced in `status` (DAE-01).
    started_at: i64,
    /// What `daemon.step_down` does after replying. Production: exit(0)
    /// (launchd KeepAlive relaunches from the new plist). Tests inject a
    /// no-op to observe the handshake without killing the harness.
    step_down_exit: Arc<dyn Fn() + Send + Sync>,
    /// DEV-05 (#276): pending-queue TTL used by `confirm`'s sweep.
    /// Production keeps [`PENDING_TTL_MS`]; a test that must exercise
    /// "row still fresh but requester already timed out" injects a long
    /// queue TTL against a short request-side TTL without sleeping.
    pending_ttl_ms: Arc<std::sync::atomic::AtomicI64>,
    /// Clock seam（同 Router::with_clock）：撤销时间戳走它，测试注入假时钟。
    now: Arc<dyn Fn() -> i64 + Send + Sync>,
    /// T-090: live connection status per device (raw 32-byte NodeId in).
    /// main injects a closure over the transport slot; the default says
    /// `Unknown` — 拿不到实况就如实报 unknown，绝不用 last_seen 推断.
    conn_status: ConnStatusFn,
    /// NET-05: path of the currently-active Flow blobs fetch, keyed by the
    /// paired control device. `None` is an inactive transfer, not offline.
    flow_connection: FlowConnectionFn,
    /// DESK-03: query plane（timeline/thumb/asset.*）——桌面壳与 daemon
    /// 同机，照片墙直接走本地 IPC 消费查询平面（与手机同一数据源）。
    /// OnceLock：main 在 transport bind 之后才建 QueryEngine（blobs 依赖
    /// 已绑定 transport），而 IpcServer 早已 Arc 化——用 set_query(&self)
    /// 后注入，dispatch 端 get() 零锁零等待。未注入时答 unsupported_method。
    query: std::sync::OnceLock<crate::query::QueryEngine>,
    /// SYNC-03: 与 Router 共用同一份登记表——`device.revoke` 命中一个
    /// 挂着 `timeline.subscribe` 长连接的设备时主动断连。main 未注入时
    /// 是一份空表（`close` 天然 no-op），不影响任何现有测试。
    subscriptions: SubscriptionRegistry,
    /// #563: `device.revoke` cancels every in-flight fetch from the removed
    /// device. OnceLock for the same reason as `query`: main builds
    /// FlowDelivery after IpcServer is already shared. Unset = no-op.
    flow_delivery: std::sync::OnceLock<crate::flow_delivery::FlowDelivery>,
    /// #1117: `device.revoke` drops the removed device's backup session.
    /// OnceLock for the same reason as `flow_delivery`. Unset = no-op.
    backup: std::sync::OnceLock<crate::backup::BackupEngine>,
    /// #1119: `device.revoke` closes every connection of the removed device.
    /// OnceLock: main sets it after the transport binds. Unset = no-op.
    peer_closer: std::sync::OnceLock<crate::unpair::PeerCloser>,
    /// #1070: the router's version-mismatch registry — feeds the device
    /// list's `needs_update`. Unset = an empty registry (never flags anyone).
    outdated: crate::router::OutdatedPeers,
    /// #1118：见 [`Self::set_desktop_name`]。未注入（测试）= status 里没有这一项。
    desktop_name: Option<String>,
    /// #1115：`config.set_library` 的写入处。`None`（测试沙盒、测试）= 这个方法不开放。
    library_location: Option<Arc<crate::library_location::LibraryLocation>>,
}

/// #1122：审计载荷导出时去掉设备名（含改名前后的名字）。设备名是用户起的
/// （「张三的手机」），属于可识别信息；排障用 actor 前缀与事件种类就够。
/// `pair.accepted` 的 `detail` 就是设备名，只留「是不是重新加入」这一位。
/// 解析不了的载荷原样返回（随后照常过 `scrub`）。
pub(crate) fn audit_payload_for_export(kind: &str, payload: &str) -> String {
    let Ok(serde_json::Value::Object(mut obj)) = serde_json::from_str::<serde_json::Value>(payload)
    else {
        return payload.to_string();
    };
    for key in ["deviceName", "oldName", "newName", "name"] {
        obj.remove(key);
    }
    if kind == "pair.accepted" {
        if let Some(detail) = obj.remove("detail") {
            let rejoined = detail.as_str().is_some_and(|d| d.ends_with("(rejoined)"));
            obj.insert("rejoined".into(), serde_json::Value::Bool(rejoined));
        }
    }
    serde_json::Value::Object(obj).to_string()
}

/// See [`IpcServer::set_conn_status_provider`].
type ConnStatusFn = Arc<dyn Fn(&[u8]) -> transport::ConnectionStatus + Send + Sync>;
/// See [`IpcServer::set_flow_connection_provider`].
type FlowConnectionFn = Arc<dyn Fn(&[u8]) -> Option<transport::ConnectionStatus> + Send + Sync>;

/// `activity.list` batch window: assets from one device arriving within
/// this gap of each other belong to one backup batch (卡片建议 10 分钟).
/// The aggregation itself lives in `storage::Db::list_activity`.
const ACTIVITY_GAP_MS: i64 = 10 * 60 * 1000;

/// Result of the DAE-01 single-instance claim (newest wins).
#[derive(Debug, PartialEq, Eq)]
pub enum Claim {
    /// No live peer — bind now.
    Proceed,
    /// We took over from an older instance (it stepped down) — bind now.
    /// (#1046: the autostart registration is the desktop shell's to reconcile.)
    TookOver,
    /// A same-or-newer instance is already serving — exit this process.
    StandDown,
}

// ── DAE-01 helpers: probe the peer socket, ask it to step down, compare
// versions. All client-side (no server changes to the wire contract).

/// Send one IPC request to the peer and read its response line.
/// #1115：签名模式下连上后先反向校验服务端，不是签名 daemon 就什么都不发。
async fn peer_call(peer: &PeerEndpoint, method: &str) -> Option<serde_json::Value> {
    let (conn, preamble) = match peer.connect().await {
        Ok(c) => c,
        Err(e) => {
            tracing::debug!("DAE-01: {e}");
            return None;
        }
    };
    let (rx, mut tx) = conn.split();
    let mut lines = BufReader::new(rx).lines();
    if let Some(token_hex) = preamble {
        tx.write_all(token_hex.as_bytes()).await.ok()?;
        tx.write_all(b"\n").await.ok()?;
    }
    let req = format!("{{\"id\":\"dae-01\",\"method\":\"{method}\",\"params\":{{}}}}\n");
    tx.write_all(req.as_bytes()).await.ok()?;
    let line = tokio::time::timeout(Duration::from_millis(800), lines.next_line())
        .await
        .ok()?
        .ok()??;
    serde_json::from_str::<serde_json::Value>(&line).ok()
}

/// Live peer (status answered) or None (dead socket / no instance).
async fn probe_peer(peer: &PeerEndpoint) -> Option<serde_json::Value> {
    peer_call(peer, "status").await
}

/// Ask the live peer to exit (newest-wins takeover).
async fn notify_step_down(peer: &PeerEndpoint) -> Option<serde_json::Value> {
    peer_call(peer, "daemon.step_down").await
}

/// 存活探测的连接上限。`peer_call` 的应答超时是 800ms；这里只需要一次
/// 连接握手的判决，500ms 足够，且必须有界（见下方 DAE-06 注释）。
const LIVENESS_CONNECT_TIMEOUT: Duration = Duration::from_millis(500);

/// True if anything is listening on the socket (raw connect, no auth).
/// Distinguishes a dead socket file (connect refused) from a live peer —
/// DAE-01b blocker①: the old code conflated the two and unlinked live
/// sockets it merely failed to authenticate against.
///
/// DAE-06：这里**必须是异步 + 有界**。原实现用同步 `Stream::connect`，
/// 却被 async 的 `claim_single_instance` 直接调用：unix domain socket 上
/// 内核会立刻接受连接，所以一直看不出问题；Windows 命名管道不同——服务端
/// 不在 accept 状态时客户端要等（ERROR_PIPE_BUSY），同步连接于是把执行器
/// 线程整条堵住。单线程 runtime 下（`#[tokio::test]` 的默认）在岗实例的
/// 任务因此永远得不到轮询 → 死锁（DAE-06 实测：该测试 60s 不返回）。
/// 生产是多线程 runtime 且对端是另一个进程，表现为「偶发堵住一个 worker」
/// 而非必死，但 async 路径里本就不该有阻塞 IO。
///
/// **超时一律判为「活着」**：有东西在监听却不应答，绝不能被当成死 socket
/// 去 unlink——那正是 DAE-01b blocker① 那次事故的形状。宁可自己 StandDown。
async fn socket_is_live(socket_name: &str) -> bool {
    let Ok(name) = socket_name.to_ns_name::<GenericNamespaced>() else {
        return false;
    };
    connect_is_live(name).await
}

/// [`socket_is_live`] 的判决本体（命名空间名与文件路径共用）。
async fn connect_is_live(name: interprocess::local_socket::Name<'_>) -> bool {
    match tokio::time::timeout(
        LIVENESS_CONNECT_TIMEOUT,
        interprocess::local_socket::tokio::Stream::connect(name),
    )
    .await
    {
        // 连上了 = 有人在监听（连接随即 drop，我们只要这个判决）。
        Ok(Ok(_conn)) => true,
        // 连接被拒 = 死 socket 文件 / 首次启动。
        Ok(Err(_)) => false,
        // 连得上但对端忙着没握手 —— 当作活的，绝不 unlink。
        Err(_elapsed) => true,
    }
}

/// The predecessor's auth token, read from `data_dir/ipc.token`
/// (`{socket_name}\n{token_hex}\n` — written by [`IpcServer::serve`]).
/// `None` = no recorded predecessor (fresh data dir / token file absent).
fn read_predecessor_token(data_dir: &std::path::Path) -> Option<String> {
    let raw = std::fs::read_to_string(data_dir.join("ipc.token")).ok()?;
    raw.lines()
        .nth(1)
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map(str::to_string)
}

/// Remove a stale socket endpoint left by a killed predecessor.
///
/// QA-09 迁移（#211）：平台分叉已收进 `crates/platform/`。unix 域套接字
/// 在文件系统里留文件，要清；Windows 的命名管道是内核对象，不留文件，
/// 适配器那边回的是 `NotApplicable`——**「不需要做」和「没实现」在契约
/// 上是两回事**，这里不必也不该区分处理。
///
/// 顺带干掉了 BUILD-06 那个补丁：原先在 Windows 上整个函数体被条件编译
/// 掉，参数没有任何使用点，`-D warnings` 把 `unused_variables` 提成
/// error，只好写一行 `let _ = socket_name;` 压住。现在参数真的被用了，
/// 补丁不需要了。
fn clean_stale_socket(socket_name: &str) {
    use platform::PlatformAdapter as _;
    let _ = platform::adapter().remove_stale_ipc_endpoint(socket_name);
}

/// The daemon's version — **compile-time only**:
/// 1. `PPF_BUILD_VERSION` (baked at compile time from the release tag,
///    DAE-01b blocker② — `CARGO_PKG_VERSION` carries no `-test.N` suffix,
///    so test.7 and test.8 would both report 0.2.0 and the newer test
///    package could never take over during dogfood week);
/// 2. `CARGO_PKG_VERSION` (local / dev builds).
///
/// #1115：不再有运行时覆盖（以前的 `PPF_DAEMON_VERSION`）。版本决定单实例交接谁胜：
/// 任何同用户程序带 `PPF_DAEMON_VERSION=999` 启动签名 daemon，就能让常驻实例退位、
/// 由自己拉起（继承自己环境）的那个接管。现在只有真的更新的正版能接管。
pub fn daemon_version() -> String {
    option_env!("PPF_BUILD_VERSION")
        .map(str::to_string)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string())
}

/// #1115：`config.set_library {library}` 的应答（常驻 daemon 与未配置状态共用）。
/// 校验类错误原样放进 `params.ui_error`（keyed JSON），窗口程序据此显示具体原因。
async fn set_library_resp(
    id: String,
    location: Arc<crate::library_location::LibraryLocation>,
    params: &serde_json::Value,
) -> Resp {
    let Some(library) = params
        .get("library")
        .and_then(|v| v.as_str())
        .map(str::to_string)
    else {
        return Resp::err(id, RespError::new(Reason::BadRequest));
    };
    match tokio::task::spawn_blocking(move || location.set(&library)).await {
        Ok(Ok(cfg)) => Resp::ok(
            id,
            serde_json::json!({ "config": cfg.display().to_string(), "restart_required": true }),
        ),
        Ok(Err(e)) => Resp::err(
            id,
            RespError::new(Reason::BadRequest).with_param("ui_error", e),
        ),
        Err(_) => Resp::err(id, RespError::new(Reason::Internal)),
    }
}

/// #639：「更改照片库位置」——校验、把搬迁计划落盘，应答后以 [`EXIT_CONFIGURED_RESTART`] 退出，
/// 重启时由 main 接着搬。照片库找不到时也能调（新位置上已经是这个库 ⇒ 只改指向）。
fn relocate_resp(
    id: String,
    library: &std::path::Path,
    local_base: &std::path::Path,
    params: &serde_json::Value,
) -> Resp {
    let Some(target) = params.get("target").and_then(|v| v.as_str()) else {
        return Resp::err(id, RespError::new(Reason::BadRequest));
    };
    let target = std::path::Path::new(target);
    // 预检（窗口确认前调）：不落盘，告诉窗口最终位置、文件夹里是否已有别的东西。
    if params.get("dry_run").and_then(|v| v.as_bool()) == Some(true) {
        return match crate::relocate::check(library, target, local_base) {
            Ok(c) => Resp::ok(
                id,
                serde_json::json!({
                    "to": c.plan.to.display().to_string(),
                    "non_empty": c.contents.to_json(),
                    "adopt": c.adopt,
                }),
            ),
            Err(e) => Resp::err(
                id,
                RespError::new(Reason::BadRequest).with_param("ui_error", e),
            ),
        };
    }
    match crate::relocate::plan(library, target, local_base) {
        Ok(check) => {
            let plan = check.plan;
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(200)).await;
                tracing::info!("#639: 搬迁计划已落盘，退出以开始搬迁");
                std::process::exit(EXIT_CONFIGURED_RESTART);
            });
            Resp::ok(
                id,
                serde_json::json!({ "to": plan.to.display().to_string() }),
            )
        }
        Err(e) => Resp::err(
            id,
            RespError::new(Reason::BadRequest).with_param("ui_error", e),
        ),
    }
}

/// #1115：未配置状态写好库位置后的退出码——「请重启我」。LaunchAgent 的 KeepAlive
/// 按非零退出把 daemon 拉起来，新实例带着库启动；壳一次性拉起的实例由壳自己收掉。
pub const EXIT_CONFIGURED_RESTART: i32 = 75;

/// #1115：未配置状态（正本里还没有库位置）的服务（签名 socket 版，macOS）：只答 `status`（报
/// `unconfigured`）与 `config.set_library`；单实例交接要的 `daemon.step_down` 照答。不开库、
/// 不起传输、不发配对码。写好库位置后以 [`EXIT_CONFIGURED_RESTART`] 退出。
pub async fn serve_unconfigured_signed(
    path: &std::path::Path,
    version: String,
    location: Arc<crate::library_location::LibraryLocation>,
) -> anyhow::Result<()> {
    serve_waiting_signed(path, version, Waiting::Unconfigured(location)).await
}

/// 常驻 daemon 还不能开库时在等什么——两种状态共用同一套端点、身份校验与单实例交接，
/// 只是能答的方法不同。
#[derive(Clone)]
pub enum Waiting {
    /// #1115：正本里还没有库位置，等首启向导写入。
    Unconfigured(Arc<crate::library_location::LibraryLocation>),
    /// #1253：库位置在，但那里找不到照片库（外置盘没接、文件夹被移走 / 删掉 / 改名，或那里是
    /// 别的库——#1260 库 ID 不符）。不退出、不开库、不起传输，说明原因与路径；用户放回后点
    /// 「重新检查」（`library.recheck`）。`local_base` = 本机服务数据目录（判库 ID 用）。
    LibraryMissing { dir: PathBuf, local_base: PathBuf },
    /// #639：正在搬迁照片库（不开库、不起传输）；只答进度。搬完由 main 改指向后重启。
    Relocating(Arc<crate::relocate::Live>),
}

/// [`Waiting`] 的签名 socket 版（macOS）。
pub async fn serve_waiting_signed(
    path: &std::path::Path,
    version: String,
    waiting: Waiting,
) -> anyhow::Result<()> {
    let _ = std::fs::remove_file(path);
    let name = path.to_fs_name::<GenericFilePath>()?;
    let listener = ListenerOptions::new().name(name).create_tokio()?;
    serve_unconfigured_verified(listener, version, waiting).await
}

/// #1167：Windows 命名管道上的未配置状态。口径与签名版一致；多一件事：写好库位置的那一刻
/// 把调用方记成主人（D3：第一个完成首启向导的用户成为主人），之后管道只对主人开放。
pub async fn serve_unconfigured_pipe(
    pipe: &str,
    version: String,
    location: Arc<crate::library_location::LibraryLocation>,
) -> anyhow::Result<()> {
    serve_waiting_pipe(pipe, version, Waiting::Unconfigured(location)).await
}

/// [`Waiting`] 的命名管道版（Windows）。
pub async fn serve_waiting_pipe(
    pipe: &str,
    version: String,
    waiting: Waiting,
) -> anyhow::Result<()> {
    let listener = platform::bind_resident_pipe(pipe)?;
    serve_unconfigured_verified(listener, version, waiting).await
}

/// 未配置状态的按身份认证服务（签名 socket 与命名管道共用）。
async fn serve_unconfigured_verified(
    listener: interprocess::local_socket::tokio::Listener,
    version: String,
    waiting: Waiting,
) -> anyhow::Result<()> {
    let started_at = now_ms();
    loop {
        let conn = match listener.accept().await {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("ipc accept: {e}");
                continue;
            }
        };
        let waiting = waiting.clone();
        let version = version.clone();
        let floor = version.clone();
        tokio::spawn(async move {
            let Some(prefix) = read_first_line_if_needed(&conn).await else {
                return;
            };
            let checked = tokio::task::spawn_blocking(move || {
                // #1150：服务端接入加版本下限——对端不得低于本 daemon 自身版本。
                let check = platform::verify_local_peer_min_version(
                    &conn,
                    &[platform::PeerRole::Shell, platform::PeerRole::Daemon],
                    &floor,
                );
                // #1167：首启向导写好库位置时要把这个人记成主人（只有 Windows 取得到）。
                let user = platform::local_peer_user(&conn);
                (conn, check, user)
            })
            .await;
            let (conn, client, user) = match checked {
                Ok((conn, platform::PeerCheck::Verified(platform::PeerRole::Shell), user)) => {
                    (conn, IpcClient::Shell, user)
                }
                Ok((conn, platform::PeerCheck::Verified(platform::PeerRole::Daemon), user)) => {
                    (conn, IpcClient::Daemon, user)
                }
                other => {
                    tracing::warn!(
                        "#1115/#1150: 拒绝 IPC 连接（未配置状态，身份或版本不符）：{:?}",
                        other.map(|(_, c, _)| c)
                    );
                    return;
                }
            };
            let (rx, tx) = conn.split();
            unconfigured_session(
                req_lines(prefix, rx),
                tx,
                client,
                user,
                &version,
                started_at,
                &waiting,
            )
            .await;
        });
    }
}

/// #1115：令牌端点上的未配置状态（Windows / Linux：没有 config.toml）。口径与签名版一致——
/// 只答 `status` / `config.set_library` / `daemon.step_down` / 不推事件的 `events.subscribe`。
/// 令牌文件写在平台数据目录（壳在那里找），持令牌者即窗口程序（与令牌模式的常驻服务同一信任
/// 模型）。socket 名固定为 [`UNCONFIGURED_SOCKET_NAME`]：两个未配置实例走同一套单实例交接。
pub async fn serve_unconfigured_token(
    platform_dir: &std::path::Path,
    token: [u8; 32],
    version: String,
    location: Arc<crate::library_location::LibraryLocation>,
) -> anyhow::Result<()> {
    serve_waiting_token(
        platform_dir,
        token,
        version,
        Waiting::Unconfigured(location),
    )
    .await
}

/// [`Waiting`] 的令牌端点版（Windows / Linux 令牌模式）。
pub async fn serve_waiting_token(
    platform_dir: &std::path::Path,
    token: [u8; 32],
    version: String,
    waiting: Waiting,
) -> anyhow::Result<()> {
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    std::fs::create_dir_all(platform_dir)?;
    let token_path = platform_dir.join("ipc.token");
    std::fs::write(
        &token_path,
        format!("{UNCONFIGURED_SOCKET_NAME}\n{token_hex}\n"),
    )?;
    {
        use platform::PlatformAdapter as _;
        platform::adapter().restrict_to_owner(&token_path)?;
    }
    clean_stale_socket(UNCONFIGURED_SOCKET_NAME);
    let name = UNCONFIGURED_SOCKET_NAME.to_ns_name::<GenericNamespaced>()?;
    let listener = ListenerOptions::new().name(name).create_tokio()?;
    let started_at = now_ms();
    loop {
        let conn = match listener.accept().await {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("ipc accept: {e}");
                continue;
            }
        };
        let waiting = waiting.clone();
        let version = version.clone();
        let expected = token_hex.clone();
        tokio::spawn(async move {
            let (rx, tx) = conn.split();
            let mut lines = req_lines(Vec::new(), rx);
            match lines.next_line().await {
                Ok(Some(first)) if first.trim() == expected => {}
                _ => {
                    tracing::warn!("#1115: 拒绝 IPC 连接（未配置状态）：令牌不对");
                    return;
                }
            }
            unconfigured_session(
                lines,
                tx,
                IpcClient::Shell,
                None,
                &version,
                started_at,
                &waiting,
            )
            .await;
        });
    }
}

/// #1115：令牌模式下未配置状态的 socket 名（还没有身份，名字不能从 NodeId 派生）。
pub const UNCONFIGURED_SOCKET_NAME: &str = "ppf-unconfigured";

/// 未配置状态的请求循环（签名 socket、命名管道与令牌端点共用）。写好库位置 ⇒ 以
/// [`EXIT_CONFIGURED_RESTART`] 退出；交班 ⇒ 0 退出。
///
/// #1167：`user` 是连接方的系统用户（只有 Windows 管道有）。写好库位置后立刻把他记成
/// 主人；记不下来就如实回错误——下次启动仍是未配置状态（服务形态下「有主人」才算配置
/// 完成），绝不在没有主人的情况下带着库开放管道。
async fn unconfigured_session(
    mut lines: ReqLines,
    mut tx: interprocess::local_socket::tokio::SendHalf,
    client: IpcClient,
    user: Option<platform::PeerUser>,
    version: &str,
    started_at: i64,
    waiting: &Waiting,
) {
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(req) = serde_json::from_str::<Req>(&line) else {
            continue;
        };
        let mut resp = match waiting {
            Waiting::Unconfigured(location) => {
                unconfigured_dispatch(&req, client, version, started_at, location).await
            }
            Waiting::LibraryMissing { dir, local_base } => {
                library_missing_dispatch(&req, client, version, started_at, dir, local_base)
            }
            Waiting::Relocating(live) => {
                relocating_dispatch(&req, client, version, started_at, live)
            }
        };
        if req.method == "config.set_library" && resp.ok {
            resp = claim_owner_after_set(resp, user.as_ref()).await;
        }
        let configured =
            (req.method == "config.set_library" && resp.ok) || recheck_found(&req, &resp);
        let step_down = req.method == "daemon.step_down" && resp.ok;
        let Ok(mut out) = serde_json::to_string(&resp) else {
            return;
        };
        out.push('\n');
        if tx.write_all(out.as_bytes()).await.is_err() {
            return;
        }
        if configured || step_down {
            tokio::time::sleep(Duration::from_millis(200)).await;
            if configured {
                tracing::info!("#1115 / #1253: 库位置已写入或照片库已回来，退出以带着库重新启动");
                std::process::exit(EXIT_CONFIGURED_RESTART);
            }
            std::process::exit(0);
        }
    }
}

/// #1167：库位置写好后把连接方记成主人；失败就把成功应答换成错误（带原因）。
async fn claim_owner_after_set(resp: Resp, user: Option<&platform::PeerUser>) -> Resp {
    let user = user.cloned();
    let claimed = tokio::task::spawn_blocking(move || {
        use platform::PlatformAdapter as _;
        platform::adapter().claim_resident_owner(user.as_ref())
    })
    .await;
    match claimed {
        Ok(Ok(applied)) => {
            if applied == platform::Applied::Done {
                tracing::info!("#1167: 首启向导完成，已记下这台电脑 P-Pass 的主人");
            }
            resp
        }
        Ok(Err(e)) => {
            tracing::error!("#1167: 库位置已写入，但记不下主人：{e}");
            Resp::err(
                resp.id,
                RespError::new(Reason::Internal).with_param("owner_error", e.to_string()),
            )
        }
        Err(_) => Resp::err(resp.id, RespError::new(Reason::Internal)),
    }
}

/// 未配置状态能答的方法：`status`、`config.set_library`，以及单实例交接的
/// `daemon.step_down` 与不推事件的 `events.subscribe`。纯函数式（除写库位置），单测直接调。
pub async fn unconfigured_dispatch(
    req: &Req,
    client: IpcClient,
    version: &str,
    started_at: i64,
    location: &Arc<crate::library_location::LibraryLocation>,
) -> Resp {
    let id = req.id.clone();
    if !client.may_call(&req.method) {
        return Resp::err(id, RespError::new(Reason::RoleForbidden));
    }
    match req.method.as_str() {
        "status" => Resp::ok(
            id,
            serde_json::json!({
                "unconfigured": true,
                "version": version,
                "pid": std::process::id(),
                "started_at": started_at,
            }),
        ),
        "daemon.step_down" => Resp::ok(id, serde_json::json!({ "stepping_down": true })),
        // 服务确实在跑，只是还没有事件可推：订阅照常成立、连接保持，壳据此把服务判成
        // 「运行中」（DESK-63 的就绪信号）而不是「不可达」，也就不会去自愈拉它。写好库位置后
        // 进程退出、连接断开，壳照常重连带库重启的新实例。
        "events.subscribe" => Resp::ok(id, serde_json::json!({ "subscribed": true })),
        "config.set_library" => set_library_resp(id, Arc::clone(location), &req.params).await,
        // 其余一律：还没有库。
        _ => Resp::err(id, RespError::new(Reason::LibraryUnavailable)),
    }
}

/// #1253：库找不到状态能答的方法。`status` 报 `library_missing` 与路径（窗口据此说明原因，
/// **不**报 `unconfigured`——那会把人送进首启向导，向导预填的正是这个找不到的路径，一点
/// 「完成」就会在原位置新建空目录，正是 DESK-46 防的挂载点阴影）；单实例交接与不推事件的
/// 订阅照答。改库位置不在这里答（选新位置要单独设计），其余一律「库不可用」。
pub fn library_missing_dispatch(
    req: &Req,
    client: IpcClient,
    version: &str,
    started_at: i64,
    dir: &std::path::Path,
    local_base: &std::path::Path,
) -> Resp {
    let id = req.id.clone();
    if !client.may_call(&req.method) {
        return Resp::err(id, RespError::new(Reason::RoleForbidden));
    }
    match req.method.as_str() {
        "status" => Resp::ok(
            id,
            serde_json::json!({
                "library_missing": true,
                "library_dir": dir.display().to_string(),
                "version": version,
                "pid": std::process::id(),
                "started_at": started_at,
            }),
        ),
        "daemon.step_down" => Resp::ok(id, serde_json::json!({ "stepping_down": true })),
        "events.subscribe" => Resp::ok(id, serde_json::json!({ "subscribed": true })),
        // 找不到照片库时不改库位置（向导里点「继续」也走到这里）。被拒要留证据：保存失败查得到原因。
        "config.set_library" => {
            tracing::warn!(
                "#1253: 照片库找不到期间拒绝 config.set_library（库位置不变：{}）",
                dir.display()
            );
            Resp::err(id, RespError::new(Reason::LibraryUnavailable))
        }
        // #639：找不到照片库时指向新位置——新位置上已经是这个库（用户自己搬过去了）⇒ 只改指向。
        "library.relocate" => relocate_resp(id, dir, local_base, &req.params),
        // 窗口上的「重新检查」：库回来了 ⇒ 应答后以 EXIT_CONFIGURED_RESTART 退出、带着库重启；
        // 还不在 ⇒ 如实回答，状态不变（不轮询、不自动重启——库是用户自己处理的）。
        "library.recheck" => Resp::ok(
            id,
            serde_json::json!({
                "found": crate::layout::library_presence(dir, local_base)
                    == crate::layout::Presence::Present
            }),
        ),
        _ => Resp::err(id, RespError::new(Reason::LibraryUnavailable)),
    }
}

/// #639：搬迁中——`status` 报进度（窗口按「备份已暂停：正在搬迁」呈现），其余一律「库不可用」。
pub fn relocating_dispatch(
    req: &Req,
    client: IpcClient,
    version: &str,
    started_at: i64,
    live: &crate::relocate::Live,
) -> Resp {
    let id = req.id.clone();
    if !client.may_call(&req.method) {
        return Resp::err(id, RespError::new(Reason::RoleForbidden));
    }
    match req.method.as_str() {
        "status" => {
            let (done, total) = live.progress();
            Resp::ok(
                id,
                serde_json::json!({
                    "relocating": true,
                    "relocate_from": live.plan.from.display().to_string(),
                    "relocate_to": live.plan.to.display().to_string(),
                    "relocate_done_bytes": done,
                    "relocate_total_bytes": total,
                    "version": version,
                    "pid": std::process::id(),
                    "started_at": started_at,
                }),
            )
        }
        "daemon.step_down" => Resp::ok(id, serde_json::json!({ "stepping_down": true })),
        "events.subscribe" => Resp::ok(id, serde_json::json!({ "subscribed": true })),
        _ => Resp::err(id, RespError::new(Reason::LibraryUnavailable)),
    }
}

/// 「重新检查」的应答是否意味着库回来了（会话据此在应答写出后退出重启）。
fn recheck_found(req: &Req, resp: &Resp) -> bool {
    req.method == "library.recheck"
        && resp.ok
        && resp
            .result
            .as_ref()
            .and_then(|r| r.get("found"))
            .and_then(|v| v.as_bool())
            == Some(true)
}

/// #1115：Unix 域套接字路径的上限（`sockaddr_un.sun_path` 104 字节，含结尾 NUL）。
pub const MAX_SOCKET_PATH_BYTES: usize = 103;

/// 签名 socket 的路径能不能用。超长（用户名很长时）⇒ 拒绝启动并说明，不静默换位置。
pub fn check_socket_path(path: &std::path::Path) -> Result<(), String> {
    let len = path.as_os_str().len();
    if len > MAX_SOCKET_PATH_BYTES {
        return Err(format!(
            "IPC socket 路径 {} 有 {len} 字节，超过系统上限 {MAX_SOCKET_PATH_BYTES}——后台服务无法启动（#1115）",
            path.display()
        ));
    }
    Ok(())
}

// DAE-01 newest-wins 与 #1044 B13 的 `status.shell_relation` 共用唯一的版本
// 比较实现（crates/version-cmp，桌面壳也依赖它）。
use version_cmp::version_cmp;

impl IpcServer {
    /// `pending_rx` is the receiver returned by [`Pairing::new`] — the
    /// IPC layer takes over the owner-confirmation queue.
    pub fn new(
        db: Db,
        pairing: Pairing,
        diag: DiagAgg,
        data_dir: PathBuf,
        mut pending_rx: tokio::sync::mpsc::UnboundedReceiver<PendingPair>,
        events: EventBus,
    ) -> Self {
        let pending: Arc<Mutex<Vec<PendingPair>>> = Arc::default();
        let queue = Arc::clone(&pending);
        let diag2 = diag.clone();
        let events2 = events.clone();
        let pending_ttl_ms = Arc::new(std::sync::atomic::AtomicI64::new(PENDING_TTL_MS));
        let ttl_for_sweep = Arc::clone(&pending_ttl_ms);
        tokio::spawn(async move {
            while let Some(p) = pending_rx.recv().await {
                diag2.apply(diag::DaemonEvent::PairingStarted);
                {
                    // DEV-05 (#276) 设计要点 3「新的顶掉旧的」: one phone
                    // scanning twice in a row leaves ONE row, not two —
                    // the old row's request half is stale by then (the
                    // phone already dropped that connection), and
                    // `confirm`'s position(...) on a duplicate would
                    // decide the OLD one while the owner believes they
                    // approved the scan on screen. Dropping the replaced
                    // PendingPair sends nothing; its waiting request (if
                    // any) sees the receiver-side channel close and
                    // resolves denied — exactly right for a stale scan.
                    // Same sweep also retires TTL-expired rows opportunistically
                    // (expiry judgment happens here because the queue holds
                    // `requested_at`, see pairing.rs).
                    let now = now_ms();
                    let ttl = ttl_for_sweep.load(std::sync::atomic::Ordering::Relaxed);
                    let mut q = queue.lock().expect("pending lock");
                    // DEV-07 follow-up (#463): withdrawn rows leave too.
                    q.retain(|old| {
                        old.requested_at + ttl > now
                            && old.peer.0 != p.peer.0
                            && !old.is_withdrawn()
                    });
                    q.push(p);
                }
                // IPC-02: 新扫码请求入队——桌面壳即时从「二维码弹窗」切到
                // 「授权列表」，不再等下一次兜底轮询。
                events::emit(
                    &events2,
                    events::PAIRING_PENDING_CHANGED,
                    serde_json::json!({ "pending": 0 }), // 占位，客户端全量拉取
                );
            }
        });
        Self {
            db,
            pairing,
            diag,
            data_dir,
            pending,
            events,
            started_at: now_ms(),
            pending_ttl_ms,
            now: Arc::new(now_ms),
            step_down_exit: Arc::new(|| std::process::exit(0)),
            conn_status: Arc::new(|_| transport::ConnectionStatus::Unknown),
            flow_connection: Arc::new(|_| None),
            query: std::sync::OnceLock::new(),
            subscriptions: SubscriptionRegistry::new(),
            flow_delivery: std::sync::OnceLock::new(),
            backup: std::sync::OnceLock::new(),
            peer_closer: std::sync::OnceLock::new(),
            outdated: crate::router::OutdatedPeers::new(),
            desktop_name: None,
            library_location: None,
        }
    }

    /// #1070: share the router's version-mismatch registry (main wires the
    /// same instance into `Router::with_outdated_peers`).
    pub fn set_outdated_peers(&mut self, outdated: crate::router::OutdatedPeers) {
        self.outdated = outdated;
    }

    /// #1118：本机电脑名，二维码弹窗下方与指纹一起显示（与 hello 里给手机的同一个）。
    pub fn set_desktop_name(&mut self, name: String) {
        self.desktop_name = Some(name);
    }

    /// #1115：开放 `config.set_library`（常驻 daemon）。测试沙盒不调它 ⇒ 方法不开放。
    pub fn set_library_location(
        &mut self,
        location: Arc<crate::library_location::LibraryLocation>,
    ) {
        self.library_location = Some(location);
    }

    /// SYNC-03: 与 Router 共用同一份订阅登记表——不注入时是一份独立空表
    /// （`close` no-op，现有测试不受影响）。main 在 transport bind 前
    /// 就能调（不依赖 transport，跟 Router 的 `with_events` 时机一致）。
    pub fn set_subscriptions(&mut self, subscriptions: SubscriptionRegistry) {
        self.subscriptions = subscriptions;
    }

    /// DESK-03: 注入查询平面（main 在 transport bind 后调用，把 Router
    /// 同款 QueryEngine clone 过来）——桌面壳照片墙走本地 IPC 消费
    /// timeline/thumb/asset.*。重复 set 静默忽略（只注入一次）。
    pub fn set_query(&self, query: crate::query::QueryEngine) {
        let _ = self.query.set(query);
    }

    /// #563: inject the Flow delivery port so `device.revoke` can cancel the
    /// removed device's in-flight fetches (main calls this once FlowDelivery
    /// exists; repeated sets are ignored).
    /// #1119: see the `peer_closer` field.
    pub fn set_peer_closer(&self, closer: crate::unpair::PeerCloser) {
        let _ = self.peer_closer.set(closer);
    }

    /// #1117: see the `backup` field.
    pub fn set_backup(&self, backup: crate::backup::BackupEngine) {
        let _ = self.backup.set(backup);
    }

    pub fn set_flow_delivery(&self, flow_delivery: crate::flow_delivery::FlowDelivery) {
        let _ = self.flow_delivery.set(flow_delivery);
    }

    /// Override the step_down side effect (tests only).
    pub fn set_step_down_exit(&mut self, f: impl Fn() + Send + Sync + 'static) {
        self.step_down_exit = Arc::new(f);
    }

    /// DEV-05 (#276): override the queue-side pending TTL (tests only —
    /// production keeps [`PENDING_TTL_MS`]). Pair it with
    /// [`Pairing::with_pending_ttl`] to exercise the two-sided expiry
    /// without sleeping minutes.
    pub fn set_pending_ttl_for_test(&mut self, ttl_ms: i64) {
        self.pending_ttl_ms
            .store(ttl_ms, std::sync::atomic::Ordering::Relaxed);
    }

    /// Override the clock (#1055; tests only): lets a test assert the exact
    /// `revoked_at` that `device.revoke` stamps.
    pub fn with_clock(mut self, now: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.now = Arc::new(now);
        self
    }

    fn pending_ttl(&self) -> i64 {
        self.pending_ttl_ms
            .load(std::sync::atomic::Ordering::Relaxed)
    }

    /// T-090: inject the live connection-status source (main wires this
    /// to the transport once it is bound; unset = honest `Unknown`).
    pub fn set_conn_status_provider(
        &mut self,
        f: impl Fn(&[u8]) -> transport::ConnectionStatus + Send + Sync + 'static,
    ) {
        self.conn_status = Arc::new(f);
    }

    /// NET-05: inject the currently-active Flow's exact blobs-plane route.
    /// Unlike `connection`, absence means there is no active transfer and is
    /// intentionally serialized as JSON null.
    pub fn set_flow_connection_provider(
        &mut self,
        f: impl Fn(&[u8]) -> Option<transport::ConnectionStatus> + Send + Sync + 'static,
    ) {
        self.flow_connection = Arc::new(f);
    }

    /// DAE-01 single-instance claim — run BEFORE binding the socket.
    ///
    /// Replaces the old unlink-before-bind (which let a latecomer blind-kill
    /// its live predecessor). Order: connect to the socket — if nothing is
    /// listening (dead socket file / first start) clean and bind; if a live
    /// instance answers, authenticate with the **predecessor's** token read
    /// from `data_dir/ipc.token` (DAE-01b blocker①: probing with our own
    /// fresh token would be rejected by the incumbent — the auth failure
    /// looked like a dead socket and the claimant unlinked the live peer's
    /// socket, ghosting it). Then compare versions (newest wins): same-or-
    /// newer peer → we stand down (exit 0, the peer keeps serving); we are
    /// newer → ask the peer to step down, wait for the socket to free, then
    /// proceed. A live peer we cannot authenticate is NEVER unlinked — we
    /// stand down instead.
    pub async fn claim_single_instance(&self, socket_name: &str, version: &str) -> Claim {
        if !socket_is_live(socket_name).await {
            // Nothing listening: stale file or first start — clean, bind.
            clean_stale_socket(socket_name);
            return Claim::Proceed;
        }
        // A live peer is listening. Authenticate with the predecessor's
        // token — never a token of our own (DAE-01b blocker①).
        let Some(token_hex) = read_predecessor_token(&self.data_dir) else {
            tracing::error!(
                "DAE-01b: live daemon on {socket_name} but no ipc.token — standing down (never blind-grab a live socket)"
            );
            return Claim::StandDown;
        };
        self.claim_with(
            &PeerEndpoint::Token {
                socket_name: socket_name.to_string(),
                token_hex,
            },
            version,
        )
        .await
    }

    /// #1115：签名 socket 上的单实例交接。与令牌版同一套裁决（newest wins）；不同的是
    /// 不需要前任的令牌——双方按代码签名互认：在位者答应 daemon 身份的 `status` /
    /// `daemon.step_down`，我们连上后先反向校验在位者是签名 daemon。校验不过（别的程序
    /// 占着这个 socket）⇒ 退位，绝不删掉一个活着的 socket。
    pub async fn claim_single_instance_signed(
        &self,
        path: &std::path::Path,
        version: &str,
    ) -> Claim {
        self.claim_with(&PeerEndpoint::Signed(path.to_path_buf()), version)
            .await
    }

    /// #1167：命名管道上的单实例交接。与签名版同理——双方按 Windows 用户 SID 互认，不需要
    /// 前任的令牌；核对不过（别的程序占着这个管道名）⇒ 退位。
    pub async fn claim_single_instance_pipe(&self, pipe: &str, version: &str) -> Claim {
        self.claim_with(&PeerEndpoint::Pipe(pipe.to_string()), version)
            .await
    }

    async fn claim_with(&self, peer: &PeerEndpoint, version: &str) -> Claim {
        claim_endpoint(peer, version).await
    }
}

/// DAE-01 单实例裁决（newest wins）的本体：令牌与签名两种端点共用，未配置状态也用它。
pub async fn claim_endpoint(peer: &PeerEndpoint, version: &str) -> Claim {
    {
        let where_ = peer.describe();
        if !peer.is_live().await {
            // Nothing listening: stale file or first start — clean, bind.
            peer.clean_stale();
            return Claim::Proceed;
        }
        let Some(probe) = probe_peer(peer).await else {
            if peer.is_live().await {
                // Socket still live but rejects us (token drift / not a signed daemon).
                tracing::error!(
                    "DAE-01b: live daemon on {where_} rejects us or is not ours — standing down (do not unlink)"
                );
                return Claim::StandDown;
            }
            // Peer exited between the two checks — dead socket, bind.
            peer.clean_stale();
            return Claim::Proceed;
        };
        let r = probe.get("result");
        let peer_version = r
            .and_then(|v| v.get("version"))
            .and_then(|v| v.as_str())
            .unwrap_or("0.0.0")
            .to_string();
        let peer_pid = r
            .and_then(|v| v.get("pid"))
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        tracing::info!("DAE-01: live daemon v{peer_version} (pid {peer_pid}) on {where_}");
        match version_cmp(version, &peer_version) {
            Ordering::Less | Ordering::Equal => {
                tracing::info!(
                    "DAE-01: existing v{peer_version} >= ours v{version} — standing down"
                );
                Claim::StandDown
            }
            Ordering::Greater => {
                tracing::info!("DAE-01: ours v{version} > existing v{peer_version} — takeover");
                let _ = notify_step_down(peer).await;
                // Wait for the peer to exit (bounded), then bind.
                for _ in 0..50 {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    if probe_peer(peer).await.is_none() {
                        break;
                    }
                }
                peer.clean_stale();
                Claim::TookOver
            }
        }
    }
}

impl IpcServer {
    /// Bind the named local socket, write the token file, serve forever.
    /// The socket name is `ppf-<8 hex of a random id>` unless a fixed
    /// name is passed (tests pass one; production derives from data_dir).
    pub async fn serve(self: Arc<Self>, socket_name: &str, token: [u8; 32]) -> anyhow::Result<()> {
        let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
        std::fs::create_dir_all(&self.data_dir)?;
        // The token file is how the UI finds AND authenticates the daemon.
        // #1115：仅属主可读写（以前是 0644，同一台机器上谁都能读到令牌）。
        let token_path = self.data_dir.join("ipc.token");
        std::fs::write(&token_path, format!("{socket_name}\n{token_hex}\n"))?;
        {
            use platform::PlatformAdapter as _;
            platform::adapter().restrict_to_owner(&token_path)?;
        }

        // The socket name is stable now (derived from the persistent
        // NodeId) — clear a stale file left by a killed predecessor or
        // bind fails with EADDRINUSE and the whole IPC plane dies
        // (launchd guarantees single instance, so unlink is safe).
        // QA-09 迁移（#211）：原先这里内联了第二份 unix 专属拷贝，和上面
        // clean_stale_socket 一模一样。现在共用同一个函数。
        clean_stale_socket(socket_name);
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

    /// #1115：在签名 socket 上服务（macOS 常驻 daemon）。父目录由调用方建成仅本用户可访问
    /// （`PlatformAdapter::prepare_private_dir`）；不写令牌文件。每个连接 accept 后、读任何
    /// 字节前按对端 audit token 校验代码签名：窗口程序 ⇒ [`IpcClient::Shell`]，daemon 自身
    /// ⇒ [`IpcClient::Daemon`]，其余断开并记一条 `ipc.bad_peer`。
    pub async fn serve_signed(self: Arc<Self>, path: &std::path::Path) -> anyhow::Result<()> {
        // 残留的 socket 文件（被杀的前任）——claim 已确认没人在听。
        let _ = std::fs::remove_file(path);
        let name = path.to_fs_name::<GenericFilePath>()?;
        let listener = ListenerOptions::new().name(name).create_tokio()?;
        self.serve_verified(listener).await
    }

    /// #1167：在 Windows 命名管道上服务（常驻 daemon）。管道 DACL 由平台按主人模型建
    /// （`platform::bind_resident_pipe`），不写令牌文件；每个连接在**应答任何东西之前**按客户端的
    /// Windows 用户 SID 认人（系统要求先读到客户端数据才能模拟它，所以先读出第一行、认过了才
    /// 解析）：服务账户 ⇒ [`IpcClient::Daemon`]，主人 ⇒ [`IpcClient::Shell`]，
    /// 其余断开并记一条 `ipc.bad_peer`。
    pub async fn serve_pipe(self: Arc<Self>, pipe: &str) -> anyhow::Result<()> {
        let listener = platform::bind_resident_pipe(pipe)?;
        self.serve_verified(listener).await
    }

    /// 按身份认证的服务循环（签名 socket 与命名管道共用）。
    async fn serve_verified(
        self: Arc<Self>,
        listener: interprocess::local_socket::tokio::Listener,
    ) -> anyhow::Result<()> {
        loop {
            let conn = match listener.accept().await {
                Ok(c) => c,
                Err(e) => {
                    tracing::warn!("ipc accept: {e}");
                    continue;
                }
            };
            let server = Arc::clone(&self);
            let floor = daemon_version();
            tokio::spawn(async move {
                let Some(prefix) = read_first_line_if_needed(&conn).await else {
                    return;
                };
                // 签名 / SID 校验是同步系统调用（毫秒级），不占 async 线程。
                let checked = tokio::task::spawn_blocking(move || {
                    // #1150：同上。
                    let check = platform::verify_local_peer_min_version(
                        &conn,
                        &[platform::PeerRole::Shell, platform::PeerRole::Daemon],
                        &floor,
                    );
                    (conn, check)
                })
                .await;
                let (conn, client) = match checked {
                    Ok((conn, platform::PeerCheck::Verified(platform::PeerRole::Shell))) => {
                        (conn, IpcClient::Shell)
                    }
                    Ok((conn, platform::PeerCheck::Verified(platform::PeerRole::Daemon))) => {
                        (conn, IpcClient::Daemon)
                    }
                    Ok((_, other)) => {
                        tracing::warn!("#1115/#1150: 拒绝 IPC 连接——对端身份不在白名单，或版本低于本 daemon：{other:?}");
                        server.note_rejected("ipc.bad_peer").await;
                        return;
                    }
                    Err(e) => {
                        tracing::warn!("#1115: IPC 对端校验线程失败：{e}");
                        return;
                    }
                };
                let (rx, tx) = conn.split();
                let lines = req_lines(prefix, rx);
                if let Err(e) = server.session(lines, tx, client).await {
                    tracing::debug!("ipc conn ended: {e}");
                }
            });
        }
    }

    async fn note_rejected(&self, kind: &str) {
        let _ = self
            .db
            .append_diag(&storage::DiagEvent {
                ts: now_ms(),
                kind: kind.into(),
                detail: None,
            })
            .await;
    }

    async fn handle_conn(
        &self,
        conn: interprocess::local_socket::tokio::Stream,
        expected_token: &str,
    ) -> anyhow::Result<()> {
        let (rx, tx) = conn.split();
        let mut lines = req_lines(Vec::new(), rx);

        let Some(first) = lines.next_line().await? else {
            return Ok(());
        };
        if first.trim() != expected_token {
            self.note_rejected("ipc.bad_token").await;
            return Ok(()); // drop the connection, say nothing
        }
        // 持令牌的客户端 = 窗口程序（测试沙盒、Windows / Linux 上的令牌模式）。
        self.session(lines, tx, IpcClient::Shell).await
    }

    /// 认证之后的请求循环。`client` 决定能调哪些方法（#1115）。
    async fn session(
        &self,
        mut lines: ReqLines,
        mut tx: interprocess::local_socket::tokio::SendHalf,
        client: IpcClient,
    ) -> anyhow::Result<()> {
        while let Some(line) = lines.next_line().await? {
            if line.trim().is_empty() {
                continue;
            }
            let req = match serde_json::from_str::<Req>(&line) {
                Ok(req) => req,
                Err(_) => {
                    let resp = Resp::err(String::new(), RespError::new(Reason::BadRequest));
                    let mut out = serde_json::to_string(&resp)?;
                    out.push('\n');
                    tx.write_all(out.as_bytes()).await?;
                    continue;
                }
            };
            // IPC-02: 事件订阅——握手应答后连接转为事件流（仍可应答
            // 其他请求），直到客户端断开或 events.unsubscribe。
            if !client.may_call(&req.method) {
                let resp = Resp::err(req.id.clone(), RespError::new(Reason::RoleForbidden));
                let mut out = serde_json::to_string(&resp)?;
                out.push('\n');
                tx.write_all(out.as_bytes()).await?;
                continue;
            }
            if req.method == "events.subscribe" {
                // 订阅语义：Resp 应答 = 订阅已生效。receiver 必须先于
                // 应答创建——broadcast 无订阅者时 send 直接丢弃（events.rs
                // 契约），若先应答后 subscribe，客户端收到 Resp 立即 emit
                // 的事件（如 pairing.start 的 pending_changed）会被丢弃，
                // 订阅方永远等不到（CI 高负载下服务端 write_all 后未及时
                // 被调度、emit 抢先，薛定谔红；2026-08-23 抓到的
                // subscription_delivers_pending_change_under_100ms 挂起）。
                let rx = self.events.subscribe();
                let resp = Resp::ok(req.id.clone(), serde_json::json!({ "subscribed": true }));
                let mut out = serde_json::to_string(&resp)?;
                out.push('\n');
                tx.write_all(out.as_bytes()).await?;
                return self
                    .serve_subscription(&mut lines, &mut tx, &req, rx, client)
                    .await;
            }
            let resp = self.dispatch(req).await;
            let mut out = serde_json::to_string(&resp)?;
            out.push('\n');
            tx.write_all(out.as_bytes()).await?;
        }
        Ok(())
    }

    /// IPC-02: 订阅模式——握手应答后连接保持，事件发生时沿连接推送
    /// newline JSON `{"event":"<name>","data":{...}}`。连接上仍可发
    /// 普通请求（照常应答），`events.unsubscribe` 或断开即退出。
    /// 类型过滤：subscribe 请求带 `types: ["pairing.pending_changed", …]`
    /// 时只推匹配事件；不带 = 全部。
    async fn serve_subscription(
        &self,
        lines: &mut ReqLines,
        tx: &mut interprocess::local_socket::tokio::SendHalf,
        req: &Req,
        mut rx: tokio::sync::broadcast::Receiver<serde_json::Value>,
        client: IpcClient,
    ) -> anyhow::Result<()> {
        let filter: Option<HashSet<String>> = req
            .params
            .get("types")
            .and_then(|t| t.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            });
        loop {
            tokio::select! {
                line = lines.next_line() => {
                    let Some(line) = line? else { return Ok(()); }; // 客户端断开
                    if line.trim().is_empty() { continue; }
                    let Ok(req) = serde_json::from_str::<Req>(&line) else {
                        let resp = Resp::err(
                            String::new(),
                            RespError::new(Reason::BadRequest),
                        );
                        let mut out = serde_json::to_string(&resp)?;
                        out.push('\n');
                        tx.write_all(out.as_bytes()).await?;
                        continue;
                    };
                    if req.method == "events.unsubscribe" {
                        return Ok(()); // 明确退订——客户端转兜底轮询
                    }
                    if !client.may_call(&req.method) {
                        let resp = Resp::err(req.id.clone(), RespError::new(Reason::RoleForbidden));
                        let mut out = serde_json::to_string(&resp)?;
                        out.push('\n');
                        tx.write_all(out.as_bytes()).await?;
                        continue;
                    }
                    // 订阅期间的其他请求照常应答（客户端可随时查状态）。
                    let resp = self.dispatch(req).await;
                    let mut out = serde_json::to_string(&resp)?;
                    out.push('\n');
                    tx.write_all(out.as_bytes()).await?;
                }
                ev = rx.recv() => {
                    match ev {
                        Ok(v) => {
                            if let Some(f) = &filter {
                                let name = v.get("event").and_then(|e| e.as_str()).unwrap_or("");
                                if !f.contains(name) { continue; }
                            }
                            let mut out = serde_json::to_string(&v)?;
                            out.push('\n');
                            tx.write_all(out.as_bytes()).await?;
                        }
                        // 慢订阅者错过的事件跳过——客户端全量 refresh 兜底。
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        // 总线关闭（daemon 退出）——连接自然结束。
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => return Ok(()),
                    }
                }
            }
        }
    }

    async fn dispatch(&self, req: Req) -> Resp {
        let id = req.id.clone();
        let internal = |id: String| Resp::err(id, RespError::new(Reason::Internal));
        match req.method.as_str() {
            // #1115：照片库位置的唯一写入口。只有窗口程序能调（IpcClient::may_call 已挡掉
            // daemon 自身）；测试沙盒没有 library_location ⇒ 拒绝。
            "config.set_library" => {
                let Some(location) = self.library_location.clone() else {
                    return Resp::err(id, RespError::new(Reason::RoleForbidden));
                };
                set_library_resp(id, location, &req.params).await
            }
            // #639：更改照片库位置 = 整库搬迁。校验、计划落盘后退出，重启时接着搬（见 daemon::relocate）。
            // 只有窗口程序能调；新位置由窗口程序从系统对话框取（网页递不进路径，#1150）。
            "library.relocate" => {
                let Some(location) = self.library_location.clone() else {
                    return Resp::err(id, RespError::new(Reason::RoleForbidden));
                };
                relocate_resp(id, &self.data_dir, location.platform_dir(), &req.params)
            }
            "status" => match self
                .status(req.params.get("shell_version").and_then(|v| v.as_str()))
                .await
            {
                Ok(v) => Resp::ok(id, v),
                Err(_) => internal(id),
            },
            // DAE-01: newest-wins takeover — the newer instance asks the
            // older one to exit; launchd (KeepAlive) relaunches it from
            // the new plist, which now points at the stable path.
            "daemon.step_down" => {
                let id2 = id.clone();
                let exit = Arc::clone(&self.step_down_exit);
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    tracing::info!("DAE-01: step_down — exiting on request");
                    exit();
                });
                Resp::ok(id2, serde_json::json!({ "bye": true }))
            }
            "pairing.start" => {
                let mut token = [0u8; 12];
                if getrandom::fill(&mut token).is_err() {
                    return internal(id);
                }
                let now = now_ms();
                let qr = self.pairing.start(token, now);
                // #1264：这张码何时失效由 daemon 说了算——窗口据此在失效前换码，或盖住过期的码。
                Resp::ok(
                    id,
                    serde_json::json!({
                        "qr": qr,
                        "expires_at_ms": now + crate::pairing::TOKEN_TTL_MS,
                    }),
                )
            }
            // #1122：二维码关闭 / 配对弹窗关掉——收回未用的令牌，配对窗口立即关闭。
            "pairing.stop" => {
                let revoked = self.pairing.stop();
                Resp::ok(id, serde_json::json!({ "revoked_tokens": revoked }))
            }
            "pairing.confirm" => {
                let accept = req
                    .params
                    .get("accept")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                // #1118: allowing means typing the phone's 6-digit code; there is no allow
                // without it.
                let code = req
                    .params
                    .get("code")
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .map(str::to_owned);
                let decision = match (accept, code) {
                    (false, _) => PairDecision::Reject,
                    (true, Some(c))
                        if c.len() == pair_pake::CODE_DIGITS
                            && c.bytes().all(|b| b.is_ascii_digit()) =>
                    {
                        PairDecision::AcceptCode(c)
                    }
                    (true, _) => return Resp::err(id, RespError::new(Reason::BadRequest)),
                };
                let device_name = req
                    .params
                    .get("device_name")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned);
                // DEV-04：按身份定位，名字只作回退——改过名的设备重连时
                // 弹窗上的名字不再等于队列里的自报名。
                let node_id = req
                    .params
                    .get("node_id")
                    .and_then(|v| v.as_str())
                    .and_then(parse_hex32);
                let (outcome, peer) =
                    self.confirm_located(node_id.as_deref(), device_name.as_deref(), decision);
                match outcome {
                    ConfirmOutcome::Decided(name) if !accept => {
                        Resp::ok(id, serde_json::json!({ "decided": false, "device": name }))
                    }
                    // #1118: the code went to the request; the phone (polling every second)
                    // answers with its key confirmation. Wait briefly so the owner sees the
                    // result on the spot; past that, the device row / a refresh tells.
                    ConfirmOutcome::Decided(name) => {
                        let verdict = match peer {
                            Some(p) => {
                                self.pairing
                                    .await_verdict(p, Duration::from_millis(CONFIRM_WAIT_MS))
                                    .await
                            }
                            None => None,
                        };
                        match verdict {
                            Some(crate::pairing::PairState::Accepted { .. }) => {
                                Resp::ok(id, serde_json::json!({ "decided": true, "device": name }))
                            }
                            Some(crate::pairing::PairState::Failed) => {
                                Resp::err(id, RespError::new(Reason::PairCodeWrong))
                            }
                            Some(
                                crate::pairing::PairState::Expired
                                | crate::pairing::PairState::Denied,
                            ) => Resp::err(id, RespError::new(Reason::NotFound)),
                            Some(crate::pairing::PairState::Pending) | None => Resp::ok(
                                id,
                                serde_json::json!({ "decided": true, "verifying": true, "device": name }),
                            ),
                        }
                    }
                    // DEV-05 (#276): the click landed on a dead request —
                    // report failure honestly (the old code answered ok
                    // and the phone never received anything).
                    ConfirmOutcome::Expired(_) | ConfirmOutcome::NotFound => {
                        Resp::err(id, RespError::new(Reason::NotFound))
                    }
                }
            }
            // UX-08: 待确认配对请求全量列表（只读）——桌面端一屏列出所有
            // pending 逐行允许/拒绝（confirm 带 device_name 逐台处理）。
            // 不动确认语义，只补「队列里都有谁」。
            "pairing.pending" => {
                let pending = self.pending_summary().await;
                Resp::ok(id, serde_json::json!({ "pending": pending }))
            }
            // DEV-03（2026-09-20 验收人推翻 DESK-02②）：默认口径从
            // 「只要在用的」改成「**家人与设备**该看见的」。
            //
            // 旧口径 `WHERE revoked = 0` 把两件事混成一件：手机点「断开与
            // 这台电脑的连接」和业主点「移除设备」都只是 `revoked = 1`，于是
            // 手机一断开，设备就从列表里凭空消失。验收人原话：「又不是我主动
            // 移除的」「不要主动让它消失，因为它可能改过名称，回头审计时我得
            // 明确到底是哪个设备」。
            //
            // 新口径：在用的 + **设备自己断开的**（标「已断开」）；业主主动
            // 移除的不列——那正是业主的意图。
            // `include_revoked=true` 仍是全量（内部统计/诊断用），不变。
            // #1044 B11：桌面已把待展示的低空间通知弹出来了。
            "low_space.ack" => match crate::low_space::ack(&self.db).await {
                Ok(()) => Resp::ok(id, serde_json::json!({})),
                Err(_) => internal(id),
            },
            "devices.list" => {
                // #1117：一行 = 一份设备档案（永不删除）+ 当前配对记录（可能没有）。
                // 默认只给「家人与设备」主列表的行（在用 + 已断开）；
                // `include_departed` 连业主移除的也给（「已移除」折叠区）。
                let include_departed = req
                    .params
                    .get("include_departed")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let listed = self.db.list_devices().await.map(|rows| {
                    rows.into_iter()
                        .filter(|d| {
                            include_departed || crate::device_projection::Removal::of(d).is_listed()
                        })
                        .collect::<Vec<_>>()
                });
                // #1044 B4：「需要看看」与「最近活跃」要用最近备份时刻。
                let last_backup: std::collections::HashMap<Vec<u8>, i64> = self
                    .db
                    .list_device_watermarks()
                    .await
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|w| w.last_backup_at.map(|t| (w.node_id, t)))
                    .collect();
                let now = now_ms();
                match listed {
                    Ok(devices) => {
                        // #1066：总览「最近一次备份」由 daemon 给结论，桌面不再拿水位自己推。
                        let last_backup_overall = crate::device_projection::last_backup_overall(
                            devices.iter().map(|d| {
                                (
                                    crate::device_projection::Removal::of(d),
                                    d.profile.name.as_str(),
                                    last_backup.get(&d.profile.node_id).copied(),
                                )
                            }),
                        );
                        let list: Vec<_> = devices
                            .iter()
                            .map(|d| {
                                // Read both sources exactly once so a response cannot combine
                                // a pre-transition `connection` with a post-transition
                                // `presence`. Flow state stays a distinct nullable field:
                                // `null` means no active transfer, not offline.
                                // DEV-03：没有配对记录的设备一律不报在线。
                                //
                                // 泛连接判定看的是传输层还有没有活口，而删配对
                                // 是**授权**上的终止——一个刚断开、连接尚未
                                // 断干净的设备如果还显示「在线」，等于告诉
                                // 用户「它还在备份」，正好相反。授权没了就是
                                // 离线，这里不做组合判断。
                                let node_id = &d.profile.node_id;
                                let paired = d.pairing.is_some();
                                let connection = if paired {
                                    (self.conn_status)(node_id)
                                } else {
                                    transport::ConnectionStatus::Offline
                                };
                                let flow_connection = if paired {
                                    (self.flow_connection)(node_id)
                                } else {
                                    None
                                };
                                let last_seen = d.profile.last_seen_at;
                                let presence = if paired {
                                    crate::presence::presence(connection.as_str(), last_seen, now)
                                } else {
                                    "offline"
                                };
                                // #1044 B4：分组、哨兵、行状态优先级、最近活跃由
                                // daemon 给结论（device_projection.rs），桌面只渲染。
                                let removal = crate::device_projection::Removal::of(d);
                                let last_backup_at = last_backup.get(node_id).copied();
                                let needs_attention = crate::device_projection::needs_attention(
                                    removal,
                                    last_backup_at,
                                    now,
                                );
                                serde_json::json!({
                                    "node_id": hex(node_id),
                                    "name": d.profile.name,
                                    "role": d.pairing.as_ref().map(|p| p.role.as_str()),
                                    "paired": paired,
                                    // DEV-03 / #1117：为什么、什么时候离开的（device /
                                    // owner / identity）；重新配对后清空。
                                    "departed_by": d.profile.departed_by.map(|b| b.as_str()),
                                    "departed_at": d.profile.departed_at,
                                    "last_seen": last_seen,
                                    // T-090: generic live transport verdict only; this
                                    // remains intentionally independent from the Flow plane.
                                    "connection": connection.as_str(),
                                    // NET-05: actual active blobs route for the current Flow
                                    // item, keyed back to this paired control device.
                                    "flow_connection": flow_connection.map(|s| s.as_str()),
                                    // PRES-01: 三档在线态只用既有泛连接/心跳口径，
                                    // 不让短暂文件传输改写在线语义。
                                    "presence": presence,
                                    "removal": removal.as_str(),
                                    "needs_attention": needs_attention,
                                    "row_state": crate::device_projection::row_state(
                                        removal,
                                        needs_attention,
                                        flow_connection.is_some(),
                                        presence,
                                    ),
                                    "last_activity_at": crate::device_projection::last_activity_at(
                                        last_seen,
                                        last_backup_at,
                                    ),
                                    // #1070: `"phone"` / `"desktop"` = that side must
                                    // update before this device can talk to us; null =
                                    // no known protocol-version mismatch.
                                    "needs_update": self.outdated.needs_update(node_id),
                                })
                            })
                            .collect();
                        Resp::ok(
                            id,
                            serde_json::json!({
                                "devices": list,
                                "last_backup_overall": last_backup_overall
                                    .map(|(at, name)| serde_json::json!({ "at": at, "name": name })),
                            }),
                        )
                    }
                    Err(_) => internal(id),
                }
            }
            // T-090: backup activity feed — read-only aggregation of the
            // existing assets table into per-device batches (10-minute
            // arrival gap = batch boundary; 口径注释在 storage::list_activity).
            "activity.list" => {
                let limit = req
                    .params
                    .get("limit")
                    .and_then(|v| v.as_u64())
                    .map_or(50, |v| v.min(1000) as u32);
                match self.db.list_activity(ACTIVITY_GAP_MS, limit).await {
                    Ok(batches) => {
                        let list: Vec<_> = batches
                            .iter()
                            .map(|b| {
                                serde_json::json!({
                                    "node_id": hex(&b.node_id),
                                    "name": b.name,
                                    "at": b.at,
                                    "asset_count": b.asset_count,
                                })
                            })
                            .collect();
                        Resp::ok(id, serde_json::json!({ "batches": list }))
                    }
                    Err(_) => internal(id),
                }
            }
            // AUDIT-02: expose canonical audit_operation rows to the Desktop
            // activity projection.  evidenceSummary is the daemon-recomputed
            // item-evidence count; never substitute phone final_counts here.
            "audit.list" => {
                let limit = req
                    .params
                    .get("limit")
                    .and_then(|v| v.as_u64())
                    .map_or(100, |v| v.min(1000) as u32);
                // #1044 B1：用户口径在截断之前过滤（见 audit_projection.rs）；
                // 不带 visibility = 全量（诊断口径）。
                let user_only =
                    req.params.get("visibility").and_then(|v| v.as_str()) == Some("user");
                let listed = if user_only {
                    self.db
                        .list_operations_excluding(
                            limit,
                            crate::audit_projection::HIDDEN_KINDS,
                            crate::audit_projection::HIDDEN_PREFIXES,
                        )
                        .await
                } else {
                    self.db.list_operations(limit).await
                };
                match listed {
                    Ok(records) => {
                        let list: Vec<_> = records
                            .iter()
                            .map(|r| {
                                serde_json::json!({
                                    // DESK-08：审计行的**唯一身份**——WATCH-02 一次
                                    // 删 N 张会在**同一毫秒**写 N 条
                                    // `asset.removed_external`，key 立刻撞，Svelte 抛
                                    // `each_key_duplicate` 整个活动流挂掉。
                                    // 时间戳不是身份，主键才是；event_id 是跨端幂等键。
                                    "id": r.id,
                                    "eventId": r.entry.operation_id,
                                    "ts": r.entry.occurred_at,
                                    "kind": r.entry.kind,
                                    "actor": r.entry.actor.as_ref().map(|b| hex(b)),
                                    "roundId": r.entry.round_id,
                                    "targetHash": r.entry.target_hash.as_ref().map(|b| hex(b)),
                                    "payload": r.entry.payload.as_ref().and_then(|p| serde_json::from_str::<serde_json::Value>(p).ok()),
                                    "evidenceSummary": r.entry.evidence_summary.as_ref().and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok()),
                                    // #1044 B1：每轮计数由 daemon 分好类（已备份/需处理/已跳过）。
                                    "counts": (r.entry.kind == "flow.round.finished").then(|| {
                                        crate::audit_projection::round_counts(
                                            &r.entry.evidence_summary.as_ref().and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok()).unwrap_or_default(),
                                        )
                                    }),
                                })
                            })
                            .collect();
                        Resp::ok(id, serde_json::json!({ "events": list }))
                    }
                    Err(_) => internal(id),
                }
            }
            // DOG-01: per-device backup watermarks — dogfood daily report /
            // desktop activity / phone "last success" share this source.
            "device.watermarks" => match self.db.list_device_watermarks().await {
                Ok(watermarks) => {
                    let list: Vec<_> = watermarks
                        .iter()
                        .map(|w| {
                            serde_json::json!({
                                "node_id": hex(&w.node_id),
                                "name": w.name,
                                "last_backup_at": w.last_backup_at,
                                "asset_count": w.asset_count,
                            })
                        })
                        .collect();
                    Resp::ok(id, serde_json::json!({ "watermarks": list }))
                }
                Err(_) => internal(id),
            },
            "device.revoke" => {
                let Some(node_hex) = req.params.get("node_id").and_then(|v| v.as_str()) else {
                    return Resp::err(id, RespError::new(Reason::BadRequest));
                };
                let Some(node_id) = parse_hex32(node_hex) else {
                    return Resp::err(id, RespError::new(Reason::BadRequest));
                };
                // DEV-03：业主主动移除——这正是业主的意图，之后它不再出现在
                // 「家人与设备」主列表里。#1117：删的是配对记录（唯一入口
                // `crate::unpair`），设备档案与审计保留。
                let Ok(peer) = <[u8; 32]>::try_from(node_id.as_slice()).map(transport::NodeId)
                else {
                    return Resp::err(id, RespError::new(Reason::BadRequest));
                };
                let holders = crate::unpair::Holders {
                    flow: self.flow_delivery.get(),
                    backup: self.backup.get(),
                    connections: self.peer_closer.get(),
                    subscriptions: Some(&self.subscriptions),
                };
                match crate::unpair::remove_pairing(
                    &self.db,
                    holders,
                    peer,
                    None,
                    storage::DepartedBy::Owner,
                    (self.now)(),
                )
                .await
                .map(|removed| removed.is_some())
                {
                    Ok(revoked) => {
                        if revoked {
                            warn_if_audit_failed(
                                "device.revoked",
                                self.db
                                    .append_audit(&storage::AuditEntry::local(
                                        (self.now)(),
                                        None, // 本机 owner 经 IPC 操作
                                        "device.revoked",
                                        None,
                                        Some(serde_json::json!({ "nodeId": node_hex }).to_string()),
                                    ))
                                    .await,
                            );
                            // AUDIT-04 card decision #4: 撤销授权是用户决定，
                            // 必须落 audit_decision（causal_object_ref = 被撤销
                            // 设备），不能只靠上面兼容层的 audit_operation 行。
                            warn_if_audit_failed(
                                "revoke_authorization",
                                self.db
                                    .append_decision(&storage::DecisionEntry {
                                        decision_id: fresh_audit_id(),
                                        decision_kind: "revoke_authorization".into(),
                                        actor: None, // 本机 owner 经 IPC 操作
                                        causal_operation_id: None,
                                        causal_object_ref: Some(node_hex.to_string()),
                                        occurred_at: (self.now)(),
                                        payload: Some(
                                            serde_json::json!({ "nodeId": node_hex }).to_string(),
                                        ),
                                    })
                                    .await,
                            );
                            // IPC-02: 设备移除——桌面设备行即时消失。
                            events::emit(
                                &self.events,
                                events::DEVICE_CHANGED,
                                serde_json::json!({ "node_id": node_hex }),
                            );
                            events::emit(
                                &self.events,
                                events::ACTIVITY_APPENDED,
                                serde_json::json!({ "action": "device.revoked" }),
                            );
                        }
                        Resp::ok(id, serde_json::json!({ "revoked": revoked }))
                    }
                    Err(_) => internal(id),
                }
            }
            // #1044：某台设备在照片库里的目录（绝对路径，平台分隔符由 Path 给）。
            // 与入库落位同一口径（core_index::device_dir）。这台设备还没落过
            // 照片时目录不存在 → 退回 originals/，库刚建还没有 originals/ →
            // 库根目录；`is_device_dir` 说清给的是哪一个，不假装有内容。
            "device.folder" => {
                let Some(node_id) = req
                    .params
                    .get("node_id")
                    .and_then(|v| v.as_str())
                    .and_then(parse_hex32)
                else {
                    return Resp::err(id, RespError::new(Reason::BadRequest));
                };
                let originals = self.data_dir.join("originals");
                let device = originals.join(core_index::device_dir(&node_id));
                let (path, is_device_dir) = if device.is_dir() {
                    (device, true)
                } else if originals.is_dir() {
                    (originals, false)
                } else {
                    (self.data_dir.clone(), false)
                };
                Resp::ok(
                    id,
                    serde_json::json!({
                        "path": path.display().to_string(),
                        "is_device_dir": is_device_dir,
                    }),
                )
            }
            "device.rename" => {
                // NAME-01: 改显示名（ID 与显示名分离——decisions ②）。
                // 本机 owner 经 IPC 操作（与 device.revoke 同鉴权面）。
                let Some(node_hex) = req.params.get("node_id").and_then(|v| v.as_str()) else {
                    return Resp::err(id, RespError::new(Reason::BadRequest));
                };
                let Some(node_id) = parse_hex32(node_hex) else {
                    return Resp::err(id, RespError::new(Reason::BadRequest));
                };
                // 新名必填（空名 = 非法请求）；长度上限防滥用。
                let Some(new_name) = req.params.get("name").and_then(|v| v.as_str()) else {
                    return Resp::err(id, RespError::new(Reason::BadRequest));
                };
                let new_name = new_name.trim();
                if new_name.is_empty() || new_name.chars().count() > MAX_DEVICE_NAME_CHARS {
                    return Resp::err(id, RespError::new(Reason::BadRequest));
                }
                match self.db.rename_device(&node_id, new_name).await {
                    Ok(Some(old_name)) => {
                        // 审计：旧名→新名 + node_id（decisions ②「audit 记
                        // device.renamed 旧名→新名+node_id」）。
                        warn_if_audit_failed(
                            "device.renamed",
                            self.db
                                .append_audit(&storage::AuditEntry::local(
                                    now_ms(),
                                    None, // 本机 owner 经 IPC 操作
                                    "device.renamed",
                                    None,
                                    Some(
                                        serde_json::json!({
                                            "nodeId": node_hex,
                                            "oldName": old_name,
                                            "newName": new_name,
                                        })
                                        .to_string(),
                                    ),
                                ))
                                .await,
                        );
                        // IPC-02: 改名后设备行即时刷新。
                        events::emit(
                            &self.events,
                            events::DEVICE_CHANGED,
                            serde_json::json!({ "node_id": node_hex }),
                        );
                        Resp::ok(
                            id,
                            serde_json::json!({
                                "renamed": true,
                                "node_id": node_hex,
                                "old_name": old_name,
                                "name": new_name,
                            }),
                        )
                    }
                    Ok(None) => {
                        // 设备不存在（已吊销/从未配对）——NOT_FOUND 语义。
                        Resp::err(id, RespError::new(Reason::NotFound))
                    }
                    Err(_) => internal(id),
                }
            }
            // #1122：三份 JSON 直接在应答里返回，不在库目录写任何文件。
            // #1236：daemon 自己的日志尾部一并带回（服务形态下只有它读得到）。
            "logs.export" => match self.export_logs().await {
                Ok(entries) => {
                    let logs = tokio::task::spawn_blocking(crate::diag_bundle::own_log_tails)
                        .await
                        .unwrap_or_else(|_| serde_json::json!({}));
                    Resp::ok(id, serde_json::json!({ "entries": entries, "logs": logs }))
                }
                Err(e) => {
                    tracing::warn!("logs.export failed: {e}");
                    internal(id)
                }
            },
            // DESK-03: 查询平面（桌面照片墙，与手机同一数据源）——
            // 未注入 QueryEngine 时统一答 unsupported_method（老测试构造
            // 零波及；main 总是注入）。响应形状与网络平面逐字段一致，
            // 桌面端消费代码可与手机端镜像。
            "timeline.page" | "thumb.get" | "asset.meta" | "asset.path" | "asset.original" => {
                let Some(query) = self.query.get() else {
                    return Resp::err(id, RespError::new(Reason::UnsupportedMethod));
                };
                match req.method.as_str() {
                    "timeline.page" => {
                        let Ok(q) =
                            serde_json::from_value::<proto::TimelineQuery>(req.params.clone())
                        else {
                            return Resp::err(id, RespError::new(Reason::BadRequest));
                        };
                        match query.timeline(&q).await {
                            Ok(page) => match serde_json::to_value(&page) {
                                Ok(v) => Resp::ok(id, v),
                                Err(_) => internal(id),
                            },
                            Err(_) => Resp::err(id, RespError::new(Reason::NotFound)),
                        }
                    }
                    "thumb.get" => {
                        let Ok(t) = serde_json::from_value::<proto::ThumbGet>(req.params.clone())
                        else {
                            return Resp::err(id, RespError::new(Reason::BadRequest));
                        };
                        // DESK-34 (#428): carries `placeholder` / `retry_after_ms`
                        // so PhotoThumb can re-fetch a placeholder once.
                        match query.thumb_reply(&t).await {
                            Ok(reply) => match serde_json::to_value(reply.into_wire()) {
                                Ok(v) => Resp::ok(id, v),
                                Err(_) => internal(id),
                            },
                            Err(_) => Resp::err(id, RespError::new(Reason::NotFound)),
                        }
                    }
                    "asset.meta" => {
                        let Some(hash) = req.params.get("hash").and_then(|v| v.as_str()) else {
                            return Resp::err(id, RespError::new(Reason::BadRequest));
                        };
                        match query.asset_meta(hash).await {
                            Ok(meta) => match serde_json::to_value(&meta) {
                                Ok(v) => Resp::ok(id, v),
                                Err(_) => internal(id),
                            },
                            Err(_) => Resp::err(id, RespError::new(Reason::NotFound)),
                        }
                    }
                    "asset.path" => {
                        let Some(hash) = req.params.get("hash").and_then(|v| v.as_str()) else {
                            return Resp::err(id, RespError::new(Reason::BadRequest));
                        };
                        match query.asset_path(hash).await {
                            Ok(path) => {
                                Resp::ok(id, serde_json::json!({ "path": path.to_string_lossy() }))
                            }
                            Err(_) => Resp::err(id, RespError::new(Reason::NotFound)),
                        }
                    }
                    "asset.original" => {
                        let Some(hash) = req.params.get("hash").and_then(|v| v.as_str()) else {
                            return Resp::err(id, RespError::new(Reason::BadRequest));
                        };
                        match query.original(hash).await {
                            Ok((media_type, bytes)) => {
                                use base64::Engine as _;
                                Resp::ok(
                                    id,
                                    serde_json::json!({
                                        "media_type": media_type,
                                        "data_base64": base64::engine::general_purpose::STANDARD.encode(bytes),
                                    }),
                                )
                            }
                            Err(_) => Resp::err(id, RespError::new(Reason::NotFound)),
                        }
                    }
                    _ => unreachable!("covered by the outer arm"),
                }
            }
            _ => Resp::err(id, RespError::new(Reason::UnsupportedMethod)),
        }
    }

    /// Decide one pending pairing request: by device name, or the queue
    /// head when `device_name` is None. Shared by IPC and the interim
    /// console confirmer in main.
    ///
    /// DEV-02: 只有允许/拒绝两种。DEV-01 的第三个入参 `merge_node_id`
    /// （「替换旧的」目标）删掉了——设备与身份 1:1，没有"接管另一个身份的
    /// 账目"这回事，配对流程也因此不再有任何写别人那一行的入口。
    ///
    /// DEV-04：定位优先看 `node_id`。展示名与身份在这张卡之后不再是同一
    /// 个字符串——改过名的老设备重连时，弹窗显示的是**桌面上**的名字，
    /// 而队列里存的是手机自报名，按名字找必然 `None`，业主就再也批不了
    /// 这台设备了。`device_name` 作为回退保留（老调用方语义不动）。
    ///
    /// DEV-05 (#276): three-way outcome + a TTL sweep on touch.
    /// - Expired rows are pruned before lookup; a click that lands on a
    ///   row the sweep just removed is NOT_FOUND (fail, no side effects).
    /// - A row still inside TTL whose phone already walked away surfaces
    ///   `decide`'s send-Err as [`ConfirmOutcome::Expired`] — the precise
    ///   fact "the owner's click acted on a request nobody is waiting on
    ///   anymore" (简报四: this used to be swallowed and reported as
    ///   success). TTL judges by estimate; the send-Err judges by fact;
    ///   both arms run, whichever fires first.
    /// - All three lookup branches (node_id / device_name / queue head)
    ///   resolve against the post-sweep queue, so the head fallback
    ///   cannot smuggle a stale row past the new semantics (简报五).
    pub fn confirm(
        &self,
        node_id: Option<&[u8]>,
        device_name: Option<&str>,
        decision: PairDecision,
    ) -> ConfirmOutcome {
        self.confirm_located(node_id, device_name, decision).0
    }

    /// [`Self::confirm`] plus the peer of the row it decided, however that
    /// row was located (node id, name, or queue head) — #1118: the IPC
    /// handler waits on that peer's verdict.
    fn confirm_located(
        &self,
        node_id: Option<&[u8]>,
        device_name: Option<&str>,
        decision: PairDecision,
    ) -> (ConfirmOutcome, Option<transport::NodeId>) {
        let mut queue = self.pending.lock().expect("pending lock");
        let now = now_ms();
        // DEV-07 follow-up (#463): a row the phone withdrew is gone before
        // lookup — including the queue-head fallback — so a click that
        // raced the removal is NOT_FOUND, never a decision on it.
        queue.retain(|p| !p.is_withdrawn());
        let idx = match (node_id, device_name) {
            (Some(id), _) => queue.iter().position(|p| p.peer.0 == id),
            (None, Some(name)) => queue.iter().position(|p| p.device_name == name),
            (None, None) => (!queue.is_empty()).then_some(0),
        };
        let Some(idx) = idx else {
            // Nothing to decide — still sweep stale rows, and report the
            // queue emptying to diag exactly as the success path would.
            queue.retain(|p| p.requested_at + self.pending_ttl() > now);
            if queue.is_empty() {
                self.diag.apply(diag::DaemonEvent::PairingEnded);
            }
            return (ConfirmOutcome::NotFound, None);
        };
        let p = queue.remove(idx);
        // The located row itself may be past TTL: answer Expired, not a
        // fake success and not a NotFound that hides which row failed.
        let stale = p.requested_at + self.pending_ttl() <= now;
        // Any other rows that aged out leave the queue with this touch.
        queue.retain(|q| q.requested_at + self.pending_ttl() > now);
        if queue.is_empty() {
            self.diag.apply(diag::DaemonEvent::PairingEnded);
        }
        // IPC-02: 处理完一条 pending——桌面壳即时刷新授权列表。
        events::emit(
            &self.events,
            events::PAIRING_PENDING_CHANGED,
            serde_json::json!({ "pending": queue.len() }),
        );
        let name = p.device_name.clone();
        if stale {
            return (ConfirmOutcome::Expired(name), None);
        }
        let peer = p.peer;
        match p.decide(decision) {
            Ok(()) => (ConfirmOutcome::Decided(name), Some(peer)),
            Err(_) => (ConfirmOutcome::Expired(name), None),
        }
    }

    /// DEV-07 follow-up (#463): the owner queue as the desktop may see it —
    /// rows the phone withdrew (`pair.cancel`) are dropped here, on every
    /// read, the same "sweep on touch" the TTL and same-phone replacement
    /// use. The decision task that marks a row also emits
    /// `pairing.pending_changed`, so the desktop's refresh is the touch.
    /// TTL-expired rows are NOT dropped here: they keep DEV-05's "已失效"
    /// display until `confirm` / a new scan retires them.
    fn live_queue(&self) -> std::sync::MutexGuard<'_, Vec<PendingPair>> {
        let mut queue = self.pending.lock().expect("pending lock");
        let before = queue.len();
        queue.retain(|p| !p.is_withdrawn());
        if before > 0 && queue.is_empty() {
            // Same bookkeeping as `confirm` emptying the queue.
            self.diag.apply(diag::DaemonEvent::PairingEnded);
        }
        queue
    }

    /// Pending pairing requests for the owner UI. DEV-02: 不做指纹匹配
    /// （DEV-01 的 `hint_match` 已删）——确认框不替任何人声称"这台手机
    /// 重装过"。
    ///
    /// DEV-04：但"库里有没有这一行"是桌面自己查得到的事实，不是手机的
    /// 一面之词，所以它该往上传。`known = true` 时名字取**桌面上**那个
    /// （业主可能改过名），并附首次配对时间和已存照片数，让审批框说得出
    /// 「允许后会恢复备份」到底恢复的是什么。
    ///
    /// 判据是 `device` 表有没有这一行，**不看 `revoked`**：被移除过的设备
    /// 再回来依然是"以前连过"，只是仍要业主重新批准。
    pub async fn pending_summary(&self) -> Vec<serde_json::Value> {
        // 先把身份抄出来再放锁：下面要 await，而 pending 是 std Mutex，
        // 跨 await 持有它既是 clippy::await_holding_lock 也是真死锁面。
        // DEV-05 (#276): 同时带出入队时刻与是否已过期——「业主等了多久
        // 没点」是队列自己的事实，桌面要把它如实标出来（设计要点 2），
        // 而不是替业主静默丢弃。过期行留在列表里直到被 touch（confirm/
        // 新请求顶掉）时清除。
        let now = now_ms();
        let queued: Vec<(transport::NodeId, String, i64, bool, storage::Role)> = self
            .live_queue()
            .iter()
            .map(|p| {
                (
                    p.peer,
                    p.device_name.clone(),
                    p.requested_at,
                    p.is_abandoned(),
                    p.role,
                )
            })
            .collect();

        let mut out = Vec::with_capacity(queued.len());
        for (peer, reported_name, requested_at, abandoned, role) in queued {
            let existing = self.db.get_device(&peer.0).await.ok().flatten();
            let mut row = serde_json::json!({
                "node_id": hex(&peer.0),
                "known": existing.is_some(),
                "name": existing
                    .as_ref()
                    .map(|d| d.profile.name.clone())
                    .unwrap_or(reported_name),
                "requested_at": requested_at,
                // #1118: the confirm box shows the role the phone asked for.
                "role": role.as_str(),
                // DEV-07 (#463): a row whose request side already ended
                // (request-side TTL) is as unapprovable as one past the
                // queue TTL. Withdrawn rows never get here (`live_queue`).
                "expired": abandoned || requested_at + self.pending_ttl() <= now,
            });
            if let Some(d) = existing {
                // #1117：有档案 = 以前连过；`paired` = 现在还有配对记录。
                // `paired_at` = 第一次配对成功的时间（档案上，永不随配对记录删除）。
                row["paired_at"] = serde_json::json!(d.profile.first_seen_at);
                row["paired"] = serde_json::json!(d.pairing.is_some());
                row["photo_count"] = serde_json::json!(self
                    .db
                    .count_assets_from_device(&d.profile.node_id)
                    .await
                    .unwrap_or(0));
            }
            out.push(row);
        }
        out
    }

    /// Names of requests waiting for the owner (UI list / console prompt).
    pub fn pending_names(&self) -> Vec<String> {
        self.live_queue()
            .iter()
            .map(|p| p.device_name.clone())
            .collect()
    }

    /// `shell_version`：调用方（桌面壳）自报的版本；给了才算 `shell_relation`。
    async fn status(&self, shell_version: Option<&str>) -> anyhow::Result<serde_json::Value> {
        let devices = self.db.list_devices().await?;
        let state = self.diag.state();
        // DEV-07 follow-up (#463): the banner is gated on this count — a
        // withdrawn row counted here would re-open a clickable 「允许」.
        let pending = self.live_queue().len();
        // T-090: photo total + disk watermarks of the library volume.
        let photo_count = self.db.count_assets().await?;
        let photo_sources = self.db.count_asset_sources().await?;
        let disk = disk_stats(&self.data_dir);
        let disk_encryption = disk_encryption_cached().await;
        // #1044 B11：低空间通知由 daemon 判定并持久化（low_space.rs）；
        // 待展示的那一次随 status 带出，桌面弹完调 `low_space.ack`。
        // 尽力而为：盘真满时索引库写入可能失败（SQLITE_FULL），那正是最需要
        // status 的时候——不许为了一个通知把整个 status 拖垮。
        let low_space_notice = match crate::low_space::observe(&self.db, disk.map(|d| d.free)).await
        {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!("#1044: 低空间通知状态读写失败（本轮不带通知）：{e}");
                None
            }
        };
        Ok(serde_json::json!({
            // T-090 data-plane fields (桌面总览卡直接消费).
            "photo_count": photo_count,
            // DESK-03: 「共 N 张 · 来自 M 台设备」的 M。
            "photo_sources": photo_sources,
            "disk_free_bytes": disk.map(|d| d.free),
            "disk_total_bytes": disk.map(|d| d.total),
            // W-4：系统盘磁盘加密状态 "on" | "off" | "unknown"；只有 "off" 时界面才提示。
            "disk_encryption": disk_encryption.as_str(),
            "low_space_notice": low_space_notice.map(|free| serde_json::json!({ "free_bytes": free })),
            "state": state_name(&state),
            "msg_key": state.msg_key(),
            // #1117：档案数（永不删除）与其中没有配对记录的数目。
            "devices": devices.len(),
            "unpaired": devices.iter().filter(|d| d.pairing.is_none()).count(),
            // #1044 B4：「已配对 N 台」= 设备页主列表行数（含自己断开的）；
            // 已移除的单独计。桌面不再自己做减法。
            "paired_devices": devices
                .iter()
                .filter(|d| crate::device_projection::Removal::of(d).is_listed())
                .count(),
            "removed_devices": devices
                .iter()
                .filter(|d| !crate::device_projection::Removal::of(d).is_listed())
                .count(),
            "pending_pairs": pending,
            // #1044：是否正有 Flow 传输——任何在用设备有活跃的 blobs 路由。
            // 与设备行「传输中」同一信号；壳（#667 内核对账推迟）只读这个结论。
            "transfer_active": devices
                .iter()
                .any(|d| d.pairing.is_some() && (self.flow_connection)(&d.profile.node_id).is_some()),
            // Where the photos physically live — the UI's "open the
            // photo folder" needs an answer to "传到哪儿了" (real
            // walkthrough question, 2026-07-31).
            "library_dir": self.data_dir.display().to_string(),
            // #639：上一次「更改照片库位置」没成的原因（keyed ui_err）；没有就是 null。
            "relocate_error": self
                .library_location
                .as_ref()
                .and_then(|l| crate::relocate::last_error(l.platform_dir())),
            // F6：搬完后原目录没删干净时它的位置（用户删掉后为 null）。
            "relocate_leftover": self
                .library_location
                .as_ref()
                .and_then(|l| crate::relocate::leftover(l.platform_dir())),
            // #1118: this desktop's identity as people read it — shown under the pairing QR code
            // and on the phone before it connects, so the two can be compared.
            "desktop_fingerprint": pair_pake::node_fingerprint(&self.pairing.node_id().to_string()),
            "desktop_name": self.desktop_name,
            // DAE-01: identity fields for newest-wins handshake + ops
            // visibility (验收①：status 报 PID/版本/路径/启动时间).
            "version": daemon_version(),
            // #1044 B13：壳与内核的版本关系由 daemon 下结论（same / shell_older /
            // shell_newer）；壳没报版本 = null（不知道就不提示）。
            "shell_relation": shell_version
                .filter(|v| !v.is_empty())
                .map(|v| version_cmp::ShellRelation::of(v, &daemon_version()).as_str()),
            "pid": std::process::id(),
            "started_at": self.started_at,
            "exe_path": std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_default(),
        }))
    }

    /// Export diagnostics as three JSON texts returned inline (#1122: nothing
    /// is written into the library; the shell saves them where the user picks). Every path-like
    /// string is sanitised: the user's home directory becomes `<DATA>` —
    /// a shared log must never leak a username (契约).
    async fn export_logs(&self) -> anyhow::Result<serde_json::Value> {
        let events = self.db.list_diag(1000).await?;
        let devices = self.db.list_devices().await?;
        // #1043：家目录由平台适配器回答；读不到 = 空串（与改前同一口径）。
        let home = {
            use platform::PlatformAdapter as _;
            platform::adapter()
                .home_dir()
                .map(|h| h.display().to_string())
                .unwrap_or_default()
        };
        let library = self.data_dir.display().to_string();

        let diag_json = serde_json::to_string_pretty(
            &events
                .iter()
                .map(|e| {
                    serde_json::json!({
                        "ts": e.ts,
                        "kind": e.kind,
                        "detail": e.detail.as_deref().map(|d| scrub(d, &home, &library)),
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
                        "node_id_prefix": hex(&d.profile.node_id[..4.min(d.profile.node_id.len())]),
                        // #544：设备名是用户起的（「张三的手机」），属于
                        // 可识别信息，不进导出件；排障用前缀 + 角色足够。
                        "role": d.pairing.as_ref().map(|p| p.role.as_str()),
                        "paired": d.pairing.is_some(),
                        "departed_by": d.profile.departed_by.map(|b| b.as_str()),
                    })
                })
                .collect::<Vec<_>>(),
        )?;

        // DESK-10: 审计事件（配对/吊销/外部删除…）也进包——桌面壳把
        // 这三份 JSON 原样搬进它本地组装的 bundle，daemon 侧只负责
        // 「只有 daemon 拿得到」的那部分。actor 仍只出 NodeId 前缀。
        // event_id 是内部幂等键（32 位随机 hex）——纯内部用途，不对
        // 支持场景有意义，且会撞上「≥24 位连续 hex 不许进包」的脱敏
        // 判据，所以显式排除在导出字段之外。
        let audit = self.db.list_audit(500).await?;
        let audit_json = serde_json::to_string_pretty(
            &audit
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "id": r.id,
                        "ts": r.entry.ts,
                        "kind": r.entry.kind,
                        "actor_prefix": r.entry.actor.as_ref().map(|a| hex(&a[..4.min(a.len())])),
                        "roundId": r.entry.round_id,
                        "payload": r
                            .entry
                            .payload
                            .as_deref()
                            .map(|p| audit_payload_for_export(&r.entry.kind, p))
                            .map(|p| scrub(&p, &home, &library)),
                    })
                })
                .collect::<Vec<_>>(),
        )?;

        Ok(serde_json::json!({
            "diag_events.json": diag_json,
            "devices.json": devices_json,
            "audit.json": audit_json,
        }))
    }
}

/// Free/total bytes of the volume holding the photo library (T-090).
#[derive(Debug, Clone, Copy)]
struct DiskStats {
    free: u64,
    total: u64,
}

/// Volume capacity for `path`. `std::fs` has no stable capacity API, so
/// `path` 所在卷的容量水位。`None` = 本平台没有实现，序列化成 null
/// ——「老实的 null 胜过编造的数字」（DAE-05）。
///
/// QA-09 迁移（#211）：这里原先按 unix / 非 unix 分成两个实现——unix 那半
/// 直接在本 crate 里调 `libc::statvfs`，非 unix 那半已经在 DAE-05 里改成了
/// 委托。迁移把 statvfs 那段搬进
/// `crates/platform/src/unix.rs`，两个分支于是塌成一次调用。
///
/// `free` 的语义是 statvfs 的 `f_bavail`——**无特权写入者真正可用**的
/// 字节数（`df` / Finder 显示的那个），不是物理空闲量。这条契约现在写在
/// trait 上，macOS / Linux / Windows 三边共同遵守。
fn disk_stats(path: &std::path::Path) -> Option<DiskStats> {
    use platform::PlatformAdapter as _;
    platform::adapter().volume_stats(path).map(|v| DiskStats {
        free: v.free,
        total: v.total,
    })
}

/// 磁盘加密状态的缓存时长：状态几乎不变，而 `status` 被界面频繁轮询。
const DISK_ENCRYPTION_TTL: std::time::Duration = std::time::Duration::from_secs(600);

/// 带缓存的磁盘加密状态（W-4）。查询放到阻塞线程，失败当 `Unknown`。
async fn disk_encryption_cached() -> platform::DiskEncryption {
    use platform::PlatformAdapter as _;
    static CACHE: std::sync::Mutex<Option<(std::time::Instant, platform::DiskEncryption)>> =
        std::sync::Mutex::new(None);
    if let Some((at, v)) = *CACHE.lock().unwrap() {
        if at.elapsed() < DISK_ENCRYPTION_TTL {
            return v;
        }
    }
    let v = tokio::task::spawn_blocking(|| platform::adapter().disk_encryption())
        .await
        .unwrap_or(platform::DiskEncryption::Unknown);
    *CACHE.lock().unwrap() = Some((std::time::Instant::now(), v));
    v
}

/// Replace the user's home directory (and thus their username) in any
/// string destined for an export.
fn sanitize(s: &str, home: &str) -> String {
    if home.is_empty() {
        return s.to_string();
    }
    s.replace(home, "<DATA>")
}

/// 导出件的统一脱敏（#544）：库目录 → `<LIBRARY>`（自定义库名 / 外置盘卷名
/// 都可能带人名，先于家目录替换），家目录 → `<DATA>`，再过
/// [`crate::redact::redact`]（公网 IP、自建 relay 域名、长 hex / base32 /
/// base64url 标识与票据）。按**值的形状**做，不挑字段名（DESK-10 教训：
/// `detail` 里的 `rel_path` 以全长 NodeId 开头）。与桌面壳
/// `daemon_logs::scrub_full` 同语义，两侧共用 `assets/privacy/redact-vectors.json`。
fn scrub(s: &str, home: &str, library: &str) -> String {
    let pre = |s: &str| {
        let s = if library.is_empty() {
            s.to_string()
        } else {
            s.replace(library, "<LIBRARY>")
        };
        sanitize(&s, home)
    };
    crate::redact::redact_export_json_or_text(s, &pre)
}

fn state_name(s: &DaemonState) -> &'static str {
    match s {
        DaemonState::OnlineDirect => "ONLINE_DIRECT",
        DaemonState::Pairing => "PAIRING",
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
    for chunk in s.as_bytes().as_chunks::<2>().0 {
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

/// AUDIT-04: idempotency key for daemon-minted `audit_decision` rows this
/// IPC surface writes directly (device.revoke). This process is the sole
/// writer — no phone retry can resend it — so a fresh random id is exactly
/// as good as one generated anywhere else in the codebase.
fn fresh_audit_id() -> String {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("OS randomness for audit decision id");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
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

    /// DESK-10 补漏：导出脱敏按值的形状做——任何字段里的长 hex 都掩到
    /// 前 8 位，短 hex 不动。#544：库目录与公网 IP 同样不许出包。
    #[test]
    fn scrub_masks_long_hex_anywhere_in_the_value() {
        let node = "ab".repeat(32);
        let s = format!("/Users/alice/x originals/{node}/2026/08/a.jpg");
        let out = scrub(&s, "/Users/alice", "");
        assert!(
            out.starts_with("<DATA>/<dir> originals/abababab…<masked>/2026/08/<file>.jpg"),
            "{out}"
        );
        assert!(!out.contains(&node), "{out}");
        // 短 hex（端口号之类）不动；前缀（8 hex）也在阈值之下。
        assert_eq!(
            scrub("port 41145 beef abababab", "", ""),
            "port 41145 beef abababab"
        );
        // 24 位配对令牌也算长 hex。
        assert!(scrub(&"c".repeat(24), "", "").contains("cccccccc…<masked>"));
    }

    #[test]
    fn scrub_hides_library_root_and_public_ips() {
        let out = scrub(
            "/Volumes/Alice Disk/Photos/originals/x.jpg via 203.0.113.7:4433",
            "/Users/alice",
            "/Volumes/Alice Disk/Photos",
        );
        assert_eq!(out, "<LIBRARY>/originals/<file>.jpg via <ipv4:public>:4433");
    }

    #[test]
    fn hex32_roundtrip_and_rejects() {
        assert!(parse_hex32("xyz").is_none());
        assert_eq!(parse_hex32(&"ab".repeat(32)).unwrap(), vec![0xab; 32]);
    }
}
