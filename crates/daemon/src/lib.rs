//! Daemon — service lifecycle, ALPN routing, IPC, telemetry client.
//!
//! No `unwrap`/`expect` allowed in production code (CI-enforced).

pub mod authz;
pub mod backup;
pub mod cli;
pub mod config;
pub mod diag_agg;
pub mod download;
pub mod events;
pub mod flow_delivery;
pub mod inbox;
pub mod ipc;
pub mod log_guard;
pub mod pairing;
pub mod presence;
pub mod query;
pub mod reconcile;
pub mod router;
pub mod subscriptions;
pub mod telemetry;
pub mod update;
pub mod upload;
pub mod watcher;

pub use authz::Decision;
pub use backup::{BackupEngine, CommitOutcome, SESSION_IDLE_TTL, STAGING_ORPHAN_GRACE};
pub use config::{Config, TelemetryConfig};
pub use diag_agg::DiagAgg;
pub use inbox::reclaim_inbox;
pub use ipc::daemon_version;
pub use ipc::Claim;
pub use ipc::IpcServer;
pub use pairing::{PairDecision, PairRejection, Pairing, PendingPair};
pub use query::QueryEngine;
pub use reconcile::Reconcile;
pub use router::Router;
pub use telemetry::{Event as TelemetryEvent, Telemetry};
pub use watcher::LibraryWatcher;
