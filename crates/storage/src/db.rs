//! Connection pool wrapper + embedded migrations.

use std::collections::HashMap;
use std::path::Path;
use std::str::FromStr;
use std::sync::{Arc, RwLock};

use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};

use crate::{Pairing, Result};

/// #1117：有效配对记录的内存副本，键为 NodeId。授权判定只读它，不查库。
/// 所有 `Db` 克隆共享同一份；只有 `device_repo` 里的配对写方法会改它，
/// 且都在事务提交之后改（库是正本，副本跟随）。#1115 把正本换到钥匙串时，
/// 换的是这份副本的加载源与写入处，读方不变。
pub(crate) type PairingIndex = Arc<RwLock<HashMap<Vec<u8>, Pairing>>>;

/// Embedded migrations — the schema ships inside the binary, so a daemon
/// upgrade migrates the index on first open.
static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// Handle to the index database. Cheap to clone (wraps a pool).
#[derive(Clone)]
pub struct Db {
    pool: SqlitePool,
    pairings: PairingIndex,
    /// 配对记录的写入一次只走一个：事务提交和副本更新作为一个整体，
    /// 并发的配对 / 删除不会让副本与库的先后顺序不一致。
    pairing_writes: Arc<tokio::sync::Mutex<()>>,
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
        Self::ready(pool).await
    }

    async fn with_options(opts: SqliteConnectOptions) -> Result<Db> {
        let pool = SqlitePoolOptions::new().connect_with(opts).await?;
        Self::ready(pool).await
    }

    /// 迁移，然后从库加载配对记录的内存副本。
    async fn ready(pool: SqlitePool) -> Result<Db> {
        MIGRATOR.run(&pool).await?;
        let db = Db {
            pool,
            pairings: Arc::default(),
            pairing_writes: Arc::default(),
        };
        let all = db.list_pairings().await?;
        db.replace_pairing_index(all);
        Ok(db)
    }

    pub(crate) async fn pairing_write_guard(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.pairing_writes.lock().await
    }

    pub(crate) fn pairing_index(&self) -> &PairingIndex {
        &self.pairings
    }

    fn replace_pairing_index(&self, all: Vec<Pairing>) {
        let mut index = self.pairings.write().unwrap_or_else(|e| e.into_inner());
        *index = all.into_iter().map(|p| (p.node_id.clone(), p)).collect();
    }

    pub(crate) fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #1044：新版本建过的库被旧版本打开 = 库里有本二进制不认识的
    /// migration。这一种失败要能被认出来（daemon 输出 keyed 错误）。
    #[tokio::test]
    async fn a_library_from_a_newer_version_is_recognised() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        let db = Db::open(&path).await.unwrap();
        sqlx::query(
            "INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time)
             VALUES (99999, 'from the future', 1, x'00', 0)",
        )
        .execute(db.pool())
        .await
        .unwrap();
        db.pool().close().await;

        let err = Db::open(&path)
            .await
            .err()
            .expect("must refuse a newer schema");
        assert!(err.is_schema_newer_than_binary(), "{err}");
        assert!(!crate::StorageError::InvalidCursor.is_schema_newer_than_binary());
    }
}
