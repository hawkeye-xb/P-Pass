//! Core index — ingest, dedup, timeline (T-011).
//!
//! Pure domain logic over `storage`: files land under
//! `originals/<device>/<yyyy>/<mm>/` and the SQLite index mirrors them.
//! Originals are the truth; the index is rebuildable (ADR-006).
//!
//! Architecture enforcement: no `iroh` imports, no platform `#[cfg]`.

use std::path::PathBuf;

mod dedup;
mod ingest;
mod rebuild;
mod timeline;

pub use dedup::hash_file;
pub use ingest::{IncomingFile, IngestOutcome, Ingestor};
pub use rebuild::{rebuild, RebuildReport};
pub use timeline::timeline_page;

/// Index-layer errors. Every I/O failure names the path it happened on —
/// clients turn these into human-readable diagnostics (审计裁决 2026-07-29:
/// "读取失败要说清是文件不存在").
#[derive(Debug, thiserror::Error)]
pub enum IndexError {
    #[error("file {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("storage: {0}")]
    Storage(#[from] storage::StorageError),

    #[error("no free file name for {0} after 10000 attempts")]
    NameSpaceExhausted(String),
}

pub type Result<T> = std::result::Result<T, IndexError>;
