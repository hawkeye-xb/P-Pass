//! #1260：把索引库原样拷到另一处并核对（老库迁移用）。
//!
//! 用 SQLite 的 `VACUUM INTO`：在线、一致的单文件副本，WAL 里的内容一并合进去；
//! 源库只读打开，任何一步失败都不碰源库。

use std::path::Path;

use sqlx::sqlite::SqliteConnectOptions;
use sqlx::{ConnectOptions, Connection, Row};

use crate::Result;

/// 把 `src` 一致地拷成 `dst`（`dst` 不得已存在）。
pub async fn vacuum_into(src: &Path, dst: &Path) -> Result<()> {
    let mut conn = SqliteConnectOptions::new()
        .filename(src)
        .read_only(true)
        .connect()
        .await?;
    sqlx::query("VACUUM INTO ?")
        .bind(dst.to_string_lossy().to_string())
        .execute(&mut conn)
        .await?;
    conn.close().await?;
    Ok(())
}

/// 每张表的行数（按表名排序），以及 `PRAGMA integrity_check` 是否为 ok。只读打开。
pub async fn table_counts(path: &Path) -> Result<(bool, Vec<(String, i64)>)> {
    let mut conn = SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .connect()
        .await?;
    let integrity: String = sqlx::query("PRAGMA integrity_check")
        .fetch_one(&mut conn)
        .await?
        .try_get(0)?;
    let tables: Vec<String> = sqlx::query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    )
    .fetch_all(&mut conn)
    .await?
    .into_iter()
    .map(|r| r.get::<String, _>(0))
    .collect();
    let mut counts = Vec::with_capacity(tables.len());
    for t in tables {
        let n: i64 = sqlx::query(&format!(
            "SELECT COUNT(*) FROM \"{}\"",
            t.replace('"', "\"\"")
        ))
        .fetch_one(&mut conn)
        .await?
        .try_get(0)?;
        counts.push((t, n));
    }
    conn.close().await?;
    Ok((integrity == "ok", counts))
}
