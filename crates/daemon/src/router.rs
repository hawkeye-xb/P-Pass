//! ALPN router (T-030): accept inbound ctrl streams, run every request
//! through the authz checkpoint (§2.3), dispatch what's allowed.
//!
//! Denials answer `Resp{err: NOT_AUTHORIZED}` with the precise reason,
//! close the stream, and record a `authz.denied` diag event — the
//! self-diagnosis UI and log export feed on those.
//!
//! #1070: before authz, every request passes the protocol-version check
//! ([`OutdatedPeers::check`]). An incompatible peer gets `VERSION_MISMATCH`
//! and nothing else happens — no state is written.

use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use futures_core::Stream;
use proto::msgs::methods;
use proto::{Hello, Reason, Req, Resp, RespError, Versions, MIN_SUPPORTED_VER, PROTO_VER};
use storage::{Db, DiagEvent};
use transport::{BiStream, Incoming, Transport};

use crate::authz::{self, Decision};
use crate::events::{self, EventBus};
use crate::subscriptions::SubscriptionRegistry;

/// Capabilities this daemon ships. Grows with T-033 (thumbnail serving)
/// and later cards; hello advertises it from day one (决策 D 项).
///
/// NET-10 (#128): `pair.status.v1` = this daemon answers
/// `pair.request{ack_then_poll}` at once and serves `pair.status`. A new
/// phone checks it in the (unpaired-allowed) hello before pairing; without
/// it the phone reports "desktop too old" instead of timing out.
pub const SERVER_CAPABILITIES: &[&str] = &[
    "thumbnail.v1",
    PAIR_STATUS_CAPABILITY,
    PAIR_CANCEL_CAPABILITY,
    FLOW_SUPERSEDE_CAPABILITY,
];

/// #851: `flow.supersede.v1` = this daemon replaces a location-redacted copy with its original in
/// place (`flow.supersede`). A phone only re-reads its already-backed-up photos for this when hello
/// advertises it — against an older desktop the original would land as a second photo.
pub const FLOW_SUPERSEDE_CAPABILITY: &str = "flow.supersede.v1";

/// NET-10 (#128): see [`SERVER_CAPABILITIES`].
pub const PAIR_STATUS_CAPABILITY: &str = "pair.status.v1";

/// DEV-07 (#463): `pair.cancel.v1` = this daemon lets the submitting phone
/// withdraw a pending `pair.request`. A phone only sends `pair.cancel` when
/// hello advertises it, so an older desktop (which would deny the unknown
/// method and log a denial) is never probed with it.
pub const PAIR_CANCEL_CAPABILITY: &str = "pair.cancel.v1";

/// #1070: which paired-or-not peers last failed the protocol-version check,
/// and which side must update. Process-local on purpose: the check never
/// writes durable state (no revoke, no grant change, no device-row write).
/// Written by the ctrl plane and the download plane, read by the IPC device
/// list (`needs_update`). Cleared for a peer the moment it sends a
/// compatible request; a daemon restart forgets it until the next probe.
///
/// #1122：容量 [`OUTDATED_PEERS_CAPACITY`]，按最近使用淘汰——按设备增长的表一律有上限。
#[derive(Clone)]
pub struct OutdatedPeers {
    inner: Arc<Mutex<lru::LruCache<[u8; 32], Reason>>>,
}

/// #1122：版本不符登记表的容量。
pub const OUTDATED_PEERS_CAPACITY: usize = 1024;

impl Default for OutdatedPeers {
    fn default() -> Self {
        Self::with_capacity(OUTDATED_PEERS_CAPACITY)
    }
}

impl OutdatedPeers {
    pub fn new() -> Self {
        Self::default()
    }

    fn with_capacity(cap: usize) -> Self {
        Self {
            inner: Arc::new(Mutex::new(lru::LruCache::new(
                std::num::NonZeroUsize::new(cap).expect("nonzero capacity"),
            ))),
        }
    }

    /// The version check for one request from `peer`. `Err` is the error to
    /// answer with: `VERSION_MISMATCH`, `phone_outdated` / `desktop_outdated`,
    /// `params.min_ver` (the version the outdated side must reach), plus the
    /// frozen v1 shim when the envelope itself is v1.
    pub fn check(&self, peer: transport::NodeId, req: &Req) -> Result<(), RespError> {
        let peer_versions = req.versions();
        let verdict = proto::compatibility(Versions::LOCAL, peer_versions, proto::Role::Desktop);
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        match verdict {
            Ok(()) => {
                map.pop(&peer.0);
                Ok(())
            }
            Err(reason) => {
                let min_ver = match reason {
                    Reason::DesktopOutdated => peer_versions.min_ver,
                    _ => MIN_SUPPORTED_VER,
                };
                // One line per change, not per request: an old phone probes
                // every ~30 s in the foreground.
                if map.put(peer.0, reason.clone()).as_ref() != Some(&reason) {
                    tracing::info!(
                        "#1070: version mismatch peer={peer:?} peer_ver={} peer_min={} → {reason}",
                        peer_versions.ver,
                        peer_versions.min_ver
                    );
                }
                let mut error = RespError::new(reason).with_param("min_ver", min_ver);
                if peer_versions.ver <= proto::version::V1 {
                    error = error.with_v1_shim(&req.method);
                }
                Err(error)
            }
        }
    }

    /// Device-list projection: `"phone"` / `"desktop"` = which side must
    /// update for this NodeId to talk to us; `None` = no known mismatch.
    pub fn needs_update(&self, node_id: &[u8]) -> Option<&'static str> {
        let map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let key: [u8; 32] = node_id.try_into().ok()?;
        map.peek(&key).map(|reason| match reason {
            Reason::DesktopOutdated => "desktop",
            _ => "phone",
        })
    }
}

/// #1119：手机断开后等「已断开」回应送达的上限，过了就直接关连接。
const UNPAIR_REPLY_GRACE: std::time::Duration = std::time::Duration::from_secs(2);

/// `device.unpair` 的回应是不是「这次配对已删除」。
fn unpaired(resp: &Resp) -> bool {
    resp.ok
        && resp
            .result
            .as_ref()
            .and_then(|r| r.get("unpaired"))
            .and_then(|v| v.as_bool())
            == Some(true)
}

/// The ctrl-plane router: one per daemon process.
#[derive(Clone)]
pub struct Router {
    db: Db,
    device_name: String,
    pairing: Option<crate::pairing::Pairing>,
    backup: Option<crate::backup::BackupEngine>,
    flow_delivery: Option<crate::flow_delivery::FlowDelivery>,
    query: Option<crate::query::QueryEngine>,
    download: Option<crate::download::DownloadPlane>,
    /// IPC-02: 事件总线（可选——未注入时事件静默不发，测试/单组件
    /// 构造不受影响）。
    events: Option<EventBus>,
    /// SYNC-03: 与 IpcServer 共用同一份订阅登记表——未注入（`Router::new`
    /// 默认值）时是独立空表，`timeline.subscribe` 仍能跑但 revoke 摘不到
    /// 它（测试/单组件构造场景，不影响现有行为）。
    subscriptions: SubscriptionRegistry,
    /// #1070: shared with the IPC device list (see [`OutdatedPeers`]).
    outdated: OutdatedPeers,
    /// Clock seam (T-070 时钟前跳剧本): production uses the wall clock;
    /// integration scenarios inject a controllable clock.
    now: std::sync::Arc<dyn Fn() -> i64 + Send + Sync>,
    /// #1119：手机断开时关掉与它的全部连接。未注入 = 不关（测试 / 单组件构造）。
    peer_closer: Option<crate::unpair::PeerCloser>,
    /// #1122：没有配对记录的对端（只可能在配对窗口内进来）按设备限速。
    unpaired_limiter: crate::frame_limits::UnpairedLimiter,
}

impl Router {
    pub fn new(db: Db, device_name: impl Into<String>) -> Self {
        Self {
            db,
            device_name: device_name.into(),
            pairing: None,
            backup: None,
            flow_delivery: None,
            query: None,
            download: None,
            events: None,
            subscriptions: SubscriptionRegistry::new(),
            outdated: OutdatedPeers::new(),
            now: std::sync::Arc::new(unix_ms_now),
            peer_closer: None,
            unpaired_limiter: crate::frame_limits::unpaired_limiter(),
        }
    }

    /// #1119：注入「关掉与某台设备的全部连接」（main 传 `IrohTransport::close_peer`）。
    pub fn with_peer_closer(mut self, closer: crate::unpair::PeerCloser) -> Self {
        self.peer_closer = Some(closer);
        self
    }

    /// IPC-02: 注入事件总线——backup commit / unpair 等数据面变化
    /// 沿订阅通道即时通知桌面壳。
    pub fn with_events(mut self, events: EventBus) -> Self {
        self.events = Some(events);
        self
    }

    /// SYNC-03: 与 IpcServer 共用同一份订阅登记表（同一个实例 clone
    /// 两次），这样 `device.revoke`（IPC 侧）才能摘到 Router 侧注册的
    /// QUIC 订阅连接。
    pub fn with_subscriptions(mut self, subscriptions: SubscriptionRegistry) -> Self {
        self.subscriptions = subscriptions;
        self
    }

    /// #1070: share the version-mismatch registry with the IPC device list.
    pub fn with_outdated_peers(mut self, outdated: OutdatedPeers) -> Self {
        self.outdated = outdated;
        self
    }

    /// Override the clock (T-070): lets integration scenarios simulate a
    /// wall-clock jump without touching the system clock.
    pub fn with_clock(mut self, now: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.now = std::sync::Arc::new(now);
        self
    }

    /// Attach the download plane (T-056).
    pub fn with_download(mut self, download: crate::download::DownloadPlane) -> Self {
        self.download = Some(download);
        self
    }

    /// Attach the pairing engine (T-031). Without it, `pair.request`
    /// answers `unsupported_method`.
    pub fn with_pairing(mut self, pairing: crate::pairing::Pairing) -> Self {
        self.pairing = Some(pairing);
        self
    }

    /// Attach the backup engine (T-032). Without it, `backup.*` answers
    /// `unsupported_method`.
    pub fn with_backup(mut self, backup: crate::backup::BackupEngine) -> Self {
        self.backup = Some(backup);
        self
    }

    /// Attach the REBUILD-02 one-item native fetch/receipt adapter.
    pub fn with_flow_delivery(mut self, flow_delivery: crate::flow_delivery::FlowDelivery) -> Self {
        self.flow_delivery = Some(flow_delivery);
        self
    }

    /// Attach the query engine (T-033). Without it, browse methods
    /// answer `unsupported_method`.
    pub fn with_query(mut self, query: crate::query::QueryEngine) -> Self {
        self.query = Some(query);
        self
    }

    /// PRES-01: hello 的心跳落点——已配对未吊销设备刷新 last_seen。
    /// AUDIT-04 card decision #5: `device.connected`/hello/连接性从不写
    /// 任何长期审计表（audit_operation 及其余三张）；presence 完全由
    /// `last_seen` + 实时连接状态派生，不需要、也不允许一条持久审计行。
    /// 失败静默：心跳是尽力而为的加速器，不是承诺——写库失败不影响
    /// hello 应答。
    async fn record_presence(&self, peer: transport::NodeId) {
        // 只刷新有配对记录的设备（没有配对 = hello 只是能力握手，不产生副作用）。
        if self.db.active_pairing(&peer.0).is_none() {
            return;
        }
        let now = (self.now)();
        let _ = self.db.touch_last_seen(&peer.0, now).await;
    }

    /// Accept-loop over inbound connections. Runs until the transport
    /// closes. Each connection is served on its own task.
    pub async fn serve<T: Transport>(&self, transport: &T) {
        let incoming = transport.listen().await;
        tokio::pin!(incoming);
        while let Some(conn) = next_item(incoming.as_mut()).await {
            let router = self.clone();
            tokio::spawn(async move { router.serve_conn(conn).await });
        }
    }

    /// Serve one connection: streams arrive sequentially; each stream is
    /// one request/response exchange (MVP framing).
    pub async fn serve_conn(&self, conn: Incoming) {
        // Data-plane dispatch: download connections never speak ctrl.
        if conn.alpn() == transport::ALPN_DOWNLOAD {
            if let Some(download) = &self.download {
                download.serve_conn(conn, &self.outdated).await;
            }
            return;
        }
        let peer = conn.peer();
        loop {
            let Ok(mut stream) = conn.accept_bi().await else {
                return; // peer went away — nothing to clean up
            };
            let router = self.clone();
            // Streams are independent; serve each to completion in turn.
            // (Parallel streams per connection can land later if a card
            // needs them — the protocol allows it.)
            if !router.serve_stream(peer, &mut stream).await {
                // The rejected stream is terminal, but the connection stays
                // reusable. Every later stream enters authz again, so a
                // revoked peer remains denied until an owner re-pairs it.
                continue;
            }
        }
    }

    /// One request/response on one stream. A rejected stream does not carry
    /// on; the caller may accept another stream, which must pass authz again.
    async fn serve_stream(&self, peer: transport::NodeId, stream: &mut BiStream) -> bool {
        // #1117：授权只读配对记录的内存副本，不查库。#1122：读帧之前就用它定上限、
        // 给未配对的对端限速——超速的流一个字节都不读。
        let pairing = self.db.active_pairing(&peer.0);
        if pairing.is_none() && self.unpaired_limiter.check_key(&peer).is_err() {
            return false;
        }
        let cap = crate::frame_limits::pre_read_cap(pairing.as_ref());
        let (req, frame_len) = match stream.recv_frame_max(cap).await {
            Ok(Some(frame)) => match proto::codec::decode::<Req>(&frame) {
                Ok(req) => (req, frame.len()),
                Err(_) => {
                    let resp = Resp::err(String::new(), RespError::new(Reason::BadRequest));
                    let _ = self.send(stream, &resp).await;
                    return false;
                }
            },
            Ok(None) => return false, // clean finish
            Err(transport::TransportError::FrameTooLarge { .. }) => {
                let resp = Resp::err(String::new(), RespError::new(Reason::BadRequest));
                let _ = self.send(stream, &resp).await;
                return false;
            }
            Err(_) => return false, // broken stream or slow sender (#1122)
        };
        // #1122：按方法核对——只有确实需要大消息的方法才放宽。
        if frame_len > crate::frame_limits::method_cap(&req.method) as usize + 4 {
            let resp = Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
            let _ = self.send(stream, &resp).await;
            return false;
        }

        // #1070: version first — an incompatible peer is told to update and
        // nothing else is looked at or written (not even a diag row: an old
        // phone probes every ~30 s).
        if let Err(error) = self.outdated.check(peer, &req) {
            let _ = self.send(stream, &Resp::err(req.id.clone(), error)).await;
            return false;
        }

        match authz::check(pairing.as_ref(), &req.method) {
            Decision::Deny { reason } => {
                // QA-17：diag 必须先于拒答响应落库。曾经先发响应再记
                // diag——客户端收到 NOT_AUTHORIZED 的瞬间即可读 diag，
                // 两条 sqlx 命令的调度顺序没保证，整轮并行下偶发断言
                // 跑在 INSERT 之前（压 29 轮 1 红，见 #357）。
                self.record_denial(peer, &req.method, &reason).await;
                let resp = Resp::err(req.id.clone(), RespError::new(reason));
                let _ = self.send(stream, &resp).await;
                false // 关流 (§2.3: deny closes the connection)
            }
            Decision::Allow => {
                if req.method == methods::TIMELINE_SUBSCRIBE {
                    return self.serve_subscription(peer, stream, &req).await;
                }
                let resp = self.dispatch(peer, &req).await;
                let _ = self.send(stream, &resp).await;
                // #1119：手机自己断开、配对记录已删——先让「已断开」的回应送达
                // （连接关闭会丢弃未送达的数据，最多等 2 秒），再关掉与它的全部
                // 连接。电脑撤销走 IPC，不经过这里，删完立即关。
                if req.method == methods::DEVICE_UNPAIR && unpaired(&resp) {
                    if let Some(close) = &self.peer_closer {
                        let _ = tokio::time::timeout(UNPAIR_REPLY_GRACE, stream.delivered()).await;
                        let closed = close(peer);
                        tracing::info!(
                            "#1119: device unpaired, closed {closed} connection(s) peer={peer:?}"
                        );
                    }
                    return false;
                }
                true
            }
        }
    }

    /// `timeline.subscribe`（SYNC-03）：应答后连接不 `finish`，转入
    /// 推送态——只推 `timeline.invalidated`（不带数据），直到吊销/客户端
    /// 断开/daemon 退出。取数据永远走独立鉴权的普通请求（同一条 QUIC
    /// 连接上的另一条 stream），这条流从头到尾不传照片内容。
    async fn serve_subscription(
        &self,
        peer: transport::NodeId,
        stream: &mut BiStream,
        req: &Req,
    ) -> bool {
        // REV-01 #1：register 提到最前——订阅请求一进来就登记，吊销窗口
        // 覆盖整个订阅生命周期。此前 register 排在 ack/initial push 之后，
        // owner 若恰好在那个窗口 revoke，ipc.rs 查表摘不到这条尚未登记的
        // 订阅（no-op），订阅继续活着直到自然断开——微秒级窗口但零成本
        // 顺手修（register 本身不依赖事件总线/ack 是否发出）。
        let (token, generation) = self.subscriptions.register(peer);

        let ack = Resp::ok(req.id.clone(), serde_json::json!({ "subscribed": true }));
        if self.send_push(stream, &ack).await.is_err() {
            self.subscriptions.unregister(peer, generation);
            return false;
        }
        // §③ 订阅即返回当前态：立即给这个新订阅者推一次，不广播给别人、
        // 不等下一次真实变更。
        if self
            .send_push(
                stream,
                &serde_json::json!({ "event": events::TIMELINE_INVALIDATED, "data": {} }),
            )
            .await
            .is_err()
        {
            self.subscriptions.unregister(peer, generation);
            return false;
        }

        let Some(bus) = &self.events else {
            // 没接事件总线（单组件构造/测试）——退化为一次性 ack，
            // 结束这条流，不假装能推送。
            self.subscriptions.unregister(peer, generation);
            let _ = stream.finish();
            return true;
        };
        let mut rx = bus.subscribe();
        // DIAG-B2：订阅的一生都留痕——手机侧说"推送没到"时，先看这条订阅
        // 在推送那一刻是不是还活着、是怎么结束的。
        let started = std::time::Instant::now();
        tracing::info!("subscription open peer={peer:?} gen={generation}");

        // 客户端预期只发一次订阅请求就半关闭发送方向（拿数据走别的
        // stream）；`Ok(None)` 之后不再 select 这个分支，避免忙等。
        let mut client_send_open = true;
        let end_reason: String = loop {
            tokio::select! {
                _ = token.cancelled() => break "revoked".to_string(),
                frame = stream.recv_frame_max(crate::frame_limits::PAIRING_FRAME_MAX), if client_send_open => {
                    match frame {
                        Ok(Some(_)) => continue, // 这条流上的多余数据——忽略
                        Ok(None) => { client_send_open = false; continue; }
                        Err(e) => break format!("recv_error: {e}"), // 连接异常
                    }
                }
                ev = rx.recv() => {
                    match ev {
                        Ok(v) if v.get("event").and_then(|e| e.as_str())
                            == Some(events::TIMELINE_INVALIDATED) =>
                        {
                            if let Err(e) = self.send_push(stream, &v).await {
                                break format!("write_error(timeline.invalidated): {e}"); // 写失败 = 连接真的断了
                            }
                        }
                        // NET-14: 完成/失败推送——只转发给这条订阅所属的那台
                        // 手机（按 node_id 过滤），不是广播给所有订阅者。
                        // 这条流原本只推 timeline.invalidated（决策档案 §⑦：
                        // 不传照片内容），完成回执/失败码不是照片内容，是
                        // 控制面事实，符合这条流的既有边界。
                        Ok(v) if matches!(
                            v.get("event").and_then(|e| e.as_str()),
                            Some(events::FLOW_DELIVERED) | Some(events::FLOW_FAILED)
                        ) =>
                        {
                            let for_this_peer = v
                                .get("data")
                                .and_then(|d| d.get("node_id"))
                                .and_then(|n| n.as_str())
                                == Some(peer.to_string().as_str());
                            if !for_this_peer {
                                continue;
                            }
                            // DIAG-B2：推送真正写进这条订阅流的那一刻（或写失败）。
                            // flow_delivery 那行 `peer_subscribed=` 只说明"表里有这台
                            // 手机"，这一行才说明"字节交给了 QUIC"。
                            let kind = v.get("event").and_then(|e| e.as_str()).unwrap_or("?");
                            let seq = v
                                .get("data")
                                .and_then(|d| d.get("queue_sequence"))
                                .cloned()
                                .unwrap_or_default();
                            match self.send_push(stream, &v).await {
                                Ok(()) => tracing::info!(
                                    "subscription push sent kind={kind} seq={seq} peer={peer:?} gen={generation}"
                                ),
                                Err(e) => {
                                    tracing::warn!(
                                        "subscription push write failed kind={kind} seq={seq} peer={peer:?} gen={generation}: {e}"
                                    );
                                    break format!("write_error({kind}): {e}");
                                }
                            }
                        }
                        Ok(_) => continue, // 只推 timeline.invalidated，别的事件不转发
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            // DIAG-B2：被挤掉的 n 条里可能正好有 flow.delivered——
                            // 以前这里静默 continue，丢了都不知道。
                            tracing::warn!(
                                "subscription lagged peer={peer:?} gen={generation}: skipped {n} events (may include flow.delivered)"
                            );
                            continue;
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break "bus_closed".to_string(),
                    }
                }
            }
        };
        tracing::info!(
            "subscription closed peer={peer:?} gen={generation} after {}ms reason={end_reason}",
            started.elapsed().as_millis()
        );
        self.subscriptions.unregister(peer, generation);
        let _ = stream.finish();
        true
    }

    /// 推送态下发一个 JSON 帧（ack 或事件），不 `finish` 发送方向。
    async fn send_push(
        &self,
        stream: &mut BiStream,
        value: &impl serde::Serialize,
    ) -> transport::Result<()> {
        let frame = proto::codec::encode(value)
            .map_err(|e| transport::TransportError::Io(e.to_string()))?;
        stream.send_frame(&frame).await
    }

    /// Method dispatch for authorized requests. T-030 ships `hello`,
    /// T-031 adds `pair.request`; every later card plugs in here.
    async fn dispatch(&self, peer: transport::NodeId, req: &Req) -> Resp {
        match req.method.as_str() {
            methods::PAIR_REQUEST => self.handle_pair(peer, req).await,
            methods::PAIR_STATUS => self.handle_pair_status(peer, req),
            methods::PAIR_CANCEL => self.handle_pair_cancel(peer, req).await,
            methods::PAIR_CONFIRM => self.handle_pair_confirm(peer, req).await,
            methods::DEVICE_UNPAIR => self.handle_unpair(peer, req).await,
            methods::FLOW_OFFER => self.handle_flow_delivery(peer, req).await,
            methods::FLOW_STATUS | methods::FLOW_SUSPEND | methods::FLOW_CANCEL_TUPLE => {
                self.handle_flow_control(peer, req).await
            }
            methods::FLOW_AUDIT_SUBMIT => self.handle_flow_audit_submit(peer, req).await,
            methods::FLOW_SUPERSEDE => self.handle_flow_supersede(peer, req).await,
            methods::BACKUP_BEGIN
            | methods::BACKUP_MANIFEST
            | methods::BACKUP_PRESENCE
            | methods::BACKUP_COMMIT => self.handle_backup(peer, req).await,
            methods::TIMELINE_PAGE
            | methods::ASSET_META
            | methods::THUMB_GET
            | methods::ASSET_BLOB_TICKET => self.handle_query(req).await,
            methods::HELLO => {
                // PRES-01: hello 是「我还活着」的轻信号——已配对未吊销的
                // 设备每次 hello 更新 last_seen（三档在线态的数据源）+
                // 记 device.connected 审计（同设备 10 分钟内去重防刷屏）。
                // 复用 hello 不加协议动词的理由：hello 是唯一对成员/未配对
                // 都放行的零数据方法，能力握手语义天然合适；新加轻方法要
                // 动 authz + 双端协议，收益为零。红线：不参与鉴权、后台
                // 不心跳（客户端侧把关）。未配对节点的 hello 只是能力握手，
                // 无设备行可更新，静默跳过。
                self.record_presence(peer).await;
                let pairing_id = self.db.active_pairing(&peer.0).map(|p| p.id);
                // #413 §7: Desktop health rides on hello for a paired member
                // only — same zero-data rule as `pairing_id`.
                let health = match (&pairing_id, &self.flow_delivery) {
                    (Some(_), Some(delivery)) => Some(delivery.health(peer).await),
                    _ => None,
                };
                let ours = Hello {
                    proto_ver: PROTO_VER,
                    capabilities: SERVER_CAPABILITIES.iter().map(|s| s.to_string()).collect(),
                    device_name: self.device_name.clone(),
                    pairing_id,
                    health,
                };
                match serde_json::to_value(&ours) {
                    Ok(v) => Resp::ok(req.id.clone(), v),
                    Err(_) => Resp::err(req.id.clone(), RespError::new(Reason::Internal)),
                }
            }
            // Authorized but not implemented yet (T-031..T-033 land them).
            _ => Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod)),
        }
    }

    /// Browse methods (T-033): timeline pages, per-asset metadata,
    /// thumbnails (base64 JPEG in-frame), blob tickets for originals.
    async fn handle_query(&self, req: &Req) -> Resp {
        let Some(query) = &self.query else {
            return Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod));
        };
        let bad_request = || Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        let not_found = || Resp::err(req.id.clone(), RespError::new(Reason::NotFound));
        let ok_or = |id: &str, v: Result<serde_json::Value, serde_json::Error>| match v {
            Ok(v) => Resp::ok(id.to_string(), v),
            Err(_) => Resp::err(id.to_string(), RespError::new(Reason::Internal)),
        };
        match req.method.as_str() {
            methods::TIMELINE_PAGE => {
                let Ok(q) = serde_json::from_value::<proto::TimelineQuery>(req.params.clone())
                else {
                    return bad_request();
                };
                match query.timeline(&q).await {
                    Ok(page) => ok_or(&req.id, serde_json::to_value(&page)),
                    Err(_) => not_found(),
                }
            }
            methods::ASSET_META => {
                let Some(hash) = req.params.get("hash").and_then(|v| v.as_str()) else {
                    return bad_request();
                };
                match query.asset_meta(hash).await {
                    Ok(meta) => ok_or(&req.id, serde_json::to_value(&meta)),
                    Err(_) => not_found(),
                }
            }
            methods::THUMB_GET => {
                let Ok(t) = serde_json::from_value::<proto::ThumbGet>(req.params.clone()) else {
                    return bad_request();
                };
                // DESK-34 (#428): phones get the same placeholder marker;
                // the fields are skipped on real thumbs, and old Android
                // builds ignore unknown keys (`ProtoJson.ignoreUnknownKeys`).
                match query.thumb_reply(&t).await {
                    Ok(reply) => ok_or(&req.id, serde_json::to_value(reply.into_wire())),
                    Err(_) => not_found(),
                }
            }
            _ => {
                let Some(hash) = req.params.get("hash").and_then(|v| v.as_str()) else {
                    return bad_request();
                };
                match query.blob_ticket(hash).await {
                    Ok(ticket) => ok_or(&req.id, serde_json::to_value(&ticket)),
                    Err(_) => not_found(),
                }
            }
        }
    }

    /// `flow.offer`: registers the grant and starts the native fetch task.
    /// The result is read through `flow.status` / the delivered push; this
    /// call never blocks on the data plane. It does not call the frozen
    /// batch backup engine.
    async fn handle_flow_delivery(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(delivery) = &self.flow_delivery else {
            return Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod));
        };
        let Ok(flow) = serde_json::from_value::<proto::FlowFetchRequest>(req.params.clone()) else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        // NET-24: `flow.offer` used to be hard-wired to a null reply
        // (`.map(|_| None)`), which threw away a terminal receipt the
        // daemon was already holding — the phone then had to learn about
        // it from a push it had not subscribed for yet, and fell back to a
        // 30s local-idle timeout. It now answers with the same
        // `FlowStatusReply` a `status()` call would give.
        let result = delivery.offer(peer, &flow).await.map(serde_json::to_value);
        match result {
            Ok(Ok(value)) => Resp::ok(req.id.clone(), value),
            Ok(Err(_)) => Resp::err(req.id.clone(), RespError::new(Reason::Internal)),
            // #413 contract §5 / #1070: every refusal names its reason —
            // a Desktop-side storage refusal (`storage_full` /
            // `library_unavailable` / `storage_failed`) lets the phone wait
            // with the right cause instead of counting a per-item failure.
            Err(error) => {
                tracing::warn!(
                    "flow delivery from {peer:?} refused ({}): {error}",
                    error.wire_code()
                );
                Resp::err(req.id.clone(), RespError::new(error.wire_code()))
            }
        }
    }

    /// NET-06: control-plane methods for one exact grant tuple. Unlike
    /// `handle_flow_delivery`, these never touch the data plane — `status`
    /// answers from durable state (+ a process-local task fact); `suspend`
    /// only aborts a task handle if one is running; `cancel_tuple` marks
    /// the grant Cancelled using the daemon's own stored content_hash/
    /// provider (no caller-supplied `FlowFetchRequest` needed). All three
    /// must always answer within the ordinary control RPC timeout, on any
    /// network condition.
    async fn handle_flow_control(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(delivery) = &self.flow_delivery else {
            return Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod));
        };
        let Ok(tuple) = serde_json::from_value::<proto::FlowTupleRef>(req.params.clone()) else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        match req.method.as_str() {
            methods::FLOW_STATUS => match delivery.status(peer, &tuple).await {
                Ok(reply) => match serde_json::to_value(reply) {
                    Ok(value) => Resp::ok(req.id.clone(), value),
                    Err(_) => Resp::err(req.id.clone(), RespError::new(Reason::Internal)),
                },
                // status is read-only and has no GrantNotFound path in
                // practice (a missing/mismatched tuple resolves to
                // `not_found` inside `status()`, not an error) — this arm
                // exists for exhaustiveness against DeliveryError's other
                // variants (storage failure, etc.).
                Err(error) => {
                    tracing::warn!("flow status from {peer:?} failed: {error}");
                    Resp::err(req.id.clone(), RespError::new(Reason::Internal))
                }
            },
            methods::FLOW_SUSPEND => match delivery.suspend(peer, &tuple).await {
                Ok(()) => Resp::ok(req.id.clone(), serde_json::Value::Null),
                Err(error) => {
                    tracing::warn!("flow suspend from {peer:?} failed: {error}");
                    Resp::err(req.id.clone(), RespError::new(error.wire_code()))
                }
            },
            methods::FLOW_CANCEL_TUPLE => match delivery.cancel_by_tuple(peer, &tuple).await {
                Ok(()) => Resp::ok(req.id.clone(), serde_json::Value::Null),
                Err(error) => {
                    tracing::warn!("flow cancel_tuple from {peer:?} failed: {error}");
                    Resp::err(req.id.clone(), RespError::new(error.wire_code()))
                }
            },
            _ => unreachable!(
                "dispatch only calls this for flow.status/flow.suspend/flow.cancel_tuple"
            ),
        }
    }

    /// AUDIT-04: batch delivery for the phone's durable Flow audit outbox.
    /// Each event carries its own event_id (minted once on the phone),
    /// so appending it here is idempotent — a retransmitted batch after a
    /// lost response never duplicates a row. Every event is routed onto the
    /// canonical `audit_operation`/`audit_item_evidence`/`audit_tombstone`/
    /// `audit_decision` tables by [`crate::audit_route::route`] — this
    /// method itself no longer decides where a fact lands (card decision
    /// #2/#9 supersede AUDIT-01's single-bucket `audit_event`). Returns
    /// exactly the ids that are now durably present (freshly inserted or
    /// already there from an earlier delivery) so the phone acknowledges
    /// only those and keeps anything else queued for the next flush.
    /// #851: see [`crate::flow_delivery::FlowDelivery::supersede`]. Refusals are an ordinary
    /// reply (`outcome = "refused"`), not an error — the phone just leaves that photo as it is.
    async fn handle_flow_supersede(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let (Some(delivery), Ok(request)) = (
            &self.flow_delivery,
            serde_json::from_value::<proto::FlowSupersedeRequest>(req.params.clone()),
        ) else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        match delivery.supersede(peer, &request).await {
            Ok(reply) => match serde_json::to_value(reply) {
                Ok(value) => Resp::ok(req.id.clone(), value),
                Err(_) => Resp::err(req.id.clone(), RespError::new(Reason::Internal)),
            },
            Err(error) => {
                tracing::warn!("flow supersede from {peer:?} failed: {error}");
                Resp::err(req.id.clone(), RespError::new(error.wire_code()))
            }
        }
    }

    async fn handle_flow_audit_submit(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Ok(submit) = serde_json::from_value::<proto::FlowAuditSubmit>(req.params.clone())
        else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        let mut accepted = Vec::with_capacity(submit.events.len());
        for event in &submit.events {
            if event.event_id.is_empty() || event.kind.is_empty() {
                continue;
            }
            let fact = crate::audit_route::FlowAuditFact {
                event_id: &event.event_id,
                kind: &event.kind,
                round_id: event.round_id.as_deref(),
                occurred_at_ms: event.occurred_at_ms,
                payload: &event.payload,
            };
            if crate::audit_route::route(&self.db, &peer.0, &fact).await {
                accepted.push(event.event_id.clone());
            } else {
                tracing::warn!(
                    "flow.audit.submit routing failed for {peer:?}: kind={}",
                    event.kind
                );
            }
        }
        if !accepted.is_empty() {
            if let Some(bus) = &self.events {
                events::emit(
                    bus,
                    events::ACTIVITY_APPENDED,
                    serde_json::json!({ "node_id": peer.to_string() }),
                );
            }
        }
        match serde_json::to_value(proto::FlowAuditAccepted {
            event_ids: accepted,
        }) {
            Ok(v) => Resp::ok(req.id.clone(), v),
            Err(_) => Resp::err(req.id.clone(), RespError::new(Reason::Internal)),
        }
    }

    /// `backup.*` (T-032): manifest 查重回 missing → 拉取+ingest → commit
    /// 更新水位. Failures answer INTERNAL/err.backup_failed — the client
    /// retries and the pipeline converges (idempotent).
    async fn handle_backup(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(backup) = &self.backup else {
            return Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod));
        };
        let internal_err =
            |id: &str| Resp::err(id.to_string(), RespError::new(Reason::BackupFailed));
        match req.method.as_str() {
            methods::BACKUP_BEGIN => {
                backup.begin(peer);
                // AUDIT-01: legacy batch backup sessions are explicitly out
                // of the v2 event matrix (card decision #4/#5) — no longer
                // written to the long-term audit trail.
                Resp::ok(req.id.clone(), serde_json::Value::Null)
            }
            methods::BACKUP_MANIFEST => {
                let Ok(m) = serde_json::from_value::<proto::BackupManifest>(req.params.clone())
                else {
                    return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
                };
                match backup.manifest(peer, &m).await {
                    Ok(missing) => match serde_json::to_value(&missing) {
                        Ok(v) => Resp::ok(req.id.clone(), v),
                        Err(_) => internal_err(&req.id),
                    },
                    Err(e) => {
                        tracing::warn!("backup.manifest from {peer:?} failed: {e}");
                        internal_err(&req.id)
                    }
                }
            }
            methods::BACKUP_PRESENCE => {
                let Ok(query) =
                    serde_json::from_value::<proto::BackupPresenceQuery>(req.params.clone())
                else {
                    return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
                };
                match backup.presence(&query.hashes).await {
                    Ok(missing) => match serde_json::to_value(&missing) {
                        Ok(v) => Resp::ok(req.id.clone(), v),
                        Err(_) => internal_err(&req.id),
                    },
                    Err(crate::backup::BackupError::InvalidPresenceQuery) => {
                        Resp::err(req.id.clone(), RespError::new(Reason::BadRequest))
                    }
                    Err(e) => {
                        tracing::warn!("backup.presence from {peer:?} failed: {e}");
                        internal_err(&req.id)
                    }
                }
            }
            _ => {
                let generation = serde_json::from_value::<proto::BackupCommit>(req.params.clone())
                    .map(|c| c.generation)
                    .unwrap_or(None);
                match backup.commit(peer, generation).await {
                    Ok(outcome) => {
                        tracing::info!(
                            "backup.commit from {peer:?}: +{} ({} dup)",
                            outcome.ingested,
                            outcome.duplicates
                        );
                        // AUDIT-01: legacy batch backup completions are
                        // explicitly out of the v2 event matrix (card
                        // decision #4/#5) — no longer written to the
                        // long-term audit trail; the activity stream event
                        // below still carries the ingested/duplicates count
                        // for the UI.
                        // IPC-02: 备份批次落地——桌面活动流/水位即时更新。
                        if let Some(bus) = &self.events {
                            events::emit(
                                bus,
                                events::ACTIVITY_APPENDED,
                                serde_json::json!({
                                    "node_id": peer.to_string(),
                                    "ingested": outcome.ingested,
                                    "duplicates": outcome.duplicates,
                                }),
                            );
                            events::emit(
                                bus,
                                events::DEVICE_CHANGED,
                                serde_json::json!({ "node_id": peer.to_string() }),
                            );
                        }
                        Resp::ok(
                            req.id.clone(),
                            serde_json::json!({
                                "ingested": outcome.ingested,
                                "duplicates": outcome.duplicates,
                            }),
                        )
                    }
                    Err(e) => {
                        tracing::warn!("backup.commit from {peer:?} failed: {e}");
                        internal_err(&req.id)
                    }
                }
            }
        }
    }

    /// `pair.request` (T-031): token check → queued for owner confirmation
    /// → `PairSubmitted`; the verdict (and the device row) comes through
    /// `pair.status`. Every token rejection is the same NOT_AUTHORIZED —
    /// a prober learns nothing about which part failed.
    async fn handle_pair(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(pairing) = &self.pairing else {
            return Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod));
        };
        let Ok(pair_req) = serde_json::from_value::<proto::PairRequest>(req.params.clone()) else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        // #1050: the blocking shape (hold the RPC open until the owner
        // clicks) is retired. A request that does not ask for accept-then-
        // poll comes from a phone older than the supported minimum; say so
        // explicitly instead of silently serving it the new shape it cannot
        // decode. Checked before the token so an old phone never burns a
        // one-time token on a reply it cannot read.
        if !pair_req.ack_then_poll {
            return Resp::err(req.id.clone(), RespError::new(Reason::PhoneOutdated));
        }
        // #1118: no pairing code exchange = a phone older than the code step; same rule, same
        // place (before the token is used up).
        if pair_req.pake_a.trim().is_empty() {
            return Resp::err(req.id.clone(), RespError::new(Reason::PhoneOutdated));
        }
        // NET-10 (#128): accept-then-poll — answer as soon as the request
        // is queued; the verdict is read through `pair.status`. A bad or
        // replayed token is still the same immediate NOT_AUTHORIZED.
        match pairing.submit_request(peer, &pair_req, (self.now)()).await {
            Ok(sub) => ok_json(
                &req.id,
                &proto::PairSubmitted {
                    accepted: true,
                    request_id: sub.request_id,
                    ttl_ms: sub.ttl_ms,
                },
            ),
            // #1118: a malformed SPAKE2 message is a broken request, not a probe of the token.
            Err(crate::pairing::PairRejection::BadPake) => {
                Resp::err(req.id.clone(), RespError::new(Reason::BadRequest))
            }
            Err(_) => {
                self.record_denial(peer, methods::PAIR_REQUEST, &Reason::PairTokenInvalid)
                    .await;
                Resp::err(req.id.clone(), RespError::new(Reason::PairTokenInvalid))
            }
        }
    }

    /// `pair.status` (NET-10 #128): read the pairing ledger for one
    /// request_id. Control-plane, never waits. authz lets any caller in
    /// (see `authz.rs`); the scoping happens here: a caller only ever sees
    /// the requests **its own NodeId** submitted — anyone else's id reads
    /// as `not_found`, same as an id that never existed.
    fn handle_pair_status(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(pairing) = &self.pairing else {
            return Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod));
        };
        let Ok(query) = serde_json::from_value::<proto::PairStatusRequest>(req.params.clone())
        else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        let view = pairing.view(peer, &query.request_id, (self.now)());
        ok_json(&req.id, &self.pair_status_reply(view))
    }

    /// `pair.confirm` (#1118): the phone's key confirmation for its own request. Same scoping
    /// as `pair.status`. A match writes the pairing record and the reply carries `accepted` +
    /// `confirm_b`; a mismatch voids the request (`pair_code_wrong`, audited as
    /// `pair.code_failed`); before the owner typed the code there is nothing to confirm.
    async fn handle_pair_confirm(&self, peer: transport::NodeId, req: &Req) -> Resp {
        use crate::pairing::ConfirmError;
        let Some(pairing) = &self.pairing else {
            return Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod));
        };
        let Ok(query) = serde_json::from_value::<proto::PairConfirmRequest>(req.params.clone())
        else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        let Some(confirm_a) = parse_hex_exact(&query.confirm_a, pair_pake::CONFIRM_LEN) else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        match pairing
            .confirm_code(peer, &query.request_id, &confirm_a, (self.now)())
            .await
        {
            Ok(view) => ok_json(&req.id, &self.pair_status_reply(Some(view))),
            Err(ConfirmError::NotFound) => ok_json(&req.id, &self.pair_status_reply(None)),
            Err(ConfirmError::NotReady) => {
                Resp::err(req.id.clone(), RespError::new(Reason::BadRequest))
            }
            Err(ConfirmError::CodeWrong) => {
                Resp::err(req.id.clone(), RespError::new(Reason::PairCodeWrong))
            }
        }
    }

    /// `pair.cancel` (DEV-07 #463): the submitting phone withdraws its own
    /// pending request. Same params, reply shape and scoping as
    /// `pair.status` — another NodeId's id reads `not_found` and is not
    /// touched. The reply is the state after the withdrawal: `expired` for
    /// a request that was still pending (the owner's queue row can no
    /// longer be approved), or the verdict that had already landed.
    async fn handle_pair_cancel(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(pairing) = &self.pairing else {
            return Resp::err(req.id.clone(), RespError::new(Reason::UnsupportedMethod));
        };
        let Ok(query) = serde_json::from_value::<proto::PairStatusRequest>(req.params.clone())
        else {
            return Resp::err(req.id.clone(), RespError::new(Reason::BadRequest));
        };
        let state = pairing.cancel(peer, &query.request_id, (self.now)()).await;
        let view = state.map(|state| crate::pairing::TicketView {
            state,
            pake_b: None,
            confirm_b: None,
        });
        ok_json(&req.id, &self.pair_status_reply(view))
    }

    /// Ledger state → wire reply, shared by `pair.status` and `pair.cancel`.
    fn pair_status_reply(
        &self,
        view: Option<crate::pairing::TicketView>,
    ) -> proto::PairStatusReply {
        use crate::pairing::PairState;
        use proto::PairStatusState as S;
        let only = |state| proto::PairStatusReply {
            state,
            ..Default::default()
        };
        let Some(view) = view else {
            return only(S::NotFound);
        };
        match view.state {
            // #1118: once the owner typed the code, the phone reads the desktop's answer here.
            PairState::Pending => proto::PairStatusReply {
                state: S::Pending,
                pake_b: view.pake_b.as_deref().map(hex_lower),
                ..Default::default()
            },
            // Idempotent replay: the same payload, plus the desktop's key confirmation.
            PairState::Accepted { pairing_id } => proto::PairStatusReply {
                state: S::Accepted,
                accepted: Some(proto::PairAccepted {
                    storage_device_name: self.device_name.clone(),
                    pairing_id,
                }),
                confirm_b: view.confirm_b.as_ref().map(|c| hex_lower(c)),
                ..Default::default()
            },
            PairState::Denied => only(S::Denied),
            PairState::Expired => only(S::Expired),
            PairState::Failed => only(S::Failed),
        }
    }

    /// `device.unpair` (UX-06): the caller ends ITS OWN pairing. Unilateral
    /// stop — no owner action needed. #1117: the pairing record is deleted
    /// through the single entry [`crate::unpair`] (same path as an owner
    /// revoke: in-flight fetches, backup session and subscriptions go with
    /// it); the device profile stays and is listed as "disconnected".
    ///
    /// #565：可选参数 `pairing_id` = 手机要结束的**那一次**配对。带了就只删 id
    /// 一致的那条（不一致 = 那次配对已被新配对取代或早已结束，什么都不动，照样
    /// 答 ok——手机要的「这次配对已结束」已经成立）；不带 = 删它当前的配对。
    async fn handle_unpair(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let expect_id = req.params.get("pairing_id").and_then(|v| v.as_str());
        let holders = crate::unpair::Holders {
            flow: self.flow_delivery.as_ref(),
            backup: self.backup.as_ref(),
            subscriptions: Some(&self.subscriptions),
            // 连接在回应送达之后再关（见 serve_stream）。
            connections: None,
        };
        // DEV-03：记下是**设备自己**断的。业主没做过这个决定，所以这台设备
        // 留在「家人与设备」里标「已断开」，而不是凭空消失。
        let removed = crate::unpair::remove_pairing(
            &self.db,
            holders,
            peer,
            expect_id,
            storage::DepartedBy::Device,
            (self.now)(),
        )
        .await;
        match removed {
            Ok(None) => {
                tracing::info!("#565: device.unpair named a pairing that is no longer current; nothing removed");
                Resp::ok(req.id.clone(), serde_json::json!({ "unpaired": false }))
            }
            Ok(Some(_)) => {
                crate::pairing::warn_if_audit_failed(
                    "device.unpaired",
                    self.db
                        .append_audit(&storage::AuditEntry::local(
                            (self.now)(),
                            Some(peer.0.to_vec()), // 设备自己断开（UX-06）
                            "device.unpaired",
                            None,
                            None,
                        ))
                        .await,
                );
                // IPC-02: 设备自己断开——桌面设备行即时刷新，状态变成「已断开」。
                if let Some(bus) = &self.events {
                    events::emit(
                        bus,
                        events::DEVICE_CHANGED,
                        serde_json::json!({ "node_id": peer.to_string() }),
                    );
                    events::emit(
                        bus,
                        events::ACTIVITY_APPENDED,
                        serde_json::json!({ "action": "device.unpaired" }),
                    );
                }
                Resp::ok(req.id.clone(), serde_json::json!({ "unpaired": true }))
            }
            Err(_) => Resp::err(req.id.clone(), RespError::new(Reason::Internal)),
        }
    }

    async fn send(&self, stream: &mut BiStream, resp: &Resp) -> transport::Result<()> {
        let frame =
            proto::codec::encode(resp).map_err(|e| transport::TransportError::Io(e.to_string()))?;
        stream.send_frame(&frame).await?;
        stream.finish()
    }

    async fn record_denial(&self, peer: transport::NodeId, method: &str, reason: &Reason) {
        let detail =
            // #544：diag 库里只存前缀（`{:?}` = 前 5 字节），全长 NodeId 不落库。
            format!("{{\"peer\":\"{peer:?}\",\"method\":\"{method}\",\"reason\":\"{reason}\"}}",);
        let event = DiagEvent {
            ts: unix_ms_now(),
            kind: "authz.denied".into(),
            detail: Some(detail),
        };
        if let Err(e) = self.db.append_diag(&event).await {
            tracing::error!("diag append failed: {e}");
        }
    }
}

/// Serialize an ok reply; a serializer failure is INTERNAL (same fallback
/// as `handle_pair`'s legacy branch).
fn ok_json(id: &str, value: &impl serde::Serialize) -> Resp {
    match serde_json::to_value(value) {
        Ok(v) => Resp::ok(id.to_string(), v),
        Err(_) => Resp::err(id.to_string(), RespError::new(Reason::Internal)),
    }
}

fn unix_ms_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Await one item from a pinned stream (futures-core only, no StreamExt).
async fn next_item<S: Stream>(mut stream: std::pin::Pin<&mut S>) -> Option<S::Item> {
    std::future::poll_fn(|cx| stream.as_mut().poll_next(cx)).await
}

/// #1118: lowercase hex for the code-exchange fields.
fn hex_lower(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// #1118: exactly `len` bytes of hex, or nothing.
fn parse_hex_exact(s: &str, len: usize) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() != len * 2 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn newer_peer_req() -> Req {
        Req {
            id: "h".into(),
            method: "hello".into(),
            ver: PROTO_VER + 1,
            min_ver: PROTO_VER + 1,
            ..Default::default()
        }
    }

    /// #1122：版本不符登记表有上限，按最近使用淘汰，不会被大量不同 NodeId 撑大。
    /// 反证：改回无上限的 HashMap，第三台登记后第一台仍在 ⇒ 变红。
    #[test]
    fn outdated_peers_are_bounded_lru() {
        let peers = OutdatedPeers::with_capacity(2);
        for n in 1..=3u8 {
            assert!(peers
                .check(transport::NodeId([n; 32]), &newer_peer_req())
                .is_err());
        }
        assert_eq!(peers.needs_update(&[1u8; 32]), None, "最旧的被淘汰");
        assert_eq!(peers.needs_update(&[3u8; 32]), Some("desktop"));
        assert_eq!(peers.inner.lock().unwrap().len(), 2);
    }
}
