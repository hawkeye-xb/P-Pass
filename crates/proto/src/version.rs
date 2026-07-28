//! P-Pass protocol — version constant.

/// Current wire protocol version.
/// Incremented on breaking changes; old peers stay on prior ALPN.
pub const PROTO_VER: u16 = 1;

/// Minimum supported protocol version.
/// Peers that declare no `min_ver` default to this value (most conservative),
/// meaning the response must be compatible with the oldest known peer.
pub const MIN_SUPPORTED_VER: u16 = 1;
