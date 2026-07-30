//! Daemon — service lifecycle, ALPN routing, IPC, telemetry client.
//!
//! No `unwrap`/`expect` allowed in production code (CI-enforced).

pub mod authz;
pub mod config;
pub mod router;

pub use authz::Decision;
pub use config::{Config, TelemetryConfig};
pub use router::Router;
