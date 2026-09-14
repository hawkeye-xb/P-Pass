# NET-06 Flow 交付异步化（202 模式）+ 两端账本强制对账——NET-01 根治　级别 L2

> ⬜ 状态：未开工（2026-09-14 验收人拍板「按最正确的方式修，禁止最小能跑通」后开卡）
> 级别：L2 · 阻塞：编码无阻塞；归档需 NET-01 的蜂窝热点/relay 真机窗口

## 问题

`flow.fetch` 把「提交任务」和「等结果」焊死在一次同步 RPC 里：桌面端只有把
blob 拉完、materialize、ingest 全部做完才回执，中间协议上不允许说话。手机侧
唯一的信息来源是「15 秒内听到回声没有」（`DaemonClient` 单次往返闸）。

后果链（NET-01 实证，证据在该卡）：
- relay 路径大文件必然超过 15 秒 → 手机判 `DaemonUnreachableException`，
  而桌面账本（`flow_delivery` 表）此刻写着 active、且数据面拉取可能仍在正常
  进行——**两端各记各的账，从不对账**；
- 手机超时挂断后盲目重试/回队，与仍在持锁干活的桌面互踩；
- 一个超时数字被迫同时服务两个相反目标（快速发现死对端 vs 耐心等大文件），
  任何取值都在错的一方 → 调参摆钟（15s→60s→……）永远到不了对的状态。

iroh 层不是哑巴：endpoint 有连接事件，iroh-blobs 有字节级进度，NET-05 已把
数据面路径（direct/relay）观测接进 fetch。缺的是把这些事实与本卡的状态查询
通道暴露给手机。

## 期望行为

标准答案形态（HTTP 202 + 任务句柄 + 轮询，推送为加速，本仓已有同型范式
`timeline.subscribe`）：

1. **提交 ≠ 等待**：手机 `flow.offer`（登记 grant，秒回）即视为任务已受理；
   桌面端在后台发起交付任务（spawn），终态与错误码写入 `flow_delivery` 账本。
2. **状态是一扇门**：新增 `flow.status` RPC——按 (queue_sequence,
   pairing_epoch[, lease_token]) 查询，返回
   `active（可选 bytes_done）/ completed（含回执）/ cancelled / failed（错误码）/
   not_found`。每次查询都是普通短 RPC，任何网络下都在控制类超时内返回。
3. **手机只认账本，不认回声**：投递流程改为 offer → 盯 status → completed
   走幂等 fetch 领回执。RPC 超时不再推断任务失败——超时后下一轮先查账；
   桌面仍 active 就继续等，**绝不重发 offer 抢锁互踩**。
4. **崩溃恢复**：daemon 重启后 task 消失但 grant 仍 active——status 发现
   「active 且无运行中任务」时重新拉起交付（iroh-blobs 断点续传兜底字节层）。
5. **推送为加速、轮询为兜底**：`timeline.subscribe` 流新增
   `flow.delivered`（完成）/ `flow.failed`（终态错误码）事件；不承诺逐字节
   推送，轮询间隔 5~10s 保证无事件也能收敛。字节进度第一阶段只入 status
   响应（iroh-blobs 进度事件接入 daemon 内存 active entry，NET-05 同法），
   UI 展示另立卡。
6. **兼容**：新手机 + 旧桌面（不认 flow.status）→ 降级走旧同步 fetch，配合
   NET-07 的 fetch 宽限档；旧手机 + 新桌面 → 旧 `flow.fetch` 保留现行为
   （内部改为等 spawn 的任务，返回语义不变）。两个方向都不许静默失败。
7. **新增 `flow.suspend`（暂停专用，验收人裁定 (b) 后加入）**：语义 =
   中断该 tuple 正在进行中的拉取任务（abort task handle），**不改 grant
   状态**（保持 active，GC 保护名单继续护 partial）。与 cancel 共用中断
   机制、落账相反：cancel 标 Cancelled（放弃→partial 随保护失效被 GC 清理）。
   两者都是尽力而为的通知：发送失败不阻塞手机本地状态切换（原则 1）。

## 控制面语义：暂停 / 继续 / 取消当前轮（2026-09-14 验收人裁决定稿）

同步模型把三个概念焊在一条连接寿命上：租约（fetch_lock 在=活是我的）、
执行（连接在=还在传）、意图（超时/挂断≈别干了）。rebuild-05「迟到回执竞态」、
MOB-54「回队无人唤醒」都是这副焊接的毛刺。异步化后三者各归各位：
**意图=改账本，观察=查账本，租约=lease token（已有）**，没有任何控制语义
依赖「这通电话活着吗」推断「这件活什么状态」。

### 设计原则（验收人 2026-09-14 定调，逐条落地）

1. **意图先行，不等回声**：暂停/取消是手机本地立即生效的状态切换 + 一个
   尽力而为的桌面通知；**暂停期间不监控对端状态**（只有继续/取消两条出路，
   观察推迟到真正需要的那一刻）。
2. **暂停 ≠ 取消，账本语义相反**（202 模式下必须区分，否则互相摧毁）：
   - 暂停的中断：任务被打断但 **grant 保持 Active** → GC 保护名单
     （`active_flow_content_hashes()`，daemon 启动时接线，main.rs 现状）
     继续护住 partial → 恢复才能断点续传；
   - 取消：**grant 标 Cancelled** → 保护失效 → partial 被下一轮 GC 自然
     清理（放弃的数据不该占桌面磁盘），无需手机确认。
   两者共享「打断进行中的拉取」这同一个能力，落账动作不同。
3. **观察只发生在需要它的路上**：继续 = 那一刻才查账/重 offer；恢复（崩溃/
   断网醒来）= 先 status 再动作，绝不凭超时重发。

### 操作语义表（协议动词只有 offer/status/claim/cancel/suspend 五个；
### round/暂停/恢复是手机账本概念，daemon 不新增 round 状态）

| 操作 | 手机账本 | 桌面动作 | 字节命运 |
|---|---|---|---|
| **暂停（当场生效）** | 本地立即 PAUSED_BY_USER（现有 StrictConsumer 语义不动），不等桌面回音 | 尽力而为发 `flow.suspend`（新方法，见期望行为⑦）：**中断当前张拉取任务，grant 留 Active** | partial 保留、GC 持续保护 |
| **继续** | 门打开 + wake（现有 continueByUser 行为不动） | 重新 offer 同一 tuple：grant 已 completed → status 指路领幂等回执；active 无任务 → **复用期望行为④的 respawn 机制自动续传** | 从断点续，零浪费 |
| **取消当前轮** | 本地标 CANCELLED_BY_USER_ROUND，下次发现跳过（现有语义不动），不查对端 | 尽力而为 `flow.cancel`：grant 标 Cancelled + 中断任务 | partial 随保护失效被 GC 清理 |
| **崩溃/断网恢复** | 醒来先 status 再决定 | active 无任务→重拉；completed→领回执；cancelled→skipped | iroh-blobs FsStore 天然续传（blobs_resume 测试实证） |

竞态规则统一：**先过 irreversible 边界（complete_flow_grant）者赢，规则
是账本数据不是时序**——cancel/suspend 后迟到的 completed status 收敛为
CONFIRMED（字节没白传，照片确实已备份），不弹 skipped。

### 原「暂停政策 a/b」已裁决

验收人拍板 (b)：暂停=当场掐断，恢复从断点续；不做「下一张才生效」——
「传 1GB 的文件你暂停了它还在跑，暂停就没作用」。实现不再需要双政策开关。

### 唯一真实缺口（另一 agent 2026-09-14 源码核实，其余地基全对）

`fetch_from_observing_path` 是一次阻塞 await、**中途无检查点**：标数据库、
清路径注册表都拦不住正在进行的那一次拉取自然结束才走到 `require_active`。
spawn 化后的修法即本卡既有设计：任务持有 JoinHandle，suspend/cancel 时
abort task → future drop 释放数据面连接 → iroh-blobs 停止字节流，partial
留在 FsStore。地基核查结论（实施 agent 不必复查）：GC 保护名单机制 ✅、
FsStore partial 续传 ✅（跨重启有 blobs_resume 集成测试）、cancel 登记+
拒绝新拉取 ✅——**只差这最后一个中断入口**。

### 三条实施前必读补丁（2026-09-14 第三轮 review，源码核实，非空想）

1. **任务追踪表的清理必须走 `Drop`，不能是顺序代码**：`abort()` 会在
   *任意*一个 await 点把 future 直接砍断，不会跑完"往下一行"的收尾代码。
   同文件已有的 `FlowPathGuard`（`flow_delivery.rs:154-191`）就是为同一个
   问题设的——照抄它的模式：新增的任务句柄登记表必须由一个 Drop 守卫负责
   摘除自己的登记项，不能指望 `complete_flow_grant` 成功之后"再往下走一行
   代码去清理"。反证窗口：abort 恰好砸在 `complete_flow_grant` 写完、清理
   代码还没跑到之间——这个窗口 Drop 守卫必须仍然正确摘除登记（哪怕账本已经
   是 Completed），顺序代码写法做不到。
2. **取消当前轮批量处理 N 项，只有曾经拿到过真实 grant 的那一项才需要真的
   发 `flow.cancel`**：`CancellationRoundController.startPausedRound()`
   批量标记的是 `QUEUED`/`FAILED_NEEDS_USER` 两类项，但按 ARCH-03 严格
   单头语义，同一时刻 daemon 只对**当前头**发过 offer；轮里其余排队项从未
   跟 daemon 打过交道，daemon 侧查无此 grant。不需要新状态字段：现有
   `deliveryState` 已隐含这个事实（`FAILED_NEEDS_USER` 或"当前被打断退回
   QUEUED 的那一项"才可能有真实 grant，纯 `QUEUED` 且未曾失败过的项没有）。
   按这个已有信号决定发不发 `flow.cancel`，没有真实 grant 的项直接跳过
   网络调用，不必对空 grant 也发一次再吞掉 `GuardMismatch`。
3. **新增的任务中断表键值范围必须照抄 `FlowPathRegistry`（设备身份 +
   queue_sequence + lease_token 三者一起校验），不能只按 `content_hash`
   键**：GC 保护名单按哈希键是对的（它问"这份内容该不该留"，与谁在传无关，
   多台设备传同一张照片时任一台在传都要保留）；但任务中断问的是"该打断
   哪台设备的哪一次具体传输"，`content_hash` 不是 grant 表的唯一键
   （主键是设备身份 + pairing_epoch + queue_sequence），三台设备完全可能
   各自独立持有同一哈希的 grant（各自备份同一张照片/截图）。若中断表图省事
   只按哈希查，A 设备 suspend 会误杀 B/C 设备正在进行的独立传输。去重只
   发生在 `complete_flow_grant` 那个终态边界之后，过程中即便哈希已知也
   仍是独立的传输，必须按设备+序号+租约精确定位，不能借用去重用的哈希键。

## 验收标准（主案）

- [ ] RED 先行（daemon 集成 scenario）：注入「数据面拉取耗时 > 控制类超时」
      的延迟 → 手机状态机（JVM 侧用假 DeliveryPort 对等场景）必须经 status
      轮询走到 CONFIRMED、拿到幂等回执；改前该场景必须真红。
- [ ] **suspend 中断用例**：数据面拉取进行中发 `flow.suspend` → 断言拉取任务
      在 <2s 内真停（字节计数不再增长，反证 await 无检查点的旧形状）、
      grant 仍 Active、GC 一轮后 partial 仍在盘上；改前必须真红。
- [ ] **suspend→继续用例**：suspend 后重新 offer → 断言从保留 partial 续传
      （对齐 blobs_resume 断言手法）、最终同一 content_hash 完成、零从头重传。
- [ ] **cancel 清理用例**：cancel 后 grant=Cancelled → 越过 GC 保护名单 →
      partial 被清理（明确断言与 suspend 的相反落账，防两路混用）。
- [ ] **迟到边界竞态用例**：materialize 前后各发一次 cancel/suspend → 两方向
      终态都确定：先过 complete_flow_grant 者赢，item 终 CONFIRMED 收回执，
      不许靠 sleep 运气。
- [ ] **暂停不观察用例**（JVM）：暂停路径断言零 status/网络查询调用（原则 1
      反证：谁把"等桌面确认停了"做进暂停，此用例变红）。
- [ ] **abort 竞态用 Drop 守卫用例**：注入 abort 恰好砸在
      `complete_flow_grant` 成功之后、清理代码前的窗口 → 断言任务追踪表
      仍被正确摘除登记（不留僵尸项）；改成非 Drop 的顺序清理写法必须让此
      用例变红。
- [ ] **取消当前轮不打无谓 grant 查询用例**：批量取消 N 项（仅 1 项曾有
      真实 grant）→ 断言只对那 1 项发出 `flow.cancel`，其余项零网络调用、
      零 `GuardMismatch` 噪音。
- [ ] **跨设备同哈希隔离用例**：两台不同设备各自持有同一 `content_hash`
      的独立 grant（各自备份同一张照片）→ 一台 suspend/cancel → 断言另一台
      的传输任务与 grant 状态不受影响（反证：任务中断表若只按 content_hash
      键，此用例必须变红）。
- [ ] 反证：移除 status 查询分支/恢复同步等待形状 → 新用例必须变红。
- [ ] 幂等：completed 后重复 status/fetch 返回同一 receipt_id，零重传
      （daemon 集成测试，复用 `persisted_receipt` 既有语义）。
- [ ] 崩溃恢复：active grant + 无运行任务 → status 触发重拉，最终 completed
      （daemon 集成测试模拟 task 丢失）。
- [ ] 重试不互踩：手机侧超时后先 status 见 active → 不重发 offer（JVM 测试
      断言 offer 调用次数）。
- [ ] 旧 fetch 行为兼容：旧手机形状的用例（直接同步 fetch 拿回执）在新桌面
      仍绿。
- [ ] Android JVM 全量（报测试计数）+ `just ci` 全绿；proto 金样本演进不破
      （旧帧字节不变，同 DEV-01 device_hint 的纪律）。
- [ ] L3 真机硬门（NET-01 窗口，等验收人）：三星热点 288MB 视频跨 relay 完整
      CONFIRMED；LAN 直连回归不破；拔网线中途 → status 报 failed 带码 →
      自动重试最终完成或终态可见（不许哑火）。

## 范围

- 只准动：`crates/proto/src/msgs.rs`（新方法/类型，serde default 演进）、
  `crates/daemon/src/flow_delivery.rs`（spawn 任务、status、suspend/cancel
  共享的中断句柄、active-entry 进度、崩溃重拉）、`crates/daemon/src/router.rs` + `authz.rs`（新方法的
  分发与门禁，照 FLOW_* 现有条目）、`crates/transport`（blobs 进度事件按
  NET-05 口径暴露为非 iroh 类型）、`apps/android/.../transport/DaemonClient.kt`
  （subscribe 事件类型）、`apps/android/.../backup/flow/`（投递状态机 +
  对应 JVM 测试）、daemon 集成测试、卡片/队列文档。
- 不准动：`StrictConsumer` 重试计数/终态判定语义（ARCH-03 锁定）、
  `flow_delivery` 表 schema（够用；确需迁移先在卡内论证）、iroh 本体与
  relay 策略、NET-05 的 path 观测语义、UI 层（进度展示另立卡）、
  legacy 批量 manifest/push/commit 管线。

## 阻塞与依赖

- 编码无前置阻塞。与 NET-07（止血过渡）并行：NET-07 先合可立刻减症，
  NET-06 合入后按 NET-07 卡内约定评估 fetch 宽限档是否保留（兼容旧桌面
  的降级路径仍需它，大概率保留为降级档而非主路径）。
- 归档阻塞：蜂窝热点/relay 真机窗口（同 NET-01）。

---

## 方案对比（为何是这个形状）

- **轮询 + 事件推送（本卡）**：抄的标准答案 = HTTP 202 + 任务资源；本仓同型
  先例 = timeline.subscribe 推 `timeline.invalidated` + 兜底对账。账本
  （grant/receipt/epoch 幂等）当年建对了，只缺查询门。
- **服务端完成回调（被否）**：需要桌面反向主动拨手机、手机保活可寻址，成本
  远高于「翻现成账本」，且手机在 NAT/后台限制下不可靠（MOB-52/75 一族教训）。
  证伪条件：若真机证明轮询+事件仍有分钟级不收敛，再重评。
- **纯加长超时（被否）**：即摆钟本身，见「问题」第 3 条；已由 AGENTS.md
  设计纪律第 1 条禁止作为终态。

## 备注

- 「传到了」≠「收到了」：字节进度归 iroh-blobs 事件（第一阶段只入 status），
  逻辑终态归 `flow_delivery` 账本——单一真相源是桌面，手机账本向它对齐。
- 本卡合入后：NET-01 的证据链（复现步骤、判决实验）保留作为回归主案；
  MOB-54 的 wake 对称补丁仍是有效防御（双保险），真机复核改在本卡的
  回归轮里一起跑。
- 进度展示的 UI 卡（hero 显示「第 N 张 · x% · 直连/中继」）待本卡 status
  字段稳定后另开。
