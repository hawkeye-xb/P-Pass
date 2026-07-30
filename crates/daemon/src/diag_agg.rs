//! Diagnostic aggregation (T-034): the daemon-side holder of the pure
//! state machine from the `diag` crate, plus the 30-day diag_event ring.

use std::sync::{Arc, Mutex};

use diag::state::{DaemonEvent, DaemonState};
use storage::Db;

const RING_DAYS_MS: i64 = 30 * 24 * 3600 * 1000;

/// Shared daemon state: subsystems feed events, IPC reads the snapshot.
#[derive(Clone)]
pub struct DiagAgg {
    state: Arc<Mutex<DaemonState>>,
    db: Db,
}

impl DiagAgg {
    pub fn new(db: Db) -> Self {
        Self {
            // Until the first connection event arrives the daemon is
            // simply up — OnlineDirect is the state machine's neutral.
            state: Arc::new(Mutex::new(DaemonState::OnlineDirect)),
            db,
        }
    }

    /// Feed one event through the pure transition function.
    pub fn apply(&self, event: DaemonEvent) {
        let mut state = self.state.lock().expect("diag state lock");
        *state = state.clone().apply(event);
    }

    /// Current state snapshot.
    pub fn state(&self) -> DaemonState {
        self.state.lock().expect("diag state lock").clone()
    }

    /// Enforce the 30-day ring on diag_event (call periodically).
    pub async fn prune_ring(&self, now_ms: i64) -> u64 {
        self.db
            .prune_diag(now_ms - RING_DAYS_MS)
            .await
            .unwrap_or_else(|e| {
                tracing::error!("diag ring prune failed: {e}");
                0
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn ring_keeps_30_days_and_drops_older() {
        let db = Db::open_in_memory().await.unwrap();
        let now = 100 * 24 * 3600 * 1000i64;
        for (ts, kind) in [(now - 40 * 24 * 3600 * 1000, "old"), (now - 1000, "new")] {
            db.append_diag(&storage::DiagEvent {
                ts,
                kind: kind.into(),
                detail: None,
            })
            .await
            .unwrap();
        }
        let agg = DiagAgg::new(db.clone());
        assert_eq!(agg.prune_ring(now).await, 1);
        let left = db.list_diag(10).await.unwrap();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].kind, "new");
    }

    #[test]
    fn pairing_event_moves_state() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let agg = DiagAgg::new(Db::open_in_memory().await.unwrap());
            agg.apply(DaemonEvent::PairingStarted);
            assert_eq!(agg.state(), DaemonState::Pairing);
            agg.apply(DaemonEvent::PairingEnded);
            assert_eq!(agg.state(), DaemonState::OnlineDirect);
        });
    }
}
