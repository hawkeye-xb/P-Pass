//! 照片库卷低空间通知（#413 §7，#1044 B11）。
//!
//! 规则唯一来源：跌破 [`LOW_SPACE_THRESHOLD_BYTES`]（5 GiB）通知一次，回升到
//! ≥ [`LOW_SPACE_REARM_BYTES`]（6 GiB）才重新布防。留 1 GiB 回差：空间在 5 GiB
//! 附近来回抖（边备份边清理）时，不能每次轮询都弹一次。
//!
//! 布防状态与「待展示的那一次」持久化在索引库（`low_space_notice`），所以
//! 重开 App 不会重复弹。通知是边沿触发：判定该通知时记一条待展示，`status`
//! 带出 `low_space_notice`，桌面弹完系统通知后调 `low_space.ack` 消费掉——
//! 不是一个每次轮询都为真的电平字段。

use storage::{Db, LowSpaceNotice};

/// 固定低空间线。与手机端同名常量同值：Android `DesktopHealth.LOW_SPACE_BYTES`
/// （FlowContract.kt）、iOS `DesktopHealth.lowSpaceBytes`（FlowTypes.swift）；
/// `tests/flow_health.rs` 读两端源码对账。
pub const LOW_SPACE_THRESHOLD_BYTES: u64 = 5 * 1024 * 1024 * 1024;

/// 通知过之后，要回升到这条线以上（含）才重新布防。
pub const LOW_SPACE_REARM_BYTES: u64 = 6 * 1024 * 1024 * 1024;

/// 纯状态机：`(armed, free)` → `(notify, armed')`。
pub fn next(armed: bool, free_bytes: u64) -> (bool, bool) {
    if armed && free_bytes < LOW_SPACE_THRESHOLD_BYTES {
        (true, false)
    } else if !armed && free_bytes >= LOW_SPACE_REARM_BYTES {
        (false, true)
    } else {
        (false, armed)
    }
}

/// 用这一次读到的剩余空间推进持久状态；返回当前待展示的通知（剩余字节数）。
/// 读不到剩余空间（`None`）不推进——不知道就不下结论。
pub async fn observe(db: &Db, free_bytes: Option<u64>) -> storage::Result<Option<i64>> {
    let mut state = db.low_space_notice().await?;
    if let Some(free) = free_bytes {
        let (notify, armed) = next(state.armed, free);
        let pending = if notify {
            Some(i64::try_from(free).unwrap_or(i64::MAX))
        } else if armed && !state.armed {
            // 回升过回差线重新布防：还没展示的那次「空间不足」已经不成立了，
            // 不许等用户下次打开 App 再弹一条过时的提醒。
            None
        } else {
            state.pending_free_bytes
        };
        let updated = LowSpaceNotice {
            armed,
            pending_free_bytes: pending,
        };
        if updated != state {
            db.set_low_space_notice(&updated).await?;
            state = updated;
        }
    }
    Ok(state.pending_free_bytes)
}

/// 桌面已展示过待展示的那一次通知。
pub async fn ack(db: &Db) -> storage::Result<()> {
    let state = db.low_space_notice().await?;
    if state.pending_free_bytes.is_some() {
        db.set_low_space_notice(&LowSpaceNotice {
            armed: state.armed,
            pending_free_bytes: None,
        })
        .await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const GIB: u64 = 1024 * 1024 * 1024;

    #[test]
    fn notifies_once_below_the_line_and_rearms_only_at_six_gib() {
        assert_eq!(next(true, 5 * GIB), (false, true), "5 GiB 整不算低");
        assert_eq!(next(true, 5 * GIB - 1), (true, false));
        assert_eq!(next(false, 4 * GIB), (false, false), "已通知过不再通知");
        assert_eq!(next(false, 6 * GIB - 1), (false, false), "回差内不复位");
        assert_eq!(next(false, 6 * GIB), (false, true));
    }

    /// 【改行为】重开 App（新连接、新进程）不再重复弹：状态在库里。
    #[tokio::test]
    async fn the_notice_is_edge_triggered_and_survives_a_restart() {
        let db = Db::open_in_memory().await.unwrap();
        assert_eq!(observe(&db, Some(10 * GIB)).await.unwrap(), None);
        assert_eq!(
            observe(&db, Some(4 * GIB)).await.unwrap(),
            Some((4 * GIB) as i64)
        );
        // 桌面还没确认前一直挂着（轮询多次不丢、也不新增）。
        assert_eq!(
            observe(&db, Some(3 * GIB)).await.unwrap(),
            Some((4 * GIB) as i64)
        );
        ack(&db).await.unwrap();
        // 「重开 App」= 状态从库里重新读：仍低于阈值，不再弹。
        assert_eq!(observe(&db, Some(3 * GIB)).await.unwrap(), None);
        assert_eq!(observe(&db, None).await.unwrap(), None, "读不到空间不推进");
        // 待展示期间空间回升过回差线：那次提醒作废，不再弹。
        assert_eq!(observe(&db, Some(6 * GIB)).await.unwrap(), None);
        assert_eq!(
            observe(&db, Some(4 * GIB)).await.unwrap(),
            Some((4 * GIB) as i64)
        );
        assert_eq!(
            observe(&db, Some(7 * GIB)).await.unwrap(),
            None,
            "未展示就恢复 = 作废"
        );
        assert_eq!(
            observe(&db, Some(4 * GIB)).await.unwrap(),
            Some((4 * GIB) as i64)
        );
        ack(&db).await.unwrap();
        // 回升过回差线再跌破，才弹第二次。
        assert_eq!(observe(&db, Some(6 * GIB)).await.unwrap(), None);
        assert_eq!(
            observe(&db, Some(4 * GIB)).await.unwrap(),
            Some((4 * GIB) as i64)
        );
    }
}
