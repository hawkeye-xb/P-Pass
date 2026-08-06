//! Storage — SQLite index over the photo library (T-010).
//!
//! The index is *derived data*: original files under `originals/` are the
//! truth; this database can be rebuilt from them at any time (ADR-006).
//! Schema: 架构文档 §5 v1.1 — see `migrations/0001_init.sql`.
//!
//! All timestamps are unix epoch milliseconds.

mod asset_repo;
mod audit_repo;
mod db;
mod device_repo;
mod diag_repo;

pub use asset_repo::{ActivityBatch, Asset, TimelinePage};
pub use audit_repo::{AuditEntry, AuditRecord};
pub use db::Db;
pub use device_repo::{Device, Role};
pub use diag_repo::DiagEvent;

/// Storage-layer errors.
#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("database: {0}")]
    Db(#[from] sqlx::Error),

    #[error("migration: {0}")]
    Migrate(#[from] sqlx::migrate::MigrateError),

    #[error("invalid timeline cursor")]
    InvalidCursor,
}

pub type Result<T> = std::result::Result<T, StorageError>;
