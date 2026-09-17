# NET-24 NET-20 去重命中时 `flow.delivered` 推送必然丢失——订阅晚于 offer　级别 L1

> ⬜ 状态：未开工（**根因已定位并经源码核实，2026-09-17**）
> 级别：L1 · 阻塞：无（从 NET-23 拆出）
> ⚠️ **卡名/范围已更正**：原标题写「断链重连场景」，实测范围更大且是
> **确定性**的——任何 NET-20 去重命中都必丢推送，与断链重连无关。

## 问题

2026-09-16 三星 SM-S9210 真机复现（断链重连后重新触发备份，11 张全部
命中 NET-20 内容去重）：NET-23 修复后传输不再永久卡死，但每一张仍然
要等满本地空闲兜底超时（30 秒）才被 `flow.status()` 轮询捞回来，不是
预期的"daemon 完成 → `flow.delivered` 推送 → 手机瞬时收到"。11 张耗时
约 3 分钟，说明这次会话里推送**从未有一次真正送达手机**（如果送达过，
`flowWaitStep` 会在 `pushed is FlowPushOutcome.Delivered` 分支立刻返回，
不会等到超时）。

## 根因（2026-09-17 源码核实，非推测；原三条候选中第一条成立且范围更大）

**订阅建立晚于 offer 发出，而 NET-20 的去重完成是同步且瞬时的，所以这场
竞态是确定性输，不是偶发。**

调用顺序（`NativeFlowDeliveryPort.kt`，同一个 `scope.launch` 块内）：

| 行 | 动作 |
|---|---|
| `:293` | `desktop.offer(request)` —— **await，先发 offer** |
| `:320` | `val pushChannel = Channel(...)` |
| `:321` | `launch { client.subscribeTimeline(...) }` —— **offer 之后才订阅，且异步 launch，返回时订阅尚未建立** |

daemon 侧在 offer 的处理过程中**同步**走完全程：

- `flow_delivery.rs:485-492` `has_durable_copy` 命中 → `complete_without_fetch`
- `flow_delivery.rs:519-527` `complete_flow_grant` 落 receipt → 紧接着
  `emit_flow_delivered`

而事件总线是 live-only 广播，`events.rs:23` `pub type EventBus =
broadcast::Sender<Value>`，模块头注释自己写着「**无订阅者时 send 直接
丢弃**」（`events.rs:4`），`emit` 是 `let _ = bus.send(...)`，错误被吞。

→ 推送在手机订阅上线**之前**就被发出并丢弃，永远不会补发。

**为什么只有去重命中才暴露**：真实传输时 `spawn_fetch_task` 要建连 + 搬
字节，这段延迟足够订阅抢先建立；而 NET-20 把这段延迟**降到零**，窗口从
"几乎不可能命中"变成"每次必中"。

**为什么之后只能干等 30 秒**：去重命中意味着数据面一个字节没走，本地
iroh-blobs 永远不会有任何 get-request/progress/completed 事件，
`idleForMs` 恒为 null（`NativeFlowDeliveryPort.kt:555-573` 的长注释已经
写明这一点）。于是唯一还在走的时钟只剩调用方自己的挂钟，走到
`LOCAL_IDLE_STALL_THRESHOLD_MS = 30_000`（`:629`）才 `CheckStatusNow`，
靠 `flow.status()` 把早已完成的状态捞回来。

**代价评估（值得在修法里一并拍板）**：NET-20 用"零字节重传"换来了"每张
多等一个兜底窗口"。对 224MB 视频仍是大赢；对小照片很可能是**净亏**——
改前是浪费字节但信令及时，改后是省了字节但每张卡一个兜底窗口。

**修法方向（未实施，等拍板）**：把订阅移到 `offer` **之前**建立并确认
就绪，再发 offer。这是标准的"先订阅后触发"顺序，不需要协议改动，也不
需要 daemon 侧补发/重放机制。剩余候选（daemon 侧订阅者表残留失效连接、
`peer: NodeId` 对应关系）在本根因修复后若仍复现再查。

## 期望行为

同 hash 去重命中时，手机应在推送到达的毫秒级时间内看到该项完成，而
不是等到 30 秒兜底轮询。

## 验收标准

- [ ] 复现「断链重连后同 hash 批量去重」场景，用 daemon 侧日志/DB
      时间戳与手机侧收到 `flow.delivered` 的时间戳对比，定位推送
      从 daemon 发出到手机接收之间具体在哪一步丢失或延迟。
- [ ] 修复后同一场景里，去重命中的每一项应在推送到达后立刻完成
      （不再等到 30 秒超时），真机计时验证。
- [ ] 反证：临时恢复丢失前的状态，上述计时验证必须变红。

## 范围

待定——需要先定位根因（daemon 侧订阅管理 / 手机侧订阅时机 / 两者
之间的连接标识对应关系），范围由根因决定。

## 阻塞与依赖

无前置。从 [NET-23](done/NET-23-flow-wait-loop-must-not-hang-forever-when-local-signal-never-fires.md)
真机验证中观察到的现象拆出——NET-23 保证了"推送缺失时不会永久卡死"，
本卡负责修"为什么推送会缺失"，两者独立。
