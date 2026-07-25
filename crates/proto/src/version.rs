//! P-Pass protocol — version constant.

/// Current wire protocol version.
/// Incremented on breaking changes; old peers stay on prior ALPN.
pub const PROTO_VER: u16 = 1;
