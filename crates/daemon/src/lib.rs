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
pub mod layout;
pub mod library_location;
pub mod log_guard;
pub mod low_space;
pub mod migrate_local;
pub mod pairing;
pub mod pairing_store;
pub mod presence;
pub mod query;
pub mod reconcile;
pub mod redact;
pub mod residue;
pub mod router;
pub mod sandbox;
pub mod stats;
pub mod subscriptions;
pub mod thumb_pregen;
pub mod unpair;
pub mod watcher;

/// #1047：收到停止信号后的收尾总死线。短于 Docker 的 10s SIGKILL 宽限。
pub const SHUTDOWN_DEADLINE: std::time::Duration = std::time::Duration::from_secs(8);

/// #1066：每小时巡检的周期（对账、会话回收、staging 孤儿、超期 grant；业务规则 §5.4）。
pub const PATROL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(3600);

/// #1066：flow-blobs 的 iroh 周期 GC（业务规则 §5.4）。
pub const FLOW_BLOBS_GC_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

/// #1066：diag 环（30 天）清理周期（业务规则 §5.4、§9.2）。
pub const DIAG_PRUNE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(6 * 3600);

/// #1066：运行统计 `daemon_alive` 的写入周期，只写本地日志（业务规则 §5.4）。
pub const DAEMON_ALIVE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(24 * 3600);

/// #1066：启动后延迟多久再开缩略图回填，不与桌面壳拉第一屏抢（业务规则 §5.4）。
pub const THUMB_BACKFILL_DELAY: std::time::Duration = std::time::Duration::from_secs(10);

pub use authz::Decision;
pub use backup::{BackupEngine, CommitOutcome, SESSION_IDLE_TTL, STAGING_ORPHAN_GRACE};
pub use config::Config;
pub use diag_agg::DiagAgg;
pub use inbox::{retire_blob_store, sweep_flow_staging_orphans, BlobStoreRetire};
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
