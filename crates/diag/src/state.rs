//! Daemon diagnostic state machine (详细设计 §4.4) — pure logic, no IO.
//!
//! The daemon feeds [`DaemonEvent`]s in; every state maps to exactly one
//! msg_key from [`crate::keys`], which clients localise into human words.

use crate::keys;

/// States exposed to clients via `diag.status`（详细设计 §4.4 原文集合）.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonState {
    OnlineDirect,
    OnlineRelay,
    StorageOffline {
        /// Unix epoch seconds of the last successful contact.
        last_seen_epoch_s: i64,
    },
    Pairing,
    DiskFull {
        free_bytes: u64,
    },
    Indexing {
        progress_pct: u8,
    },
}

/// Inputs that drive transitions. Produced by transport / storage / pairing
/// subsystems; this crate only encodes the pure transition rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonEvent {
    /// A connection is up over a direct or LAN path.
    ConnDirect,
    /// A connection is up but only via relay.
    ConnRelay,
    /// All connections lost; carries the timestamp of last contact.
    ConnLost { last_seen_epoch_s: i64 },
    /// Owner started a pairing flow (QR shown / request pending).
    PairingStarted,
    /// Pairing flow finished (accepted, rejected or expired).
    PairingEnded,
    /// Free space dropped below the ingest threshold.
    DiskFull { free_bytes: u64 },
    /// Free space recovered above the threshold.
    DiskRecovered,
    /// Library (re)index started.
    IndexingStarted,
    /// Index progress update, 0..=100.
    IndexingProgress { progress_pct: u8 },
    /// Index finished.
    IndexingDone,
}

impl DaemonState {
    /// The msg_key clients localise for this state.
    pub fn msg_key(&self) -> &'static str {
        match self {
            DaemonState::OnlineDirect => keys::DIAG_ONLINE_DIRECT,
            DaemonState::OnlineRelay => keys::DIAG_ONLINE_RELAY,
            DaemonState::StorageOffline { .. } => keys::DIAG_STORAGE_OFFLINE,
            DaemonState::Pairing => keys::DIAG_PAIRING,
            DaemonState::DiskFull { .. } => keys::ERR_DISK_FULL,
            DaemonState::Indexing { .. } => keys::DIAG_INDEXING,
        }
    }

    /// Pure transition function.
    ///
    /// Priority rules (documented design choices within T-003):
    /// - `DiskFull` is sticky: only `DiskRecovered` leaves it — a full disk
    ///   makes every other status secondary for the user.
    /// - Connectivity events always apply otherwise (they answer the user's
    ///   first question: "can I reach my photos?").
    /// - `DiskRecovered`/`PairingEnded`/`IndexingDone` fall back to
    ///   `OnlineDirect`; the next Conn* event immediately corrects the path
    ///   flavour, so the fallback is visible for at most one poll cycle.
    pub fn apply(self, event: DaemonEvent) -> DaemonState {
        use DaemonEvent as E;
        use DaemonState as S;

        // Sticky disk-full: ignore everything except recovery.
        if let S::DiskFull { .. } = self {
            return match event {
                E::DiskRecovered => S::OnlineDirect,
                E::DiskFull { free_bytes } => S::DiskFull { free_bytes },
                _ => self,
            };
        }

        match event {
            E::DiskFull { free_bytes } => S::DiskFull { free_bytes },
            E::DiskRecovered => self,
            E::ConnDirect => S::OnlineDirect,
            E::ConnRelay => S::OnlineRelay,
            E::ConnLost { last_seen_epoch_s } => S::StorageOffline { last_seen_epoch_s },
            E::PairingStarted => S::Pairing,
            E::PairingEnded => match self {
                S::Pairing => S::OnlineDirect,
                other => other,
            },
            E::IndexingStarted => S::Indexing { progress_pct: 0 },
            E::IndexingProgress { progress_pct } => match self {
                S::Indexing { .. } => S::Indexing {
                    progress_pct: progress_pct.min(100),
                },
                other => other,
            },
            E::IndexingDone => match self {
                S::Indexing { .. } => S::OnlineDirect,
                other => other,
            },
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
        let states = [
            S::OnlineDirect,
            S::OnlineRelay,
            S::StorageOffline {
                last_seen_epoch_s: 0,
            },
            S::Pairing,
            S::DiskFull { free_bytes: 0 },
            S::Indexing { progress_pct: 0 },
        ];
        for s in states {
            assert!(
                keys::ALL.contains(&s.msg_key()),
                "unregistered msg_key for {s:?}"
            );
        }
    }

    #[test]
    fn connectivity_transitions() {
        let s = S::OnlineDirect.apply(E::ConnRelay);
        assert_eq!(s, S::OnlineRelay);
        let s = s.apply(E::ConnLost {
            last_seen_epoch_s: 42,
        });
        assert_eq!(
            s,
            S::StorageOffline {
                last_seen_epoch_s: 42
            }
        );
        let s = s.apply(E::ConnDirect);
        assert_eq!(s, S::OnlineDirect);
    }

    #[test]
    fn disk_full_is_sticky_until_recovered() {
        let s = S::OnlineDirect.apply(E::DiskFull { free_bytes: 100 });
        assert_eq!(s, S::DiskFull { free_bytes: 100 });
        // Connectivity noise must not mask a full disk.
        let s = s
            .apply(E::ConnDirect)
            .apply(E::ConnRelay)
            .apply(E::IndexingStarted);
        assert_eq!(s, S::DiskFull { free_bytes: 100 });
        // Threshold updates refresh the free-space figure.
        let s = s.apply(E::DiskFull { free_bytes: 50 });
        assert_eq!(s, S::DiskFull { free_bytes: 50 });
        let s = s.apply(E::DiskRecovered);
        assert_eq!(s, S::OnlineDirect);
    }

    #[test]
    fn pairing_flow() {
        let s = S::OnlineRelay.apply(E::PairingStarted);
        assert_eq!(s, S::Pairing);
        assert_eq!(s.clone().apply(E::PairingEnded), S::OnlineDirect);
        // PairingEnded outside a pairing flow is a no-op.
        assert_eq!(S::OnlineRelay.apply(E::PairingEnded), S::OnlineRelay);
    }

    #[test]
    fn indexing_progress_clamped_and_scoped() {
        let s = S::OnlineDirect.apply(E::IndexingStarted);
        assert_eq!(s, S::Indexing { progress_pct: 0 });
        let s = s.apply(E::IndexingProgress { progress_pct: 250 });
        assert_eq!(s, S::Indexing { progress_pct: 100 });
        assert_eq!(s.apply(E::IndexingDone), S::OnlineDirect);
        // Progress events outside indexing are no-ops.
        assert_eq!(
            S::Pairing.apply(E::IndexingProgress { progress_pct: 10 }),
            S::Pairing
        );
    }
}
