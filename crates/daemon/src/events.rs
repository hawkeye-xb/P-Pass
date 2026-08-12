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
//! - `timeline.invalidated` — BackupEngine（ingest，经 [`Throttle`] 合并）/
//!   Reconcile（对账一轮完成，直发不经节流，见 SYNC-02）

use std::sync::{Arc, Mutex};
use std::time::Duration;

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
/// 时间线可能已变化（ingest/对账）——不带数据，只是"该刷新了"的 ping。
/// SYNC-02（docs/product/2026-08-12-metadata-sync-decisions.md §②③④⑤）。
pub const TIMELINE_INVALIDATED: &str = "timeline.invalidated";

/// [`Throttle`] 默认合并窗口——窗口内多次 [`Throttle::signal`] 只发一次，
/// 窗口到点必发（不是防抖：防抖会在持续到达场景下让用户整批传输期间
/// 什么都看不到，见决策档案 §⑤，明确否掉的方案）。可调参数，非定案值。
pub const DEFAULT_THROTTLE_WINDOW: Duration = Duration::from_secs(3);

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

#[derive(Default)]
struct ThrottleState {
    pending: bool,
    /// 每次真正 emit（force 或窗口到点）自增，用来让"已经在 sleep 里
    /// 排队"的旧任务在醒来时发现自己过期，不会补发一次多余的 emit。
    generation: u64,
}

/// `timeline.invalidated` 的节流合并器：窗口内多次 [`signal`] 只
/// emit 一次；窗口到点必发；[`flush_now`] 供批次收尾（如
/// `backup.commit`）立即强制触发，不等窗口到点。SYNC-02 §⑤。
///
/// [`signal`]: Throttle::signal
/// [`flush_now`]: Throttle::flush_now
#[derive(Clone)]
pub struct Throttle {
    bus: EventBus,
    window: Duration,
    state: Arc<Mutex<ThrottleState>>,
}

impl Throttle {
    pub fn new(bus: EventBus, window: Duration) -> Self {
        Self {
            bus,
            window,
            state: Arc::new(Mutex::new(ThrottleState::default())),
        }
    }

    /// "东西变了"——第一次调用（或上一个窗口已经发过之后的第一次）
    /// 会安排一个 `window` 之后的 emit；窗口内的后续调用只是把
    /// `pending` 标记为真，不新开定时器。
    pub fn signal(&self) {
        let mut st = self.state.lock().expect("throttle lock");
        let already_scheduled = st.pending;
        st.pending = true;
        if already_scheduled {
            return;
        }
        let generation = st.generation;
        drop(st);
        let this = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(this.window).await;
            this.fire_if_current(generation);
        });
    }

    /// 有挂起信号就立即 emit（不等窗口），没有就什么都不做——批次
    /// 收尾钩子用这个，不是无条件发送。
    pub fn flush_now(&self) {
        let mut st = self.state.lock().expect("throttle lock");
        if !st.pending {
            return;
        }
        st.pending = false;
        st.generation += 1;
        drop(st);
        emit(&self.bus, TIMELINE_INVALIDATED, json!({}));
    }

    fn fire_if_current(&self, generation: u64) {
        let mut st = self.state.lock().expect("throttle lock");
        if !st.pending || st.generation != generation {
            // 已经被 flush_now 抢先发过（generation 已推进），或本来
            // 就没有新信号——这次窗口到点什么都不做。
            return;
        }
        st.pending = false;
        st.generation += 1;
        drop(st);
        emit(&self.bus, TIMELINE_INVALIDATED, json!({}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn window_merges_bursts_into_one_emit() {
        let (bus, mut rx) = bus();
        let throttle = Throttle::new(bus, Duration::from_millis(100));

        throttle.signal();
        throttle.signal();
        throttle.signal();
        tokio::task::yield_now().await; // 让 spawn 出来的任务先跑到 sleep 挂起
        assert!(rx.try_recv().is_err(), "窗口内不该提前 emit");

        tokio::time::advance(Duration::from_millis(150)).await;
        tokio::task::yield_now().await;
        let first = rx.try_recv().expect("窗口到点必发");
        assert_eq!(first["event"], TIMELINE_INVALIDATED);
        assert!(rx.try_recv().is_err(), "一个窗口只能 emit 一次");
    }

    #[tokio::test(start_paused = true)]
    async fn flush_now_fires_immediately_without_waiting_for_window() {
        let (bus, mut rx) = bus();
        let throttle = Throttle::new(bus, Duration::from_secs(30));

        throttle.signal();
        throttle.flush_now();
        // 不 advance 时钟——如果 flush_now 真的立即触发，这里已经能收到。
        rx.try_recv().expect("批次收尾必须立即 emit，不等窗口");
    }

    #[tokio::test(start_paused = true)]
    async fn flush_now_without_pending_signal_is_a_noop() {
        let (bus, mut rx) = bus();
        let throttle = Throttle::new(bus, Duration::from_secs(30));

        throttle.flush_now(); // 没有挂起信号，不该发空事件
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn stale_window_task_does_not_double_fire_after_flush_now() {
        let (bus, mut rx) = bus();
        let throttle = Throttle::new(bus, Duration::from_millis(100));

        throttle.signal();
        throttle.flush_now();
        rx.try_recv().expect("flush_now 立即 emit");

        // 原来那个窗口定时任务仍在排队，醒来时应发现自己过期，不补发。
        tokio::time::advance(Duration::from_millis(150)).await;
        tokio::task::yield_now().await;
        assert!(
            rx.try_recv().is_err(),
            "flush_now 之后，原窗口任务醒来不该再发一次"
        );
    }
}
