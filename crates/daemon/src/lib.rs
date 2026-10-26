//! Daemon — service lifecycle, ALPN routing, IPC, local stats logging.
//!
//! No `unwrap`/`expect` allowed in production code (CI-enforced).

pub mod admission;
pub mod audit_projection;
pub mod audit_route;
pub mod authz;
pub mod awake;
pub mod backup;
pub mod blobs_gate;
pub mod cli;
pub mod config;
pub mod device_projection;
pub mod diag_agg;
pub mod diag_bundle;
pub mod events;
pub mod flow_delivery;
pub mod frame_limits;
pub mod identity;
pub mod inbox;
pub mod ipc;
pub mod library_location;
pub mod log_guard;
pub mod low_space;
pub mod pairing;
pub mod pairing_store;
pub mod presence;
pub mod query;
pub mod reconcile;
pub mod redact;
pub mod router;
pub mod sandbox;
pub mod stats;
pub mod subscriptions;
pub mod thumb_pregen;
pub mod unpair;
pub mod watcher;

/// #1047：收到停止信号后的收尾总死线。短于 Docker 的 10s SIGKILL 宽限。
pub const SHUTDOWN_DEADLINE: std::time::Duration = std::time::Duration::from_secs(8);

pub use authz::Decision;
pub use backup::{BackupEngine, CommitOutcome, SESSION_IDLE_TTL, STAGING_ORPHAN_GRACE};
pub use config::Config;
pub use diag_agg::DiagAgg;
pub use inbox::{reclaim_inbox, sweep_flow_staging_orphans};
pub use ipc::daemon_version;
pub use ipc::Claim;
pub use ipc::ConfirmOutcome;
pub use ipc::IpcServer;
pub use pairing::{
    DecisionUndelivered, PairDecision, PairRejection, PairState, PairSubmission, Pairing,
    PendingPair, PENDING_TTL_MS, TOKEN_TTL_MS,
};
pub use query::QueryEngine;
pub use reconcile::Reconcile;
pub use router::Router;
pub use thumb_pregen::{ThumbPregen, PREGEN_WORKERS};
pub use watcher::LibraryWatcher;

#[cfg(test)]
mod business_rules_table;
