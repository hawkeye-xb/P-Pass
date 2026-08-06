//! ConnInfo — path classification for telemetry and the diag UI.
//!
//! Classification is a pure function over iroh-independent [`PathFacts`],
//! so the mapping logic is unit-testable without touching the network.
//! (Lesson from the Android probe's ipver bug: classifier logic gets its
//! own tests, always.)

use std::net::IpAddr;
use std::time::Duration;

/// Network path class of a live connection (详细设计 §3.1: Lan|Direct|Relay).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathKind {
    /// Remote address is non-routable — same local network.
    Lan,
    /// Holepunched or public UDP path across the internet.
    Direct,
    /// Traffic rides a relay server (TCP 443) — works, but rate-limited.
    Relay,
}

/// Connection facts for telemetry and the self-diagnosis UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnInfo {
    /// `None` = no live connection to this peer. §3.1 declares `conn_info`
    /// infallible and the diag UI needs an "offline" answer anyway, so
    /// absence is modeled here rather than as an error.
    pub path: Option<PathKind>,
    /// RTT of the selected path in milliseconds; 0 when `path` is `None`.
    pub rtt_ms: u64,
}

impl ConnInfo {
    /// The "no live connection" answer.
    pub const NONE: ConnInfo = ConnInfo {
        path: None,
        rtt_ms: 0,
    };
}

/// Neutral per-device connection status for `devices.list` (T-090).
/// This vocabulary is the ONLY connection surface allowed past the
/// transport boundary — iroh types never leave this crate (rule B.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionStatus {
    /// Live connection over a LAN or holepunched/public UDP path.
    Direct,
    /// Live connection riding a relay server (works, rate-limited).
    Relay,
    /// No live connection to this peer right now (definitive: the
    /// endpoint holds no open connection).
    Offline,
    /// Cannot determine — transport not bound yet, or a live connection
    /// whose paths are unreadable. Never inferred from `last_seen`.
    Unknown,
}

impl ConnectionStatus {
    /// Wire form used in the IPC JSON (`devices.list[].connection`).
    pub fn as_str(self) -> &'static str {
        match self {
            ConnectionStatus::Direct => "direct",
            ConnectionStatus::Relay => "relay",
            ConnectionStatus::Offline => "offline",
            ConnectionStatus::Unknown => "unknown",
        }
    }
}

/// Status of a LIVE connection from its classified path info. `Offline`
/// is the caller's verdict (absence of a connection); a live connection
/// whose paths cannot be read is `Unknown`, never guessed.
pub(crate) fn status_of_live(info: ConnInfo) -> ConnectionStatus {
    match info.path {
        Some(PathKind::Lan | PathKind::Direct) => ConnectionStatus::Direct,
        Some(PathKind::Relay) => ConnectionStatus::Relay,
        None => ConnectionStatus::Unknown,
    }
}

/// iroh-independent snapshot of one open network path.
#[derive(Debug, Clone, Copy)]
pub(crate) struct PathFacts {
    /// Whether the QUIC path selector currently routes traffic here.
    pub selected: bool,
    /// Whether this path goes through a relay server.
    pub relay: bool,
    /// Remote IP for UDP paths; `None` for relay paths.
    pub remote_ip: Option<IpAddr>,
    pub rtt: Duration,
}

/// Classify a connection from its open paths. Prefers the selected path —
/// that is what traffic actually rides on; falls back to the first path
/// during the brief window before selection settles.
pub(crate) fn classify(paths: &[PathFacts]) -> ConnInfo {
    let Some(p) = paths.iter().find(|p| p.selected).or_else(|| paths.first()) else {
        return ConnInfo::NONE;
    };
    let kind = if p.relay {
        PathKind::Relay
    } else if p.remote_ip.is_some_and(is_lan_ip) {
        PathKind::Lan
    } else {
        PathKind::Direct
    };
    ConnInfo {
        path: Some(kind),
        rtt_ms: p.rtt.as_millis() as u64,
    }
}

/// LAN = the remote address is non-routable (private/loopback/link-local).
/// Deliberately address-based, not RTT-based: deterministic and testable.
/// Known gap: two machines on the same LAN reaching each other via public
/// IPv6 classify as Direct — acceptable for MVP telemetry.
fn is_lan_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private() || v4.is_loopback() || v4.is_link_local(),
        IpAddr::V6(v6) => {
            v6.is_loopback()
                // fe80::/10 link-local
                || (v6.segments()[0] & 0xffc0) == 0xfe80
                // fc00::/7 unique-local
                || (v6.segments()[0] & 0xfe00) == 0xfc00
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(selected: bool, relay: bool, ip: Option<&str>, rtt_ms: u64) -> PathFacts {
        PathFacts {
            selected,
            relay,
            remote_ip: ip.map(|s| s.parse().unwrap()),
            rtt: Duration::from_millis(rtt_ms),
        }
    }

    #[test]
    fn loopback_is_lan() {
        let info = classify(&[facts(true, false, Some("127.0.0.1"), 1)]);
        assert_eq!(info.path, Some(PathKind::Lan));
        assert_eq!(info.rtt_ms, 1);
    }

    #[test]
    fn private_v4_is_lan() {
        for ip in ["192.168.1.10", "10.0.0.5", "172.16.9.9", "169.254.0.1"] {
            let info = classify(&[facts(true, false, Some(ip), 2)]);
            assert_eq!(info.path, Some(PathKind::Lan), "{ip} should be Lan");
        }
    }

    #[test]
    fn public_v4_is_direct() {
        let info = classify(&[facts(true, false, Some("123.119.22.188"), 24)]);
        assert_eq!(info.path, Some(PathKind::Direct));
        assert_eq!(info.rtt_ms, 24);
    }

    #[test]
    fn v6_lan_vs_direct() {
        for ip in ["::1", "fe80::1", "fd00::1"] {
            let info = classify(&[facts(true, false, Some(ip), 1)]);
            assert_eq!(info.path, Some(PathKind::Lan), "{ip} should be Lan");
        }
        let info = classify(&[facts(true, false, Some("2408:8207:5455:ef60::1"), 8)]);
        assert_eq!(info.path, Some(PathKind::Direct));
    }

    #[test]
    fn relay_path_is_relay() {
        let info = classify(&[facts(true, true, None, 150)]);
        assert_eq!(info.path, Some(PathKind::Relay));
    }

    #[test]
    fn selected_path_wins_over_first() {
        // Relay path listed first, but the selected path is a LAN one.
        let info = classify(&[
            facts(false, true, None, 150),
            facts(true, false, Some("192.168.1.2"), 3),
        ]);
        assert_eq!(info.path, Some(PathKind::Lan));
        assert_eq!(info.rtt_ms, 3);
    }

    #[test]
    fn no_selected_path_falls_back_to_first() {
        let info = classify(&[facts(false, true, None, 150)]);
        assert_eq!(info.path, Some(PathKind::Relay));
    }

    #[test]
    fn no_paths_means_none() {
        assert_eq!(classify(&[]), ConnInfo::NONE);
        assert_eq!(ConnInfo::NONE.path, None);
    }

    // ── T-090: ConnectionStatus mapping ──

    #[test]
    fn live_status_maps_lan_and_direct_to_direct() {
        let lan = classify(&[facts(true, false, Some("192.168.1.2"), 3)]);
        assert_eq!(status_of_live(lan), ConnectionStatus::Direct);
        let direct = classify(&[facts(true, false, Some("123.119.22.188"), 24)]);
        assert_eq!(status_of_live(direct), ConnectionStatus::Direct);
    }

    #[test]
    fn live_status_maps_relay_to_relay() {
        let relay = classify(&[facts(true, true, None, 150)]);
        assert_eq!(status_of_live(relay), ConnectionStatus::Relay);
    }

    #[test]
    fn live_status_without_readable_paths_is_unknown_not_offline() {
        // A live connection whose paths are unreadable: we must not
        // claim offline — the connection exists. Honest answer: unknown.
        assert_eq!(status_of_live(classify(&[])), ConnectionStatus::Unknown);
    }

    #[test]
    fn status_wire_strings_match_ipc_contract() {
        assert_eq!(ConnectionStatus::Direct.as_str(), "direct");
        assert_eq!(ConnectionStatus::Relay.as_str(), "relay");
        assert_eq!(ConnectionStatus::Offline.as_str(), "offline");
        assert_eq!(ConnectionStatus::Unknown.as_str(), "unknown");
    }
}
