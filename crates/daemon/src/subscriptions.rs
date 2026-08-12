//! SYNC-03: `NodeId → 该设备当前挂着的订阅连接` 登记表。
//!
//! 只做一件事：让 `device.revoke`/`device.unpair` 能主动关掉一个还
//! 挂着 `timeline.subscribe` 长连接的设备，不必等它自然掉线。用
//! `tokio_util::sync::CancellationToken`（tokio 生态本来就有的「从外部
//! 取消一个任务」原语）而不是手搓 channel——单一性强，别人看这段代码
//! 不用先学一套自定义协议。
//!
//! 一个设备同一时刻只认最新一次订阅：新的 [`register`] 直接覆盖旧
//! entry。`generation` 只是为了让旧订阅流结束时的 `unregister` 认得出
//! "我摘的是不是还是我自己那一份"——避免旧流收尾时误删掉同一设备刚
//! 建立的新登记（`CancellationToken` 本身不提供身份比较）。
//!
//! [`register`]: SubscriptionRegistry::register

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio_util::sync::CancellationToken;

struct Entry {
    token: CancellationToken,
    generation: u64,
}

/// 登记表本身：`NodeId` → 取消它当前订阅流的 handle。`Clone` 廉价
/// （`Arc` 共享同一份状态）——Router/IpcServer 各拿一份 clone，指向
/// 同一张表，`device.revoke`（IPC 侧）才能真的关掉 Router 侧登记的
/// 订阅连接。
#[derive(Clone, Default)]
pub struct SubscriptionRegistry {
    inner: Arc<Mutex<HashMap<transport::NodeId, Entry>>>,
    next_generation: Arc<AtomicU64>,
}

impl SubscriptionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// 新订阅流启动时调用：登记一个新 token，返回它 + 一个身份凭证
    /// （`generation`），流结束时把两者一起传给 [`unregister`]。
    pub fn register(&self, peer: transport::NodeId) -> (CancellationToken, u64) {
        let token = CancellationToken::new();
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        self.inner.lock().expect("registry lock").insert(
            peer,
            Entry {
                token: token.clone(),
                generation,
            },
        );
        (token, generation)
    }

    /// 订阅流结束时调用（不管是客户端断开还是被 cancel）——只摘除
    /// "仍然是这一份"的登记：如果这期间同一设备已经注册了新的订阅
    /// （更高的 generation），不能把新登记误摘掉。
    pub fn unregister(&self, peer: transport::NodeId, generation: u64) {
        let mut map = self.inner.lock().expect("registry lock");
        if map.get(&peer).is_some_and(|e| e.generation == generation) {
            map.remove(&peer);
        }
    }

    /// `device.revoke`/`device.unpair`：命中就主动取消，不等自然掉线。
    /// 没有活跃订阅（大多数情况）什么都不做。
    pub fn close(&self, peer: transport::NodeId) {
        if let Some(entry) = self.inner.lock().expect("registry lock").remove(&peer) {
            entry.token.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer(b: u8) -> transport::NodeId {
        transport::NodeId([b; 32])
    }

    #[test]
    fn close_cancels_a_registered_token() {
        let reg = SubscriptionRegistry::new();
        let (token, _generation) = reg.register(peer(1));
        assert!(!token.is_cancelled());
        reg.close(peer(1));
        assert!(token.is_cancelled(), "revoke 必须主动取消");
    }

    #[test]
    fn close_without_registration_is_a_noop() {
        let reg = SubscriptionRegistry::new();
        reg.close(peer(9)); // 没有活跃订阅——不该 panic
    }

    #[test]
    fn unregister_does_not_clobber_a_newer_registration() {
        let reg = SubscriptionRegistry::new();
        let (old_token, old_generation) = reg.register(peer(1));
        let (new_token, _new_generation) = reg.register(peer(1)); // 同设备重连

        // 旧订阅流的收尾——它的 generation 已经不是表里最新的了。
        reg.unregister(peer(1), old_generation);

        // 新登记必须还在，revoke 必须取消的是新 token，不是旧的。
        reg.close(peer(1));
        assert!(
            !old_token.is_cancelled(),
            "旧 token 早就该被扔掉，不该被 close 影响"
        );
        assert!(
            new_token.is_cancelled(),
            "revoke 取消的必须是当前活跃的那一份"
        );
    }
}
