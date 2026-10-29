//! Connection pool wrapper + embedded migrations.

use std::collections::HashMap;
use std::path::Path;
use std::str::FromStr;
use std::sync::{Arc, RwLock};

use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};

use crate::{Pairing, PairingVault, Result, StorageError, VaultAlignment};

/// #1117：有效配对记录的内存副本，键为 NodeId。授权判定只读它，不查库。
/// 所有 `Db` 克隆共享同一份；只有 `device_repo` 里的配对写方法会改它。
/// 正本：没有 [`PairingVault`] 时是库本身；有时是 vault（#1115，macOS 钥匙串），
/// 库里的 `pairing` 表只是镜像，副本只从 vault 加载（见 `pairing_vault.rs`）。
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
    /// #1115：配对记录正本。`None` = 库就是正本（Windows / Linux / 测试沙盒）。
    vault: Option<Arc<dyn PairingVault>>,
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

    /// #1115：打开库，配对记录正本在 `vault`。先按正本对齐镜像，再从正本加载内存副本。
    /// 读正本失败 ⇒ `Err`（调用方拒绝启动），不回退到镜像。
    pub async fn open_with_vault(
        path: &Path,
        vault: Arc<dyn PairingVault>,
    ) -> Result<(Db, VaultAlignment)> {
        let opts = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new().connect_with(opts).await?;
        Self::ready_with_vault(pool, vault).await
    }

    /// 测试用：内存库 + 指定的正本。
    pub async fn open_in_memory_with_vault(
        vault: Arc<dyn PairingVault>,
    ) -> Result<(Db, VaultAlignment)> {
        let opts = SqliteConnectOptions::from_str("sqlite::memory:")
            .expect("static connection string")
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await?;
        Self::ready_with_vault(pool, vault).await
    }

    async fn with_options(opts: SqliteConnectOptions) -> Result<Db> {
        let pool = SqlitePoolOptions::new().connect_with(opts).await?;
        Self::ready(pool).await
    }

    /// 迁移，然后从库加载配对记录的内存副本（库就是正本）。
    async fn ready(pool: SqlitePool) -> Result<Db> {
        MIGRATOR.run(&pool).await?;
        let db = Db {
            pool,
            pairings: Arc::default(),
            pairing_writes: Arc::default(),
            vault: None,
        };
        let all = db.list_pairings().await?;
        db.replace_pairing_index(all);
        Ok(db)
    }

    async fn ready_with_vault(
        pool: SqlitePool,
        vault: Arc<dyn PairingVault>,
    ) -> Result<(Db, VaultAlignment)> {
        MIGRATOR.run(&pool).await?;
        let db = Db {
            pool,
            pairings: Arc::default(),
            pairing_writes: Arc::default(),
            vault: Some(vault),
        };
        let authority = db.vault_call(|v| v.load_all()).await?;
        let alignment = db.align_mirror(&authority).await?;
        db.replace_pairing_index(authority);
        Ok((db, alignment))
    }

    /// 正本的同步调用放进 blocking 线程（钥匙串读写是同步 Security 调用，毫秒级）。
    /// 没有正本时不会被调到。
    pub(crate) async fn vault_call<T, F>(&self, f: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&dyn PairingVault) -> std::result::Result<T, String> + Send + 'static,
    {
        let vault = Arc::clone(self.vault.as_ref().expect("vault_call 只在有正本时调用"));
        let location = vault.location();
        match tokio::task::spawn_blocking(move || f(vault.as_ref())).await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(detail)) => Err(StorageError::Vault { location, detail }),
            Err(e) => Err(StorageError::Vault {
                location,
                detail: format!("调用线程失败：{e}"),
            }),
        }
    }

    pub(crate) fn has_vault(&self) -> bool {
        self.vault.is_some()
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

    /// 关掉连接池（等在用的连接归还后关闭）。之后这个 `Db` 的任何查询都会失败。
    pub async fn close(&self) {
        self.pool.close().await;
    }

    pub(crate) fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #1237：编进程序的迁移脚本一律是 LF。校验值按原始字节算，CRLF 检出（Windows 的
    /// core.autocrlf）编出的程序会拒绝 LF 检出编出的程序建的库，反之亦然。
    /// 反证：把任一 `.sql` 转成 CRLF 再编译 → 红。
    #[test]
    fn embedded_migrations_have_lf_line_endings() {
        for m in MIGRATOR.iter() {
            assert!(
                !m.sql.contains('\r'),
                "迁移 {} ({}) 含 CR：检查 .gitattributes 的 *.sql eol=lf",
                m.version,
                m.description
            );
        }
    }

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
