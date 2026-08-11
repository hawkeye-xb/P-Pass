//! IPC-02: 事件总线——`events.subscribe` 订阅通道的事件源。
//!
//! 事件是 newline JSON `{"event":"<name>","data":{...}}`，经 broadcast
//! 分发到所有订阅连接。broadcast 语义：无订阅者时 send 直接丢弃
//! （emit 静默，绝不阻塞调用方）；慢订阅者 Lagged 时跳过旧事件
//! （客户端以全量 refresh 兜底，事件只是加速器，不承诺零丢失）。
//!
//! 触发点约定（每类事件的发出位置）：
//! - `pairing.pending_changed` — IpcServer（pending 队列增/减）
//! - `status.changed` — main（daemon 启动就绪）
//! - `activity.appended` — Router/IpcServer（audit/活动流新条目）
//! - `device.changed` — Router/Pairing/IpcServer（配对/移除/水位推进）

use serde_json::{json, Value};
use tokio::sync::broadcast;

/// 事件总线句柄：`events.subscribe` 连接从中取接收端。
pub type EventBus = broadcast::Sender<Value>;

/// 配对待确认队列变化（扫码进来 / 处理完一条）。
pub const PAIRING_PENDING_CHANGED: &str = "pairing.pending_changed";
/// 服务态/版本变化（当前触发点少：daemon 启动就绪；订阅建立时客户端
/// 自行全量刷新，事件用于未来状态突变）。
pub const STATUS_CHANGED: &str = "status.changed";
/// 活动流新条目（备份批次/审计事件）。
pub const ACTIVITY_APPENDED: &str = "activity.appended";
/// 设备表变化（配对/移除/水位推进）。
pub const DEVICE_CHANGED: &str = "device.changed";

/// 创建事件总线（sender + 首个 receiver）。容量 64：事件只是加速器，
/// 满则 Lagged 跳过，客户端全量 refresh 兜底。
pub fn bus() -> (EventBus, broadcast::Receiver<Value>) {
    broadcast::channel(64)
}

/// 发一个事件。无订阅者 / 订阅者全掉线时静默丢弃——事件不是持久
/// 存储，绝不因此报错或阻塞调用方。
pub fn emit(bus: &EventBus, event: &str, data: Value) {
    let _ = bus.send(json!({ "event": event, "data": data }));
}
