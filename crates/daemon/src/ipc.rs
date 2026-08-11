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
use interprocess::local_socket::traits::Stream as _;
use interprocess::local_socket::{GenericNamespaced, ListenerOptions};
use proto::{codes, Req, Resp, RespError};
use storage::Db;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::diag_agg::DiagAgg;
use crate::events::{self, EventBus};
use crate::pairing::{PairDecision, Pairing, PendingPair};

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
    /// T-090: live connection status per device (raw 32-byte NodeId in).
    /// main injects a closure over the transport slot; the default says
    /// `Unknown` — 拿不到实况就如实报 unknown，绝不用 last_seen 推断.
    conn_status: ConnStatusFn,
    /// DESK-03: query plane（timeline/thumb/asset.*）——桌面壳与 daemon
    /// 同机，照片墙直接走本地 IPC 消费查询平面（与手机同一数据源）。
    /// OnceLock：main 在 transport bind 之后才建 QueryEngine（blobs 依赖
    /// 已绑定 transport），而 IpcServer 早已 Arc 化——用 set_query(&self)
    /// 后注入，dispatch 端 get() 零锁零等待。未注入时答 err.unsupported。
    query: std::sync::OnceLock<crate::query::QueryEngine>,
}

/// See [`IpcServer::set_conn_status_provider`].
type ConnStatusFn = Arc<dyn Fn(&[u8]) -> transport::ConnectionStatus + Send + Sync>;

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

/// True if anything is listening on the socket (raw connect, no auth).
/// Distinguishes a dead socket file (connect refused) from a live peer —
/// DAE-01b blocker①: the old code conflated the two and unlinked live
/// sockets it merely failed to authenticate against.
fn socket_is_live(socket_name: &str) -> bool {
    let Ok(name) = socket_name.to_ns_name::<GenericNamespaced>() else {
        return false;
    };
    // Sync connect, drop immediately — we only want the connect verdict.
    interprocess::local_socket::Stream::connect(name).is_ok()
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

/// Remove a stale socket file (unix only; named pipes don't leave files).
fn clean_stale_socket(socket_name: &str) {
    #[cfg(unix)]
    {
        let _ = std::fs::remove_file(format!("/tmp/{socket_name}"));
    }
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
                queue.lock().expect("pending lock").push(p);
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
            step_down_exit: Arc::new(|| std::process::exit(0)),
            conn_status: Arc::new(|_| transport::ConnectionStatus::Unknown),
            query: std::sync::OnceLock::new(),
        }
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

    /// T-090: inject the live connection-status source (main wires this
    /// to the transport once it is bound; unset = honest `Unknown`).
    pub fn set_conn_status_provider(
        &mut self,
        f: impl Fn(&[u8]) -> transport::ConnectionStatus + Send + Sync + 'static,
    ) {
        self.conn_status = Arc::new(f);
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
        if !socket_is_live(socket_name) {
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
            if socket_is_live(socket_name) {
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
                let resp = Resp::ok(req.id.clone(), serde_json::json!({ "subscribed": true }));
                let mut out = serde_json::to_string(&resp)?;
                out.push('\n');
                tx.write_all(out.as_bytes()).await?;
                return self.serve_subscription(&mut lines, &mut tx, &req).await;
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
        let mut rx = self.events.subscribe();
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
                // DEV-01: merge_node_id (hex) = owner picked "替换旧的".
                let merge_node_id = req
                    .params
                    .get("merge_node_id")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned);
                match self.confirm(device_name.as_deref(), accept, merge_node_id.as_deref()) {
                    Some(name) => {
                        Resp::ok(id, serde_json::json!({ "decided": accept, "device": name }))
                    }
                    None => Resp::err(
                        id,
                        RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
                    ),
                }
            }
            // UX-08: 待确认配对请求全量列表（只读）——桌面端一屏列出所有
            // pending 逐行允许/拒绝（confirm 带 device_name 逐台处理）。
            // 不动确认语义，只补「队列里都有谁」。
            // DEV-01: 每项带 hint_match——存量同指纹设备（「替换旧的」选项）。
            "pairing.pending" => {
                let pending = self.pending_summary();
                Resp::ok(id, serde_json::json!({ "pending": pending }))
            }
            // DESK-02②: 默认只返回在用设备（include_revoked 默认 false）——
            // 被移除/吊销的设备不再挂在列表；include_revoked=true 时全量
            // （内部统计/诊断用）。
            "devices.list" => {
                let include_revoked = req
                    .params
                    .get("include_revoked")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                match self.db.list_devices(include_revoked).await {
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
                                    // T-090: live transport verdict only —
                                    // "unknown" when no live info exists;
                                    // never derived from last_seen.
                                    "connection": (self.conn_status)(&d.node_id).as_str(),
                                    // PRES-01: 三档在线态（纯函数，单测覆盖
                                    // 边界）——在线 / x 分钟前在线 / 离线。
                                    // 展示口径，不参与鉴权。
                                    "presence": crate::presence::presence(
                                        (self.conn_status)(&d.node_id).as_str(),
                                        d.last_seen,
                                        now_ms(),
                                    ),
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
            // T5: 审计事件流——配对请求/允许/拒绝、备份会话、吊销、传输，
            // 桌面「活动记录」页展示（时间倒序由 UI 兜底）。与 activity.list
            // （资产聚合批次）互补：这里看"发生了什么"，那里看"传了多少"。
            "audit.list" => {
                let limit = req
                    .params
                    .get("limit")
                    .and_then(|v| v.as_u64())
                    .map_or(100, |v| v.min(1000) as u32);
                match self.db.list_audit(limit).await {
                    Ok(records) => {
                        let list: Vec<_> = records
                            .iter()
                            .map(|r| {
                                serde_json::json!({
                                    "ts": r.entry.ts,
                                    "action": r.entry.action,
                                    "actor": r.entry.actor.as_ref().map(|b| hex(b)),
                                    "detail": r.entry.detail,
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
                            .append_audit(&storage::AuditEntry {
                                ts: now_ms(),
                                actor: None, // 本机 owner 经 IPC 操作
                                action: "device.renamed".into(),
                                target_hash: None,
                                detail: Some(format!("{old_name} -> {new_name} ({node_hex})")),
                            })
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
    /// head when `device_name` is None. Returns the decided device's
    /// name. Shared by IPC and the interim console confirmer in main.
    ///
    /// DEV-01: `merge_node_id` (hex) — when the owner picked "替换旧的",
    /// the decision carries the old device whose data the fresh pairing
    /// takes over. `None` = plain accept (pre-DEV-01 semantics).
    pub fn confirm(
        &self,
        device_name: Option<&str>,
        accept: bool,
        merge_node_id: Option<&str>,
    ) -> Option<String> {
        let mut queue = self.pending.lock().expect("pending lock");
        let idx = match device_name {
            Some(name) => queue.iter().position(|p| p.device_name == name),
            None => (!queue.is_empty()).then_some(0),
        }?;
        let p = queue.remove(idx);
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
        let decision = if !accept {
            PairDecision::Reject
        } else if let Some(hex_id) = merge_node_id {
            // Only offer the merge when the pending request actually has
            // a matching old device — a client-side fabrication must not
            // turn into a data migration (authz stays untouched: this is
            // still an owner-confirmed accept, just with a target).
            match p.hint_match.as_ref() {
                Some(m) if hex_id == hex(&m.node_id) => PairDecision::AcceptMerge {
                    old_node_id: m.node_id.clone(),
                },
                _ => PairDecision::Accept,
            }
        } else {
            PairDecision::Accept
        };
        p.decide(decision);
        Some(name)
    }

    /// Pending pairing requests for the owner UI — name plus, when the
    /// joining device carries a reinstall hint that matches an existing
    /// device, that old device's identity (DEV-01 "替换旧的" option).
    pub fn pending_summary(&self) -> Vec<serde_json::Value> {
        self.pending
            .lock()
            .expect("pending lock")
            .iter()
            .map(|p| {
                let hint_match = p.hint_match.as_ref().map(|m| {
                    serde_json::json!({
                        "node_id": hex(&m.node_id),
                        "name": m.name,
                    })
                });
                serde_json::json!({
                    "name": p.device_name,
                    "hint_match": hint_match,
                })
            })
            .collect()
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

/// Free/total bytes of the volume holding the photo library (T-090).
#[derive(Debug, Clone, Copy)]
struct DiskStats {
    free: u64,
    total: u64,
}

/// Volume capacity for `path`. `std::fs` has no stable capacity API, so
/// unix goes through `libc::statvfs` (libc was already in the dependency
/// tree via tokio/iroh; declared directly for this call). `free` is
/// `f_bavail` — what an unprivileged writer can actually use, matching
/// what Finder/`df` report. Non-unix returns `None` (fields serialize as
/// null) until a platform adapter lands — rule B.2 keeps platform gates
/// out of this crate, and honest null beats a made-up number.
// statvfs field widths differ per unix (fsblkcnt_t: u32 on macOS, u64 on
// Linux) — `u64::from` is required on one and "useless" on the other, so
// the lint cannot be satisfied on both. From (not `as`) keeps it lossless.
#[allow(clippy::useless_conversion)]
#[cfg(unix)]
fn disk_stats(path: &std::path::Path) -> Option<DiskStats> {
    use std::os::unix::ffi::OsStrExt as _;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut vfs: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut vfs) } != 0 {
        return None;
    }
    // u64::from, not `as`: fsblkcnt_t is u32 on macOS and u64 on Linux —
    // From compiles clean on both (identity impl on Linux), no lossy cast.
    let frsize = u64::from(vfs.f_frsize);
    Some(DiskStats {
        free: u64::from(vfs.f_bavail) * frsize,
        total: u64::from(vfs.f_blocks) * frsize,
    })
}

#[cfg(not(unix))]
fn disk_stats(_path: &std::path::Path) -> Option<DiskStats> {
    None
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
