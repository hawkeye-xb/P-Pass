//! Pairing flow (T-031, 详细设计 §2.2): one-time QR token, owner
//! confirmation, whitelist write.
//!
//! ```text
//! owner UI:  start()  ──► QR "ppf://pair?node=<id>&t=<token>[&r=<relay>]"
//! phone:     scan     ──► PairRequest{token, name, role} over ctrl
//! daemon:    token valid (unused, unexpired)? ──► pending queue
//! owner UI:  confirm(name) / reject(name)
//! daemon:    confirm ──► device row written ──► PairAccepted
//! ```
//!
//! Tokens are 12 random bytes (24 hex), TTL 600 s, strictly one-time: the first
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
//!
//! #1118: approving means **typing the phone's 6-digit code**. `pair.request` carries the
//! phone's SPAKE2 message (`pake_a`, `crates/pair-pake`); the owner's "confirm" hands the typed
//! code to the decision task ([`PairDecision::AcceptCode`]), which answers with `pake_b`
//! (read by the phone through `pair.status`) and keeps the session in the ledger. The phone's
//! `pair.confirm` then carries its key confirmation `cA`: only a matching `cA` writes the
//! pairing record and releases the desktop's `cB`; a mismatch voids the request (its token was
//! already used up) — one attempt per request. Refreshing the QR code drops every older token.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use storage::{Db, Role};
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
    Accepted { pairing_id: String },
    /// The owner said no.
    Denied,
    /// Left the queue without an owner verdict: the pending TTL ran out,
    /// or the row was replaced/swept on the desktop.
    Expired,
    /// #1118: the owner typed a code but the phone's confirmation did not match — the request
    /// is void (scan again).
    Failed,
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
    /// #1118: `pake_a` is missing or not a well-formed SPAKE2 message.
    BadPake,
}

/// Owner-side verdict for one pending pairing request.
///
/// DEV-02: 只有两种结果。DEV-01 的 `AcceptMerge`（「替换旧的」= 把旧身份
/// 的资产/水位接管过来再把旧设备行删掉）连同它的指纹匹配一起删掉了——
/// 设备与身份 1:1，续旧账目就是两个身份共享一份账，当场破 1:1。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairDecision {
    /// #1118: the owner typed this code — join as a device in its own right **if** the phone's
    /// key confirmation matches it.
    AcceptCode(String),
    /// The owner said no.
    Reject,
}

/// #552: how a pending request ended — the input to its audit kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ending {
    /// The owner said yes.
    Accept,
    /// The owner said no → `pair.denied`.
    Denied,
    /// The phone withdrew (`pair.cancel`) before any verdict → `pair.cancelled`.
    Cancelled,
    /// No verdict in time: TTL, or the owner's half dropped → `pair.expired`.
    Expired,
    /// #1118: the owner typed a code and the phone's confirmation did not match →
    /// `pair.code_failed`.
    CodeWrong,
}

impl Ending {
    /// The audit kind of a non-join ending; `None` for [`Ending::Accept`].
    fn refusal_kind(self) -> Option<&'static str> {
        match self {
            Ending::Accept => None,
            Ending::Denied => Some("pair.denied"),
            Ending::Cancelled => Some("pair.cancelled"),
            Ending::Expired => Some("pair.expired"),
            Ending::CodeWrong => Some("pair.code_failed"),
        }
    }
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

/// #1118: everything the decision task needs to know about one request.
struct Applicant {
    request_id: String,
    peer: transport::NodeId,
    device_name: String,
    role: Role,
    token: [u8; 12],
    pake_a: Vec<u8>,
}

/// #1118: how the code exchange after the owner's "confirm" ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CodeOutcome {
    Matched,
    Wrong,
    Withdrawn,
    TimedOut,
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
    /// #1118: the desktop's SPAKE2 answer, set once the owner typed the code.
    pake_b: Option<Vec<u8>>,
    /// #1118: the session waiting for the phone's `cA`, with the decision task's ear for the
    /// result (`Some(cB)` = matched, `None` = wrong). Taken by [`Pairing::confirm_code`]: used once.
    session: Option<(pair_pake::Desktop, oneshot::Sender<Option<[u8; 32]>>)>,
    /// #1118: the `cA` that was checked, and the `cB` it released (`None` = it did not match).
    /// Makes a resend of the same `cA` idempotent; any other `cA` is a wrong code.
    checked: Option<(Vec<u8>, Option<[u8; 32]>)>,
}

/// #1118: one ledger entry as the submitting phone may see it (`pair.status` / `pair.confirm`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TicketView {
    pub state: PairState,
    /// The desktop's SPAKE2 answer once the owner typed the code (while pending).
    pub pake_b: Option<Vec<u8>>,
    /// The desktop's key confirmation, released only after the phone's `cA` matched.
    pub confirm_b: Option<[u8; 32]>,
}

/// #1118: why a `pair.confirm` was not accepted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfirmError {
    /// Unknown id, another device's id, or swept.
    NotFound,
    /// The owner has not typed the code yet (no `pake_b` was handed out).
    NotReady,
    /// The confirmation did not match: the request is void.
    CodeWrong,
}

impl Ticket {
    fn view(&self) -> TicketView {
        let state = self.state.borrow().clone();
        TicketView {
            pake_b: (state == PairState::Pending)
                .then(|| self.pake_b.clone())
                .flatten(),
            confirm_b: match state {
                PairState::Accepted { .. } => self.checked.as_ref().and_then(|(_, cb)| *cb),
                _ => None,
            },
            state,
        }
    }
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
    /// Relay URL provider, appended to QR strings as `&r=` (H-10b).
    /// The QR must stay short — a relay URL (~30 chars) instead of the full
    /// PeerAddr (~150 chars) — so the full dialable address is never embedded
    /// (H-10b rework 2026-08-08: the `&a=` PeerAddr QR was too dense to scan;
    /// the Android side rebuilds the address token from node + relay).
    relay_provider: Option<Arc<dyn Fn() -> Option<String> + Send + Sync>>,
    /// IPC-02: 事件总线（可选）——配对落定（accept/merge）后发
    /// device.changed，桌面设备行即时更新。
    events: Option<crate::events::EventBus>,
    inner: Arc<Mutex<Inner>>,
}

impl Pairing {
    /// Returns the engine plus the receiver the owner UI listens on.
    /// `relay_provider` returns `transport.local_addr().relay_url()` in
    /// production (None keeps QR strings short in unit tests).
    pub fn new(
        db: Db,
        node_id: transport::NodeId,
        relay_provider: Option<Arc<dyn Fn() -> Option<String> + Send + Sync>>,
    ) -> (Self, tokio::sync::mpsc::UnboundedReceiver<PendingPair>) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (
            Self {
                db,
                node_id,
                pending_ttl_ms: PENDING_TTL_MS,
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

    /// This desktop's NodeId (the `B` identity of the pairing code exchange, #1118).
    pub fn node_id(&self) -> transport::NodeId {
        self.node_id
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
        // #1118: one QR code at a time — showing a fresh one (refresh) voids every older token,
        // used or not; expired ones go with them. Submitted requests keep their ledger entries.
        inner.tokens.clear();
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

    /// #1122：配对窗口——二维码显示期间才对未配对的对端开放配对入口。
    ///
    /// 窗口开着 = 还有一个没用过、没过期、没被收回的令牌（二维码在显示，或配对串
    /// 刚复制出去）。另外，已经提交过配对申请的那台设备在申请结束（含结束后的
    /// 保留期）之前照常放行，否则业主关掉二维码后它就没法轮询自己的结果。
    pub fn admits(&self, peer: transport::NodeId, now_ms: i64) -> bool {
        let mut inner = self.inner.lock().expect("pairing lock");
        // Same retention rule as every other ledger read: a settled request past its retention no
        // longer admits its peer (nothing else may have swept since — no periodic prune runs).
        inner.sweep_tickets(now_ms);
        Self::open_in(&inner, now_ms) || inner.tickets.values().any(|t| t.peer == peer)
    }

    /// #1122 / #1118：配对窗口开着（二维码在显示）——见 [`Self::admits`]。电脑名只在这期间
    /// 发给未配对的对端。
    pub fn window_open(&self, now_ms: i64) -> bool {
        Self::open_in(&self.inner.lock().expect("pairing lock"), now_ms)
    }

    fn open_in(inner: &Inner, now_ms: i64) -> bool {
        inner
            .tokens
            .values()
            .any(|t| !t.used && now_ms <= t.expires_at)
    }

    /// #1122：二维码关闭——收回所有还没用掉的令牌，配对窗口立即关闭。已提交的
    /// 申请不受影响（它们的令牌已经用掉了）。返回收回了几个。
    pub fn stop(&self) -> usize {
        let mut inner = self.inner.lock().expect("pairing lock");
        let before = inner.tokens.len();
        inner.tokens.retain(|_, t| t.used);
        before - inner.tokens.len()
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

        let (request_id, decision_rx, withdraw_rx, withdrawn, token, pake_a) = {
            let mut inner = self.inner.lock().expect("pairing lock");
            inner.sweep_tickets(now_ms);
            let token = parse_token(&req.token).ok_or(PairRejection::BadToken)?;
            // #1118: checked before the token is used up — a malformed request burns nothing.
            let pake_a = parse_pake_msg(&req.pake_a).ok_or(PairRejection::BadPake)?;
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
                    pake_b: None,
                    session: None,
                    checked: None,
                },
            );
            (request_id, rx, withdraw_rx, withdrawn, token, pake_a)
        };

        // T5: 扫码请求到达即审计（含后续被拒/超时——审计要全，不只看成功）。
        warn_if_audit_failed(
            "pair.requested",
            self.db
                .append_audit(&storage::AuditEntry::local(
                    now_ms,
                    Some(peer.0.to_vec()),
                    "pair.requested",
                    None,
                    Some(serde_json::json!({ "deviceName": req.device_name.clone() }).to_string()),
                ))
                .await,
        );

        let this = self.clone();
        let device_name = req.device_name.clone();
        let id = request_id.clone();
        tokio::spawn(async move {
            let (state, settled_at) = this
                .await_owner(
                    Applicant {
                        request_id: id.clone(),
                        peer,
                        device_name,
                        role,
                        token,
                        pake_a,
                    },
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
        applicant: Applicant,
        now_ms: i64,
        mut decision_rx: oneshot::Receiver<PairDecision>,
        withdrawal: Withdrawal,
    ) -> (PairState, i64) {
        let Applicant {
            request_id,
            peer,
            device_name,
            role,
            token,
            pake_a,
        } = applicant;
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
        // `pair.expired` (#552; was `denied`). Elapsed is added to the
        // caller-injected `now_ms` (never wall-clock raw) so clock-jump
        // scenarios keep the trail monotonic (T-070's injected clock stays
        // the truth).
        // #552: how the request ended decides its audit kind. The
        // "phone withdrew" test is exactly the one above that takes the row
        // off the owner's screen — an owner verdict that won the race is
        // recorded as the owner's, never as the phone's cancel.
        // #1118: the owner's "confirm" carries the typed code; the request only joins if the
        // phone's key confirmation then matches it (same pending deadline, phone may still
        // withdraw meanwhile).
        let ending = match decision.as_ref() {
            Some(PairDecision::AcceptCode(code)) => match self
                .exchange_code(
                    &request_id,
                    peer,
                    &token,
                    &pake_a,
                    code,
                    ttl.as_mut(),
                    &mut withdraw_rx,
                )
                .await
            {
                CodeOutcome::Matched => Ending::Accept,
                CodeOutcome::Wrong => Ending::CodeWrong,
                CodeOutcome::Withdrawn => Ending::Cancelled,
                CodeOutcome::TimedOut => Ending::Expired,
            },
            Some(PairDecision::Reject) => Ending::Denied,
            None if phone_withdrew => Ending::Cancelled,
            // TTL, or the owner's half dropped (row replaced/swept, UI gone).
            None => Ending::Expired,
        };
        let decided_at = now_ms.saturating_add(wait_started.elapsed().as_millis() as i64);

        let state = match self
            .apply_verdict(peer, &device_name, role, now_ms, ending, decided_at)
            .await
        {
            Ok(pairing_id) => PairState::Accepted { pairing_id },
            Err(_) => match ending {
                // #1118: wrong code — void, scan again.
                Ending::CodeWrong => PairState::Failed,
                // No verdict at all: the request aged out, left the queue, or was withdrawn.
                Ending::Expired | Ending::Cancelled => PairState::Expired,
                // The owner said no (or an accepted write failed — the phone
                // must not proceed either way).
                Ending::Denied | Ending::Accept => PairState::Denied,
            },
        };
        (state, decided_at)
    }

    /// #1118: the owner typed `code`. Answer the phone's `pake_a` (the answer `pake_b` and the
    /// session go into the ledger, where `pair.status` and `pair.confirm` find them), then wait —
    /// within the same pending deadline — for [`Self::confirm_code`] to check the phone's `cA`.
    #[allow(clippy::too_many_arguments)]
    async fn exchange_code(
        &self,
        request_id: &str,
        peer: transport::NodeId,
        token: &[u8; 12],
        pake_a: &[u8],
        code: &str,
        ttl: std::pin::Pin<&mut tokio::time::Sleep>,
        withdraw_rx: &mut oneshot::Receiver<()>,
    ) -> CodeOutcome {
        let Ok((session, pake_b)) =
            pair_pake::Desktop::respond(code, token, peer.0, self.node_id.0, pake_a)
        else {
            // Not six digits (the IPC checks first) — counts as the one wrong attempt.
            return CodeOutcome::Wrong;
        };
        let (tx, rx) = oneshot::channel();
        {
            let mut inner = self.inner.lock().expect("pairing lock");
            let Some(t) = inner.tickets.get_mut(request_id) else {
                return CodeOutcome::TimedOut;
            };
            t.pake_b = Some(pake_b);
            t.session = Some((session, tx));
        }
        let outcome = tokio::select! {
            biased;
            r = rx => match r {
                Ok(Some(_)) => CodeOutcome::Matched,
                Ok(None) => CodeOutcome::Wrong,
                Err(_) => CodeOutcome::TimedOut,
            },
            Ok(()) = withdraw_rx => CodeOutcome::Withdrawn,
            () = ttl => CodeOutcome::TimedOut,
        };
        if outcome != CodeOutcome::Matched && outcome != CodeOutcome::Wrong {
            // No confirmation will be checked any more.
            if let Some(t) = self
                .inner
                .lock()
                .expect("pairing lock")
                .tickets
                .get_mut(request_id)
            {
                t.session = None;
            }
        }
        outcome
    }

    /// #1118: `pair.confirm` — check the phone's key confirmation `cA` for its own request,
    /// once. A match lets the decision task write the pairing record; the reply (after the
    /// ledger settled) carries the desktop's `cB`. A mismatch voids the request. A resend of the
    /// same `cA` replays the same answer; any other `cA` after the first check is wrong.
    pub async fn confirm_code(
        &self,
        peer: transport::NodeId,
        request_id: &str,
        confirm_a: &[u8],
        now_ms: i64,
    ) -> Result<TicketView, ConfirmError> {
        let mut rx = {
            let mut inner = self.inner.lock().expect("pairing lock");
            inner.sweep_tickets(now_ms);
            let t = inner
                .tickets
                .get_mut(request_id)
                .filter(|t| t.peer == peer)
                .ok_or(ConfirmError::NotFound)?;
            match &t.checked {
                Some((seen, _)) if seen.as_slice() != confirm_a => {
                    return Err(ConfirmError::CodeWrong)
                }
                Some(_) => {}
                None => {
                    if *t.state.borrow() == PairState::Failed {
                        return Err(ConfirmError::CodeWrong);
                    }
                    let (session, verdict) = t.session.take().ok_or(ConfirmError::NotReady)?;
                    let released = session.verify(confirm_a).ok();
                    t.checked = Some((confirm_a.to_vec(), released));
                    let _ = verdict.send(released);
                }
            }
            t.state.subscribe()
        };
        // The decision task writes the pairing record (or the refusal) right after the check;
        // the bound only keeps a stuck DB from holding a control-plane RPC open.
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            rx.wait_for(|s| *s != PairState::Pending),
        )
        .await;
        let inner = self.inner.lock().expect("pairing lock");
        let view = inner
            .tickets
            .get(request_id)
            .map(Ticket::view)
            .ok_or(ConfirmError::NotFound)?;
        if view.state == PairState::Failed {
            return Err(ConfirmError::CodeWrong);
        }
        Ok(view)
    }

    /// #1118: wait (bounded) for `peer`'s latest pending request to settle — the owner just
    /// typed the code and wants to see the result. `None` = nothing pending for it, or still
    /// pending at the deadline.
    pub async fn await_verdict(
        &self,
        peer: transport::NodeId,
        timeout: std::time::Duration,
    ) -> Option<PairState> {
        let mut rx = {
            let inner = self.inner.lock().expect("pairing lock");
            inner
                .tickets
                .values()
                .filter(|t| t.peer == peer && t.settled_at.is_none())
                .max_by_key(|t| t.submitted_at)?
                .state
                .subscribe()
        };
        let _ = tokio::time::timeout(timeout, rx.wait_for(|s| *s != PairState::Pending)).await;
        let state = rx.borrow().clone();
        Some(state)
    }

    /// #1118: [`Self::status`] plus the code-exchange fields the phone needs.
    pub fn view(
        &self,
        peer: transport::NodeId,
        request_id: &str,
        now_ms: i64,
    ) -> Option<TicketView> {
        let mut inner = self.inner.lock().expect("pairing lock");
        inner.sweep_tickets(now_ms);
        inner
            .tickets
            .get(request_id)
            .filter(|t| t.peer == peer)
            .map(Ticket::view)
    }

    /// Apply the owner's verdict: audit + (on Allow) device profile and a
    /// fresh pairing record, events. `Ok(pairing_id)` only when the pairing
    /// record is durable.
    async fn apply_verdict(
        &self,
        peer: transport::NodeId,
        device_name: &str,
        role: Role,
        now_ms: i64,
        ending: Ending,
        decided_at: i64,
    ) -> Result<String, PairRejection> {
        if let Some(kind) = ending.refusal_kind() {
            // T5: 没成的配对同样入审计。#552：按结局分 kind——业主拒绝
            // `pair.denied`、手机取消 `pair.cancelled`、没人及时决策
            // `pair.expired`，桌面活动记录据此显示不同文案。
            warn_if_audit_failed(
                kind,
                self.db
                    .append_audit(&storage::AuditEntry::local(
                        decided_at,
                        Some(peer.0.to_vec()),
                        kind,
                        None,
                        Some(serde_json::json!({ "deviceName": device_name }).to_string()),
                    ))
                    .await,
            );
            return Err(PairRejection::OwnerDeclined);
        }

        // DEV-04：已有档案 = 这台以前连过。这一次查询回答两件事——审批记录该说
        // 「加入」还是「重新连接」，**以及叫什么名字**。
        let existing = self.db.get_device(&peer.0).await.ok().flatten();
        let rejoining = existing.as_ref().is_some_and(|d| d.pairing.is_none());
        // DEV-04（验收人 2026-09-20 实测）：桌面上改过的名字不能被重连冲掉。
        // `device.rename` 是业主对这台设备的称呼，手机自报名只在还没有档案时
        // 作数（storage 的 accept_pairing 对已有档案保留原名）。
        let name = match &existing {
            Some(d) => d.profile.name.clone(),
            None => safe_name(device_name),
        };
        // #1117：一次配对 = 一条新配对记录，新 id。档案、旧记录替换（若有，连同
        // 挂在它上面的传输状态）、新记录在 storage 里是**一个事务**，中途失败不留
        // 中间态。回复手机之前落库，daemon 重启后照样认得这个 id。
        let pairing_id = fresh_pairing_id().map_err(|_| PairRejection::OwnerDeclined)?;
        let record = storage::Pairing {
            id: pairing_id.clone(),
            node_id: peer.0.to_vec(),
            role,
            paired_at: now_ms,
        };
        self.db
            .accept_pairing(&peer.0, &name, &record)
            .await
            .map_err(|e| {
                tracing::warn!("#1117: accept_pairing failed, pairing rolled back: {e}");
                PairRejection::OwnerDeclined
            })?;

        // DEV-02: 配对流程只写自己这一台。它无权改写任何其它设备的记录。
        let detail = if rejoining {
            format!("{name} (rejoined)")
        } else {
            name.clone()
        };

        warn_if_audit_failed(
            "pair.accepted",
            self.db
                .append_audit(&storage::AuditEntry::local(
                    decided_at,
                    Some(peer.0.to_vec()),
                    "pair.accepted",
                    None,
                    Some(serde_json::json!({ "detail": detail }).to_string()),
                ))
                .await,
        );
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
        Ok(pairing_id)
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

/// 设备名上限，按**字符数**（`chars().count()`）计，不是字节数。
/// 配对自报名（[`safe_name`]）与 `device.rename`（ipc.rs）共用这一个常量。
pub const MAX_DEVICE_NAME_CHARS: usize = 64;

/// #1055：审计写入是尽力而为，不因它让配对/撤销失败；但失败不能静默——
/// 至少留一条 warn，事后查日志能知道这条审计缺了。
pub(crate) fn warn_if_audit_failed<T, E: std::fmt::Display>(action: &str, result: Result<T, E>) {
    if let Err(e) = result {
        tracing::warn!("audit write failed for {action}: {e}");
    }
}

/// Device names come from the network — cap length, strip control chars.
fn safe_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_DEVICE_NAME_CHARS)
        .collect();
    if cleaned.trim().is_empty() {
        "未命名设备".into()
    } else {
        cleaned
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// 128 bits of OS entropy name one owner-approved pairing record (#1117). It
/// is persisted before `PairAccepted` is emitted, so Desktop and phone agree
/// across daemon restart; a re-pair is a new record with a new id.
fn fresh_pairing_id() -> Result<String, getrandom::Error> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)?;
    Ok(hex(&bytes))
}

// H-10b v2 (2026-08-08): 配对 token 32B → 12B。一次性配对 + 10 分钟
// TTL，96-bit 熵绰绰有余；QR 里 token 从 64 hex 字符降到 24。
// （IPC socket token 保持 32B——不同用途，见 main.rs/ipc.rs。）
/// #1118: a SPAKE2 message on the wire (lowercase or uppercase hex, [`pair_pake::MSG_LEN`] bytes).
fn parse_pake_msg(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() != pair_pake::MSG_LEN * 2 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}

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
            let (pairing, _rx) = Pairing::new(db, transport::NodeId([0xAB; 32]), None);
            let qr = pairing.start([0x11; 12], 1_000);
            assert_eq!(
                qr,
                format!("ppf://pair?node={}&t={}", "ab".repeat(32), "11".repeat(12))
            );
        });
    }

    /// #1122：配对窗口跟着二维码走——没有令牌时关着；`start` 后开着；令牌过期或
    /// `stop`（二维码关闭）后立即关上。已提交申请的那台设备在申请结束前照常放行。
    /// 反证：`admits` 恒 true，第一条与 stop 后那条变红；`stop` 不收回令牌，stop
    /// 后那条变红；不看 tickets，最后一条变红。
    #[tokio::test]
    async fn pairing_window_follows_the_qr_code() {
        let db = Db::open_in_memory().await.unwrap();
        let (pairing, _rx) = Pairing::new(db, transport::NodeId([0xAB; 32]), None);
        let phone = transport::NodeId([0x01; 32]);
        assert!(!pairing.admits(phone, 1_000), "没有二维码 = 窗口关着");

        pairing.start([0x11; 12], 1_000);
        assert!(pairing.admits(phone, 1_000), "二维码显示期间开着");
        assert!(
            !pairing.admits(phone, 1_000 + TOKEN_TTL_MS + 1),
            "令牌过期即关"
        );

        assert_eq!(pairing.stop(), 1);
        assert!(!pairing.admits(phone, 1_001), "二维码关闭即关");

        // 已提交申请的设备：业主关掉二维码后仍能轮询自己的结果。
        pairing.start([0x22; 12], 2_000);
        // #1118: the request carries the phone's SPAKE2 message.
        let (_start, msg_a) =
            pair_pake::PhoneStart::start("246810", &[0x22; 12], phone.0, pairing.node_id().0)
                .unwrap();
        let req = proto::PairRequest {
            token: "22".repeat(12),
            device_name: "phone".into(),
            pake_a: msg_a.iter().map(|b| format!("{b:02x}")).collect(),
            ..Default::default()
        };
        pairing.submit_request(phone, &req, 2_000).await.unwrap();
        pairing.stop();
        assert!(pairing.admits(phone, 2_001), "申请人照常放行");
        assert!(
            !pairing.admits(transport::NodeId([0x02; 32]), 2_001),
            "别的设备不放行"
        );
    }

    /// 统一回归发现（#1122）：申请落定、过了保留期以后，这台设备不再过握手准入——被移除的手机
    /// 重连要在握手层收到 401，不能因为一条没人清的旧申请记录一直放行。
    #[tokio::test]
    async fn a_settled_request_stops_admitting_after_its_retention() {
        let db = Db::open_in_memory().await.unwrap();
        let (pairing, mut rx) = Pairing::new(db, transport::NodeId([0xAB; 32]), None);
        let phone = transport::NodeId([0x03; 32]);
        pairing.start([0x33; 12], 2_000);
        let (_start, msg_a) =
            pair_pake::PhoneStart::start("246810", &[0x33; 12], phone.0, pairing.node_id().0)
                .unwrap();
        let req = proto::PairRequest {
            token: "33".repeat(12),
            device_name: "phone".into(),
            pake_a: msg_a.iter().map(|b| format!("{b:02x}")).collect(),
            ..Default::default()
        };
        let submitted = pairing.submit_request(phone, &req, 2_000).await.unwrap();
        rx.recv()
            .await
            .unwrap()
            .decide(PairDecision::Reject)
            .unwrap();
        // Wait for the decision task to settle the ticket.
        for _ in 0..200 {
            let settled = !matches!(
                pairing
                    .view(phone, &submitted.request_id, 2_000)
                    .map(|v| v.state),
                Some(PairState::Pending)
            );
            if settled {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        assert!(
            pairing.admits(phone, 2_001),
            "落定后保留期内照常放行（好轮询结果）"
        );
        // Far past any retention, whatever clock stamped the settlement.
        let much_later = 4_000_000_000_000;
        assert!(
            !pairing.admits(phone, much_later),
            "过了保留期，这条申请记录不再放行"
        );
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
        assert_eq!(
            safe_name(&"x".repeat(200)).chars().count(),
            MAX_DEVICE_NAME_CHARS
        );
        assert_eq!(
            safe_name(&"设".repeat(200)).chars().count(),
            MAX_DEVICE_NAME_CHARS
        );
    }
}
