//! Pairing link (`ppf://pair?...`) parsing — the one Rust implementation.
//!
//! The daemon (`crates/daemon/src/pairing.rs`) writes the link; the dev
//! `testclient` and the iOS app (through the `mobile-ffi` binding) read it here.
//! Android reads it through the same `mobile-ffi` binding (#1149) — there is no
//! second parser.
//!
//! Strict (#1149): `node` is exactly 64 hex, `t` is exactly 24 hex (the daemon's one-time
//! token), and `r` is `https://` + a valid host name (+ optional port / bare `/`). Anything else
//! is a malformed link; nothing downstream sees its parts.
//!
//! Shapes accepted (same contract as Android `parsePairLink`):
//! - current (H-10b): `ppf://pair?node=<64hex>&t=<token>&r=<relay URL>` — the
//!   address is rebuilt from node + relay;
//! - legacy (<= 0.3.0-test.2): `&a=<full PeerAddr token>`;
//! - neither: node + token only; the address carries no hints and iroh
//!   resolves it via address lookup.

use crate::{NodeId, PeerAddr, Result, TransportError};

const PREFIX: &str = "ppf://pair?node=";

/// A parsed pairing link.
#[derive(Debug, Clone)]
pub struct PairLink {
    /// The storage end (daemon) to pair with.
    pub node_id: NodeId,
    /// One-time pairing token for `pair.request`.
    pub token: String,
    /// Where to dial `node_id`; always names `node_id`.
    pub peer_addr: PeerAddr,
}

fn bad(msg: impl Into<String>) -> TransportError {
    TransportError::InvalidPairLink(msg.into())
}

/// Hex digits of the daemon's one-time pairing token (`pairing.rs::parse_token`: 12 bytes).
const TOKEN_HEX_LEN: usize = 24;

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// `https://<host>[:port][/]` with a plain host name (letters, digits, `-`, dot-separated labels,
/// one optional trailing dot). No userinfo, query, fragment, quotes, backslashes or other path.
fn valid_relay(relay: &str) -> bool {
    let Some(rest) = relay.strip_prefix("https://") else {
        return false;
    };
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let (host, port) = match rest.split_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (rest, None),
    };
    if let Some(port) = port {
        let digits =
            !port.is_empty() && port.len() <= 5 && port.bytes().all(|b| b.is_ascii_digit());
        if !digits || port.parse::<u32>().map_or(true, |p| p == 0 || p > 65535) {
            return false;
        }
    }
    let host = host.strip_suffix('.').unwrap_or(host);
    !host.is_empty()
        && host.len() <= 253
        && host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

/// Parses a `ppf://pair?...` link (surrounding whitespace ignored).
pub fn parse_pair_link(link: &str) -> Result<PairLink> {
    let link = link.trim();
    let rest = link
        .strip_prefix(PREFIX)
        .ok_or_else(|| bad("must start with ppf://pair?node="))?;
    let (node_hex, rest) = rest
        .split_once("&t=")
        .ok_or_else(|| bad("missing &t=<token>"))?;
    if !is_hex(node_hex, 64) {
        return Err(bad("node id must be 64 hex characters"));
    }
    let node_id: NodeId = node_hex
        .parse()
        .map_err(|_| bad(format!("node id {node_hex:?} is not a valid NodeId")))?;
    let (token, peer_addr) = match rest.split_once("&r=") {
        Some((token, relay)) => {
            if !valid_relay(relay) {
                return Err(bad("relay must be https:// plus a valid host name"));
            }
            (token, PeerAddr::from_node_relay(node_id, Some(relay))?)
        }
        None => match rest.split_once("&a=") {
            Some((token, legacy)) => {
                let addr: PeerAddr = legacy
                    .parse()
                    .map_err(|_| bad("legacy &a= address is not a PeerAddr token"))?;
                if addr.node_id() != node_id {
                    return Err(bad("legacy &a= address names a different node"));
                }
                (token, addr)
            }
            None => (rest, PeerAddr::from_node_relay(node_id, None)?),
        },
    };
    if !is_hex(token, TOKEN_HEX_LEN) {
        return Err(bad("token must be 24 hex characters"));
    }
    Ok(PairLink {
        node_id,
        token: token.to_owned(),
        peer_addr,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node_id_from_secret_key;

    // Real public keys: NodeId parsing checks the curve point.
    fn node(seed: u8) -> NodeId {
        node_id_from_secret_key(&[seed; 32])
    }

    #[test]
    fn current_relay_shape() {
        let n = node(1);
        let link = parse_pair_link(&format!(
            "ppf://pair?node={n}&t=9fc4f658f6ce2c0300000000&r=https://usw1-1.relay.n0.iroh.link\n"
        ))
        .unwrap();
        assert_eq!(link.node_id, n);
        assert_eq!(link.token, "9fc4f658f6ce2c0300000000");
        assert_eq!(link.peer_addr.node_id(), n);
        // iroh normalises the URL (default port dropped, trailing slash).
        assert_eq!(
            link.peer_addr
                .relay_url()
                .as_deref()
                .map(|u| u.trim_end_matches('/')),
            Some("https://usw1-1.relay.n0.iroh.link")
        );
        // The token form round-trips (what Swift hands to CtrlClient.call).
        let back: PeerAddr = link.peer_addr.to_string().parse().unwrap();
        assert_eq!(back.node_id(), n);
    }

    #[test]
    fn legacy_full_address_shape() {
        let n = node(2);
        let full = PeerAddr::from_node_relay(n, Some("https://relay.example")).unwrap();
        let link = parse_pair_link(&format!(
            "ppf://pair?node={n}&t=abcd1234abcd1234abcd1234&a={full}"
        ))
        .unwrap();
        assert_eq!(link.token, "abcd1234abcd1234abcd1234");
        assert_eq!(link.peer_addr.node_id(), n);
        let other = PeerAddr::from_node_relay(node(3), None).unwrap();
        assert!(parse_pair_link(&format!(
            "ppf://pair?node={n}&t=abcd1234abcd1234abcd1234&a={other}"
        ))
        .is_err());
    }

    #[test]
    fn node_and_token_only() {
        let n = node(4);
        let link =
            parse_pair_link(&format!("ppf://pair?node={n}&t=deadbeefdeadbeefdeadbeef")).unwrap();
        assert_eq!(link.token, "deadbeefdeadbeefdeadbeef");
        assert_eq!(link.peer_addr.node_id(), n);
        assert_eq!(link.peer_addr.relay_url(), None);
    }

    const TOKEN: &str = "9fc4f658f6ce2c0300000000";

    #[test]
    fn accepts_the_relay_shapes_the_daemon_emits() {
        let n = node(6);
        for relay in [
            "https://usw1-1.relay.n0.iroh.link",
            "https://aps1-1.relay.n0.iroh.link./",
            "https://relay.example.com:8443",
            "https://relay.example.com:8443/",
        ] {
            parse_pair_link(&format!("ppf://pair?node={n}&t={TOKEN}&r={relay}"))
                .unwrap_or_else(|e| panic!("{relay}: {e}"));
        }
    }

    #[test]
    fn rejects_malformed_links() {
        let n = node(5);
        for bad in [
            "http://not-a-pair-link".to_owned(),
            "ppf://pair?node=abc".to_owned(),
            "ppf://pair?node=zz&t=1".to_owned(),
            format!("ppf://pair?node={n}&t="),
            format!("ppf://pair?node={n}&t=1&r=not a url"),
            format!("ppf://pair?node={n}&t=1&a=@@@"),
            // #1149：长度不对 / 非 hex 的 node 与 token
            format!("ppf://pair?node={}&t={TOKEN}", &n.to_string()[..62]),
            format!("ppf://pair?node={n}0&t={TOKEN}"),
            format!("ppf://pair?node={}&t={TOKEN}", "g".repeat(64)),
            format!("ppf://pair?node={n}&t=9fc4f658f6ce2c0"),
            format!("ppf://pair?node={n}&t=9fc4f658f6ce2c033"),
            format!("ppf://pair?node={n}&t=zzzzzzzzzzzzzzzzzzzzzzzz"),
            // relay 不是 https / 主机名不合法 / 带引号、反斜杠、userinfo、query
            format!("ppf://pair?node={n}&t={TOKEN}&r=http://relay.example.com"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=relay.example.com"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=https://"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=https://re\"lay.example.com"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=https://relay\\.example.com"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=https://user@relay.example.com"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=https://relay.example.com/x?y=1"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=https://relay.example.com:0"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=https://relay.example.com:99999"),
            format!("ppf://pair?node={n}&t={TOKEN}&r=https://-bad.example.com"),
        ] {
            assert!(parse_pair_link(&bad).is_err(), "{bad} should be rejected");
        }
    }
}
