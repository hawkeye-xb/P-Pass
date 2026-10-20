//! Daemon diagnostic state machine (详细设计 §4.4) — pure logic, no IO.
//!
//! The daemon feeds [`DaemonEvent`]s in; every state maps to exactly one
//! msg_key from [`crate::keys`], which clients localise into human words.
//!
//! Only the states that have a production event source live here:
//! `OnlineDirect` (default) and `Pairing`. The relay / offline / disk-full /
//! indexing states were retired in #1053 — nothing ever emitted their events.

use crate::keys;

/// States exposed to clients via `diag.status`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonState {
    OnlineDirect,
    Pairing,
}

/// Inputs that drive transitions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonEvent {
    /// Owner started a pairing flow (QR shown / request pending).
    PairingStarted,
    /// Pairing flow finished (accepted, rejected or expired).
    PairingEnded,
}

impl DaemonState {
    /// The msg_key clients localise for this state.
    pub fn msg_key(&self) -> &'static str {
        match self {
            DaemonState::OnlineDirect => keys::DIAG_ONLINE_DIRECT,
            DaemonState::Pairing => keys::DIAG_PAIRING,
        }
    }

    /// Pure transition function.
    pub fn apply(self, event: DaemonEvent) -> DaemonState {
        use DaemonEvent as E;
        use DaemonState as S;

        match event {
            E::PairingStarted => S::Pairing,
            E::PairingEnded => S::OnlineDirect,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::DaemonEvent as E;
    use super::DaemonState as S;
    use super::*;

    #[test]
    fn every_state_maps_to_a_registered_key() {
        for s in [S::OnlineDirect, S::Pairing] {
            assert!(
                keys::ALL.contains(&s.msg_key()),
                "unregistered msg_key for {s:?}"
            );
        }
    }

    #[test]
    fn pairing_flow() {
        let s = S::OnlineDirect.apply(E::PairingStarted);
        assert_eq!(s, S::Pairing);
        assert_eq!(s.apply(E::PairingEnded), S::OnlineDirect);
        // PairingEnded outside a pairing flow is a no-op.
        assert_eq!(S::OnlineDirect.apply(E::PairingEnded), S::OnlineDirect);
    }
}
