//! Daemon — service lifecycle, ALPN routing, IPC, telemetry client.
//!
//! No `unwrap`/`expect` allowed in production code (CI-enforced).

pub mod authz;
pub mod backup;
pub mod config;
pub mod diag_agg;
pub mod download;
pub mod events;
pub mod ipc;
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
pub use backup::{BackupEngine, CommitOutcome};
pub use config::{Config, TelemetryConfig};
pub use diag_agg::DiagAgg;
pub use ipc::daemon_version;
pub use ipc::Claim;
pub use ipc::IpcServer;
pub use pairing::{PairDecision, PairRejection, Pairing, PendingPair};
pub use query::QueryEngine;
pub use reconcile::Reconcile;
pub use router::Router;
pub use telemetry::{Event as TelemetryEvent, Telemetry};
pub use watcher::LibraryWatcher;
