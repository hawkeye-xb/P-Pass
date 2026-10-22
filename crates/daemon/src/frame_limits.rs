//! #1122：控制面请求帧上限与未配对对端限速。
//!
//! 读帧前按对端的配对状态定上限（方法在帧里，读之前还不知道）：未配对（只可能
//! 在配对窗口内进来）只给配对流程那几 KB；viewer 只能调小方法；member 才放到
//! 需要大消息的方法所需的上限。解码后再按方法核对：只有确实需要大消息的方法
//! 才放宽，其余一律默认小上限。配合 transport 的增量读帧、读帧超时与全进程
//! 在途字节预算，未认证对端无法让电脑分配大块内存，已认证对端也有上限。

use std::num::NonZeroU32;
use std::sync::Arc;

use proto::msgs::methods;
use storage::{Pairing, Role};

/// 没有配对记录的对端（配对窗口内）：hello / pair.* 都只有几百字节。
pub const PAIRING_FRAME_MAX: u32 = 8 * 1024;
/// 已配对设备的默认请求上限。
pub const METHOD_FRAME_DEFAULT: u32 = 64 * 1024;
/// `backup.presence`：至多 500 个 hash（`backup.rs` 的上限），约 35 KB。
pub const PRESENCE_FRAME_MAX: u32 = 128 * 1024;
/// `flow.audit_submit`：手机一批至多 200 条审计事件（Android `AUDIT_BATCH`）。
pub const AUDIT_SUBMIT_FRAME_MAX: u32 = 1024 * 1024;
/// `backup.manifest`（旧批量管线，#990 退役前保留）：清单可能较长。
pub const MANIFEST_FRAME_MAX: u32 = 4 * 1024 * 1024;

/// 读帧之前的上限：按配对状态（与角色）定。
pub fn pre_read_cap(pairing: Option<&Pairing>) -> u32 {
    match pairing.map(|p| p.role) {
        None => PAIRING_FRAME_MAX,
        Some(Role::Viewer) => METHOD_FRAME_DEFAULT,
        Some(Role::Member) => MANIFEST_FRAME_MAX,
    }
}

/// 解码之后按方法核对的上限。
pub fn method_cap(method: &str) -> u32 {
    match method {
        methods::BACKUP_MANIFEST => MANIFEST_FRAME_MAX,
        methods::FLOW_AUDIT_SUBMIT => AUDIT_SUBMIT_FRAME_MAX,
        methods::BACKUP_PRESENCE => PRESENCE_FRAME_MAX,
        _ => METHOD_FRAME_DEFAULT,
    }
}

/// 未配对对端（配对窗口内）的请求限速：每台设备每秒 5 个、突发 10 个。配对
/// 流程正常节奏是每几秒轮询一次 `pair.status`，远低于这个量。
pub type UnpairedLimiter = Arc<
    governor::RateLimiter<
        transport::NodeId,
        governor::state::keyed::DefaultKeyedStateStore<transport::NodeId>,
        governor::clock::DefaultClock,
    >,
>;

pub fn unpaired_limiter() -> UnpairedLimiter {
    let quota = governor::Quota::per_second(NonZeroU32::new(5).expect("nonzero"))
        .allow_burst(NonZeroU32::new(10).expect("nonzero"));
    Arc::new(governor::RateLimiter::keyed(quota))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paired(role: Role) -> Pairing {
        Pairing {
            id: "p".into(),
            node_id: vec![1; 32],
            role,
            paired_at: 0,
        }
    }

    /// 反证：未配对给到成员上限，第一条变红；某个小方法被放宽，最后一条变红。
    #[test]
    fn caps_follow_pairing_state_and_method() {
        assert_eq!(pre_read_cap(None), PAIRING_FRAME_MAX);
        assert_eq!(
            pre_read_cap(Some(&paired(Role::Viewer))),
            METHOD_FRAME_DEFAULT
        );
        assert_eq!(
            pre_read_cap(Some(&paired(Role::Member))),
            MANIFEST_FRAME_MAX
        );
        assert_eq!(
            method_cap(methods::FLOW_AUDIT_SUBMIT),
            AUDIT_SUBMIT_FRAME_MAX
        );
        assert_eq!(method_cap(methods::BACKUP_MANIFEST), MANIFEST_FRAME_MAX);
        for m in [
            methods::HELLO,
            methods::PAIR_REQUEST,
            methods::FLOW_OFFER,
            methods::TIMELINE_PAGE,
        ] {
            assert_eq!(method_cap(m), METHOD_FRAME_DEFAULT, "{m}");
        }
        // 每个按方法的上限都不超过 member 的读前上限（否则那个方法永远读不进来）。
        for m in [
            methods::BACKUP_MANIFEST,
            methods::FLOW_AUDIT_SUBMIT,
            methods::BACKUP_PRESENCE,
        ] {
            assert!(method_cap(m) <= pre_read_cap(Some(&paired(Role::Member))));
        }
        const { assert!(PAIRING_FRAME_MAX < METHOD_FRAME_DEFAULT) };
    }

    #[test]
    fn unpaired_requests_are_rate_limited_per_device() {
        let limiter = unpaired_limiter();
        let a = transport::NodeId([1; 32]);
        let b = transport::NodeId([2; 32]);
        let allowed = (0..50).filter(|_| limiter.check_key(&a).is_ok()).count();
        assert!(allowed <= 11, "突发之后被限速：{allowed}");
        assert!(limiter.check_key(&b).is_ok(), "限速按设备分开");
    }
}
