//! #1117 / #1119：删除配对记录的唯一入口。
//!
//! 电脑撤销（IPC `device.revoke`）、手机断开（`device.unpair`）都走这里；电脑
//! 换身份（#1109）在启动时、组件还没起来之前直接调 `Db::remove_all_pairings`，
//! 那时没有任何内存态要清。
//!
//! 顺序：先删库里的配对记录（同一事务里级联删掉备份水位与交付租约 / 回执，
//! 并更新授权内存副本——从这一刻起这台设备的任何请求都在 authz 处被拒），
//! 再清挂在这台设备上的内存态：在途拉取、备份会话、订阅，最后关掉与它的全部
//! 网络连接（#1119，iroh 自带的 `Connection::close`，经 [`PeerCloser`]）。撤销
//! 的生效不依赖对端知道：从删库那一刻起，它的每个请求都在 authz 处被拒。审计与
//! 事件由调用方按各自语义记录。

use std::sync::Arc;

use storage::{Db, DepartedBy, Pairing};

/// #1119：关掉与某台设备的全部网络连接，返回关掉了几条（main 注入
/// `IrohTransport::close_peer`；transport 还没 bind 时是空操作）。
pub type PeerCloser = Arc<dyn Fn(transport::NodeId) -> usize + Send + Sync>;

/// 删配对记录时要一并清掉的内存态的持有者。缺哪个就跳过哪个（测试 / 单组件
/// 构造）。
#[derive(Clone, Copy, Default)]
pub struct Holders<'a> {
    pub flow: Option<&'a crate::flow_delivery::FlowDelivery>,
    pub backup: Option<&'a crate::backup::BackupEngine>,
    pub subscriptions: Option<&'a crate::subscriptions::SubscriptionRegistry>,
    pub connections: Option<&'a PeerCloser>,
}

/// 删除 `peer` 的配对记录。`expect_id` 给出时只删 id 一致的那条（#565）。
/// 返回被删的记录；`None` = 没有（或 id 不符），什么都没改、什么都不清。
pub async fn remove_pairing(
    db: &Db,
    holders: Holders<'_>,
    peer: transport::NodeId,
    expect_id: Option<&str>,
    by: DepartedBy,
    at_ms: i64,
) -> storage::Result<Option<Pairing>> {
    let removed = db.remove_pairing(&peer.0, expect_id, by, at_ms).await?;
    if removed.is_some() {
        release(holders, peer).await;
    }
    Ok(removed)
}

/// 清掉挂在 `peer` 上的内存态。
async fn release(holders: Holders<'_>, peer: transport::NodeId) {
    // #1126: its upload provider runs an endpoint identity of its own — close those connections
    // with the same 410, so the phone hears the removal even with no control connection open.
    let mut providers = Vec::new();
    if let Some(flow) = holders.flow {
        providers = flow.take_provider_endpoints(peer);
        flow.release_peer(peer).await;
    }
    if let Some(backup) = holders.backup {
        backup.end_session(peer);
    }
    if let Some(subscriptions) = holders.subscriptions {
        subscriptions.close(peer);
    }
    // 最后关连接：前面几步收掉的任务此时已退出，不会再借这条连接发东西。
    if let Some(close) = holders.connections {
        let closed = close(peer);
        let provider_closed: usize = providers.iter().map(|p| close(*p)).sum();
        tracing::info!(
            "#1119: pairing removed, closed {closed} connection(s) + {provider_closed} provider connection(s) peer={peer:?}"
        );
    }
}
