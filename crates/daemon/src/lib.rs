//! Daemon — service lifecycle, ALPN routing, IPC, telemetry client.
//!
//! No `unwrap`/`expect` allowed in production code (CI-enforced).

pub mod authz;
pub mod backup;
pub mod config;
pub mod diag_agg;
pub mod ipc;
pub mod pairing;
pub mod query;
pub mod router;
pub mod telemetry;

pub use authz::Decision;
pub use backup::{BackupEngine, CommitOutcome};
pub use config::{Config, TelemetryConfig};
pub use diag_agg::DiagAgg;
pub use ipc::IpcServer;
pub use pairing::{PairRejection, Pairing, PendingPair};
pub use query::QueryEngine;
pub use router::Router;
pub use telemetry::{Event as TelemetryEvent, Telemetry};
