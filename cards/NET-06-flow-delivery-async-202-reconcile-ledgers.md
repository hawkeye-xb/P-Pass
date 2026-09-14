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

## 控制面语义：暂停 / 继续 / 取消当前轮（2026-09-14 外部 review 指出缺口后补全）

同步模型把三个概念焊在一条连接寿命上：租约（fetch_lock 在=活是我的）、
执行（连接在=还在传）、意图（超时/挂断≈别干了）。rebuild-05「迟到回执竞态」、
MOB-54「回队无人唤醒」都是这副焊接的毛刺。异步化后三者必须各归各位：
**意图=改账本（围栏/状态），观察=查状态，租约=lease token（已有）**，
没有任何控制语义再依赖「这通电话活着吗」来推断「这件活什么状态」。

四动词语义表（协议只有这四个动词，round/暂停/恢复全是手机侧账本概念，
daemon 不新增 round 状态）：

| 操作 | 语义 |
|---|---|
| 暂停 | 手机停止签发新 offer。当前张政策**待验收人拍板**：(a) drain——让本张跑完拿回执；(b) abort——对当前张发 cancel，字节由 iroh-blobs 保留（T-021 resume 测试实证续传可用），恢复时从断点续。实现按 (b) 做（含 cancel handle），政策若要 (a) 只是不调用 handle。 |
| 继续 | 无新协议：重新 offer 同一 tuple。桌面已 completed → status 直接指路领幂等回执（字节没浪费，照片已算备份成功）；未 completed → 数据面续传。 |
| 取消当前轮 | 手机停发 + 对当前张 cancel + 其余本地标记 skipped。**竞态规则先定死：先过 irreversible 边界（complete_flow_grant）者赢**——已 completed 的算 CONFIRMED 收进回执，不许事后改 skipped；cancel 先赢的 materialize 被 require_active 拒绝、零入库。规则必须是数据（账本状态），不许是时序（rebuild-05 竞态在异步模型里无生存空间）。 |
| 崩溃/断网恢复 | 醒来先 status 再决定动作：active 且无运行任务→桌面重拉（本卡期望行为④）；completed→领回执；cancelled→按 skipped。手机任何状态下不凭超时重发 offer（NET-01 病根）。 |

随之必须实做的两件（原方案缺的）：
- **cancel 真中断**：`fetch_inner` 现状只在 materialize 边界检查 cancelled，
  字节流本身不掐。spawn 化后任务须持有 iroh-blobs 下载的中断句柄（abort
  tokio task + 释放数据面），否则「暂停=drain」是唯一选项、政策菜单( b )
  名存实亡。
- **status 词表补全**：`active(+bytes_done)/completed(receipt)/cancelled/
  failed(错误码)/not_found`——failed 码复用 `DeliveryError::telemetry_code`
  词表，禁止裸字符串。

## 验收标准（控制面增补，接上表编号执行）

- [ ] 竞态用例：item 数据面拉取中途发 cancel → 断言 cancelled 且不 materialize；
      改「先 materialize 再 cancel」顺序 → 断言回执已定、item 终 CONFIRMED
      （两个方向都必须确定，不许靠 sleep 运气）。
- [ ] 暂停-续传用例（政策 b）：abort 后重新 offer → 断言 daemon 侧字节从
      保留 partial 续传（对齐 T-021 断言手法）、最终同一 content_hash 完成。
- [ ] 暂停-恢复免传用例：abort 前桌面其实已 completed → 重新 offer 后 status
      指路、claim 直接拿回执、零重传。
- [ ] 取消轮+迟到回执：JVM 侧断言手机账本对「cancel 后到达的 completed
      status」收敛为 CONFIRMED（规则=先过边界者赢），不弹 skipped。

## 验收标准（主案）

- [ ] RED 先行（daemon 集成 scenario）：注入「数据面拉取耗时 > 控制类超时」
      的延迟 → 手机状态机（JVM 侧用假 DeliveryPort 对等场景）必须经 status
      轮询走到 CONFIRMED、拿到幂等回执；改前该场景必须真红。
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
  `crates/daemon/src/flow_delivery.rs`（spawn 任务、status、active-entry
  进度、崩溃重拉、cancel 持中断句柄真断字节流）、`crates/daemon/src/router.rs` + `authz.rs`（新方法的
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
