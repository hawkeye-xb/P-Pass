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
//! is rejected even while the first request is still pending.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use storage::{Db, Device, Role};
use tokio::sync::oneshot;

pub const TOKEN_TTL_MS: i64 = 600_000;

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
/// DEV-01: `AcceptMerge` carries the old device whose data (assets,
/// watermark, name) the fresh pairing takes over — the owner picked
/// "替换旧的 <名字>" in the confirm dialog. `Accept` = plain join.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairDecision {
    /// Join as a brand-new device (identical to pre-DEV-01 accept).
    Accept,
    /// Join and merge the named old device's data into this identity.
    AcceptMerge { old_node_id: Vec<u8> },
    /// The owner said no.
    Reject,
}

/// A device that matches the joining device's reinstall hint (DEV-01).
#[derive(Debug, Clone)]
pub struct HintMatch {
    pub node_id: Vec<u8>,
    pub name: String,
}

/// A pairing request waiting for the owner's decision.
#[derive(Debug)]
pub struct PendingPair {
    pub peer: transport::NodeId,
    pub device_name: String,
    pub role: Role,
    /// DEV-01: joining device's reinstall fingerprint, if the client
    /// sent one (owner enabled 重装识别 on the phone).
    pub device_hint: Option<String>,
    /// DEV-01: an existing non-revoked device sharing the same hint —
    /// the "replace the old device" candidate. None = no match.
    pub hint_match: Option<HintMatch>,
    decision: oneshot::Sender<PairDecision>,
}

impl PendingPair {
    pub fn decide(self, decision: PairDecision) {
        let _ = self.decision.send(decision);
    }
}

struct TokenState {
    expires_at: i64,
    used: bool,
}

struct Inner {
    tokens: HashMap<[u8; 12], TokenState>,
    /// Owner-side queue of requests awaiting confirmation (UI drains it;
    /// tests drain it directly).
    pending_tx: tokio::sync::mpsc::UnboundedSender<PendingPair>,
}

/// Pairing engine: token issuance + request handling. Cloneable — router
/// and IPC layer share one.
#[derive(Clone)]
pub struct Pairing {
    db: Db,
    node_id: transport::NodeId,
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
                addr_provider,
                relay_provider,
                events: None,
                inner: Arc::new(Mutex::new(Inner {
                    tokens: HashMap::new(),
                    pending_tx: tx,
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

    /// Handle one inbound PairRequest. Consumes the token, parks the
    /// request for owner confirmation, resolves when the owner decides.
    pub async fn handle_request(
        &self,
        peer: transport::NodeId,
        req: &proto::PairRequest,
        now_ms: i64,
    ) -> Result<String, PairRejection> {
        let role = match req.role.as_str() {
            "viewer" => Role::Viewer,
            // §2.2: joining devices are members unless explicitly viewer;
            // owner is never granted over the network.
            _ => Role::Member,
        };

        // DEV-01: resolve the reinstall-hint match *before* parking the
        // request — the confirm dialog needs to know whether "替换旧的"
        // is even offered. Hint is a hint only: no match = plain join.
        let hint_match = match &req.device_hint {
            Some(hint) => self
                .db
                .find_by_hint(hint, &peer.0)
                .await
                .ok()
                .and_then(|v| v.into_iter().next())
                .map(|d| HintMatch {
                    node_id: d.node_id,
                    name: d.name,
                }),
            None => None,
        };

        let decision_rx = {
            let mut inner = self.inner.lock().expect("pairing lock");
            let token = parse_token(&req.token).ok_or(PairRejection::BadToken)?;
            let state = inner
                .tokens
                .get_mut(&token)
                .ok_or(PairRejection::BadToken)?;
            if state.used || now_ms > state.expires_at {
                return Err(PairRejection::BadToken);
            }
            state.used = true; // one-time, consumed no matter what follows

            let (tx, rx) = oneshot::channel();
            let pending = PendingPair {
                peer,
                device_name: req.device_name.clone(),
                role,
                device_hint: req.device_hint.clone(),
                hint_match,
                decision: tx,
            };
            if inner.pending_tx.send(pending).is_err() {
                return Err(PairRejection::OwnerDeclined); // UI gone = no
            }
            rx
        };

        // T5: 扫码请求到达即审计（含后续被拒/超时——审计要全，不只看成功）。
        let _ = self
            .db
            .append_audit(&storage::AuditEntry {
                ts: now_ms,
                actor: Some(peer.0.to_vec()),
                action: "pair.requested".into(),
                target_hash: None,
                detail: Some(req.device_name.clone()),
            })
            .await;

        let decision = decision_rx.await;
        let (accept, merge_from) = match decision {
            Ok(PairDecision::Accept) => (true, None),
            Ok(PairDecision::AcceptMerge { old_node_id }) => (true, Some(old_node_id)),
            _ => (false, None),
        };

        if !accept {
            // T5: owner 拒绝（或 UI 消失/超时）同样入审计。
            let _ = self
                .db
                .append_audit(&storage::AuditEntry {
                    ts: now_ms,
                    actor: Some(peer.0.to_vec()),
                    action: "pair.denied".into(),
                    target_hash: None,
                    detail: Some(req.device_name.clone()),
                })
                .await;
            return Err(PairRejection::OwnerDeclined);
        }

        let device = Device {
            node_id: peer.0.to_vec(),
            name: safe_name(&req.device_name),
            role,
            paired_at: now_ms,
            last_seen: Some(now_ms),
            revoked: false,
            device_hint: req.device_hint.clone(),
        };
        let rejoining = matches!(
            self.db.get_device(&peer.0).await,
            Ok(Some(d)) if d.revoked
        );
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

        // DEV-01: owner picked "替换旧的" — migrate the old device's
        // assets/watermark into this fresh identity and delete it.
        let mut detail = if rejoining {
            format!("{} (rejoined after revoke)", device.name)
        } else {
            device.name.clone()
        };
        if let Some(old_id) = merge_from {
            if let Ok(old_name) = self.db.merge_device(&old_id, &peer.0).await {
                detail = format!(
                    "{} (merged from {} — reinstall replacement)",
                    device.name, old_name
                );
                let _ = self
                    .db
                    .append_audit(&storage::AuditEntry {
                        ts: now_ms,
                        actor: Some(peer.0.to_vec()),
                        action: "device.merged".into(),
                        target_hash: None,
                        detail: Some(format!(
                            "from {} to {} (reinstall replacement)",
                            hex(&old_id),
                            hex(&peer.0)
                        )),
                    })
                    .await;
            }
        }

        let _ = self
            .db
            .append_audit(&storage::AuditEntry {
                ts: now_ms,
                actor: Some(peer.0.to_vec()),
                action: "pair.accepted".into(),
                target_hash: None,
                detail: Some(detail),
            })
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
    }
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
