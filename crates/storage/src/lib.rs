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
mod flow_delivery_repo;
mod low_space_repo;
mod supersede_repo;

pub use asset_repo::{ActivityBatch, Asset, TimelinePage};
pub use audit_repo::{
    AuditEntry, AuditOperationEntry, AuditOperationRecord, AuditRecord, DecisionEntry,
    DecisionRecord, ItemEvidenceEntry, ItemEvidenceRecord, TombstoneEntry, TombstoneRecord,
};
pub use db::Db;
pub use device_repo::{DepartedBy, DeviceProfile, DeviceRow, DeviceWatermark, Pairing, Role};
pub use diag_repo::DiagEvent;
pub use flow_delivery_repo::{FlowGrant, FlowGrantState, FlowReceipt};
pub use low_space_repo::LowSpaceNotice;
pub use supersede_repo::PendingSwap;

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

impl StorageError {
    /// #1044：库里记着本二进制没有的 migration——用更旧的版本打开了新版本
    /// 建过的库。daemon 据此输出 keyed 启动错误，桌面给「装回新版本」指引。
    pub fn is_schema_newer_than_binary(&self) -> bool {
        matches!(
            self,
            StorageError::Migrate(sqlx::migrate::MigrateError::VersionMissing(_))
        )
    }
}

pub type Result<T> = std::result::Result<T, StorageError>;
