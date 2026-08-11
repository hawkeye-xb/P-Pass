---
title: 从 3 秒轮询到 36 毫秒
date: 2026-08-11
tags: [工程, IPC, 重构]
lang: zh
draft: false
---

P-Pass 的桌面端有一个"壳"（Tauri 前端），负责显示配对请求、备份状态、设备列表。它和后台 daemon（Rust）通过本地 socket 通信。

在很长一段时间里，壳是这么知道"状态变了"的：**每 3 秒问一次 daemon，"有什么新情况吗？"** 没有新情况就再等 3 秒，再问。

轮询不是不能用，但它有三个毛病：体验上，配对请求来了要等最多 3 秒才弹窗；实现上，每次全量拉取状态，前端要 diff 才知道变没变；资源上，3 秒一次的全量查询，对一个常驻进程来说既费 CPU 也费电。

## 决定：改成事件驱动

结论写进了任务卡，理由只有一句话："轮询是体验、实现、内存都不友好。"

做法是标准的发布-订阅：daemon 内部有个事件总线，状态变化的地方发事件；壳通过一条长连接订阅，有事件就收到通知，然后拉一次全量刷新。壳的刷新逻辑本身不变——事件只是"告诉它该刷新了"的加速器。

## daemon 侧：一个 broadcast channel

Rust 侧实现意外地简单，一个 tokio broadcast channel 就是总线：

```rust
pub type EventBus = broadcast::Sender<Value>;
pub const PAIRING_PENDING_CHANGED: &str = "pairing.pending_changed";
pub const STATUS_CHANGED: &str = "status.changed";
// ...

pub fn emit(bus: &EventBus, event: &str, data: Value) {
    let _ = bus.send(json!({"event": event, "data": data}));
}
```

四个事件：配对请求变化、状态变化、活动追加、设备变化。每个事件都在**真实变化发生的地方**发——不是定时器模拟，是 `pending` 入队时、`confirm` 出队时、备份提交时、设备吊销时。这一条很重要：事件必须挂在真实触点上，否则它只是另一种轮询。

## 订阅协议：握手后变事件流

IPC 新增一个方法 `events.subscribe`。客户端发订阅请求，daemon 回 `{ok:true}`，然后这条连接**变成事件流**——每行一个 JSON 事件帧。

```
→ {"method":"events.subscribe","id":1}
← {"ok":true,"result":{"subscribed":true}}
← {"event":"pairing.pending_changed","data":{"pending":1}}
← {"event":"device.changed","data":{...}}
```

两个细节值得说：

**慢订阅者会被跳过（Lagged）**。如果订阅者消费太慢、事件积压超过缓冲区容量，tokio 会报 Lagged——我们的处理是跳过旧事件，等它追上来。因为事件是"加速器"不是"承诺"：丢了也没关系，客户端本来就要靠全量刷新兜底。写进注释的契约是：*事件是加速器不是承诺，丢了由客户端全量 refresh 兜底*。

**老 daemon 兼容**。老版本不认识 `events.subscribe`，会返回错误。壳收到错误就静默降级回轮询——升级是渐进的，老 daemon 用户不会坏。

## 壳侧：长连接 + 重连 + 降级

壳在启动时开一个后台线程，无限循环：发现 daemon → 建立订阅连接 → 读事件 → 断开后等 2 秒重连。前端监听 `daemon-event`，收到就刷新。

轮询没有删除，只是降级：从 3 秒主通道变成 **60 秒兜底对账**。万一事件丢了、连接断了没发现，60 秒内必然对账一次。这不是偷懒——是防御性设计：事件驱动偶尔漏，兜底轮询保证最终一致。

## 测试：36 毫秒

验收标准是"订阅后注入配对请求，事件必须在 100ms 内到达"。集成测试走真实链路：配对请求入队 → 事件发出 → 客户端收到。

实测 **36ms**。对比：原来轮询要等 3 秒。

还写了两条反证测试：一是类型过滤——只订阅 `status.changed` 的连接，收到 `pending` 事件必须超时；二是 unsubscribe——取消订阅后连接必须被服务端关闭。反证的意义是证明"过滤真的在过滤、关闭真的在关闭"，不是碰巧没收到。

## 复盘

这个重构没有引入任何新依赖——tokio broadcast 是现成的，协议是既有 IPC 框架的一个新方法。改动的核心其实是**想清楚一件事**：状态推送是"通知"不是"状态本身"，通知可以丢，状态不能错。想清楚这个，实现就只是顺着写。

相关材料：
- 实现提交：[f6f734a](https://github.com/hawkeye-xb/P-Pass/commit/f6f734a02d3e5ac71b99c43c65035a69797adb4f)
- daemon 事件总线：[crates/daemon/src/events.rs](https://github.com/hawkeye-xb/P-Pass/blob/main/crates/daemon/src/events.rs)
- 订阅协议实现：[crates/daemon/src/ipc.rs](https://github.com/hawkeye-xb/P-Pass/blob/main/crates/daemon/src/ipc.rs)
