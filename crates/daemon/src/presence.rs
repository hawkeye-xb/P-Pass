//! PRES-01: 三档在线态判定（纯函数）。
//!
//! 设备行的在线语义从「有无活跃 QUIC 连接」升级为三档：
//!
//! - `online`：活跃连接（direct/relay）**或** last_seen 距今 ≤ 2 分钟
//!   （手机前台 30s 轻心跳，两跳间隔内视为在线——锁屏瞬间不误判离线）；
//! - `recent`：last_seen 距今在 2 分钟 ~ 5 天之间——「x 分钟前在线」；
//! - `offline`：last_seen 距今 > 5 天（哨兵口径，桌面行亮红不变）或
//!   从未上报过（`None`）。
//!
//! 契约：connection 是活连接事实（direct/relay/offline/unknown），
//! 优先级最高；last_seen 只在没有活连接时参与判定。红线：本函数只做
//! 展示判定，**绝不参与鉴权**（authz 不读 presence）；后台不心跳
//! （耗电红线在客户端侧）。

/// 心跳新鲜窗口：30s 心跳的两跳间隔 + 余量 → 2 分钟内算在线。
pub const ONLINE_HEARTBEAT_MS: i64 = 2 * 60 * 1000;
/// 哨兵口径：超过 5 天 = 离线（与设计稿「>5 天亮红」同源，改不得）。
pub const OFFLINE_SENTINEL_MS: i64 = 5 * 24 * 3600 * 1000;
/// device.connected 审计去重窗口：同设备 10 分钟内只记一条。
pub const CONNECTED_AUDIT_DEDUPE_MS: i64 = 10 * 60 * 1000;

/// 三档在线态字符串（devices.list 直出的 wire 值）。
pub fn presence(conn: &str, last_seen: Option<i64>, now_ms: i64) -> &'static str {
    if conn == "direct" || conn == "relay" {
        return "online";
    }
    let Some(ls) = last_seen else {
        return "offline";
    };
    let age = now_ms - ls;
    if age <= ONLINE_HEARTBEAT_MS {
        "online"
    } else if age <= OFFLINE_SENTINEL_MS {
        "recent"
    } else {
        "offline"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000_000;

    // ── 活跃连接：不管 last_seen 是什么，有活连接就是在线 ─────────
    #[test]
    fn active_connection_is_online_even_with_stale_last_seen() {
        assert_eq!(
            presence("direct", Some(NOW - 10 * 24 * 3600 * 1000), NOW),
            "online"
        );
        assert_eq!(presence("relay", None, NOW), "online");
    }

    // ── 心跳新鲜边界：≤2min 在线，>2min 转 recent ─────────────────
    #[test]
    fn heartbeat_freshness_boundary() {
        // 2 分钟整 = 在线（边界含等号）。
        assert_eq!(
            presence("unknown", Some(NOW - ONLINE_HEARTBEAT_MS), NOW),
            "online"
        );
        // 2 分钟 + 1ms = 刚刚在线。
        assert_eq!(
            presence("unknown", Some(NOW - ONLINE_HEARTBEAT_MS - 1), NOW),
            "recent"
        );
        // 30s 心跳量级：在线。
        assert_eq!(presence("offline", Some(NOW - 30_000), NOW), "online");
    }

    // ── stale 边界：>5 天 = 离线（哨兵口径）────────────────────────
    #[test]
    fn sentinel_boundary() {
        // 5 天整 = recent（哨兵是从「超过 5 天」开始）。
        assert_eq!(
            presence("unknown", Some(NOW - OFFLINE_SENTINEL_MS), NOW),
            "recent"
        );
        // 5 天 + 1ms = 离线。
        assert_eq!(
            presence("unknown", Some(NOW - OFFLINE_SENTINEL_MS - 1), NOW),
            "offline"
        );
        // 中间量级：3 分钟前 → recent。
        assert_eq!(
            presence("unknown", Some(NOW - 3 * 60 * 1000), NOW),
            "recent"
        );
    }

    // ── 从未上报 / 缺失 ─────────────────────────────────────────────
    #[test]
    fn never_seen_is_offline() {
        assert_eq!(presence("unknown", None, NOW), "offline");
        assert_eq!(presence("offline", None, NOW), "offline");
    }

    // ── 时钟偏差：last_seen 在未来（轻微时钟前跳）→ 在线 ────────────
    #[test]
    fn future_last_seen_is_online() {
        assert_eq!(presence("unknown", Some(NOW + 60_000), NOW), "online");
    }
}
