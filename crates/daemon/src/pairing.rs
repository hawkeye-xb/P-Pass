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

/// A pairing request waiting for the owner's decision.
#[derive(Debug)]
pub struct PendingPair {
    pub peer: transport::NodeId,
    pub device_name: String,
    pub role: Role,
    decision: oneshot::Sender<bool>,
}

impl PendingPair {
    pub fn decide(self, accept: bool) {
        let _ = self.decision.send(accept);
    }
}

struct TokenState {
    expires_at: i64,
    used: bool,
}

struct Inner {
    tokens: HashMap<[u8; 32], TokenState>,
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
    /// Serialized dialable address, appended to QR strings as `&a=` so a
    /// scan connects without discovery services (真机冒烟教训: 办公网屏蔽
    /// n0 发现,纯 NodeId 拨号失败).
    addr_token: Option<String>,
    inner: Arc<Mutex<Inner>>,
}

impl Pairing {
    /// Returns the engine plus the receiver the owner UI listens on.
    /// `addr_token` is `transport.local_addr().to_string()` in production
    /// (None keeps QR strings short in unit tests).
    pub fn new(
        db: Db,
        node_id: transport::NodeId,
        addr_token: Option<String>,
    ) -> (Self, tokio::sync::mpsc::UnboundedReceiver<PendingPair>) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (
            Self {
                db,
                node_id,
                addr_token,
                inner: Arc::new(Mutex::new(Inner {
                    tokens: HashMap::new(),
                    pending_tx: tx,
                })),
            },
            rx,
        )
    }

    /// Issue a fresh one-time token and return the QR content string.
    pub fn start(&self, token: [u8; 32], now_ms: i64) -> String {
        let mut inner = self.inner.lock().expect("pairing lock");
        inner.tokens.insert(
            token,
            TokenState {
                expires_at: now_ms + TOKEN_TTL_MS,
                used: false,
            },
        );
        let mut qr = format!("ppf://pair?node={}&t={}", self.node_id, hex(&token));
        if let Some(addr) = &self.addr_token {
            qr.push_str("&a=");
            qr.push_str(addr);
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
    ) -> Result<(), PairRejection> {
        let role = match req.role.as_str() {
            "viewer" => Role::Viewer,
            // §2.2: joining devices are members unless explicitly viewer;
            // owner is never granted over the network.
            _ => Role::Member,
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
                decision: tx,
            };
            if inner.pending_tx.send(pending).is_err() {
                return Err(PairRejection::OwnerDeclined); // UI gone = no
            }
            rx
        };

        match decision_rx.await {
            Ok(true) => {}
            _ => return Err(PairRejection::OwnerDeclined),
        }

        let device = Device {
            node_id: peer.0.to_vec(),
            name: safe_name(&req.device_name),
            role,
            paired_at: now_ms,
            last_seen: Some(now_ms),
            revoked: false,
        };
        self.db
            .upsert_device(&device)
            .await
            .map_err(|_| PairRejection::OwnerDeclined)?;
        let _ = self
            .db
            .append_audit(&storage::AuditEntry {
                ts: now_ms,
                actor: Some(peer.0.to_vec()),
                action: "pair.accepted".into(),
                target_hash: None,
                detail: Some(device.name.clone()),
            })
            .await;
        Ok(())
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

fn parse_token(s: &str) -> Option<[u8; 32]> {
    let s = s.trim();
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in s.as_bytes().chunks_exact(2).enumerate() {
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
            let qr = pairing.start([0x11; 32], 1_000);
            assert_eq!(
                qr,
                format!("ppf://pair?node={}&t={}", "ab".repeat(32), "11".repeat(32))
            );
        });
    }

    #[test]
    fn token_parsing_rejects_garbage() {
        assert!(parse_token(&"zz".repeat(32)).is_none());
        assert!(parse_token("abcd").is_none());
        assert_eq!(parse_token(&"11".repeat(32)), Some([0x11; 32]));
    }

    #[test]
    fn hostile_device_names_are_defanged() {
        assert_eq!(safe_name("妈妈的手机"), "妈妈的手机");
        assert_eq!(safe_name("a\x00b\x1fc"), "abc");
        assert_eq!(safe_name("   "), "未命名设备");
        assert_eq!(safe_name(&"x".repeat(200)).len(), 64);
    }
}
