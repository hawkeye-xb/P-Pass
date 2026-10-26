//! Pairing link (`ppf://pair?...`) parsing — the one Rust implementation.
//!
//! The daemon (`crates/daemon/src/pairing.rs`) writes the link; the dev
//! `testclient` and the iOS app (through the `mobile-ffi` binding) read it here.
//! Android keeps its Kotlin twin (`PeerAddrToken.kt`) until it moves to a
//! shared binding.
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

/// Parses a `ppf://pair?...` link (surrounding whitespace ignored).
pub fn parse_pair_link(link: &str) -> Result<PairLink> {
    let link = link.trim();
    let rest = link
        .strip_prefix(PREFIX)
        .ok_or_else(|| bad("must start with ppf://pair?node="))?;
    let (node_hex, rest) = rest
        .split_once("&t=")
        .ok_or_else(|| bad("missing &t=<token>"))?;
    let node_id: NodeId = node_hex
        .parse()
        .map_err(|_| bad(format!("node id {node_hex:?} is not a valid NodeId")))?;
    let (token, peer_addr) = match rest.split_once("&r=") {
        Some((token, relay)) => (token, PeerAddr::from_node_relay(node_id, Some(relay))?),
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
    let token = token.trim();
    if token.is_empty() {
        return Err(bad("empty token"));
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
            "ppf://pair?node={n}&t=9fc4f658f6ce2c03&r=https://usw1-1.relay.n0.iroh.link\n"
        ))
        .unwrap();
        assert_eq!(link.node_id, n);
        assert_eq!(link.token, "9fc4f658f6ce2c03");
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
        let link = parse_pair_link(&format!("ppf://pair?node={n}&t=abcd1234&a={full}")).unwrap();
        assert_eq!(link.token, "abcd1234");
        assert_eq!(link.peer_addr.node_id(), n);
        let other = PeerAddr::from_node_relay(node(3), None).unwrap();
        assert!(parse_pair_link(&format!("ppf://pair?node={n}&t=abcd1234&a={other}")).is_err());
    }

    #[test]
    fn node_and_token_only() {
        let n = node(4);
        let link = parse_pair_link(&format!("ppf://pair?node={n}&t=deadbeef")).unwrap();
        assert_eq!(link.token, "deadbeef");
        assert_eq!(link.peer_addr.node_id(), n);
        assert_eq!(link.peer_addr.relay_url(), None);
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
        ] {
            assert!(parse_pair_link(&bad).is_err(), "{bad} should be rejected");
        }
    }
}
