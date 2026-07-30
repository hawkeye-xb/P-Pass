//! Transport — thin abstraction over the network stack (详细设计 §3.1).
//!
//! Architecture enforcement: this is the ONLY crate allowed to import `iroh`.
//! Business code sees the [`Transport`] trait plus the opaque [`Incoming`],
//! [`BiStream`] and [`ConnInfo`] types. The MVP implementation is iroh
//! (ADR-001); the Phase-2 WebRTC read-only subset hangs off the same
//! interface, at which point these concrete types become enums.

mod blobs;
mod conninfo;
mod iroh_impl;

pub use blobs::Blobs;
pub use conninfo::{ConnInfo, PathKind};
pub use iroh_impl::{BiStream, Incoming, IrohTransport, PeerAddr, TransportConfig};

use std::fmt;

use futures_core::Stream;

/// ALPN for the control plane: pairing, timeline queries, thumbnails,
/// diagnostics. Payload: length-prefixed JSON frames (`proto::codec`).
/// 详细设计 §3.2 — the trailing number is the major version; incompatible
/// changes open a new ALPN and run dual-stack during transition.
pub const ALPN_CTRL: &str = "ppf/ctrl/1";

/// ALPN for the data plane: photo/video content via iroh-blobs (T-021).
pub const ALPN_BLOBS: &str = "ppf/blobs/1";

/// Device identity: the 32-byte ed25519 public key of an endpoint (ADR-004,
/// no account system). Displayed as 64 lowercase hex characters.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId(pub [u8; 32]);

impl fmt::Display for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for b in self.0 {
            write!(f, "{b:02x}")?;
        }
        Ok(())
    }
}

impl fmt::Debug for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Short form for logs: first 5 bytes, like iroh's fmt_short().
        for b in &self.0[..5] {
            write!(f, "{b:02x}")?;
        }
        write!(f, "…")
    }
}

impl std::str::FromStr for NodeId {
    type Err = TransportError;

    fn from_str(s: &str) -> Result<Self> {
        let s = s.trim();
        if s.len() != 64 || !s.is_ascii() {
            return Err(TransportError::InvalidNodeId);
        }
        let mut bytes = [0u8; 32];
        for (i, chunk) in s.as_bytes().chunks_exact(2).enumerate() {
            let hi = hex_val(chunk[0]).ok_or(TransportError::InvalidNodeId)?;
            let lo = hex_val(chunk[1]).ok_or(TransportError::InvalidNodeId)?;
            bytes[i] = (hi << 4) | lo;
        }
        Ok(NodeId(bytes))
    }
}

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// Transport-layer errors. String payloads instead of wrapped iroh error
/// types — iroh types must not leak through this crate's public API.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("bind endpoint: {0}")]
    Bind(String),

    #[error("connect to {peer}: {reason}")]
    Connect { peer: NodeId, reason: String },

    #[error("stream I/O: {0}")]
    Io(String),

    #[error("frame too large: {0} bytes (max {MAX_FRAME})")]
    FrameTooLarge(u32),

    #[error("truncated frame: expected {expected} payload bytes, got {got}")]
    TruncatedFrame { expected: usize, got: usize },

    #[error("invalid node id")]
    InvalidNodeId,
}

pub type Result<T> = std::result::Result<T, TransportError>;

/// Maximum frame size accepted on the wire. Mirrors `proto::codec`'s
/// MAX_PAYLOAD (16 MiB) — kept as a local constant because transport must
/// not depend on proto (dependency direction: daemon wires them together).
pub const MAX_FRAME: u32 = 16 * 1024 * 1024;

/// 详细设计 §3.1 —— trait 签名逐字实施（对冲 iroh 风险的瘦抽象）。
///
/// `ConnInfo` feeds both telemetry and the self-diagnosis UI
/// ("直连中 ✓ / 中继中，速度受限").
#[allow(async_fn_in_trait)] // MVP: single in-process implementation, no dyn/Send bounds needed yet
pub trait Transport {
    async fn listen(&self) -> impl Stream<Item = Incoming>;
    async fn connect(&self, peer: NodeId, alpn: &str) -> Result<BiStream>;
    fn conn_info(&self, peer: NodeId) -> ConnInfo;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_id_hex_roundtrip() {
        let id = NodeId([0xab; 32]);
        let s = id.to_string();
        assert_eq!(s.len(), 64);
        assert_eq!(s.parse::<NodeId>().unwrap(), id);
    }

    #[test]
    fn node_id_rejects_bad_input() {
        assert!("zz".repeat(32).parse::<NodeId>().is_err());
        assert!("abcd".parse::<NodeId>().is_err());
    }

    #[test]
    fn alpn_constants_match_registry() {
        // 详细设计 §3.2 registry — a typo here would silently split the network.
        assert_eq!(ALPN_CTRL, "ppf/ctrl/1");
        assert_eq!(ALPN_BLOBS, "ppf/blobs/1");
    }
}
