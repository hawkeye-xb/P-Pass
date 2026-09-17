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

## 修法（2026-09-17 验收人拍板）

**`flow.offer` 的应答改为返回 `FlowStatusReply`——即"你 offer 完立刻调
一次 `flow.status` 会得到什么，我直接给你什么"。**

验收人明确否掉了"调订阅/offer 顺序"那条：**靠时序组合去赢一场竞态不是
合适的修法**。并拍板测试阶段**不考虑旧手机兼容**，可以非兼容迭代。

### 为什么是这个形状（先找标准答案，非发明）

`offer` 是 HTTP-202 那套（提交任务 + 去轮询）。而 202 的标准用法里，
**200/201 与 202 是按每次请求决定的，不是按端点固定死的**：活当场干完
就返回结果，只有真要异步才回 202 + 任务句柄。现在的代码是知道答案也
坚持回 202。业界同形先例：

- **Docker Registry v2 blob 上传**（最贴近：同为内容 digest 寻址 + 去重
  短路）：`POST /v2/<name>/blobs/uploads/?mount=<digest>&from=<repo>`
  —— 已有则 **`201 Created`，零字节传输，终态就在这个应答里**；没有则
  `202 Accepted` + upload location 走正常上传。`201` vs `202` 就是判别式。
- **HTTP 条件请求 / `304 Not Modified`**：客户端报 ETag，服务端答"你已经
  有了"，同一个应答里给终态，不传 body。
- **Git smart protocol 的 have/want 协商**：客户端先报 `have <sha>`，
  重复对象根本不进传输阶段；去重发生在传输之前、同一次交换之内。
- **rsync**：先换校验和，只传差异。

共同点：**"我已经有了"这个事实一律在发起方还在等的那个应答里回答，
从不推给带外通知或轮询。** 这也正是 NET-14 卡自己写的原则——
「推送为加速，不是唯一路径」——本卡是回到该原则，不是引入新规矩。

### 本仓已有范式，零新类型

`proto/msgs.rs:342` 的 `FlowStatusReply` 形状正好：
`state`（`active`/`completed`/`cancelled`/`not_found`）+
`receipt: Option<_>`（仅 completed 有）+ `task_running`。

- 命中去重 → `state:"completed"` + 手里已有的 receipt → 手机零等待
- 正常起传 → `state:"active", task_running:true` → 走现有等待循环
- 输给并发 cancel/suspend（`complete_flow_grant` 返回 false）→ 据实回
  当前状态，**不伪造 receipt**

手机侧连解析都不用新写：`NativeFlowDeliveryPort.kt:383` 已有纯函数
`flowStatusPollOutcome(reply)`，正是轮询路径在用的那个。

### 已核实的顾虑（不是推测）

- **重复 receipt 安全**：应答给一次 + 推送可能再来一次。
  `CompletionAndScope.kt:49-52` 明写「AUDIT-04: a replayed receipt for an
  item already CONFIRMED must not mint a second audit_item_evidence
  fact」——幂等是设计好的，无需额外去重。
- **本卡不解决全部推送丢失**：只关"offer 时已终态"这一个洞。真实传输
  中途丢推送时本地 iroh 有事件、`idleForMs` 非 null，停滞检测正常工作，
  降级为"稍慢"而非"卡 30 秒"。原卡剩余候选（daemon 侧订阅者表残留失效
  连接、`peer: NodeId` 对应关系）若修完仍复现再单独查。
- **代价**：proto 快照测试会红，需显式重新生成；新手机配旧 daemon 拿到
  `null` 时必须**明确失败**，不许静默挂住。

## 期望行为

同 hash 去重命中时，手机在 `offer` 的应答里当场拿到终态 receipt，该项
立即完成——不依赖推送是否送达，也不等 30 秒兜底轮询。

## 验收标准

- [ ] **[E2]** daemon 单测：`offer` 命中 `has_durable_copy` 时返回
      `state=="completed"` 且 `receipt` 非空；未命中时返回
      `state=="active"`、`task_running==true`
- [ ] **[E2]** daemon 单测：`complete_flow_grant` 输给并发 cancel 时，
      `offer` 不返回 completed、不伪造 receipt
- [ ] **[E2]** Android 单测：`offer` 应答为 completed 时，交付流程不进
      等待循环直接落 receipt
- [ ] **[E2]** 反证：把 completed 分支的 receipt 摘掉（退回恒 null），
      上述用例必须变红
- [ ] **[E1]** `just ci` 全绿（含 proto 快照重新生成后的 roundtrip）
- [ ] **[E3]** 真机计时：同一批照片连发两次，第二次每张**毫秒级**完成，
      不再是 30 秒/张；对照改动前的同场景计时

## 范围

- 只准动：`crates/proto/src/msgs.rs`（offer 应答类型）、
  `crates/daemon/src/flow_delivery.rs`（`offer`/`offer_inner`/
  `complete_without_fetch` 返回值）、`crates/daemon/src/router.rs`
  （FLOW_OFFER 分支）、`apps/android/.../transport/DaemonClient.kt`、
  `apps/android/.../backup/flow/NativeFlowDeliveryPort.kt`
- 不准动：`flow.fetch` 的既有应答形状（旧桌面降级路径，NET-18 的范围）；
  `emit_flow_delivered` 推送本身（保留为加速路径，不删）；
  `flowWaitStep` 的兜底逻辑（NET-23 的资产，本卡只是让它不再是唯一出路）

## 阻塞与依赖

无前置。从 [NET-23](done/NET-23-flow-wait-loop-must-not-hang-forever-when-local-signal-never-fires.md)
真机验证中观察到的现象拆出——NET-23 保证了"推送缺失时不会永久卡死"，
本卡负责修"为什么推送会缺失"，两者独立。
