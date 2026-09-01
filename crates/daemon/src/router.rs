//! ALPN router (T-030): accept inbound ctrl streams, run every request
//! through the authz checkpoint (§2.3), dispatch what's allowed.
//!
//! Denials answer `Resp{err: NOT_AUTHORIZED}` with the precise msg_key,
//! close the stream, and record a `authz.denied` diag event — the
//! self-diagnosis UI and log export feed on those.

use std::time::{SystemTime, UNIX_EPOCH};

use futures_core::Stream;
use proto::msgs::methods;
use proto::{codes, Hello, Req, Resp, RespError, PROTO_VER};
use storage::{Db, DiagEvent};
use transport::{BiStream, Incoming, Transport};

use crate::authz::{self, Decision};
use crate::events::{self, EventBus};
use crate::subscriptions::SubscriptionRegistry;

/// Capabilities this daemon ships. Grows with T-033 (thumbnail serving)
/// and later cards; hello advertises it from day one (决策 D 项).
pub const SERVER_CAPABILITIES: &[&str] = &["thumbnail.v1"];

/// The ctrl-plane router: one per daemon process.
#[derive(Clone)]
pub struct Router {
    db: Db,
    device_name: String,
    pairing: Option<crate::pairing::Pairing>,
    backup: Option<crate::backup::BackupEngine>,
    query: Option<crate::query::QueryEngine>,
    upload: Option<crate::upload::UploadPlane>,
    download: Option<crate::download::DownloadPlane>,
    /// IPC-02: 事件总线（可选——未注入时事件静默不发，测试/单组件
    /// 构造不受影响）。
    events: Option<EventBus>,
    /// SYNC-03: 与 IpcServer 共用同一份订阅登记表——未注入（`Router::new`
    /// 默认值）时是独立空表，`timeline.subscribe` 仍能跑但 revoke 摘不到
    /// 它（测试/单组件构造场景，不影响现有行为）。
    subscriptions: SubscriptionRegistry,
    /// Clock seam (T-070 时钟前跳剧本): production uses the wall clock;
    /// integration scenarios inject a controllable clock.
    now: std::sync::Arc<dyn Fn() -> i64 + Send + Sync>,
}

impl Router {
    pub fn new(db: Db, device_name: impl Into<String>) -> Self {
        Self {
            db,
            device_name: device_name.into(),
            pairing: None,
            backup: None,
            query: None,
            upload: None,
            download: None,
            events: None,
            subscriptions: SubscriptionRegistry::new(),
            now: std::sync::Arc::new(unix_ms_now),
        }
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

    /// Attach the upload plane (T-054). Without it, `ppf/upload/1`
    /// connections are dropped.
    pub fn with_upload(mut self, upload: crate::upload::UploadPlane) -> Self {
        self.upload = Some(upload);
        self
    }

    /// Attach the pairing engine (T-031). Without it, `pair.request`
    /// answers `err.unsupported`.
    pub fn with_pairing(mut self, pairing: crate::pairing::Pairing) -> Self {
        self.pairing = Some(pairing);
        self
    }

    /// Attach the backup engine (T-032). Without it, `backup.*` answers
    /// `err.unsupported`.
    pub fn with_backup(mut self, backup: crate::backup::BackupEngine) -> Self {
        self.backup = Some(backup);
        self
    }

    /// Attach the query engine (T-033). Without it, browse methods
    /// answer `err.unsupported`.
    pub fn with_query(mut self, query: crate::query::QueryEngine) -> Self {
        self.query = Some(query);
        self
    }

    /// PRES-01: hello 的心跳落点——已配对未吊销设备刷新 last_seen +
    /// 记 device.connected 审计（同设备 10 分钟去重防刷屏，防「锁屏
    /// 重连」刷爆活动流）。失败静默：心跳是尽力而为的加速器，不是
    /// 承诺——写库失败不影响 hello 应答。
    async fn record_presence(&self, peer: transport::NodeId) {
        let Ok(Some(device)) = self.db.get_device(&peer.0).await else {
            return; // 未配对节点：hello 只是能力握手，不产生副作用
        };
        if device.revoked {
            return;
        }
        let now = (self.now)();
        let _ = self.db.touch_last_seen(&peer.0, now).await;
        let last = self
            .db
            .last_audit_ts(&peer.0, "device.connected")
            .await
            .unwrap_or(None);
        if last.is_none_or(|t| now - t > crate::presence::CONNECTED_AUDIT_DEDUPE_MS) {
            let _ = self
                .db
                .append_audit(&storage::AuditEntry {
                    ts: now,
                    actor: Some(peer.0.to_vec()),
                    action: "device.connected".into(),
                    target_hash: None,
                    detail: Some(device.name.clone()),
                })
                .await;
        }
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
        // Data-plane dispatch: upload connections never speak ctrl.
        if conn.alpn() == transport::ALPN_UPLOAD {
            if let Some(upload) = &self.upload {
                upload.serve_conn(conn).await;
            }
            return;
        }
        if conn.alpn() == transport::ALPN_DOWNLOAD {
            if let Some(download) = &self.download {
                download.serve_conn(conn).await;
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
                return;
            }
        }
    }

    /// One request/response on one stream. Returns `false` when the
    /// connection should be dropped (authz denial closes the door).
    async fn serve_stream(&self, peer: transport::NodeId, stream: &mut BiStream) -> bool {
        let req = match stream.recv_frame().await {
            Ok(Some(frame)) => match proto::codec::decode::<Req>(&frame) {
                Ok(req) => req,
                Err(_) => {
                    let resp = Resp::err(
                        String::new(),
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                    let _ = self.send(stream, &resp).await;
                    return false;
                }
            },
            _ => return false, // clean finish or broken stream
        };

        let device = match self.db.get_device(&peer.0).await {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("device lookup failed: {e}");
                let resp = Resp::err(
                    req.id.clone(),
                    RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
                );
                let _ = self.send(stream, &resp).await;
                return false;
            }
        };

        match authz::check(device.as_ref(), &req.method) {
            Decision::Deny { msg_key } => {
                let resp = Resp::err(
                    req.id.clone(),
                    RespError::new(codes::NOT_AUTHORIZED, msg_key),
                );
                let _ = self.send(stream, &resp).await;
                self.record_denial(peer, &req.method, msg_key).await;
                false // 关流 (§2.3: deny closes the connection)
            }
            Decision::Allow => {
                if req.method == methods::TIMELINE_SUBSCRIBE {
                    return self.serve_subscription(peer, stream, &req).await;
                }
                let resp = self.dispatch(peer, &req).await;
                let _ = self.send(stream, &resp).await;
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

        // 客户端预期只发一次订阅请求就半关闭发送方向（拿数据走别的
        // stream）；`Ok(None)` 之后不再 select 这个分支，避免忙等。
        let mut client_send_open = true;
        loop {
            tokio::select! {
                _ = token.cancelled() => break,
                frame = stream.recv_frame(), if client_send_open => {
                    match frame {
                        Ok(Some(_)) => continue, // 这条流上的多余数据——忽略
                        Ok(None) => { client_send_open = false; continue; }
                        Err(_) => break, // 连接异常
                    }
                }
                ev = rx.recv() => {
                    match ev {
                        Ok(v) if v.get("event").and_then(|e| e.as_str())
                            == Some(events::TIMELINE_INVALIDATED) =>
                        {
                            if self.send_push(stream, &v).await.is_err() {
                                break; // 写失败 = 连接真的断了
                            }
                        }
                        Ok(_) => continue, // 只推 timeline.invalidated，别的事件不转发
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
        }
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
            methods::DEVICE_UNPAIR => self.handle_unpair(peer, req).await,
            methods::BACKUP_BEGIN
            | methods::BACKUP_MANIFEST
            | methods::BACKUP_PRESENCE
            | methods::BACKUP_COMMIT => {
                self.handle_backup(peer, req).await
            }
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
                let ours = Hello {
                    proto_ver: PROTO_VER,
                    capabilities: SERVER_CAPABILITIES.iter().map(|s| s.to_string()).collect(),
                    device_name: self.device_name.clone(),
                };
                match serde_json::to_value(&ours) {
                    Ok(v) => Resp::ok(req.id.clone(), v),
                    Err(_) => Resp::err(
                        req.id.clone(),
                        RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
                    ),
                }
            }
            // Authorized but not implemented yet (T-031..T-033 land them).
            _ => Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            ),
        }
    }

    /// Browse methods (T-033): timeline pages, per-asset metadata,
    /// thumbnails (base64 JPEG in-frame), blob tickets for originals.
    async fn handle_query(&self, req: &Req) -> Resp {
        let Some(query) = &self.query else {
            return Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            );
        };
        let bad_request = || {
            Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            )
        };
        let not_found = || {
            Resp::err(
                req.id.clone(),
                RespError::new(codes::NOT_FOUND, diag::keys::ERR_UNSUPPORTED),
            )
        };
        let ok_or = |id: &str, v: Result<serde_json::Value, serde_json::Error>| match v {
            Ok(v) => Resp::ok(id.to_string(), v),
            Err(_) => Resp::err(
                id.to_string(),
                RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
            ),
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
                match query.thumb(&t).await {
                    Ok(bytes) => {
                        use base64::Engine as _;
                        let data = proto::ThumbData {
                            jpeg_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
                        };
                        ok_or(&req.id, serde_json::to_value(&data))
                    }
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

    /// `backup.*` (T-032): manifest 查重回 missing → 拉取+ingest → commit
    /// 更新水位. Failures answer INTERNAL/err.backup_failed — the client
    /// retries and the pipeline converges (idempotent).
    async fn handle_backup(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(backup) = &self.backup else {
            return Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            );
        };
        let internal_err = |id: &str| {
            Resp::err(
                id.to_string(),
                RespError::new(codes::INTERNAL, diag::keys::ERR_BACKUP_FAILED),
            )
        };
        match req.method.as_str() {
            methods::BACKUP_BEGIN => {
                backup.begin(peer);
                // T5: 备份会话开始（会话级审计——与资产级 commit 互补）。
                let _ = self
                    .db
                    .append_audit(&storage::AuditEntry {
                        ts: unix_ms_now(),
                        actor: Some(peer.0.to_vec()),
                        action: "backup.started".into(),
                        target_hash: None,
                        detail: None,
                    })
                    .await;
                Resp::ok(req.id.clone(), serde_json::Value::Null)
            }
            methods::BACKUP_MANIFEST => {
                let Ok(m) = serde_json::from_value::<proto::BackupManifest>(req.params.clone())
                else {
                    return Resp::err(
                        req.id.clone(),
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
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
                let Ok(query) = serde_json::from_value::<proto::BackupPresenceQuery>(req.params.clone())
                else {
                    return Resp::err(
                        req.id.clone(),
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    );
                };
                match backup.presence(&query.hashes).await {
                    Ok(missing) => match serde_json::to_value(&missing) {
                        Ok(v) => Resp::ok(req.id.clone(), v),
                        Err(_) => internal_err(&req.id),
                    },
                    Err(crate::backup::BackupError::InvalidPresenceQuery) => Resp::err(
                        req.id.clone(),
                        RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
                    ),
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
                        // T5: 备份会话结束 + 结果（几张/去重几张）。
                        let _ = self
                            .db
                            .append_audit(&storage::AuditEntry {
                                ts: unix_ms_now(),
                                actor: Some(peer.0.to_vec()),
                                action: "backup.finished".into(),
                                target_hash: None,
                                detail: Some(format!(
                                    "ingested={} duplicates={}",
                                    outcome.ingested, outcome.duplicates
                                )),
                            })
                            .await;
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

    /// `pair.request` (T-031): token check → owner confirmation → device
    /// row → PairAccepted. Every rejection is the same NOT_AUTHORIZED —
    /// a prober learns nothing about which part failed.
    async fn handle_pair(&self, peer: transport::NodeId, req: &Req) -> Resp {
        let Some(pairing) = &self.pairing else {
            return Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            );
        };
        let Ok(pair_req) = serde_json::from_value::<proto::PairRequest>(req.params.clone()) else {
            return Resp::err(
                req.id.clone(),
                RespError::new(codes::INVALID_REQUEST, diag::keys::ERR_UNSUPPORTED),
            );
        };
        match pairing.handle_request(peer, &pair_req, (self.now)()).await {
            Ok(()) => {
                let accepted = proto::PairAccepted {
                    storage_device_name: self.device_name.clone(),
                };
                match serde_json::to_value(&accepted) {
                    Ok(v) => Resp::ok(req.id.clone(), v),
                    Err(_) => Resp::err(
                        req.id.clone(),
                        RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
                    ),
                }
            }
            Err(_) => {
                self.record_denial(peer, methods::PAIR_REQUEST, diag::keys::ERR_NOT_AUTHORIZED)
                    .await;
                Resp::err(
                    req.id.clone(),
                    RespError::new(codes::NOT_AUTHORIZED, diag::keys::ERR_NOT_AUTHORIZED),
                )
            }
        }
    }

    /// `device.unpair` (UX-06): the caller revokes ITSELF. Unilateral
    /// stop — no owner action needed (product file §二双端共通). The
    /// device row is marked revoked; hello is denied from then on, and
    /// a fresh owner-issued token can rejoin (T-041 rejoin door).
    async fn handle_unpair(&self, peer: transport::NodeId, req: &Req) -> Resp {
        match self.db.revoke(&peer.0).await {
            Ok(_) => {
                let _ = self
                    .db
                    .append_audit(&storage::AuditEntry {
                        ts: unix_ms_now(),
                        actor: Some(peer.0.to_vec()), // 设备自我撤销（UX-06）
                        action: "device.unpaired".into(),
                        target_hash: None,
                        detail: None,
                    })
                    .await;
                // IPC-02: 设备自我断开——桌面设备行即时消失。
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
                // SYNC-03 §⑦：自我退出——顺手把自己的订阅登记摘掉（如果
                // 同一连接上还有一条 timeline.subscribe 挂着）。
                self.subscriptions.close(peer);
                Resp::ok(req.id.clone(), serde_json::json!({ "unpaired": true }))
            }
            Err(_) => Resp::err(
                req.id.clone(),
                RespError::new(codes::INTERNAL, diag::keys::ERR_UNSUPPORTED),
            ),
        }
    }

    async fn send(&self, stream: &mut BiStream, resp: &Resp) -> transport::Result<()> {
        let frame =
            proto::codec::encode(resp).map_err(|e| transport::TransportError::Io(e.to_string()))?;
        stream.send_frame(&frame).await?;
        stream.finish()
    }

    async fn record_denial(&self, peer: transport::NodeId, method: &str, msg_key: &str) {
        let detail =
            format!("{{\"peer\":\"{peer}\",\"method\":\"{method}\",\"msg_key\":\"{msg_key}\"}}",);
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
