//! Daemon — service lifecycle, ALPN routing, IPC, telemetry client.
//!
//! No `unwrap`/`expect` allowed in production code (CI-enforced).

pub mod authz;
pub mod backup;
pub mod config;
pub mod pairing;
pub mod router;

pub use authz::Decision;
pub use backup::{BackupEngine, CommitOutcome};
pub use config::{Config, TelemetryConfig};
pub use pairing::{PairRejection, Pairing, PendingPair};
pub use router::Router;
