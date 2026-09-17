# NET-24 NET-20 去重命中时 `flow.delivered` 推送必然丢失——订阅晚于 offer　级别 L1

状态：✅ 已归档（commit `496cf68`），2026-09-17 真机验收通过
级别：L1
关联: 从 [NET-23](NET-23-flow-wait-loop-must-not-hang-forever-when-local-signal-never-fires.md) 分出；
  触发条件由 NET-20 的去重短路造成（NET-20 已归档，本卡不改动它）

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

- [x] **[E2]** daemon 单测：`offer` 命中 `has_durable_copy` 时返回
      `state=="completed"` 且 `receipt` 非空；未命中时返回
      `state=="active"`、`task_running==true`
- [~] **[E2]** daemon 单测：`complete_flow_grant` 输给并发 cancel 时，
      `offer` 不返回 completed、不伪造 receipt
- [x] **[E2]** Android 单测（源码合同式，理由见实施记录）：`offer` 应答为 completed 时，交付流程不进
      等待循环直接落 receipt
- [x] **[E2]** 反证：把 completed 分支的 receipt 摘掉（退回恒 null），
      上述用例必须变红
- [x] **[E1]** `just ci` 全绿（含 proto 快照重新生成后的 roundtrip）
- [x] **[E3]** 真机计时：同一批照片连发两次，第二次每张**毫秒级**完成，
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

无前置。从 [NET-23](NET-23-flow-wait-loop-must-not-hang-forever-when-local-signal-never-fires.md)
真机验证中观察到的现象拆出——NET-23 保证了"推送缺失时不会永久卡死"，
本卡负责修"为什么推送会缺失"，两者独立。

## 实施记录（2026-09-17）

**改动五处**（与「范围」一致，无越界）：

1. `flow_delivery.rs` — `offer`/`offer_inner`/`complete_without_fetch` 返回
   `FlowStatusReply`；抽出共用私有 helper `reply_for_grant`，`status()` 改为
   调它（同一份「状态 → 应答」映射，两条路径不可能漂开）。
2. `flow_delivery.rs` — **三个**终态分支全部带回终态，不只 NET-20 那一个：
   NET-22 rebind 分支（它的注释自己记着也踩过同一个 30s 坑）、NET-20 去重
   分支、以及输给并发 cancel 时改为 `reply_for_grant(当前真实行)`——**不伪造
   receipt**。`spawn_fetch_task` 分支回 `active` + `task_running: true`。
3. `router.rs` — `FLOW_OFFER` 的 `.map(|_| None)` 去掉（那一行就是把 daemon
   手里已有的 receipt 扔掉的地方）；三个分支统一产出 `Value`，序列化失败仍走
   原来那条显式 `INTERNAL` 分支，未静默吞。
4. `NativeFlowDeliveryPort.kt` — 接口改 `offer(...): FlowStatusReply`；
   `DaemonFlowReceiptClient.offer` 解析应答，**应答为空即明确报错**（对端
   daemon 早于本卡时不许静默退回推送/超时老路——那正是本卡要消灭的隐形卡顿）。
5. `NativeFlowDeliveryPort.kt` — offer 返回后立刻过 `flowStatusPollOutcome`：
   Completed 直接 `acceptReceipt` 并结束本轮（压根不建订阅、不进等待循环）、
   Cancelled 放弃本轮、KeepPolling 才走原有流程。

### 验收证据

**[E2]** `cargo test -p daemon --test flow_delivery` → **31 passed**
（29 既有 + 2 新）。新增
`offer_reply_carries_the_terminal_receipt_when_content_already_exists`
（并断言 offer 应答里的 receipt_id 与随后 `status()` 报的是同一个——应答不是
为这条路径另造的弱事实）与 `offer_reply_is_active_when_a_real_fetch_must_run`
（异步分支必须仍回 202，`receipt` 必须为 None）。既有 NET-22 用例补两条断言。

**[E2] 反证（真跑，已还原）**：把两个终态分支退回改前形状（应答不带终态）
→ `offer_reply_carries_the_terminal_receipt...` 与
`reoffering_an_already_completed_tuple...` **双双变红**；
`offer_reply_is_active...` 保持绿（正确，该分支未被反证触及）。

**[E2]** Android `NET24OfferReplyTerminalTest` **3 条全绿**。
*为何用源码合同式*：`NativeFlowDeliveryPort.start()` 依赖 ContentResolver /
`Uri.parse` / Blake3 原生库 / 原生 blobs bridge，起一套能跑通它的测试环境的
成本远大于要锁的东西；而要锁的恰恰是一个**顺序不变量**（应答先于订阅被
消费），源码断言直接表达它。本仓已有同款惯例
（`ForegroundSyncNotFrozenTest` / `OneBackupPipelineTest`）。
**反证（真跑，已还原）**：把接线撤回 `desktop.offer(request)`（丢弃返回值）
→ 3 条中 2 条变红（第 1 条只断言接口签名，不受此反证触及）。

**[E1]** `just ci` 全绿；`cargo nextest run --all-features`
**425 passed / 1 skipped**（改动前 423）；Android
**80 类 / 403 tests / 0 failures / 0 errors / 4 skipped**（XML 时间戳为本次
生成；改动前 79 类 / 400）。

**版本**：`0.5.4-test.4` → **`0.5.4-test.5`**，versionCode 25 → 26。

### 实施中追加（范围外但阻塞）

`tools/bump-version.sh` 拒绝执行：`apps/desktop/src-tauri/Cargo.lock
(p-pass-desktop) version drift: 0.5.4-test.3 != 0.5.4-test.4`。核实为既有
漂移——该 lock 最后一次更新停在 `f3f81d8`（test.3），09-16 那次 bump 到
test.4 没带上它（脚本的断言本身是好的，是那次 bump 绕过了它）。用
`cargo metadata` 让 cargo 自己重算而不是手改 lock（手改正是这类漂移的来源），
diff 确认只动两个本地包的版本行、零依赖变动，然后才 bump。

### 留白 / 未做（不装作完成）

- **真机验收未做**——本卡唯一剩余项（E3）：同一批照片连发两次，第二次每张应
  毫秒级完成而非 30 秒/张，需与改动前同场景计时对照。
- **并发 cancel 竞态分支无直接用例**（验收标准第 2 条标 `[~]`）：
  `complete_flow_grant` 返回 false 需要在 upsert 与 complete 之间精确插入一次
  cancel，当前测试设施无注入点，不硬造。该分支委托给 `reply_for_grant`，那条
  路径由 `status()` 的既有用例覆盖；**不宣称它被直接验证过**。
- **非 NET-20 路径的推送丢失仍未查**（原卡剩余两条候选）：真实传输有本地
  iroh 事件兜底，表现为"稍慢"而非"卡 30 秒"，修完本卡后若仍复现再单独开卡。

## 真机验收（2026-09-17，通过）

**环境**：三星 One UI 测试机（设备上读出 `versionName=0.5.4-test.5`、
`versionCode=26`）；macOS 端重建重装后 `lsof` 核实持有生产库
`.ppf/index.sqlite-shm` 的就是新二进制（运行中文件 md5 与新构建一致，
旧包 md5 不同——不靠版本号自证）。

**场景**：测试机重装后重新配对。库里此前已有同一批 11 张照片（上一次
会话由同一台手机的旧身份上传），因此重新发现后这 11 张全部命中 NET-20
内容去重——正是本卡的路径。

**逐项计时**（`adb logcat -v threadtime`，判据取 `Flow epoch preflight`
——它是每次交付尝试在 `desktop.offer` 之前打的唯一一行，相邻两行之差
即单张耗时）：

| 批次 | 张数 | 总耗时 | 每张平均 | 每张最大 | ≥30s 的项 | ≥5s 的项 |
|---|---|---|---|---|---|---|
| 11:22:51 | 11 | 3.30s | 0.330s | 0.396s | **0** | **0** |
| 11:23:22 | 2 | 1.02s | 1.017s | 1.017s | **0** | **0** |
| 11:23:54 | 13 | 3.58s | 0.298s | 0.466s | **0** | **0** |

**去重确实发生了**（不是"传得快"）：库内资产总计 13 条——旧设备身份
11 条（上次会话）、本次新身份 2 条，11:22 之后全库只新增 **2** 条。
即 11:23:54 那批 13 张里 **11 张走的是去重短路、零字节传输**，只有 2 张
是真实传输。

**对照**：同一台设备、同样这 11 张照片，改动前 2026-09-16 实测约 3 分钟
（每张耗满 30 秒本地兜底）。改动后 **3.30 秒**。

**新应答路径确实在跑**（直接证据，非推断）：手机侧对空应答加了硬失败
（`flow.offer: empty reply — peer daemon predates NET-24`）。整段 22351 行
logcat 里该错误 **0 次**，flow 相关报错/异常 **0 次**，`reports cancelled`
**0 次**。若桌面仍是旧 daemon 回 `null`，这道守卫必然报错——它没报，说明
终态确实是从 offer 应答里拿到的。

**遗留**：非去重路径的 `flow.delivered` 推送是否送达仍未验证，已拆
[NET-25](NET-25-flow-delivered-push-unverified-on-the-real-transfer-path.md)
单独跟踪（本卡范围内的洞已闭合：真实传输有本地 iroh 事件兜底，最坏是
"稍慢"，不会再出现 30 秒卡顿）。
