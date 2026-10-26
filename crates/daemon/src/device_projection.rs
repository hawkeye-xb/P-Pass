//! 设备行投影（#1044 B4）：设备分组、「需要看看」哨兵、行状态优先级、
//! 最近活跃时刻与计数口径，都由 daemon 给出；桌面只按结论取文案渲染。
//!
//! 过去这些写在桌面 JS（`disconnected.js`、`humanTime.js` 的哨兵、`App.svelte`
//! 的 `deviceRow`/`lastActivityAt`/`status.devices - status.revoked`），页头
//! 「已配对 N 台」不含自己断开的设备，列表里却显示它们——口径打架。

use storage::{DepartedBy, DeviceRow};

/// 这台设备是否、以及因何离开（DEV-03；#1117 起由档案上的 `departed_by` 决定）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Removal {
    /// 有配对记录，在用。
    None,
    /// 没有配对记录，但不是业主的意图：手机自己断开，或电脑换了身份（需要
    /// 重新扫码）。留在主列表标「已断开」。
    Disconnected,
    /// 业主移除：单独列出。
    Removed,
}

impl Removal {
    pub fn of(d: &DeviceRow) -> Self {
        if d.pairing.is_some() {
            return Removal::None;
        }
        match d.profile.departed_by {
            Some(DepartedBy::Device | DepartedBy::Identity) => Removal::Disconnected,
            // 业主移除；没有离开原因的档案（理论上不存在：档案只在配对时建）
            // 保守按业主移除处理，不凭空冒出一台。
            Some(DepartedBy::Owner) | None => Removal::Removed,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Removal::None => "none",
            Removal::Disconnected => "disconnected",
            Removal::Removed => "removed",
        }
    }

    /// 设备页主列表的一行（含自己断开的）。页头「已配对 N 台」就数这个。
    pub fn is_listed(self) -> bool {
        self != Removal::Removed
    }
}

/// 「需要看看」哨兵：最近一次备份距今超过 5 天。从未备份过不算——那是
/// 「还没备份过」，另有文案。已离开的设备不算——授权都没了，催用户去开
/// App 备份是错的。
pub fn needs_attention(removal: Removal, last_backup_at: Option<i64>, now_ms: i64) -> bool {
    removal == Removal::None
        && last_backup_at
            .filter(|t| *t > 0)
            .is_some_and(|t| now_ms - t > crate::presence::BACKUP_ATTENTION_MS)
}

/// 设备行状态，按优先级取一个（一台设备两个真相时先说要紧的）：
/// 已断开 > 需要看看 > 正在传输 > 在线态（online/recent/offline）。
/// 业主移除的行只出现在「已移除」区，给 `removed`。
pub fn row_state(
    removal: Removal,
    needs_attention: bool,
    transferring: bool,
    presence: &'static str,
) -> &'static str {
    match removal {
        Removal::Removed => "removed",
        Removal::Disconnected => "disconnected",
        Removal::None if needs_attention => "needs_attention",
        Removal::None if transferring => "transferring",
        Removal::None => presence,
    }
}

/// 最近活跃 = max(最近在线, 最近备份)——两者都是「这台设备最近有动静」
/// 的真实证据，只看一个会漏（刚连上还没备份 / 备份完就锁屏离线）。
/// 两者都没有 → `None`。
pub fn last_activity_at(last_seen: Option<i64>, last_backup_at: Option<i64>) -> Option<i64> {
    match (
        last_seen.filter(|t| *t > 0),
        last_backup_at.filter(|t| *t > 0),
    ) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000_000;
    const DAY: i64 = 24 * 3600 * 1000;

    fn dev(paired: bool, by: Option<DepartedBy>) -> DeviceRow {
        DeviceRow {
            profile: storage::DeviceProfile {
                node_id: vec![1; 32],
                name: "x".into(),
                first_seen_at: 0,
                last_seen_at: None,
                departed_at: by.map(|_| 1),
                departed_by: by,
            },
            pairing: paired.then(|| storage::Pairing {
                id: "p".into(),
                node_id: vec![1; 32],
                role: storage::Role::Member,
                paired_at: 0,
            }),
        }
    }

    /// #1109 D2：电脑换身份后，手机归到「已断开」（提示重新扫码），不归「已移除」。
    /// 反证：把 Identity 归到 Removed，第三条断言变红。
    #[test]
    fn removal_groups_rows_by_why_the_pairing_was_deleted() {
        assert_eq!(Removal::of(&dev(true, None)), Removal::None);
        assert_eq!(
            Removal::of(&dev(false, Some(DepartedBy::Device))),
            Removal::Disconnected
        );
        assert_eq!(
            Removal::of(&dev(false, Some(DepartedBy::Identity))),
            Removal::Disconnected
        );
        assert_eq!(
            Removal::of(&dev(false, Some(DepartedBy::Owner))),
            Removal::Removed
        );
        assert_eq!(Removal::of(&dev(false, None)), Removal::Removed);
        assert!(
            Removal::Disconnected.is_listed(),
            "自己断开的留在主列表、计入已配对"
        );
        assert!(!Removal::Removed.is_listed());
    }

    #[test]
    fn attention_starts_strictly_after_five_days_and_ignores_never_backed_up() {
        assert!(!needs_attention(Removal::None, Some(NOW - 5 * DAY), NOW));
        assert!(needs_attention(Removal::None, Some(NOW - 5 * DAY - 1), NOW));
        assert!(!needs_attention(Removal::None, None, NOW));
        assert!(!needs_attention(Removal::None, Some(0), NOW));
        assert!(!needs_attention(
            Removal::Disconnected,
            Some(NOW - 30 * DAY),
            NOW
        ));
    }

    #[test]
    fn row_state_priority() {
        assert_eq!(
            row_state(Removal::Disconnected, false, true, "online"),
            "disconnected"
        );
        assert_eq!(
            row_state(Removal::None, true, true, "online"),
            "needs_attention"
        );
        assert_eq!(
            row_state(Removal::None, false, true, "offline"),
            "transferring"
        );
        assert_eq!(row_state(Removal::None, false, false, "recent"), "recent");
        assert_eq!(
            row_state(Removal::Removed, false, false, "offline"),
            "removed"
        );
    }

    #[test]
    fn last_activity_is_the_later_of_seen_and_backup() {
        assert_eq!(last_activity_at(Some(5), Some(9)), Some(9));
        assert_eq!(last_activity_at(Some(9), None), Some(9));
        assert_eq!(last_activity_at(None, Some(0)), None);
    }
}
