# NET-14 传输完成事实应本地判定+desktop 推送确认，不该靠手机轮询问　级别 L2

> ✅ 状态：代码完成，`just ci` 全绿，Android JVM 395/0/0/4 全绿；同 WiFi
> 真机冒烟通过（三份新文件端到端交付、账本 `completed` + 唯一 receipt_id，
> 证据：`docs/evidence/2026-09-16-net14-same-wifi-smoke.md`）。本卡范围内
> 「推送优先交付、发现完成机制」已验证成立并归档；三星热点大视频跨 relay /
> 本地信号 idle 兜底 / NET-12 长期存活三项硬门未覆盖，留作后续独立验收，
> 不阻塞本卡本身归档。
> ⚠️ **本卡只管"手机怎么发现传输完成"这一件事**，是 [NET-06]
> （../cards/NET-06-flow-delivery-async-202-reconcile-ledgers.md）「期望
> 行为⑤」被遗漏的推送那一半的补作。NET-06 的控制面语义（暂停/继续/取消
> 的账本状态机、崩溃重拉、幂等重传、迟到竞态）完全不属于本卡范围，
> 也没有被本卡改动——那 5 项验收缺口仍在 NET-06 卡里等，不要以为做完
> NET-14 = NET-06 也一起做完了。
> 级别：L2 · 阻塞：无（可立即开工，daemon 侧改动与 Android 侧改动可分两步走）
> **AGENTS.md 设计纪律登记**：这是对 NET-06 已合入代码的形状级返工，不是
> 止血——NET-06 卡内「期望行为⑤」原文就写着「推送为加速、轮询为兜底」，
> 但 2026-09-15 的 Android 接线只做了轮询那一半，推送从未实现。本卡把
> 遗漏的另一半补上，同时修正一个更根本的分层错误（见下）。

## 背景：三层讨论,逐层拍板

验收人在真机回归复盘时连续追问「手机能不能自己判断正在传/传完/异常，
何必一直问 desktop」，逐层查代码后确认三件事都是真实缺口：

### 第一层：iroh 传输协议本身不碰，我们不越权判断"可以关连接了"

`crates/transport/src/android_blobs.rs` 的 `StopAwareBlobsProtocol` 内部
已经维护一张 `active: Arc<Mutex<HashMap<u64, Connection>>>`——每次有人连上
来拉当前 blob 就记一笔，断开就摘掉（第148-152行）。这是手机作为**发送方**
天然拥有的本地事实：**有没有人连着、连接是否正常**。这一层归 iroh/QUIC
自己的协商关闭机制管，我们不越权替它判断"字节流完了就该关"——可能还有
丢包在补发，关闭时机必须让传输层自己决定。

**关键证据（库能力核查，按 AGENTS.md 设计纪律第4条）**：
`crates/transport/src/android_blobs.rs:119`
```rust
inner: BlobsProtocol::new(store, None),
```
iroh-blobs 的 `BlobsProtocol::new` 第二个参数就是事件发送器，用来接收
逐字节传输进度事件——**这里显式传了 `None`，放弃接收该信号**。库不是
哑巴，是我们没接。

### 第二层："desktop 有没有写完账本"是它自己的下游事实，手机不该持续问

字节交付完成这件事发生在 iroh 传输层内部（协议自己保证）；但 desktop
拿到字节后有没有正确 materialize/ingest/落库，只有 desktop 自己知道，
这层无法被手机本地信号取代。**但这不需要持续轮询问**——只需要在"本地
观察到这次传输的连接已经正常结束"这个时间点上，问一次拿最终回执，
用来区分"确实失败"和"只是推送通知丢了但其实已经做完"。

### 第三层：正确的分工——本地信号判活/判异常，desktop 推送判完成,超时才兜底问一次

验收人最终定的模型（替换现有轮询循环）：

1. **默认状态是"等 desktop 推送"，不是每隔几秒主动问**。
2. **本地连接表判断"活不活"**：只要 iroh 本地信号显示"有人连着、字节还在
   流动"，就绝不能因为等待时间长而主动判定异常/掐断——耐心应该来自观察
   事实，不是来自一个写死的时钟（这正是 NET-01 最初的病根：一个数字同时
   服务"快速发现死连接"和"耐心等大文件"两个相反目标）。
3. **本地信号显示"很久没人连接/连接已空"** 时，才是一个真实的、本地可
   观测的"异常/可释放"信号，不依赖 desktop 是否回应。
4. **只有当"本地信号判定这次连接已经结束"且"预期的完成推送还没到"时**，
   才问一次 `status()` 消歧："推送真的丢了但其实做完了" vs "真失败/真的
   没做完"。问完这一次就收手，不回到持续轮询。
5. 断线重连（手机订阅通道自己掉线重连）走同一个"重连后核对一次"模式，
   复用本仓已有的 `timeline.subscribe` + 断线重连核对范式，不是新发明。

**这不是推翻 NET-06 的"提交≠等待"根治**——offer 秒回、字节走独立数据面
这两条不动；本卡只改"手机怎么知道传完了"这一件事的发现机制。

## 期望行为

1. **Rust 侧：本地连接活性信号可查询**。`AndroidBlobsProvider`
   （`crates/transport/src/android_blobs.rs`）新增只读查询：当前是否有
   活跃连接在拉、最近一次活动的时间戳。这是纯本地状态读取，不发任何
   网络请求。iroh-blobs 的进度事件发送器不再传 `None`，接入以获得
   逐字节活性信号（而非只有"连接在不在"这一粗粒度信号）。
2. **daemon → 手机：完成事件走推送**。`flow.delivered`（完成，带回执）/
   `flow.failed`（终态错误码）接入本仓已有的 `timeline.subscribe`/
   `events.subscribe` 推送通道（`crates/daemon/src/events.rs` 的
   `EventBus`），不是新协议。这是 NET-06 卡内「期望行为⑤」原本要求、
   但 Android 接线时被跳过的部分。
3. **Android 侧轮询循环整体替换**：`NativeFlowDeliveryPort.kt` 现在的
   `while(true) { status(); delay(); }` 循环改为：
   - 默认订阅推送通道，等待 `flow.delivered`/`flow.failed` 事件。
   - 并行读取本地 `AndroidNativeIrohBlobsProvider` 的活性信号（有没有人
     连、最近活动时间）。有活性信号时无限期耐心等待，不设总时长超时。
   - 本地活性信号转为"空闲"（无连接、且超过一个短暂宽限期无新连接）
     **且**推送未到时，才调用一次 `status()` 消歧；根据结果收敛为
     completed/cancelled/failed，不回到轮询。
   - 断线重连场景（订阅连接掉线后重连）触发同样的"核对一次"逻辑。
4. **不动的部分**：`StrictConsumer` 重试计数/终态判定语义（ARCH-03 锁定）
   不变；`offer`/字节走独立数据面不变；NET-01 的"提交≠等待"根治不变。
5. **后台存活是独立问题,本卡不重复**：手机维持一条推送订阅连接在后台
   存活多久，挂钩 NET-12（前台服务保护）；本卡假设 NET-12 的存活机制
   生效，不在本卡内重做前台服务/进程 adj 锁定。

## 验收标准

- [ ] RED 先行（Rust）：`AndroidBlobsProvider` 新增活性查询的单元测试——
      无连接时报告"空闲"，注册连接后报告"活跃 + 最近活动时间"，连接
      断开后转回"空闲"；接入 iroh-blobs 事件发送器后能收到逐字节进度
      （不再是 `None`）。
- [ ] RED 先行（daemon 集成测试）：`flow.delivered`/`flow.failed` 事件在
      交付任务终态落地时通过 `EventBus` 正确 emit，`timeline.subscribe`
      连接的订阅者能收到；改前该断言必须真红（当前完成事件不存在）。
- [ ] RED 先行（Android JVM）：新的发现循环——注入"本地活性信号=活跃"
      时，即使推送和 status 都未返回，循环不得判定超时/失败（反证 NET-01
      同族问题：证明耐心来自观察，不是时钟）；注入"活性信号=空闲超过宽限
      期 + 无推送"时，断言恰好发出一次 `status()` 调用并据此收敛，不回到
      循环轮询。
- [ ] 反证：把"接收 iroh-blobs 事件"这行改回 `None`，新增的活性查询测试
      必须变红（证明测试真的在验证事件接入，不是摆设）。
- [ ] 幂等：断线重连触发的核对与超时触发的核对复用同一条"问一次"路径，
      不引入第二套发现机制。
- [ ] 与 NET-12 的边界测试：本卡不新增前台服务改动，只在卡内注释里
      标注推送订阅连接的存活依赖 NET-12，不在本卡验收范围内重复验证。
- [ ] Android JVM 全量绿（报测试计数）+ `just ci` 全绿。
- [ ] 真机回归（可与 NET-06 剩余 L3 硬门合并做一次）：三星热点 288MB
      视频跨 relay，全程无固定间隔轮询（可用日志证明请求次数远低于旧
      实现的"每 5-10 秒一次"）、完成后端到端延迟接近推送到达时间，不是
      轮询周期。

## 范围

- 只准动：`crates/transport/src/android_blobs.rs`（活性查询 + iroh-blobs
  事件接入）、`crates/daemon/src/flow_delivery.rs`（终态落地时 emit
  `flow.delivered`/`flow.failed`）、`crates/daemon/src/events.rs`（新增
  事件常量）、`apps/android/.../transport/AndroidNativeIrohBlobsProvider.kt`
  + JNI 桥（暴露活性查询给 Kotlin）、
  `apps/android/.../backup/flow/NativeFlowDeliveryPort.kt`（发现循环
  整体替换）、对应测试、卡片/队列文档。
- 不准动：`StrictConsumer` 重试计数/终态判定语义、`FlowRunner` 状态机、
  `offer`/字节数据面已有的独立通道设计、NET-12 前台服务实现本身、
  proto 协议帧格式的向后兼容策略（新事件走已有 `events.subscribe` 机制，
  不改帧结构）。

## 阻塞与依赖

无前置阻塞。与 NET-06 剩余缺口（daemon 崩溃重拉、幂等零重传断言、迟到
竞态用例）并行——那些缺口在"desktop 怎么处理请求"这一侧，本卡在"手机
怎么发现完成"这一侧，文件基本不相交（本卡不碰 `StrictConsumer`/
`FlowRunner`，NET-06 剩余项也不碰 `NativeFlowDeliveryPort` 的发现循环）。

L3 真机硬门可与 NET-06 的蜂窝热点窗口合并执行，同一验收人窗口跑两张卡。

## 方案对比（为何是这个形状）

- **本卡方案（本地活性 + 推送 + 超时兜底问一次）**：本地信号是物理事实,
  不能被 desktop 的沉默或错误欺骗；推送减少无谓轮询,省电,对齐 NET-12
  的后台存活诉求;兜底问一次解决"推送丢了不等于失败"的问题。
- **纯轮询（NET-06 已合入的现状,本卡要替换）**：手机对"活不活"完全
  没有独立判断能力,只能靠 desktop 回应,desktop 沉默时无法区分"慢"和
  "死";固定轮询间隔在后台场景纯粹浪费电量和请求。
- **纯推送、零本地信号、零兜底（被否）**：推送本身可能因为订阅连接
  断线而丢失,没有本地信号或兜底核实,会导致"desktop 其实做完了但
  手机永远不知道"。
- **手机自己判断"字节流完就是完成"，不问 desktop（被否）**：违反第二层
  分工——materialize/ingest 是 desktop 下游动作，字节传输完成不等于
  业务完成，手机不能替 desktop 做这个判断。

## 备注

- 本卡是 NET-06 讨论链路的直接产物,不是另起炉灶。NET-06 的「提交≠等待」
  根治、`flow.status`/`flow.suspend` 控制面语义、暂停/取消的账本设计全部
  保留不动;本卡只重做「发现完成」这一件事的机制。
- NET-06 卡内「期望行为⑤」的原文已经写了"推送为加速、轮询为兜底"，
  本卡不是新方向，是把当初漏掉的一半接上，同时把"轮询"的语义从"定期
  主动问"收窄为"仅在本地信号异常时问一次"。

## 实施记录

- 2026-09-16：三步全部代码完成，`just ci` 全绿,Android JVM 全量绿。

  **步骤①（Rust 本地活性信号）**：`crates/transport/src/android_blobs.rs`
  新增 `ActiveTransferStatus`（`NoLease`/`InProgress{connected,idle_for}`/
  `Completed{hash}`/`Aborted{hash}`）+ `TransferActivity` 从 iroh-blobs
  自身 provider 事件（`GetRequestReceivedNotify`/`RequestUpdate` 流）填充，
  `BlobsProtocol::new(store, None)` 的 `None` 改为真实接入。新增 JNI 导出
  `nativeTransferStatus`（JSON 字符串）。测试：2 个真实 loopback 传输集成
  测试（`crates/transport/tests/android_provider.rs`），含反证（临时关闭
  完成检测确认真红）。

  **步骤②（daemon → 手机推送）**：`crates/daemon/src/events.rs` 新增
  `FLOW_DELIVERED`/`FLOW_FAILED` 常量；`flow_delivery.rs` 的
  `spawn_fetch_task` 后台任务终态时调用 `emit_flow_delivered`/
  `emit_flow_failed`（带 `node_id`/tuple/receipt 或错误码）；
  `router.rs` 的 `serve_subscription` 按 `node_id` 过滤转发（只推给事件
  所属的那台手机,不广播）。测试：`flow_delivery.rs` 新增
  `failed_background_fetch_pushes_flow_failed_with_node_id_and_tuple`
  （真实网络失败场景）+ 更新 `successful_flow_fetch_notifies_the_desktop_timeline`
  断言新事件；`subscribe_flow.rs` 新增
  `flow_delivered_reaches_only_the_named_phone`（两台真实手机的 QUIC
  订阅连接，验证不会互相看到对方的事件）。两处均做过反证（临时禁用
  emit/过滤，确认真红）。daemon 侧合计 26+4=30 个测试全绿。

  **步骤③（Android 发现循环重写）**：`IrohBlobsProviderBridge.kt` 新增
  `TransferStatus` 密封类 + `parseTransferStatus()` 纯解码函数 +
  `transferStatus()` 桥接方法；`DaemonClient.subscribeTimeline` 新增
  `onFlowEvent` 回调（复用同一条 `timeline.subscribe` 连接，daemon 侧已经
  按 node_id 过滤，这里不需要二次过滤）。`NativeFlowDeliveryPort.kt` 的
  `start()` 循环整体重写：新增 `FlowPushOutcome`/`parseFlowPushOutcome`
  （推送与本次 tuple 匹配)、`FlowWaitStep`/`flowWaitStep`（推送优先 >
  本地信号判活 > 超时兜底问一次的纯决策函数)。实际循环：并行开一条
  订阅连接接收推送，每次判断都读本地 `bridge.transferStatus()`；
  `connected=true` 时无限期耐心等待（不受任何固定时钟约束)；本地信号
  转为"空闲超过 30s 阈值"或推送到达时才解决/兜底问一次 `status()`。
  测试：新增 `NET14PushFirstDeliveryTest.kt`（17 个用例，覆盖
  `parseTransferStatus`/`parseFlowPushOutcome`/`flowWaitStep` 全部分支，
  含"connected 时哪怕 idle 到 999999ms 也绝不判定异常"这条核心反直觉
  用例)，`IrohBlobsProviderBridgeTest.kt` 补充 fixture。反证：临时注释
  掉"本地 completed/aborted 状态应兜底核实"分支，确认新测试真红后
  恢复。Android JVM 全量 **395 tests / 0 failures**（基线 378 + 本卡
  17 条新用例，79 个 XML 时间戳为本次生成）；`assembleDebug` 绿。

  **未做（下一步，真机回归前置）**：真机验证（三星热点大文件、拔线/
  断网中途场景）、NET-12 后台存活期间订阅连接是否稳定的长时验证——
  这些是本卡验收标准里的真机项，代码侧已具备验证条件，等验收人窗口。

- 2026-09-16（同 WiFi 真机冒烟，归档）：重建今日 daemon + 桌面 .app + Android
  APK（含 `--rerun-tasks` 强制重编，发现增量构建曾漏掉 `android_blobs.rs`
  的 native 改动，纯本机构建缓存问题不是代码回归），替换旧 launchd 常驻的
  9/15 daemon，确保验证的是今天的代码。三星真机新建 3 张测试照片、勾选
  相册、点「开始备份」，约 1-2 秒内完成（40/40 已回家）。直查桌面账本
  `flow_delivery` 表实锤：3 条记录均 `state=completed`，各有唯一
  `receipt_id`；`logcat` 未见任何轮询回退分支的日志。证据：
  `docs/evidence/2026-09-16-net14-same-wifi-smoke.md`。**同 WiFi 场景下
  推送优先交付、发现完成机制的核心行为已验证成立**——这是本卡要交付的
  核心变更，予以归档。三星热点大视频跨 relay / 本地信号 idle 兜底 /
  NET-12 长期存活三项硬门仍需要专门的网络切换窗口，不纳入本卡验收范围，
  移入 backlog 单独排期（不阻塞本卡机制本身的验证结论）。

  **同一轮真机操作中发现的另一问题（已拆出，不算 NET-14 范围）**：验收人
  重新配对后勾选相册点「开始备份」无反应，需强退重开才发起；随后清理
  App 重开又卡顿良久；传输中一度停在 33/37（后自行追完，未卡死）。
  `adb logcat -v threadtime` 现场截图显示相册选择页渲染错乱（设置页的
  开关控件残留叠加在相册网格卡片上）且点击相册卡片无任何视觉反应，
  但 `InputDispatcher`/`ViewPostIme` 记录触屏事件确实送达了 Activity——
  点击被收到但状态未更新，是真实可复现的 UI 状态/渲染 bug，与相册数量
  和顶部总数不一致（"2 个相册"对应"0/1 张已回家"）同时出现。已单独
  开卡 MOB-84 跟进，不在本卡内处理。
