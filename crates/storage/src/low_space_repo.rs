//! #1044 B11: 低空间通知布防状态的持久化（单行表 `low_space_notice`）。
//! 规则（阈值、回差、何时通知）在 daemon，本层只存取。

use sqlx::Row;

use crate::{Db, Result};

/// 低空间通知的持久状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LowSpaceNotice {
    /// 跌破阈值时该不该通知（通知过一次后为 false，回升过回差线才复位）。
    pub armed: bool,
    /// 已判定该通知、尚未被桌面确认展示的那一次（判定时的剩余字节数）。
    pub pending_free_bytes: Option<i64>,
}

impl Db {
    pub async fn low_space_notice(&self) -> Result<LowSpaceNotice> {
        let row =
            sqlx::query("SELECT armed, pending_free_bytes FROM low_space_notice WHERE id = 1")
                .fetch_one(self.pool())
                .await?;
        Ok(LowSpaceNotice {
            armed: row.get::<i64, _>("armed") != 0,
            pending_free_bytes: row.get("pending_free_bytes"),
        })
    }

    pub async fn set_low_space_notice(&self, n: &LowSpaceNotice) -> Result<()> {
        sqlx::query("UPDATE low_space_notice SET armed = ?, pending_free_bytes = ? WHERE id = 1")
            .bind(i64::from(n.armed))
            .bind(n.pending_free_bytes)
            .execute(self.pool())
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn starts_armed_with_nothing_pending_and_round_trips() {
        let db = Db::open_in_memory().await.unwrap();
        assert_eq!(
            db.low_space_notice().await.unwrap(),
            LowSpaceNotice {
                armed: true,
                pending_free_bytes: None
            }
        );
        let n = LowSpaceNotice {
            armed: false,
            pending_free_bytes: Some(42),
        };
        db.set_low_space_notice(&n).await.unwrap();
        assert_eq!(db.low_space_notice().await.unwrap(), n);
    }
}
