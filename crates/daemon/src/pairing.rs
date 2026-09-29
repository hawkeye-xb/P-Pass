//! Pairing flow (T-031, 详细设计 §2.2): one-time QR token, owner
//! confirmation, whitelist write.
//!
//! ```text
//! owner UI:  start()  ──► QR "ppf://pair?node=<id>&t=<token>"
//! phone:     scan     ──► PairRequest{token, name, role} over ctrl
//! daemon:    token valid (unused, unexpired)? ──► pending queue
//! owner UI:  confirm(name) / reject(name)
//! daemon:    confirm ──► device row written ──► PairAccepted
//! ```
//!
//! Tokens are 32 random bytes, TTL 600 s, strictly one-time: the first
//! PairRequest consumes the token whatever happens afterwards — a replay
//! from another device is rejected even while the first request is still
//! pending.
//!
//! NET-10 (#128): submitting and waiting are two different things. A
//! request enters an in-memory **ledger** keyed by `request_id`; a task
//! spawned per request waits for the owner and writes the verdict back
//! into the ledger. `pair.status` reads the ledger; the legacy blocking
//! `pair.request` is "submit, then wait on the same ledger entry". The
//! ledger is process memory on purpose: a daemon restart forgets it and
//! `pair.status` answers `not_found` — the phone then asks for a fresh
//! code instead of blindly resending.
//!
//! DEV-07 (#463): the phone can **withdraw** a pending request
//! (`pair.cancel`). Before this, the phone's Cancel only changed its own
//! screen: the decision task kept `decision_rx` alive for the whole
//! pending TTL, so a later owner "Allow" still wrote a device row the
//! phone never learned about. A withdrawal ends the decision task the same
//! way the TTL does — `decision_rx` is closed, the owner's click then gets
//! `decide`'s Err (`ConfirmOutcome::Expired`), and nothing is written.
//!
//! DEV-07 follow-up (#463): a withdrawn row also **leaves the owner's
//! queue**. The decision task marks the queued [`PendingPair`] withdrawn
//! and emits `pairing.pending_changed`; the IPC queue drops marked rows on
//! every read (`ipc.rs`), so the desktop's refresh no longer lists it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use storage::{Db, Device, Role};
use tokio::sync::{oneshot, watch};

pub const TOKEN_TTL_MS: i64 = 600_000;

/// How long a pending request may wait for the owner — DEV-05 (#276)
/// bounded it, NET-10 (#128) makes it the **single** number every side
/// uses: the request-side wait (the spawned decision task), the owner
/// queue's sweep and "已失效" marker (`ipc.rs`), and the phone's polling
/// deadline (sent back as `PairSubmitted.ttl_ms`). Equal to the token TTL:
/// the owner gets the same 10 minutes the QR code promised.
///
/// DEV-05's old 110 s had to stay below the phone's 120 s blocking wait.
/// That wait never really existed — the phone's control-plane client caps
/// every round trip at 15 s (`DaemonClient.kt` `CONNECT_TIMEOUT_MS`) — and
/// the phone no longer waits inside an RPC at all: it polls `pair.status`
/// until this deadline, so the desktop row and the phone expire together.
pub const PENDING_TTL_MS: i64 = TOKEN_TTL_MS;

/// How long a settled ledger entry (accepted / denied / expired) stays
/// queryable, so a phone that lost the network right after the owner's
/// click still reads the verdict — and replays the same `PairAccepted` —
/// instead of needing a second click.
const SETTLED_RETENTION_MS: i64 = TOKEN_TTL_MS;

/// Where one submitted pairing request stands (NET-10 ledger state).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairState {
    /// Queued; the owner has not decided yet.
    Pending,
    /// The owner allowed it; the device row and this epoch are durable.
    Accepted { pairing_epoch: String },
    /// The owner said no.
    Denied,
    /// Left the queue without an owner verdict: the pending TTL ran out,
    /// or the row was replaced/swept on the desktop.
    Expired,
}

/// `pair.request{ack_then_poll}` result: what the phone polls, and until when.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairSubmission {
    pub request_id: String,
    /// Remaining pending time for this request, from [`PENDING_TTL_MS`].
    pub ttl_ms: i64,
}

/// Why a PairRequest was turned away.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairRejection {
    /// Unknown, expired, or already-used token.
    BadToken,
    /// The owner said no.
    OwnerDeclined,
}

/// Owner-side verdict for one pending pairing request.
///
/// DEV-02: 只有两种结果。DEV-01 的 `AcceptMerge`（「替换旧的」= 把旧身份
/// 的资产/水位接管过来再把旧设备行删掉）连同它的指纹匹配一起删掉了——
/// 设备与身份 1:1，续旧账目就是两个身份共享一份账，当场破 1:1。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairDecision {
    /// Join as a device in its own right.
    Accept,
    /// The owner said no.
    Reject,
}

/// A pairing request waiting for the owner's decision.
#[derive(Debug)]
pub struct PendingPair {
    pub peer: transport::NodeId,
    pub device_name: String,
    pub role: Role,
    /// DEV-05 (#276): wall-clock ms when this request entered the
    /// queue. The queue side had no way to tell "how long has this row
    /// been waiting" — without it neither a TTL sweep nor a
    /// "已失效" marker is expressible. Set at enqueue; never updated.
    pub requested_at: i64,
    decision: oneshot::Sender<PairDecision>,
    /// DEV-07 follow-up (#463): set by the decision task when the phone's
    /// withdrawal — not the TTL, not an owner verdict — ended the request.
    /// The owner queue drops such rows instead of listing them.
    withdrawn: Arc<AtomicBool>,
}

/// The owner's click landed on a request whose other end is gone: the
/// phone already gave up (or its connection dropped), so the decision
/// has nowhere to go. DEV-05 (#276): this used to be swallowed by
/// `let _ = send(...)` — the desktop showed "已允许" for a request
/// nobody would ever honour. An exception to expose, not to hide.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecisionUndelivered;

impl PendingPair {
    /// Sends the decision to the waiting request. `Err` means the
    /// receiving half was already dropped — the phone is not there
    /// anymore, the owner approved a dead request.
    pub fn decide(self, decision: PairDecision) -> Result<(), DecisionUndelivered> {
        self.decision
            .send(decision)
            .map_err(|_| DecisionUndelivered)
    }

    /// DEV-07 (#463): the request side is gone — the phone withdrew it,
    /// its pending TTL ran out, or it was otherwise settled without this
    /// row. Such a row can no longer be approved (`decide` would Err); the
    /// owner queue reports it as expired instead of as a live request.
    pub fn is_abandoned(&self) -> bool {
        self.decision.is_closed()
    }

    /// DEV-07 follow-up (#463): the phone withdrew this request
    /// (`pair.cancel`) and no owner verdict had landed. Narrower than
    /// [`Self::is_abandoned`]: a request-side TTL expiry closes the channel
    /// too, but that row keeps its DEV-05 "已失效" display — only a
    /// withdrawn row leaves the queue.
    pub fn is_withdrawn(&self) -> bool {
        self.withdrawn.load(Ordering::Acquire)
    }
}

/// DEV-07 (#463): the decision task's half of a phone withdrawal — the
/// signal `Pairing::cancel` fires, and the marker the task sets on the
/// queued [`PendingPair`] when that signal (not the owner) ended it.
struct Withdrawal {
    signal: oneshot::Receiver<()>,
    marker: Arc<AtomicBool>,
}

struct TokenState {
    expires_at: i64,
    used: bool,
}

/// One NET-10 ledger entry.
struct Ticket {
    /// Only this NodeId may read the entry (authz 口径, see `router.rs`).
    peer: transport::NodeId,
    /// The one-time token that created it — `(token, peer)` is the dedup
    /// key for a resend.
    token: [u8; 12],
    submitted_at: i64,
    /// Set when the verdict lands; drives retention.
    settled_at: Option<i64>,
    /// Current state; legacy blocking callers wait on a receiver of it.
    state: watch::Sender<PairState>,
    /// DEV-07 (#463): fires the phone's withdrawal into the decision task.
    /// Taken (and sent) at most once; `None` once used.
    withdraw: Option<oneshot::Sender<()>>,
}

struct Inner {
    tokens: HashMap<[u8; 12], TokenState>,
    /// Owner-side queue of requests awaiting confirmation (UI drains it;
    /// tests drain it directly).
    pending_tx: tokio::sync::mpsc::UnboundedSender<PendingPair>,
    /// NET-10: request_id → ledger entry.
    tickets: HashMap<String, Ticket>,
}

impl Inner {
    /// Drop settled entries past retention. Pending entries are never
    /// dropped here — their own decision task settles them within the
    /// pending TTL.
    fn sweep_tickets(&mut self, now_ms: i64) {
        self.tickets.retain(|_, t| match t.settled_at {
            Some(at) => now_ms <= at.saturating_add(SETTLED_RETENTION_MS),
            None => true,
        });
    }
}

/// Pairing engine: token issuance + request handling. Cloneable — router
/// and IPC layer share one.
#[derive(Clone)]
pub struct Pairing {
    db: Db,
    node_id: transport::NodeId,
    /// DEV-05 (#276): how long the request side waits for the owner
    /// before the pairing is resolved as denied. Production default is
    /// [`PENDING_TTL_MS`]; tests inject a short one via
    /// [`Pairing::with_pending_ttl`] instead of sleeping 110 s.
    pending_ttl_ms: i64,
    /// Live dialable-address provider — historically appended to QR
    /// strings as `&a=` (full PeerAddr base64) so a scan connects without
    /// discovery services (真机冒烟教训: 办公网屏蔽 n0 发现,纯 NodeId
    /// 拨号失败). A PROVIDER, not a cached string: the relay attaches
    /// seconds after bind and addresses drift over a daemon's weeks-long
    /// life — a QR must carry NOW's address (真机教训: 常驻 20 分钟的
    /// daemon 发着启动瞬间的裸内网地址).
    ///
    /// H-10b rework (2026-08-08): the full PeerAddr QR (id + relay +
    /// direct IPs, 100–180 chars base64) was too dense to scan. The QR
    /// now carries only the relay URL as `&r=`; the Android side rebuilds
    /// the address token from node + relay. Kept for reference only —
    /// start() no longer appends `&a=`.
    #[allow(dead_code)]
    addr_provider: Option<Arc<dyn Fn() -> String + Send + Sync>>,
    /// Relay URL provider, appended to QR strings as `&r=` (H-10b).
    /// Separate from addr_provider because the QR must stay short — a
    /// relay URL (~30 chars) instead of the full PeerAddr (~150 chars).
    relay_provider: Option<Arc<dyn Fn() -> Option<String> + Send + Sync>>,
    /// IPC-02: 事件总线（可选）——配对落定（accept/merge）后发
    /// device.changed，桌面设备行即时更新。
    events: Option<crate::events::EventBus>,
    inner: Arc<Mutex<Inner>>,
}

impl Pairing {
    /// Returns the engine plus the receiver the owner UI listens on.
    /// `addr_provider` returns `transport.local_addr().to_string()` in
    /// production (None keeps QR strings short in unit tests);
    /// `relay_provider` returns `transport.local_addr().relay_url()`.
    pub fn new(
        db: Db,
        node_id: transport::NodeId,
        addr_provider: Option<Arc<dyn Fn() -> String + Send + Sync>>,
        relay_provider: Option<Arc<dyn Fn() -> Option<String> + Send + Sync>>,
    ) -> (Self, tokio::sync::mpsc::UnboundedReceiver<PendingPair>) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (
            Self {
                db,
                node_id,
                pending_ttl_ms: PENDING_TTL_MS,
                addr_provider,
                relay_provider,
                events: None,
                inner: Arc::new(Mutex::new(Inner {
                    tokens: HashMap::new(),
                    pending_tx: tx,
                    tickets: HashMap::new(),
                })),
            },
            rx,
        )
    }

    /// IPC-02: 注入事件总线——配对落定后发 device.changed。
    pub fn with_events(mut self, events: crate::events::EventBus) -> Self {
        self.events = Some(events);
        self
    }

    /// DEV-05 (#276): override the request-side pending TTL (test seam —
    /// production keeps [`PENDING_TTL_MS`] so tests need not sleep 110 s).
    pub fn with_pending_ttl(mut self, ttl_ms: i64) -> Self {
        self.pending_ttl_ms = ttl_ms;
        self
    }

    /// Issue a fresh one-time token and return the QR content string.
    pub fn start(&self, token: [u8; 12], now_ms: i64) -> String {
        let mut inner = self.inner.lock().expect("pairing lock");
        inner.tokens.insert(
            token,
            TokenState {
                expires_at: now_ms + TOKEN_TTL_MS,
                used: false,
            },
        );
        let mut qr = format!("ppf://pair?node={}&t={}", self.node_id, hex(&token));
        // H-10b: relay URL only (`&r=`), not the full PeerAddr (`&a=` was
        // 100–180 chars base64 and too dense to scan). The Android side
        // rebuilds the address token from node + relay. Plain text is safe
        // here: relay URLs are controlled (https://host[:port]) and carry
        // no '&' or '=' that would break the query split.
        if let Some(provider) = &self.relay_provider {
            if let Some(relay) = provider() {
                qr.push_str("&r=");
                qr.push_str(&relay);
            }
        }
        qr
    }

    /// Legacy `pair.request` (old phones, `ack_then_poll == false`): the
    /// reply still waits for the owner and its semantics are unchanged —
    /// `Ok(pairing_epoch)` on Allow, `Err` otherwise. NET-10: internally it
    /// is [`Self::submit_request`] plus a wait on the same ledger entry the
    /// spawned decision task settles, so both protocol shapes share one
    /// source of truth.
    pub async fn handle_request(
        &self,
        peer: transport::NodeId,
        req: &proto::PairRequest,
        now_ms: i64,
    ) -> Result<String, PairRejection> {
        let submission = self.submit_request(peer, req, now_ms).await?;
        let mut rx = {
            let inner = self.inner.lock().expect("pairing lock");
            inner
                .tickets
                .get(&submission.request_id)
                .map(|t| t.state.subscribe())
                .ok_or(PairRejection::OwnerDeclined)?
        };
        let settled = match rx.wait_for(|s| *s != PairState::Pending).await {
            Ok(s) => s.clone(),
            Err(_) => PairState::Expired,
        };
        match settled {
            PairState::Accepted { pairing_epoch } => Ok(pairing_epoch),
            _ => Err(PairRejection::OwnerDeclined),
        }
    }

    /// NET-10 (#128): accept-then-poll. Validates the token, parks the
    /// request in the owner's queue, records it in the ledger, spawns the
    /// task that waits for the owner — and returns at once.
    ///
    /// Dedup: the same `(token, peer)` resubmitted (the phone lost the
    /// reply, or re-scanned the same QR) returns the **existing**
    /// `request_id` and pushes nothing to the owner queue — a second push
    /// would make the queue's same-phone replacement (`ipc.rs`) drop the
    /// live row. The same token from another device is still a replay.
    pub async fn submit_request(
        &self,
        peer: transport::NodeId,
        req: &proto::PairRequest,
        now_ms: i64,
    ) -> Result<PairSubmission, PairRejection> {
        let role = match req.role.as_str() {
            "viewer" => Role::Viewer,
            // §2.2: joining devices are members unless explicitly viewer;
            // owner is never granted over the network.
            _ => Role::Member,
        };

        let (request_id, decision_rx, withdraw_rx, withdrawn) = {
            let mut inner = self.inner.lock().expect("pairing lock");
            inner.sweep_tickets(now_ms);
            let token = parse_token(&req.token).ok_or(PairRejection::BadToken)?;
            if let Some((id, t)) = inner
                .tickets
                .iter()
                .find(|(_, t)| t.token == token && t.peer == peer)
            {
                return Ok(PairSubmission {
                    request_id: id.clone(),
                    ttl_ms: (t.submitted_at + self.pending_ttl_ms - now_ms).max(0),
                });
            }
            let state = inner
                .tokens
                .get_mut(&token)
                .ok_or(PairRejection::BadToken)?;
            if state.used || now_ms > state.expires_at {
                return Err(PairRejection::BadToken);
            }
            state.used = true; // one-time, consumed no matter what follows

            let request_id = fresh_request_id().map_err(|_| PairRejection::OwnerDeclined)?;
            let (tx, rx) = oneshot::channel();
            let withdrawn = Arc::new(AtomicBool::new(false));
            let pending = PendingPair {
                peer,
                device_name: req.device_name.clone(),
                role,
                requested_at: now_ms,
                decision: tx,
                withdrawn: Arc::clone(&withdrawn),
            };
            if inner.pending_tx.send(pending).is_err() {
                return Err(PairRejection::OwnerDeclined); // UI gone = no
            }
            let (state_tx, _) = watch::channel(PairState::Pending);
            let (withdraw_tx, withdraw_rx) = oneshot::channel();
            inner.tickets.insert(
                request_id.clone(),
                Ticket {
                    peer,
                    token,
                    submitted_at: now_ms,
                    settled_at: None,
                    state: state_tx,
                    withdraw: Some(withdraw_tx),
                },
            );
            (request_id, rx, withdraw_rx, withdrawn)
        };

        // T5: 扫码请求到达即审计（含后续被拒/超时——审计要全，不只看成功）。
        let _ = self
            .db
            .append_audit(&storage::AuditEntry::local(
                now_ms,
                Some(peer.0.to_vec()),
                "pair.requested",
                None,
                Some(serde_json::json!({ "deviceName": req.device_name.clone() }).to_string()),
            ))
            .await;

        let this = self.clone();
        let device_name = req.device_name.clone();
        let id = request_id.clone();
        tokio::spawn(async move {
            let (state, settled_at) = this
                .await_owner(
                    peer,
                    device_name,
                    role,
                    now_ms,
                    decision_rx,
                    Withdrawal {
                        signal: withdraw_rx,
                        marker: withdrawn,
                    },
                )
                .await;
            let mut inner = this.inner.lock().expect("pairing lock");
            if let Some(t) = inner.tickets.get_mut(&id) {
                t.settled_at = Some(settled_at);
                t.state.send_replace(state);
            }
        });

        Ok(PairSubmission {
            request_id,
            ttl_ms: self.pending_ttl_ms,
        })
    }

    /// NET-10: the ledger entry for `request_id`, **as seen by `peer`**.
    /// `None` = not_found: unknown id, swept, daemon restarted — or an id
    /// that belongs to another NodeId (indistinguishable on purpose, so a
    /// request's existence and its `PairAccepted` never leak).
    pub fn status(
        &self,
        peer: transport::NodeId,
        request_id: &str,
        now_ms: i64,
    ) -> Option<PairState> {
        let mut inner = self.inner.lock().expect("pairing lock");
        inner.sweep_tickets(now_ms);
        inner
            .tickets
            .get(request_id)
            .filter(|t| t.peer == peer)
            .map(|t| t.state.borrow().clone())
    }

    /// DEV-07 (#463): the submitting phone withdraws its own request
    /// (`pair.cancel`). Scoped exactly like [`Self::status`]: another
    /// NodeId's id, an unknown id, or a swept one is `None` (not_found) and
    /// touches nothing. A still-pending request is ended without an owner
    /// verdict — it settles `Expired` and the owner's queue row can no
    /// longer be approved. An already-settled one is left as it is (an
    /// owner Allow that landed first stays a real join).
    ///
    /// Returns the state after the withdrawal has settled, waiting (briefly)
    /// for the decision task so the caller's answer is the ledger's truth:
    /// once this returns `Expired`, the owner-side `decision_rx` is closed.
    pub async fn cancel(
        &self,
        peer: transport::NodeId,
        request_id: &str,
        now_ms: i64,
    ) -> Option<PairState> {
        let mut rx = {
            let mut inner = self.inner.lock().expect("pairing lock");
            inner.sweep_tickets(now_ms);
            let ticket = inner
                .tickets
                .get_mut(request_id)
                .filter(|t| t.peer == peer)?;
            if *ticket.state.borrow() == PairState::Pending {
                if let Some(withdraw) = ticket.withdraw.take() {
                    let _ = withdraw.send(());
                }
            }
            ticket.state.subscribe()
        };
        // The decision task settles within one audit write; the bound only
        // keeps a stuck DB from holding a control-plane RPC open.
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            rx.wait_for(|s| *s != PairState::Pending),
        )
        .await;
        let settled = rx.borrow().clone();
        Some(settled)
    }

    /// The decision task body: wait (bounded) for the owner, then apply
    /// the verdict. Returns the ledger state and the settle timestamp.
    async fn await_owner(
        &self,
        peer: transport::NodeId,
        device_name: String,
        role: Role,
        now_ms: i64,
        mut decision_rx: oneshot::Receiver<PairDecision>,
        withdrawal: Withdrawal,
    ) -> (PairState, i64) {
        let Withdrawal {
            signal: mut withdraw_rx,
            marker: withdrawn,
        } = withdrawal;
        // DEV-05 (#276): the wait for the owner is bounded. Without this
        // arm, a request whose phone already gave up sat in `await` until
        // process exit — and the queue row stayed clickable. The timeout
        // drops `decision_rx`, so the *queue* half of the fix is
        // `ipc.rs`'s prune sweep + `confirm` surfacing `decide`'s
        // Err; one side alone leaves the other lying.
        let wait_started = tokio::time::Instant::now();
        let ttl = tokio::time::sleep(std::time::Duration::from_millis(self.pending_ttl_ms as u64));
        tokio::pin!(ttl);
        let mut phone_withdrew = false;
        let heard = tokio::select! {
            // DEV-07 (#463): `biased` with the owner's arm FIRST. A decision
            // already delivered means `confirm` has told the owner
            // "已允许/已拒绝" — it must be honoured even if the phone's
            // withdrawal is also ready, or the desktop lies (DEV-05).
            biased;
            d = &mut decision_rx => d.ok(),
            // Only an actual withdrawal counts; the ticket dropping its
            // sender (never happens while pending) disables this arm.
            Ok(()) = &mut withdraw_rx => {
                phone_withdrew = true;
                None
            }
            // TTL: no verdict. A dropped sender (row replaced/swept, owner
            // UI gone) resolves the first arm with Err → None as well.
            () = &mut ttl => None,
        };
        // Close the owner's half NOW, before the (awaiting) verdict write:
        // from here on `decide` fails → `ConfirmOutcome::Expired`, so the
        // desktop can never report success for a click this task ignores.
        // A decision sent before the close is still read and honoured.
        decision_rx.close();
        let decision = heard.or_else(|| decision_rx.try_recv().ok());
        drop(decision_rx);
        // DEV-07 follow-up (#463): withdrawn with no owner verdict — the
        // row is unapprovable from the close above, so take it off the
        // owner's screen now: mark it (the IPC queue drops marked rows on
        // every read) and push the existing queue-change event so the
        // desktop refreshes instead of waiting for its fallback poll. An
        // owner verdict that won the race is not marked: `confirm` already
        // removed that row itself.
        if phone_withdrew && decision.is_none() {
            withdrawn.store(true, Ordering::Release);
            if let Some(bus) = &self.events {
                crate::events::emit(
                    bus,
                    crate::events::PAIRING_PENDING_CHANGED,
                    serde_json::json!({ "pending": 0 }), // 占位，客户端全量拉取
                );
            }
        }
        // DEV-05 (#276) 验收标准 4: the verdict timestamp is taken NOW —
        // the moment the owner decided (or the request expired) — not the
        // `now_ms` captured at request entry. Accept and deny share the
        // same fix: the audit must answer "how long did the owner take to
        // click?" for BOTH verdicts, and the timeout path lands on
        // `denied`. Elapsed is added to the caller-injected `now_ms`
        // (never wall-clock raw) so clock-jump scenarios keep the trail
        // monotonic (T-070's injected clock stays the truth).
        let decided_at = now_ms.saturating_add(wait_started.elapsed().as_millis() as i64);

        let state = match self
            .apply_verdict(
                peer,
                &device_name,
                role,
                now_ms,
                decision.as_ref(),
                decided_at,
            )
            .await
        {
            Ok(pairing_epoch) => PairState::Accepted { pairing_epoch },
            // No verdict at all: the request aged out or left the queue.
            Err(_) if decision.is_none() => PairState::Expired,
            // The owner said no (or an accepted write failed — the phone
            // must not proceed either way).
            Err(_) => PairState::Denied,
        };
        (state, decided_at)
    }

    /// Apply the owner's verdict: audit + (on Allow) device row, epoch,
    /// events. `Ok(pairing_epoch)` only when the pairing is durable.
    async fn apply_verdict(
        &self,
        peer: transport::NodeId,
        device_name: &str,
        role: Role,
        now_ms: i64,
        decision: Option<&PairDecision>,
        decided_at: i64,
    ) -> Result<String, PairRejection> {
        let accept = matches!(decision, Some(PairDecision::Accept));

        if !accept {
            // T5: owner 拒绝（或 UI 消失/超时）同样入审计。
            let _ = self
                .db
                .append_audit(&storage::AuditEntry::local(
                    decided_at,
                    Some(peer.0.to_vec()),
                    "pair.denied",
                    None,
                    Some(serde_json::json!({ "deviceName": device_name }).to_string()),
                ))
                .await;
            return Err(PairRejection::OwnerDeclined);
        }

        // DEV-04：库里已有这一行 = 这台以前连过。这一次查询同时回答三件
        // 事——要不要 unrevoke、审批框该说「加入」还是「重新连接」、
        // **以及叫什么名字**。
        let existing = self.db.get_device(&peer.0).await.ok().flatten();
        let rejoining = existing.as_ref().is_some_and(|d| d.revoked);
        // DEV-04（验收人 2026-09-20 实测）：桌面上改过的名字不能被重连
        // 冲掉。`device.rename` 是业主对这台设备的称呼，手机自报名只在
        // 库里还没有这一行时作数。
        //
        // 旧写法无条件 `safe_name(&req.device_name)`，配上 upsert 的
        // `name = excluded.name`，业主 19:32:29 改的名 19:32:42 就被
        // 重连覆盖回 "SM-S9210"——审计流水里两行挨着。
        let name = match &existing {
            Some(d) => d.name.clone(),
            None => safe_name(device_name),
        };
        let device = Device {
            node_id: peer.0.to_vec(),
            name,
            role,
            paired_at: now_ms,
            last_seen: Some(now_ms),
            revoked: false,
            // DEV-03：新配对/重新配对的设备不带吊销痕迹。已被吊销过的设备
            // 由 `unrevoke` 清列——`upsert_device` 有意不碰这三列（防误触）。
            revoked_at: None,
            revoked_by: None,
        };
        self.db
            .upsert_device(&device)
            .await
            .map_err(|_| PairRejection::OwnerDeclined)?;
        if rejoining {
            // Owner confirmation = renewed trust; upsert never clears the
            // flag by design, so reinstate explicitly.
            let _ = self.db.unrevoke(&peer.0).await;
        }
        // REBUILD-02: a newly accepted pairing replaces every old Flow
        // grant. Persist the epoch before replying so the phone never starts
        // a fetch against an epoch the Desktop cannot verify after restart.
        let pairing_epoch = fresh_pairing_epoch().map_err(|_| PairRejection::OwnerDeclined)?;
        if !self
            .db
            .set_pairing_epoch(&peer.0, &pairing_epoch)
            .await
            .map_err(|_| PairRejection::OwnerDeclined)?
        {
            return Err(PairRejection::OwnerDeclined);
        }

        // DEV-02: 配对流程只写自己这一行。它无权改写、更无权删除任何
        // 其它设备的记录——DEV-01 的 merge 正是在这里删掉另一行的。
        let detail = if rejoining {
            format!("{} (rejoined after revoke)", device.name)
        } else {
            device.name.clone()
        };

        let _ = self
            .db
            .append_audit(&storage::AuditEntry::local(
                decided_at,
                Some(peer.0.to_vec()),
                "pair.accepted",
                None,
                Some(serde_json::json!({ "detail": detail }).to_string()),
            ))
            .await;
        // IPC-02: 配对落定——桌面设备行即时出现（新设备/替换旧设备）。
        if let Some(bus) = &self.events {
            crate::events::emit(
                bus,
                crate::events::DEVICE_CHANGED,
                serde_json::json!({ "node_id": peer.to_string() }),
            );
            crate::events::emit(
                bus,
                crate::events::ACTIVITY_APPENDED,
                serde_json::json!({ "action": "pair.accepted" }),
            );
        }
        Ok(pairing_epoch)
    }

    /// Drop expired/used tokens (housekeeping; daemon calls periodically).
    pub fn prune(&self, now_ms: i64) {
        let mut inner = self.inner.lock().expect("pairing lock");
        inner
            .tokens
            .retain(|_, s| !s.used && now_ms <= s.expires_at);
        inner.sweep_tickets(now_ms);
    }
}

/// NET-10: 128 bits of OS entropy per request id — unguessable, so the
/// per-NodeId scoping in [`Pairing::status`] is defence in depth, not the
/// only barrier.
fn fresh_request_id() -> Result<String, getrandom::Error> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)?;
    Ok(hex(&bytes))
}

/// Device names come from the network — cap length, strip control chars.
fn safe_name(name: &str) -> String {
    let cleaned: String = name.chars().filter(|c| !c.is_control()).take(64).collect();
    if cleaned.trim().is_empty() {
        "未命名设备".into()
    } else {
        cleaned
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// 128 bits of OS entropy names an owner-approved pairing generation. It is
/// persisted before `PairAccepted` is emitted, so Desktop and phone agree
/// across daemon restart and a re-pair invalidates old delivery grants.
fn fresh_pairing_epoch() -> Result<String, getrandom::Error> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)?;
    Ok(hex(&bytes))
}

// H-10b v2 (2026-08-08): 配对 token 32B → 12B。一次性配对 + 10 分钟
// TTL，96-bit 熵绰绰有余；QR 里 token 从 64 hex 字符降到 24。
// （IPC socket token 保持 32B——不同用途，见 main.rs/ipc.rs。）
fn parse_token(s: &str) -> Option<[u8; 12]> {
    let s = s.trim();
    if s.len() != 24 {
        return None;
    }
    let mut out = [0u8; 12];
    for (i, chunk) in s.as_bytes().as_chunks::<2>().0.iter().enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = ((hi << 4) | lo) as u8;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qr_string_carries_node_and_token() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let db = Db::open_in_memory().await.unwrap();
            let (pairing, _rx) = Pairing::new(db, transport::NodeId([0xAB; 32]), None, None);
            let qr = pairing.start([0x11; 12], 1_000);
            assert_eq!(
                qr,
                format!("ppf://pair?node={}&t={}", "ab".repeat(32), "11".repeat(12))
            );
        });
    }

    #[test]
    fn token_parsing_rejects_garbage() {
        assert!(parse_token(&"zz".repeat(12)).is_none());
        assert!(parse_token("abcd").is_none());
        assert_eq!(parse_token(&"11".repeat(12)), Some([0x11; 12]));
    }

    #[test]
    fn hostile_device_names_are_defanged() {
        assert_eq!(safe_name("妈妈的手机"), "妈妈的手机");
        assert_eq!(safe_name("a\x00b\x1fc"), "abc");
        assert_eq!(safe_name("   "), "未命名设备");
        assert_eq!(safe_name(&"x".repeat(200)).len(), 64);
    }
}
