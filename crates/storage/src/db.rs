//! Connection pool wrapper + embedded migrations.

use std::path::Path;
use std::str::FromStr;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};

use crate::Result;

/// Embedded migrations — the schema ships inside the binary, so a daemon
/// upgrade migrates the index on first open.
static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// Handle to the index database. Cheap to clone (wraps a pool).
#[derive(Clone)]
pub struct Db {
    pool: SqlitePool,
}

impl Db {
    /// Open (creating if missing) the index at `path` and run migrations.
    pub async fn open(path: &Path) -> Result<Db> {
        let opts = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            // WAL: readers (timeline) don't block the writer (ingest).
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
            .foreign_keys(true);
        Self::with_options(opts).await
    }

    /// In-memory database for tests. `max_connections(1)` because every
    /// new connection to `sqlite::memory:` would be a *different* empty DB.
    pub async fn open_in_memory() -> Result<Db> {
        let opts = SqliteConnectOptions::from_str("sqlite::memory:")
            .expect("static connection string")
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await?;
        MIGRATOR.run(&pool).await?;
        Ok(Db { pool })
    }

    async fn with_options(opts: SqliteConnectOptions) -> Result<Db> {
        let pool = SqlitePoolOptions::new().connect_with(opts).await?;
        MIGRATOR.run(&pool).await?;
        Ok(Db { pool })
    }

    pub(crate) fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}
