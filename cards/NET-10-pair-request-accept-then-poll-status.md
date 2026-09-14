# NET-10 配对流程拆「提交 ≠ 等人」：pair.request 受理即回，等待走查询（NET-06 形状推广到配对）　级别 L2

> ⬜ 状态：未开工（2026-09-14 NET-08 普查产出，焊点 P1）
> 级别：L2 · 阻塞：**等 NET-06 的 status 范式合入**（复用其查询门形状与
> 兼容降级策略，避免两套异步协议各长各的）
> **AGENTS.md 设计纪律登记：本卡即终态方案；无需另开根治卡。**

## 问题

NET-08 普查（焊点 P1）：配对是 fetch 病的「人类版」——把「提交配对
请求」和「等主人点 Allow」焊死在一次同步 RPC 里：

- 手机 `apps/android/.../transport/PairFlow.kt:105`：`pair.request` 包在
  `withTimeout(waitMs=120_000)` 里硬等。超时后 `DaemonUnreachableException`
  与「主人点了 Deny」「主人根本没看手机」「网络断了」共用一个出口
  （`:134` catch-all → `PairOutcome.Failed`），用户拿到一锅烩的失败。
- 桌面 `crates/daemon/src/pairing.rs:249`：`decision_rx.await` 把这条
  iroh bi 流**无限期**挂住等人类——主人 10 分钟不看，流就吊着 10 分钟；
  三个时限各管各且互相矛盾：客户端 120s、daemon 无界、配对 token 600s
  （`pairing.rs:22 TOKEN_TTL_MS`）。
- 桌面明明**有账本**：pairing.pending IPC 队列（`ipc.rs:615`）记着每个
  待确认请求，手机从不翻它，只猜回声——W2 回声即状态。
- 后果与 NET-01 同族：超时后手机重扫 → `pair.request` 重发 → 桌面 pending
  队列里堆同一台手机的多个条目（未见去重逻辑，实施时核实），主人在桌面
  看到 N 个「张三的 iPhone」不知道点哪个——W3 超时即重发的对偶。

## 期望行为

照抄 NET-06 定稿的形状（提交 ≠ 等待、状态是一扇门、手机只认账本）：

1. `pair.request` 改为**受理即回**：token 校验通过、进入 pending 队列就返回
   `{ accepted: true, request_id }`（秒级 RPC，走 NET-07 控制档超时）。
   token 无效/已用 → 现在就回明确拒绝码，不再混在 120s 超时里。
2. 手机盯**待确认状态**直到出结果：轮询 `pair.status(request_id)`（新方法，
   返回 pending / accepted(含 Hello 载荷) / denied(理由码) / expired /
   not_found）——间隔 5s，上限对齐 token TTL（600s，单一来源）。
   加速通道（可选、非正确性依赖）：daemon 在 accepted/denied 时把事件推给
   该手机这条订阅流；无事件纯轮询也必须收敛。
3. accepted 的结果在 daemon 账本里活过 RPC：手机查 status 时若该 request
   已被批准，直接补发 PairAccepted 载荷（幂等重放），断网重扫窗口内
   不需要主人二次点击。
4. 崩溃语义：daemon 重启 → pending 队列消失 → status 返回 not_found →
   手机明确提示「电脑端服务重启了，请重新生成配对码」，不盲重发。
5. 兼容：新手机 + 旧桌面（不认 pair.status）→ 降级走旧同步 pair.request
   长等待（NET-07 fetch 宽限档同法给 pair 档一个过渡宽限，注释写明是
   降级档）；旧手机 + 新桌面 → 旧 `pair.request` 保留现行为（内部改为
   等 spawn 的确认任务，返回语义不变）。两向不许静默失败。

## 验收标准

- [ ] RED 先行（daemon 集成）：注入「主人 20s 后才点 Allow」→ 新形状手机
      状态机必须经 status 轮询走到 accepted；改前（同步等待撞控制档超时）
      真红。
- [ ] 反证：去掉 status 查询分支恢复同步等待 → 用例变红。
- [ ] 幂等：accepted 后重复 status 返回同一载荷；重发 pair.request 同
      (token, pair_epoch) 不堆重复 pending 条目（断言队列长度）。
- [ ] 死因四分可测：denied（即时拒绝码）/ expired / not_found（重启）/
      网络失败（status RPC 自身超时）在 JVM 测试各自独立分支。
- [ ] 桌面 UI 走查：主人侧「待确认」列表与新账本一致，同一手机重发只
      出现一条。
- [ ] Android JVM 全量（报计数）+ `just ci` 全绿；proto 金样本演进不破。
- [ ] 真机：扫码→主人隔 1 分钟再点→手机自动进首页，全程无「失败」闪烁。

## 范围

- 只准动：`crates/proto/src/msgs.rs`（pair.status 方法/类型，serde default
  演进）、`crates/daemon/src/pairing.rs`（受理即回 + 结果账本化 + status）、
  `crates/daemon/src/router.rs` + `authz.rs`（新方法分发门禁，未配对设备
  即可查自己的 request_id——authz 白名单口径写进卡内实施记录）、
  `apps/android/.../transport/PairFlow.kt` + 对应 JVM 测试、daemon 集成
  测试、卡片/队列文档。
- 不准动：flow 交付管线（NET-06 地盘）、token 生成/QR 内容（H-10b 已收口）、
  DEV-01 重装指纹语义、设备行合并逻辑（merge_device）。

## 阻塞与依赖

- 前置：NET-06 合入（status 门的协议形状、兼容降级策略、authz 口径直接
  复用，不开第二套）。编码可先行到 proto 层，集成联调等 NET-06。
- 归档：真机扫码窗口（与 NET-01/06 同一轮即可，不单独占窗口）。

---

## 实施记录

（待补）

## 备注

- 「等人类」比「等大文件」更不能焊在 RPC 里——人类响应时间是分钟级且
  无界，本次普查抓到说明判据（三句话自检：这通电话最长堵多久/谁定的
  上限/上限到了caller 知道任务死活吗）有效。
- 手机超时重扫堆 pending 的具体症状是否已在真机出现过，实施时翻
  NET-03/UX-08 记录与 git log 取证；无先例不影响本卡成立（形状错误
  本身就是修复对象——AGENTS.md 设计纪律第 1 条）。
