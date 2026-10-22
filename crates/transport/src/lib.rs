//! Transport — thin abstraction over the network stack (详细设计 §3.1).
//!
//! Architecture enforcement: this is the ONLY crate allowed to import `iroh`.
//! Business code sees the [`Transport`] trait plus the opaque [`Incoming`],
//! [`BiStream`] and [`ConnInfo`] types. The MVP implementation is iroh
//! (ADR-001); the Phase-2 WebRTC read-only subset hangs off the same
//! interface, at which point these concrete types become enums.

// IOS-05 (#312)：provider 内核与绑定分离。`provider` 平台中立、不含任何
// `jni::` 符号；JNI 是绑定 #1，只在 `android-jni` feature 下编进来。
#[cfg(feature = "android-jni")]
mod android_jni;
#[cfg(feature = "android-jni")]
mod android_logcat;
#[cfg(any(feature = "android-jni", test))]
mod android_wire;
mod blobs;
mod conninfo;
#[cfg(feature = "ios-ffi")]
mod ios_ffi;
mod iroh_impl;
mod pair_link;
mod provider;
/// #548：Rust → logcat 出口的脱敏（daemon `redact()` 的日志口径拷贝，跑共用向量）。
pub mod redact;

pub use blobs::{Blobs, PeerGate};
pub use conninfo::{ConnInfo, ConnectionStatus, PathKind};
pub use iroh_impl::{
    node_id_from_secret_key, BiStream, Incoming, IrohTransport, PeerAddr, TransportConfig,
};
pub use pair_link::{parse_pair_link, PairLink};
/// IOS-05 (#312)：内核改名为平台中立的 [`BlobsProvider`] 之前的名字。现有
/// 调用方（本 crate 与 daemon 的集成测试）照旧可用；新代码用 `BlobsProvider`。
pub use provider::BlobsProvider as AndroidBlobsProvider;
pub use provider::{
    ActiveTransferStatus, BlobsProvider, ImportFallback, MediaImport, ServeError, SourceFault,
};

use std::fmt;

// IOS-06 (#313): UniFFI scaffolding for binding #2. Feature-gated exactly like
// the JNI binding — never a target_os cfg (arch-check B.2).
#[cfg(feature = "ios-ffi")]
uniffi::setup_scaffolding!();

use futures_core::Stream;

/// ALPN for the control plane: pairing, timeline queries, thumbnails,
/// diagnostics. Payload: length-prefixed JSON frames (`proto::codec`).
/// #1069: this ALPN never follows the protocol version — it stays
/// `ppf/ctrl/1`. Incompatibility is negotiated in band (`Req`/`Resp`
/// `ver` / `min_ver`, `proto::compatibility`), so an outdated peer still
/// connects and is told which device to update instead of failing at the
/// connection layer. (Supersedes 详细设计 §3.2's "new ALPN + dual-stack".)
pub const ALPN_CTRL: &str = "ppf/ctrl/1";

/// #544：给宿主进程 `EnvFilter` 追加的指令——iroh 的 net_report 在 warn
/// 级别直接打印本机公网地址（QAD 结果），源头压到 error。iroh 的 target
/// 名只许出现在本 crate（架构红线 B.1），所以由这里导出。
pub const QUIET_LOG_DIRECTIVES: &str = "iroh::net_report=error";

/// ALPN for the data plane: photo/video content via iroh-blobs (T-021).
pub const ALPN_BLOBS: &str = "ppf/blobs/1";

/// ALPN for the download plane (T-056): original-file bytes for video
/// playback — one asset per stream, authz-gated like everything else.
pub const ALPN_DOWNLOAD: &str = "ppf/download/1";

/// #1119：桌面删掉一台设备的配对记录后主动关闭与它的连接时用的 QUIC 关闭码
/// （`IrohTransport::close_peer`）。与 blobs 拒绝码 403 区分开：这一条的意思是
/// 「你的配对已被删除」。
pub const UNPAIRED_CLOSE_CODE: u32 = 410;

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
        for (i, chunk) in s.as_bytes().as_chunks::<2>().0.iter().enumerate() {
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

    #[error("invalid pairing link: {0}")]
    InvalidPairLink(String),
}

pub type Result<T> = std::result::Result<T, TransportError>;

/// Maximum frame size accepted on the wire. Mirrors `proto::codec`'s
/// MAX_PAYLOAD (16 MiB) — kept as a local constant because transport must
/// not depend on proto (dependency direction: daemon wires them together).
pub const MAX_FRAME: u32 = 16 * 1024 * 1024;

/// 详细设计 §3.1 —— trait 签名逐字实施（对冲 iroh 风险的瘦抽象）。
///
/// `ConnInfo` feeds the self-diagnosis UI
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
