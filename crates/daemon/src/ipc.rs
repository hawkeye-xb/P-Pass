//! Local IPC for the tray UI (T-034, ADR-012): local socket / named pipe
//! via `interprocess` (no platform #[cfg] here — rule B.2), guarded by a
//! random per-launch token written into the data dir.
//!
//! Wire format: newline-delimited JSON. First line from the client is the
//! raw token; every following line is a `proto::Req`, answered by one
//! `proto::Resp` line. Wrong token = connection dropped, one diag event.
//!
//! Methods (契约): `status` `pairing.start` `pairing.confirm`
//! `devices.list` `device.revoke` `device.watermarks` `folder.set`
//! `logs.export` `activity.list` (T-090) — plus DAE-01
//! `daemon.step_down` (newest-wins takeover, added 2026-08-04) and
//! NAME-01 `device.rename` (display-name only, ID 不变, added 2026-08-12).

use std::cmp::Ordering;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use diag::state::DaemonState;
use interprocess::local_socket::tokio::prelude::*;
use interprocess::local_socket::{GenericNamespaced, ListenerOptions};
use proto::{codes, Req, Resp, RespError};
use storage::Db;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::diag_agg::DiagAgg;
use crate::events::{self, EventBus};
use crate::pairing::{PairDecision, Pairing, PendingPair, PENDING_TTL_MS};
use crate::subscriptions::SubscriptionRegistry;

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
    pending_ttl_ms: i64,
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
    /// 后注入，dispatch 端 get() 零锁零等待。未注入时答 err.unsupported。
    query: std::sync::OnceLock<crate::query::QueryEngine>,
    /// SYNC-03: 与 Router 共用同一份登记表——`device.revoke` 命中一个
    /// 挂着 `timeline.subscribe` 长连接的设备时主动断连。main 未注入时
    /// 是一份空表（`close` 天然 no-op），不影响任何现有测试。
    subscriptions: SubscriptionRegistry,
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
    /// We took over from an older instance (it stepped down) — bind now,
    /// and re-install autostart so launchd points at this (stable) path.
    TookOver,
    /// A same-or-newer instance is already serving — exit this process.
    StandDown,
}

// ── DAE-01 helpers: probe the peer socket, ask it to step down, compare
// versions. All client-side (no server changes to the wire contract).

/// Send one IPC request to the peer and read its response line.
async fn peer_call(socket_name: &str, token_hex: &str, method: &str) -> Option<serde_json::Value> {
    let name = socket_name.to_ns_name::<GenericNamespaced>().ok()?;
    let conn = interprocess::local_socket::tokio::Stream::connect(name)
        .await
        .ok()?;
    let (rx, mut tx) = conn.split();
    let mut lines = BufReader::new(rx).lines();
    tx.write_all(token_hex.as_bytes()).await.ok()?;
    tx.write_all(b"\n").await.ok()?;
    let req = format!("{{\"id\":\"dae-01\",\"method\":\"{method}\",\"params\":{{}}}}\n");
    tx.write_all(req.as_bytes()).await.ok()?;
    let line = tokio::time::timeout(Duration::from_millis(800), lines.next_line())
        .await
        .ok()?
        .ok()??;
    serde_json::from_str::<serde_json::Value>(&line).ok()
}

/// Live peer (status answered) or None (dead socket / no instance).
async fn probe_peer(socket_name: &str, token_hex: &str) -> Option<serde_json::Value> {
    peer_call(socket_name, token_hex, "status").await
}

/// Ask the live peer to exit (newest-wins takeover).
async fn notify_step_down(socket_name: &str, token_hex: &str) -> Option<serde_json::Value> {
    peer_call(socket_name, token_hex, "daemon.step_down").await
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

/// Resolve the effective daemon version, in precedence order:
/// 1. `PPF_DAEMON_VERSION` (runtime override — integration tests);
/// 2. `PPF_BUILD_VERSION` (baked at compile time from the release tag,
///    DAE-01b blocker② — `CARGO_PKG_VERSION` carries no `-test.N` suffix,
///    so test.7 and test.8 would both report 0.2.0 and the newer test
///    package could never take over during dogfood week);
/// 3. `CARGO_PKG_VERSION` (local / dev builds).
pub fn daemon_version() -> String {
    std::env::var("PPF_DAEMON_VERSION")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            option_env!("PPF_BUILD_VERSION")
                .map(str::to_string)
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string())
}

/// Numeric-segment semver compare ("0.2.0-test.7" vs "0.1.0" → Greater).
/// Pre-release suffixes sort below the same core ("0.1.0" > "0.1.0-test.3"),
/// so a formal build always takes over from a test build of the same core.
/// Two pre-releases of the same core compare by their numeric segments
/// ("0.2.0-test.8" > "0.2.0-test.7" — DAE-01b blocker②), so dogfood test
/// packages can take over from each other.
fn version_cmp(a: &str, b: &str) -> Ordering {
    let nums = |seg: &str| -> Vec<u64> {
        seg.split(|c: char| !c.is_ascii_digit())
            .filter(|p| !p.is_empty())
            .map(|p| p.parse().unwrap_or(0))
            .collect()
    };
    let parse = |s: &str| -> (Vec<u64>, Vec<u64>, bool) {
        let (core, pre) = match s.split_once('-') {
            Some((c, p)) => (c, Some(p)),
            None => (s, None),
        };
        (nums(core), pre.map(nums).unwrap_or_default(), pre.is_some())
    };
    let (na, npa, pa) = parse(a);
    let (nb, npb, pb) = parse(b);
    for i in 0..na.len().max(nb.len()) {
        let (x, y) = (
            na.get(i).copied().unwrap_or(0),
            nb.get(i).copied().unwrap_or(0),
        );
        if x != y {
            return x.cmp(&y);
        }
    }
    match (pa, pb) {
        (false, true) => Ordering::Greater,
        (true, false) => Ordering::Less,
        (true, true) => {
            for i in 0..npa.len().max(npb.len()) {
                let (x, y) = (
                    npa.get(i).copied().unwrap_or(0),
                    npb.get(i).copied().unwrap_or(0),
                );
                if x != y {
                    return x.cmp(&y);
                }
            }
            Ordering::Equal
        }
        (false, false) => Ordering::Equal,
    }
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
        events: EventBus,
    ) -> Self {
        let pending: Arc<Mutex<Vec<PendingPair>>> = Arc::default();
        let queue = Arc::clone(&pending);
        let diag2 = diag.clone();
        let events2 = events.clone();
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
                    let ttl = PENDING_TTL_MS;
                    let mut q = queue.lock().expect("pending lock");
                    q.retain(|old| old.requested_at + ttl > now && old.peer.0 != p.peer.0);
                    q.push(p);
                }
                // IPC-02: 新扫码请求入队——桌面壳即时从「二维码弹窗」切到
                // 「授权列表」，不再等下一次 3s 轮询。
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
            pending_ttl_ms: PENDING_TTL_MS,
            step_down_exit: Arc::new(|| std::process::exit(0)),
            conn_status: Arc::new(|_| transport::ConnectionStatus::Unknown),
            flow_connection: Arc::new(|_| None),
            query: std::sync::OnceLock::new(),
            subscriptions: SubscriptionRegistry::new(),
        }
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

    /// Override the step_down side effect (tests only).
    pub fn set_step_down_exit(&mut self, f: impl Fn() + Send + Sync + 'static) {
        self.step_down_exit = Arc::new(f);
    }

    /// DEV-05 (#276): override the queue-side pending TTL (tests only —
    /// production keeps [`PENDING_TTL_MS`]). Pair it with
    /// [`Pairing::with_pending_ttl`] to exercise the two-sided expiry
    /// without sleeping minutes.
    pub fn set_pending_ttl_for_test(&mut self, ttl_ms: i64) {
        self.pending_ttl_ms = ttl_ms;
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
        let Some(peer) = probe_peer(socket_name, &token_hex).await else {
            if socket_is_live(socket_name).await {
                // Socket still live but rejects the recorded token (drift).
                tracing::error!(
                    "DAE-01b: live daemon on {socket_name} rejects the recorded token — standing down (do not unlink)"
                );
                return Claim::StandDown;
            }
            // Peer exited between the two checks — dead socket, bind.
            clean_stale_socket(socket_name);
            return Claim::Proceed;
        };
        let r = peer.get("result");
        let peer_version = r
            .and_then(|v| v.get("version"))
            .and_then(|v| v.as_str())
            .unwrap_or("0.0.0")
            .to_string();
        let peer_pid = r
            .and_then(|v| v.get("pid"))
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        tracing::info!("DAE-01: live daemon v{peer_version} (pid {peer_pid}) on {socket_name}");
        match version_cmp(version, &peer_version) {
            Ordering::Less | Ordering::Equal => {
                tracing::info!(
                    "DAE-01: existing v{peer_version} >= ours v{version} — standing down"
                );
                Claim::StandDown
            }
            Ordering::Greater => {
                tracing::info!("DAE-01: ours v{version} > existing v{peer_version} — takeover");
                let _ = notify_step_down(socket_name, &token_hex).await;
                // Wait for the peer to exit (bounded), then bind.
                for _ in 0..50 {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    if probe_peer(socket_name, &token_hex).await.is_none() {
                        break;
                    }
                }
                clean_stale_socket(socket_name);
                Claim::TookOver
            }
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
            let req = match serde_json::from_str::<Req>(&line) {
                Ok(req) => req,
                Err(_) => {
                    let resp = Resp::err(
                        String::new(),
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                    let mut out = serde_json::to_string(&resp)?;
                    out.push('\n');
                    tx.write_all(out.as_bytes()).await?;
                    continue;
                }
            };
            // IPC-02: 事件订阅——握手应答后连接转为事件流（仍可应答
            // 其他请求），直到客户端断开或 events.unsubscribe。
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
                return self.serve_subscription(&mut lines, &mut tx, &req, rx).await;
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
        lines: &mut tokio::io::Lines<BufReader<interprocess::local_socket::tokio::RecvHalf>>,
        tx: &mut interprocess::local_socket::tokio::SendHalf,
        req: &Req,
        mut rx: tokio::sync::broadcast::Receiver<serde_json::Value>,
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
                            RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                        );
                        let mut out = serde_json::to_string(&resp)?;
                        out.push('\n');
                        tx.write_all(out.as_bytes()).await?;
                        continue;
                    };
                    if req.method == "events.unsubscribe" {
                        return Ok(()); // 明确退订——客户端转兜底轮询
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
                // DEV-04：按身份定位，名字只作回退——改过名的设备重连时
                // 弹窗上的名字不再等于队列里的自报名。
                let node_id = req
                    .params
                    .get("node_id")
                    .and_then(|v| v.as_str())
                    .and_then(parse_hex32);
                match self.confirm(node_id.as_deref(), device_name.as_deref(), accept) {
                    ConfirmOutcome::Decided(name) => {
                        Resp::ok(id, serde_json::json!({ "decided": accept, "device": name }))
                    }
                    // DEV-05 (#276): the click landed on a dead request —
                    // report failure honestly (the old code answered ok
                    // and the phone never received anything).
                    ConfirmOutcome::Expired(_) | ConfirmOutcome::NotFound => Resp::err(
                        id,
                        RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                    ),
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
            "devices.list" => {
                let include_revoked = req
                    .params
                    .get("include_revoked")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let listed = if include_revoked {
                    self.db.list_devices(true).await
                } else {
                    self.db.list_devices_for_family_view().await
                };
                match listed {
                    Ok(devices) => {
                        let list: Vec<_> = devices
                            .iter()
                            .map(|d| {
                                // Read both sources exactly once so a response cannot combine
                                // a pre-transition `connection` with a post-transition
                                // `presence`. Flow state stays a distinct nullable field:
                                // `null` means no active transfer, not offline.
                                // DEV-03：已吊销的设备一律不报在线。
                                //
                                // 泛连接判定看的是传输层还有没有活口，而吊销
                                // 是**授权**上的终止——一个刚断开、连接尚未
                                // 断干净的设备如果还显示「在线」，等于告诉
                                // 用户「它还在备份」，正好相反。授权没了就是
                                // 离线，这里不做组合判断。
                                let connection = if d.revoked {
                                    transport::ConnectionStatus::Offline
                                } else {
                                    (self.conn_status)(&d.node_id)
                                };
                                let flow_connection = if d.revoked {
                                    None
                                } else {
                                    (self.flow_connection)(&d.node_id)
                                };
                                serde_json::json!({
                                    "node_id": hex(&d.node_id),
                                    "name": d.name,
                                    "role": d.role.as_str(),
                                    "revoked": d.revoked,
                                    // DEV-03：谁让它离开的 + 什么时候。
                                    // 展示层据此把「已断开」和「在用」分开渲染，
                                    // 并能答「它什么时候断的」。
                                    "revoked_by": d.revoked_by.map(|b| b.as_str()),
                                    "revoked_at": d.revoked_at,
                                    "last_seen": d.last_seen,
                                    // T-090: generic live transport verdict only; this
                                    // remains intentionally independent from the Flow plane.
                                    "connection": connection.as_str(),
                                    // NET-05: actual active blobs route for the current Flow
                                    // item, keyed back to this paired control device.
                                    "flow_connection": flow_connection.map(|s| s.as_str()),
                                    // PRES-01: 三档在线态只用既有泛连接/心跳口径，
                                    // 不让短暂文件传输改写在线语义。
                                    "presence": if d.revoked {
                                        "offline"
                                    } else {
                                        crate::presence::presence(
                                            connection.as_str(),
                                            d.last_seen,
                                            now_ms(),
                                        )
                                    },
                                })
                            })
                            .collect();
                        Resp::ok(id, serde_json::json!({ "devices": list }))
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
                match self.db.list_operations(limit).await {
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
                // DEV-03：业主主动移除——这正是业主的意图，之后它不再出现在
                // 「家人与设备」里（行仍在库里，审计可查，`arch-check B.3`
                // 禁止物理删除这一条不变）。
                match self
                    .db
                    .revoke(&node_id, storage::RevokedBy::Owner, now_ms())
                    .await
                {
                    Ok(revoked) => {
                        if revoked {
                            let _ = self
                                .db
                                .append_audit(&storage::AuditEntry::local(
                                    now_ms(),
                                    None, // 本机 owner 经 IPC 操作
                                    "device.revoked",
                                    None,
                                    Some(serde_json::json!({ "nodeId": node_hex }).to_string()),
                                ))
                                .await;
                            // AUDIT-04 card decision #4: 撤销授权是用户决定，
                            // 必须落 audit_decision（causal_object_ref = 被撤销
                            // 设备），不能只靠上面兼容层的 audit_operation 行。
                            let _ = self
                                .db
                                .append_decision(&storage::DecisionEntry {
                                    decision_id: fresh_audit_id(),
                                    decision_kind: "revoke_authorization".into(),
                                    actor: None, // 本机 owner 经 IPC 操作
                                    causal_operation_id: None,
                                    causal_object_ref: Some(node_hex.to_string()),
                                    occurred_at: now_ms(),
                                    payload: Some(
                                        serde_json::json!({ "nodeId": node_hex }).to_string(),
                                    ),
                                })
                                .await;
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
                            // SYNC-03 §⑦：命中一个还挂着 timeline.subscribe
                            // 长连接的设备就主动关掉，不等它自然掉线。
                            if let Ok(bytes) = <[u8; 32]>::try_from(node_id.as_slice()) {
                                self.subscriptions.close(transport::NodeId(bytes));
                            }
                        }
                        Resp::ok(id, serde_json::json!({ "revoked": revoked }))
                    }
                    Err(_) => internal(id),
                }
            }
            "device.rename" => {
                // NAME-01: 改显示名（ID 与显示名分离——decisions ②）。
                // 本机 owner 经 IPC 操作（与 device.revoke 同鉴权面）。
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
                // 新名必填（空名 = 非法请求）；长度上限防滥用。
                let Some(new_name) = req.params.get("name").and_then(|v| v.as_str()) else {
                    return Resp::err(
                        id,
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                };
                let new_name = new_name.trim();
                if new_name.is_empty() || new_name.chars().count() > 64 {
                    return Resp::err(
                        id,
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                }
                match self.db.rename_device(&node_id, new_name).await {
                    Ok(Some(old_name)) => {
                        // 审计：旧名→新名 + node_id（decisions ②「audit 记
                        // device.renamed 旧名→新名+node_id」）。
                        let _ = self
                            .db
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
                            .await;
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
                        Resp::err(
                            id,
                            RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                        )
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
            // DESK-03: 查询平面（桌面照片墙，与手机同一数据源）——
            // 未注入 QueryEngine 时统一答 err.unsupported（老测试构造
            // 零波及；main 总是注入）。响应形状与网络平面逐字段一致，
            // 桌面端消费代码可与手机端镜像。
            "timeline.page" | "thumb.get" | "asset.meta" | "asset.path" | "asset.original" => {
                let Some(query) = self.query.get() else {
                    return Resp::err(
                        id,
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                };
                match req.method.as_str() {
                    "timeline.page" => {
                        let Ok(q) =
                            serde_json::from_value::<proto::TimelineQuery>(req.params.clone())
                        else {
                            return Resp::err(
                                id,
                                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                            );
                        };
                        match query.timeline(&q).await {
                            Ok(page) => match serde_json::to_value(&page) {
                                Ok(v) => Resp::ok(id, v),
                                Err(_) => internal(id),
                            },
                            Err(_) => Resp::err(
                                id,
                                RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                            ),
                        }
                    }
                    "thumb.get" => {
                        let Ok(t) = serde_json::from_value::<proto::ThumbGet>(req.params.clone())
                        else {
                            return Resp::err(
                                id,
                                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                            );
                        };
                        match query.thumb(&t).await {
                            Ok(bytes) => {
                                use base64::Engine as _;
                                let data = proto::ThumbData {
                                    jpeg_base64: base64::engine::general_purpose::STANDARD
                                        .encode(bytes),
                                };
                                match serde_json::to_value(&data) {
                                    Ok(v) => Resp::ok(id, v),
                                    Err(_) => internal(id),
                                }
                            }
                            Err(_) => Resp::err(
                                id,
                                RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                            ),
                        }
                    }
                    "asset.meta" => {
                        let Some(hash) = req.params.get("hash").and_then(|v| v.as_str()) else {
                            return Resp::err(
                                id,
                                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                            );
                        };
                        match query.asset_meta(hash).await {
                            Ok(meta) => match serde_json::to_value(&meta) {
                                Ok(v) => Resp::ok(id, v),
                                Err(_) => internal(id),
                            },
                            Err(_) => Resp::err(
                                id,
                                RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                            ),
                        }
                    }
                    "asset.path" => {
                        let Some(hash) = req.params.get("hash").and_then(|v| v.as_str()) else {
                            return Resp::err(
                                id,
                                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                            );
                        };
                        match query.asset_path(hash).await {
                            Ok(path) => {
                                Resp::ok(id, serde_json::json!({ "path": path.to_string_lossy() }))
                            }
                            Err(_) => Resp::err(
                                id,
                                RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                            ),
                        }
                    }
                    "asset.original" => {
                        let Some(hash) = req.params.get("hash").and_then(|v| v.as_str()) else {
                            return Resp::err(
                                id,
                                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                            );
                        };
                        match query.original(hash).await {
                            Ok(bytes) => {
                                use base64::Engine as _;
                                Resp::ok(
                                    id,
                                    serde_json::json!({
                                        "data_base64": base64::engine::general_purpose::STANDARD.encode(bytes),
                                    }),
                                )
                            }
                            Err(_) => Resp::err(
                                id,
                                RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                            ),
                        }
                    }
                    _ => unreachable!("covered by the outer arm"),
                }
            }
            _ => Resp::err(
                id,
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            ),
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
        accept: bool,
    ) -> ConfirmOutcome {
        let mut queue = self.pending.lock().expect("pending lock");
        let now = now_ms();
        let idx = match (node_id, device_name) {
            (Some(id), _) => queue.iter().position(|p| p.peer.0 == id),
            (None, Some(name)) => queue.iter().position(|p| p.device_name == name),
            (None, None) => (!queue.is_empty()).then_some(0),
        };
        let Some(idx) = idx else {
            // Nothing to decide — still sweep stale rows, and report the
            // queue emptying to diag exactly as the success path would.
            queue.retain(|p| p.requested_at + self.pending_ttl_ms > now);
            if queue.is_empty() {
                self.diag.apply(diag::DaemonEvent::PairingEnded);
            }
            return ConfirmOutcome::NotFound;
        };
        let p = queue.remove(idx);
        // The located row itself may be past TTL: answer Expired, not a
        // fake success and not a NotFound that hides which row failed.
        let stale = p.requested_at + self.pending_ttl_ms <= now;
        // Any other rows that aged out leave the queue with this touch.
        queue.retain(|q| q.requested_at + self.pending_ttl_ms > now);
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
            return ConfirmOutcome::Expired(name);
        }
        let decision = if accept {
            PairDecision::Accept
        } else {
            PairDecision::Reject
        };
        match p.decide(decision) {
            Ok(()) => ConfirmOutcome::Decided(name),
            Err(_) => ConfirmOutcome::Expired(name),
        }
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
        let queued: Vec<(transport::NodeId, String, i64)> = self
            .pending
            .lock()
            .expect("pending lock")
            .iter()
            .map(|p| (p.peer, p.device_name.clone(), p.requested_at))
            .collect();

        let mut out = Vec::with_capacity(queued.len());
        for (peer, reported_name, requested_at) in queued {
            let existing = self.db.get_device(&peer.0).await.ok().flatten();
            let mut row = serde_json::json!({
                "node_id": hex(&peer.0),
                "known": existing.is_some(),
                "name": existing
                    .as_ref()
                    .map(|d| d.name.clone())
                    .unwrap_or(reported_name),
                "requested_at": requested_at,
                "expired": requested_at + self.pending_ttl_ms <= now,
            });
            if let Some(d) = existing {
                row["paired_at"] = serde_json::json!(d.paired_at);
                row["revoked"] = serde_json::json!(d.revoked);
                row["photo_count"] = serde_json::json!(self
                    .db
                    .count_assets_from_device(&d.node_id)
                    .await
                    .unwrap_or(0));
            }
            out.push(row);
        }
        out
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
        let devices = self.db.list_devices(true).await?;
        let state = self.diag.state();
        let pending = self.pending.lock().expect("pending lock").len();
        // T-090: photo total + disk watermarks of the library volume.
        let photo_count = self.db.count_assets().await?;
        let photo_sources = self.db.count_asset_sources().await?;
        let disk = disk_stats(&self.data_dir);
        Ok(serde_json::json!({
            // T-090 data-plane fields (桌面总览卡直接消费).
            "photo_count": photo_count,
            // DESK-03: 「共 N 张 · 来自 M 台设备」的 M。
            "photo_sources": photo_sources,
            "disk_free_bytes": disk.map(|d| d.free),
            "disk_total_bytes": disk.map(|d| d.total),
            "state": state_name(&state),
            "msg_key": state.msg_key(),
            "devices": devices.len(),
            "revoked": devices.iter().filter(|d| d.revoked).count(),
            "pending_pairs": pending,
            // Where the photos physically live — the UI's "open the
            // photo folder" needs an answer to "传到哪儿了" (real
            // walkthrough question, 2026-07-31).
            "library_dir": self.data_dir.display().to_string(),
            // DAE-01: identity fields for newest-wins handshake + ops
            // visibility (验收①：status 报 PID/版本/路径/启动时间).
            "version": daemon_version(),
            "pid": std::process::id(),
            "started_at": self.started_at,
            "exe_path": std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_default(),
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
        let devices = self.db.list_devices(true).await?;
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
                        "detail": e.detail.as_deref().map(|d| scrub(d, &home)),
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
                        "name": scrub(&d.name, &home),
                        "role": d.role.as_str(),
                        "revoked": d.revoked,
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
                        "payload": r.entry.payload.as_deref().map(|p| scrub(p, &home)),
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
        zip.start_file("audit.json", opts)?;
        zip.write_all(audit_json.as_bytes())?;
        zip.finish()?;
        Ok(zip_path)
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

/// Replace the user's home directory (and thus their username) in any
/// string destined for an export.
fn sanitize(s: &str, home: &str) -> String {
    if home.is_empty() {
        return s.to_string();
    }
    s.replace(home, "<DATA>")
}

/// 长 hex 串（NodeId 全长 64 hex、配对令牌 24 hex）只留前 8 位。
///
/// DESK-10 真机验收的教训：脱敏必须按**值的形状**做，不能按字段名
/// 白名单。`actor` 有前缀掩码，但 `detail` 里的 `rel_path` 本身就以
/// 全长 NodeId 开头（库布局 `originals/<nodeid>/YYYY/MM/<file>`），
/// 于是完整 NodeId 照样进了支持包。短 hex（端口号、小 id）不动。
/// 与桌面壳 `daemon_logs::mask_long_hex` 同语义（ADR-012：桌面壳是
/// 独立 workspace，不依赖业务 crate），靠导出包「不许有 ≥24 位连续
/// hex」的测试锁死两侧。
fn mask_long_hex(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while !rest.is_empty() {
        let start = match rest.find(|c: char| c.is_ascii_hexdigit()) {
            Some(i) => i,
            None => break,
        };
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        let len = tail
            .find(|c: char| !c.is_ascii_hexdigit())
            .unwrap_or(tail.len());
        let run = &tail[..len];
        if len >= 24 {
            out.push_str(&run[..8]);
            out.push_str("…<masked>");
        } else {
            out.push_str(run);
        }
        rest = &tail[len..];
    }
    out.push_str(rest);
    out
}

/// 导出件的统一脱敏：家目录 + 长 hex。导出包里的每个字段都过这里，
/// 不挑字段名。
fn scrub(s: &str, home: &str) -> String {
    mask_long_hex(&sanitize(s, home))
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
    /// 前 8 位，短 hex 不动。
    #[test]
    fn scrub_masks_long_hex_anywhere_in_the_value() {
        let node = "ab".repeat(32);
        let s = format!("/Users/alice/x originals/{node}/2026/08/a.jpg");
        let out = scrub(&s, "/Users/alice");
        assert!(
            out.starts_with("<DATA>/x originals/abababab…<masked>/"),
            "{out}"
        );
        assert!(!out.contains(&node), "{out}");
        // 短 hex（端口号之类）不动；前缀（8 hex）也在阈值之下。
        assert_eq!(
            mask_long_hex("port 41145 beef abababab"),
            "port 41145 beef abababab"
        );
        // 24 位配对令牌也算长 hex。
        assert!(mask_long_hex(&"c".repeat(24)).contains("cccccccc…<masked>"));
    }

    #[test]
    fn hex32_roundtrip_and_rejects() {
        assert!(parse_hex32("xyz").is_none());
        assert_eq!(parse_hex32(&"ab".repeat(32)).unwrap(), vec![0xab; 32]);
    }

    // ── DAE-01: version comparison (newest-wins handshake) ──
    #[test]
    fn version_cmp_semver_segments() {
        assert_eq!(version_cmp("0.1.0", "0.1.0"), Ordering::Equal);
        assert_eq!(version_cmp("0.2.0", "0.1.0"), Ordering::Greater);
        assert_eq!(version_cmp("0.1.0", "0.2.0"), Ordering::Less);
        assert_eq!(version_cmp("1.0.0", "0.9.9"), Ordering::Greater);
        assert_eq!(version_cmp("0.10.0", "0.9.0"), Ordering::Greater);
        // 预发布后缀：数字段比较为主（0.2.0-test.7 > 0.1.0）
        assert_eq!(version_cmp("0.2.0-test.7", "0.1.0"), Ordering::Greater);
        assert_eq!(version_cmp("0.1.0", "0.2.0-test.7"), Ordering::Less);
        // DAE-01b blocker②: pre-release numeric segments — dogfood test
        // packages must take over from each other (test.8 > test.7).
        assert_eq!(
            version_cmp("0.2.0-test.8", "0.2.0-test.7"),
            Ordering::Greater
        );
        assert_eq!(version_cmp("0.2.0-test.7", "0.2.0-test.8"), Ordering::Less);
        assert_eq!(
            version_cmp("0.2.0-test.10", "0.2.0-test.9"),
            Ordering::Greater
        );
        assert_eq!(version_cmp("0.2.0-test.8", "0.2.0-test.8"), Ordering::Equal);
        // A formal build outranks any test build of the same core.
        assert_eq!(version_cmp("0.2.0", "0.2.0-test.8"), Ordering::Greater);
        assert_eq!(version_cmp("0.2.0-test.8", "0.2.0"), Ordering::Less);
        // 同核心数字段：正式 > 预发布（正式构建接管 test 构建）
        assert_eq!(version_cmp("0.1.0", "0.1.0-test.3"), Ordering::Greater);
        assert_eq!(version_cmp("0.1.0-test.3", "0.1.0"), Ordering::Less);
        // 垃圾输入退化为 0
        assert_eq!(version_cmp("", "0.0.0"), Ordering::Equal);
        assert_eq!(version_cmp("alpha", "0.1.0"), Ordering::Less);
    }
}
