//! #546: the blobs data plane's gate. `ALPN_BLOBS` connections are served by
//! iroh-blobs inside the transport, not by the router, so they never reach
//! `router.rs` `serve_stream`; this module is how they still pass the one
//! authz checkpoint (`authz::check` with the [`authz::BLOBS_FETCH`]
//! pseudo-method) — for the connection and again for every request on it.
//!
//! The device row is read fresh on every call (no cache): revoking a device
//! denies its very next blobs request.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use storage::{Db, DiagEvent};
use transport::{NodeId, PeerGate};

use crate::authz::{self, Decision};

/// The gate handed to `Blobs::attach_to_listener`.
pub fn gate(db: Db) -> PeerGate {
    Arc::new(move |peer| {
        let db = db.clone();
        Box::pin(async move { allow(&db, peer).await })
    })
}

/// One decision. A failed device lookup is a denial (fail closed).
pub async fn allow(db: &Db, peer: NodeId) -> bool {
    let device = match db.get_device(&peer.0).await {
        Ok(device) => device,
        Err(error) => {
            tracing::error!("blobs gate: device lookup failed, denying: {error}");
            record_denial(db, peer, diag::keys::ERR_NOT_AUTHORIZED).await;
            return false;
        }
    };
    match authz::check(device.as_ref(), authz::BLOBS_FETCH) {
        Decision::Allow => true,
        Decision::Deny { msg_key } => {
            tracing::warn!("blobs gate: denied peer={} ({msg_key})", peer_prefix(peer));
            record_denial(db, peer, msg_key).await;
            false
        }
    }
}

/// Only the first 4 bytes (8 hex chars) of the NodeId are recorded: enough
/// to tell devices apart in a diagnosis, not enough to dial anyone.
pub fn peer_prefix(peer: NodeId) -> String {
    peer.0[..4].iter().map(|b| format!("{b:02x}")).collect()
}

/// Same event kind as the ctrl plane's denials (`authz.denied`); the method
/// field says which plane. No address, no hash.
async fn record_denial(db: &Db, peer: NodeId, msg_key: &str) {
    let detail = format!(
        "{{\"peer\":\"{}\",\"method\":\"{}\",\"msg_key\":\"{msg_key}\"}}",
        peer_prefix(peer),
        authz::BLOBS_FETCH
    );
    let event = DiagEvent {
        ts: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0),
        kind: "authz.denied".into(),
        detail: Some(detail),
    };
    if let Err(error) = db.append_diag(&event).await {
        tracing::error!("diag append failed: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefix_is_eight_hex_chars() {
        let peer = NodeId([0xab; 32]);
        assert_eq!(peer_prefix(peer), "abababab");
    }
}
