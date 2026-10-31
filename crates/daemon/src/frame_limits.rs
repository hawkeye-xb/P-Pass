//! #1122：控制面请求帧上限与未配对对端限速。#1269：配对窗口里，已出示二维码令牌的手机
//! 走单独的名额与额度，不和还没出示令牌的连接抢。
//!
//! 读帧前按对端的配对状态定上限（方法在帧里，读之前还不知道）：未配对（只可能
//! 在配对窗口内进来）只给配对流程那几 KB；viewer 只能调小方法；member 才放到
//! 需要大消息的方法所需的上限。解码后再按方法核对：只有确实需要大消息的方法
//! 才放宽，其余一律默认小上限。配合 transport 的增量读帧、读帧超时与全进程
//! 在途字节预算，未认证对端无法让电脑分配大块内存，已认证对端也有上限。

use std::collections::VecDeque;
use std::num::NonZeroU32;
use std::sync::{Arc, Mutex};
use std::time::Duration;

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

/// 未配对对端（配对窗口内）的请求限速：**所有未配对对端共用一个总额度**，每秒 20 个、
/// 突发 40 个。配对流程正常节奏是每几秒轮询一次 `pair.status`，远低于这个量。
///
/// 不按设备身份分桶：身份就是一把密钥、换起来零成本——按身份限速换个身份就绕过，
/// 而且每个新身份都在限速表里多占一条、永不清理（内存随攻击者无限增长）。总额度
/// 的状态是固定大小，与对端数量无关（同 SSH `MaxStartups` 的思路）。代价：配对窗口
/// 内攻击者可以占满额度、让家人暂时配不上——能进同一网络的攻击者本就能干扰，
/// 换来的是内存有上限。
pub type UnpairedLimiter = Arc<
    governor::RateLimiter<
        governor::state::NotKeyed,
        governor::state::InMemoryState,
        governor::clock::DefaultClock,
    >,
>;

pub fn unpaired_limiter() -> UnpairedLimiter {
    let quota = governor::Quota::per_second(NonZeroU32::new(20).expect("nonzero"))
        .allow_burst(NonZeroU32::new(40).expect("nonzero"));
    Arc::new(governor::RateLimiter::direct(quota))
}

/// 同时在线的、还没出示令牌的未配对连接上限（全局）。配对时一次只有一两台手机在扫码。
pub const UNPAIRED_CONN_MAX: usize = 8;

/// #1269：还没出示令牌的连接，从连接建立起最多活这么久。手机每个请求单独建一条连接、
/// 连上即发（扫码后 `hello` 紧接着 `pair.request`），用不到 5 秒；出示过令牌的那台手机
/// 不受这个限制（见 [`TICKET_CONN_MAX`]）。
pub const UNPROVEN_TTL: Duration = Duration::from_secs(5);

/// #1269：已出示有效令牌（有自己的配对申请）的手机，单独的连接名额。它轮询 `pair.status`
/// 时一次一条连接、用完即关；二维码同时只有一个、令牌一次性，持有申请的设备只有一两台。
pub const TICKET_CONN_MAX: usize = 4;

/// #1269：已出示令牌的手机单独的请求额度，与未配对对端的总额度同一个量，但不共用。
pub fn ticket_limiter() -> UnpairedLimiter {
    unpaired_limiter()
}

/// #1149：在场的未配对连接多久复核一次「配对窗口还开着吗」。窗口关闭（二维码关闭或
/// 令牌过期）到连接被收回，最长就是这个间隔，要求在 1 秒内。
pub const WINDOW_RECHECK: std::time::Duration = std::time::Duration::from_millis(250);

/// #1269：已出示令牌的手机的名额池：连接建立时取一个名额、连接结束时归还；没有名额就断开。
pub type TicketConns = Arc<tokio::sync::Semaphore>;

pub fn ticket_conns() -> TicketConns {
    Arc::new(tokio::sync::Semaphore::new(TICKET_CONN_MAX))
}

/// #1269：还没出示令牌的连接的名额池（全局 [`UNPAIRED_CONN_MAX`] 个）。满了不拒新来的，
/// 而是淘汰最早来的那条（同 SSH `MaxStartups` 的思路：认证前的名额满了丢旧的）——
/// 否则先占满名额的连接能把后来扫码的手机一直挡在外面。被淘汰的连接从
/// [`UnprovenSlot::evicted`] 得知，由持有者断开。
#[derive(Clone)]
pub struct UnprovenConns(Arc<Mutex<UnprovenInner>>);

struct UnprovenInner {
    cap: usize,
    next_id: u64,
    /// 按到达先后排列。
    live: VecDeque<(u64, tokio_util::sync::CancellationToken)>,
}

/// 一个名额；丢掉即归还。
pub struct UnprovenSlot {
    id: u64,
    evicted: tokio_util::sync::CancellationToken,
    pool: UnprovenConns,
}

impl UnprovenConns {
    pub fn new(cap: usize) -> Self {
        Self(Arc::new(Mutex::new(UnprovenInner {
            cap,
            next_id: 0,
            live: VecDeque::new(),
        })))
    }

    /// 取一个名额；满了先淘汰最早来的那条。
    pub fn admit(&self) -> UnprovenSlot {
        let mut inner = self.0.lock().expect("unproven conns lock");
        while inner.live.len() >= inner.cap {
            match inner.live.pop_front() {
                Some((_, oldest)) => oldest.cancel(),
                None => break,
            }
        }
        let id = inner.next_id;
        inner.next_id += 1;
        let evicted = tokio_util::sync::CancellationToken::new();
        inner.live.push_back((id, evicted.clone()));
        UnprovenSlot {
            id,
            evicted,
            pool: self.clone(),
        }
    }
}

impl UnprovenSlot {
    /// 这个名额被后来的连接挤掉时触发。
    pub fn evicted(&self) -> &tokio_util::sync::CancellationToken {
        &self.evicted
    }
}

impl Drop for UnprovenSlot {
    fn drop(&mut self) {
        let mut inner = self.pool.0.lock().expect("unproven conns lock");
        inner.live.retain(|(id, _)| *id != self.id);
    }
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

    /// 反证：改回按身份分桶（`RateLimiter::keyed` + `check_key`），换身份就能无限
    /// 通过——这条必须红。
    #[test]
    fn rotating_identities_does_not_bypass_the_unpaired_limit() {
        let limiter = unpaired_limiter();
        let allowed = (0..10_000u32).filter(|_| limiter.check().is_ok()).count();
        assert!(
            allowed <= 41,
            "所有未配对对端共用一个额度，换身份不增加额度：{allowed}"
        );
    }

    /// #1269：名额满了，新来的照样进，挤掉最早来的那条；同时在场的始终不超过上限，
    /// 归还的名额不再占位。反证：满了改成拒绝新来的，第一条断言变红。
    #[test]
    fn full_unproven_pool_evicts_the_oldest_instead_of_refusing() {
        let pool = UnprovenConns::new(UNPAIRED_CONN_MAX);
        let mut held: Vec<_> = (0..UNPAIRED_CONN_MAX).map(|_| pool.admit()).collect();
        let newcomer = pool.admit();
        assert!(held[0].evicted().is_cancelled(), "最早来的被挤掉");
        assert!(held[1..].iter().all(|s| !s.evicted().is_cancelled()));
        assert!(!newcomer.evicted().is_cancelled());

        // 被挤掉的那条断开（丢掉名额）；在场的仍是上限个，下一个新来的挤掉第二早的。
        held.remove(0);
        let next = pool.admit();
        assert!(held[0].evicted().is_cancelled());
        assert!(!next.evicted().is_cancelled());
        assert_eq!(pool.0.lock().unwrap().live.len(), UNPAIRED_CONN_MAX);

        // 归还后不再占位：空出来的名额直接可用，不挤任何人。
        drop(held);
        let fresh = pool.admit();
        assert!(!newcomer.evicted().is_cancelled() && !fresh.evicted().is_cancelled());
    }
}
