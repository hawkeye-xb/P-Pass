# NET-08 全仓「同步等长任务」焊点普查（只读审计，产卡不改码）　级别 L2

> 🟡 状态：普查完成（2026-09-14 Hermes：清单见「普查结果」节，新卡
> NET-09/10/11、TEL-05 已开）——按本卡备注，后续卡逐个归档后本卡以
> 「清单闭环」为准归档，现留本目录。
> 级别：L2 · 阻塞：无 · 本卡是**只读审计**——产出 = 焊点清单 + 每张一个
> 后续卡（或并入现有卡），**不改任何生产代码**。

## 问题

NET-01/06 的教训不是"一个超时值设错了"，而是一个**可复发的形状错误**：
把「提交任务」和「等结果」焊死在一次同步往返里，用单一超时同时扮演
"快速发现死对端"和"耐心等长任务"两个相反目标，客户端靠**回声有没有**猜
任务状态，而不是**翻对端的账本**。凡是这个形状的地方，都会在未来某个
网络/负载条件下长出同一个病：一端判死刑、另一端还在干活、两本账不对账。

## 期望行为（= 审计判据）

对全仓（Rust daemon / Kotlin Android / Svelte 桌面 / tools / infra workers）
系统排查，凡同时或部分命中以下特征的调用点，登记为焊点：

- **W1 单值多语义**：一个超时/常量同时管 建连 / 控制 RPC / 长数据任务
  （NET-01 原型：`CONNECT_TIMEOUT_MS` 一值三用）。
- **W2 回声即状态**：调用方只凭「响应来没来/超时没超」推断任务成败，
  而被调方存在（或应该有）持久化任务状态可查。
- **W3 超时即重发**：超时后直接重发任务型请求，不先查对端账本
  （双端互踩/重复劳动风险；对照 NET-06「重试前先查账」）。
- **W4 摆钟已发生**：历史上围绕该点出现过调参式修复（注释/卡片/git log
  里找得出"改数字救场"痕迹的）。
- **W5 库能力闲置**：底层库自带事件/进度/状态接口但调用方没用
  （NET-06 备注的口径；对照 AGENTS.md 设计纪律第 4 条）。

每个焊点给出：位置（文件:行）、命中 W 几、当前是否已被某卡覆盖（NET-06/07
范围外的才算新发现）、建议处置（开新卡 / 并入现有卡 / 明确豁免并写理由——
"LAN-only 场景"不构成豁免，产品核心场景就是在外面）。

## 验收标准

- [ ] 排查覆盖清单可核对：`crates/daemon/src`（全部 RPC handler 与外呼，含
      legacy 批量 manifest/push/commit、blob GC、缩略图生成、审计 outbox）、
      `apps/android`（DaemonClient 全部 call 点、WorkManager 各 Job、预览/
      下载大图路径、更新检查）、`apps/desktop/src-tauri`（对 daemon 的 IPC、
      对 updater 的网络调用）、`tools/`、`infra/`（relay/telemetry worker
      对外调用）逐域打勾，不许抽查。
- [ ] 产出登记在本卡「普查结果」节：每条含 位置/W 编号/覆盖情况/处置。
- [ ] 每个未覆盖新焊点 → 按 §C.2 模板开卡（或并入现有卡并在 QUEUE 挂号），
      过 `just queue-check`。
- [ ] 零生产代码 diff（`git diff` 只含 cards/ docs/）。
- [ ] 已知答案先自检：NET-01 链条本身（fetch）必须出现在清单里且标记
      "已被 NET-06/07 覆盖"——普查若连已知焊点都没找全，即为不合格。

## 范围

- 只准动：`cards/`、`docs/QUEUE.md`、本卡证据节。
- 不准动：任何 `crates/` `apps/` `tools/` `infra/` 代码。发现问题只登记，
  修复一律走各自卡。

## 阻塞与依赖

无。可与任何卡并行（只读，不动代码，天然无冲突）。

---

## 普查方法建议（供实施 agent 参考，不强制）

1. 全仓 grep 超时/等待面：`withTimeout|TimeoutCancellationException|timeout|
   DEADLINE|sleep|poll`（Kotlin/Rust/JS 各来一遍），得到候选点全集再逐个
   定性，比通读快且可核对。
2. 对每个 RPC 方法问三句话：这个调用最长会堵多久？谁定的上限？上限到了
   调用方知道"任务死活"还是只知道"这通电话断了"？第三问答不出=焊点。
3. 桌面 IPC（Tauri command）也算调用点：桌面壳同步等 daemon 做长活（缩略图
   批量重生成等）与本病同形，DESK-13 的 ingest 冻结是同族前科。

## 普查结果（2026-09-14，Hermes）

### 覆盖核对表（卡面验收 §1 的逐域打勾）

- [x] `crates/daemon/src` 全部 RPC handler 与外呼：router.rs（dispatch 全方法：
      hello/pair.request/device.unpair/flow.offer|fetch|cancel/flow.audit.submit/
      backup.begin|manifest|presence|commit/timeline.page/asset.meta/thumb.get/
      asset.blob.ticket）、flow_delivery.rs、backup.rs、query.rs、upload.rs、
      download.rs、pairing.rs、telemetry.rs、ipc.rs（本地 socket 全部方法）、
      main.rs、watcher.rs、inbox.rs、update.rs（纯解析，无网络调用，零焊点）
- [x] `apps/android`：DaemonClient.kt 全部 call/connect/download/subscribe 点
      （grep `client.call(` 共 14 处调用点，逐一过：PhotosScreen×2、PairFlow×3、
      ForegroundHeartbeat×1、BackupRunner×1、BackupUiStateHolder×1、
      NativeFlowDeliveryPort×5、RemotePresenceProbe×1）、WorkManager（BackupWorker/MediaWatchJob/
      TriggerPolicy）、FlowRunner/StrictConsumer/NativeFlowDeliveryPort、
      PhotosScreen（预览/下载大图）、BackupRunner（legacy）、PairFlow、
      BackupUiStateHolder、ForegroundHeartbeat、RemotePresenceProbe、
      UpdateChecker（更新检查）
- [x] `apps/desktop/src-tauri`：ipc.rs（call/subscribe_events）、lib.rs 全部 16
      个 command（含 daemon_call 透传、restart/start/stop、export_logs_bundle）、
      tauri-plugin-updater 配置
- [x] `tools/`：testclient、scenarios/*.sh、dogfood、ipc-lib.sh、win-smoke.ps1、
      android-backup.sh、make-update-manifest.mjs
- [x] `infra/`：workers/update、workers/telemetry、workers/rendezvous、relay
      （容器配置无 RPC 调用点）、selfhost compose

### 焊点清单

编号 N=网络/交付，P=配对，D=桌面，T=工具/infra。命中列 = W1..W5。

| # | 位置 | 命中 | 覆盖 | 处置 |
|---|---|---|---|---|
| N1 | `apps/android/.../transport/DaemonClient.kt:44`（`CONNECT_TIMEOUT_MS=15_000` 一值三用：`:56` 建连、`:121` 整轮往返含长活、错误文案 `:59/:146` 同一异常） | **W1 W2 W4**（UX-11 `971c0e5` 加保险丝、NET-01 摆钟史） | **NET-07（止血分档）+ NET-06（根治）** | 已覆盖，勿动 |
| N2 | `apps/android/.../backup/flow/NativeFlowDeliveryPort.kt:180`（`flow.fetch` 同步 RPC，成功回执=唯一信息来源）+ `StrictConsumer.kt:163` `recordPermanentFailure` 3 次计数回队**不先查桌面账本** | **W2 W3**（超时→`DaemonUnreachableException`→回队重发 offer/fetch，与仍持 `fetch_lock` 的桌面互踩，NET-06 问题链实证） | **NET-06**（status 门 + 「重试前先查账」条款） | 已覆盖，勿动 |
| N3 | `crates/daemon/src/flow_delivery.rs:385`（`fetch_from_observing_path` 一次阻塞 await、fetch RPC 内部无中断检查点）+ `router.rs:472`（`FLOW_FETCH => delivery.fetch(...)` 同步等等结果） | **W1 W2**（桌面账本有 active/completed 却无查询门——NET-06「唯一真实缺口」节源码核实过） | **NET-06**（spawn + suspend/cancel 中断） | 已覆盖，勿动 |
| N4 | `apps/android/.../ui/PhotosScreen.kt:190`（`download` → `DaemonClient.kt:241` `downloadAsset`：拨号有 `connectBounded` 闸，**数据面 `recv.readExact` 循环（`:280`）无任何 idle/总时长上限**——半开连接让查看大图的协程永久挂起，UI 停在进度百分比且无「死活」信号） | **W1（无值=另一种单值缺失）W2**（挂 vs 慢不可区分） | 未覆盖 | **开卡 NET-09**（与 daemon 侧 `upload.rs:148`/`download.rs:102` 数据面同形，一卡收口） |
| N5 | `apps/android/.../update/UpdateChecker.kt:158-159`（APK 下载 `readTimeout=30s` 单值：既管「服务器死了」又管「百 MB 包在蜂窝慢速下载」；`:175` catch-all→false，用户只看到「点了没反应」） | **W1 W2**（轻度：无对端账本可查，但死因不可辨=同族） | 未覆盖 | 并入 **NET-09**（同为「长数据传输无进度感知超时」） |
| P1 | `apps/android/.../transport/PairFlow.kt:105`（`pair.request` 在 15s 档 `call()` 之外用 `withTimeout(120_000)` 硬等主人点 Allow）+ `crates/daemon/src/pairing.rs:249`（`decision_rx.await` 对端**无限期**挂 RPC 流等人类） | **W1 W2**（超时后手机只见「电话断了」，分不清被拒/没人点/网络死；`daemon.pending` 账本就在，客户端不翻）+ 两端上限不对称（客户端 120s、daemon ∞、token 600s 三个数各管各） | 未覆盖（NET-06 只圈 flow 交付） | **开卡 NET-10**（形状=照抄 NET-06：pair 受理后 status/订阅事件，人类等待移出 RPC 往返；L2 依赖 NET-06 的 status 范式落地） |
| D1 | `apps/desktop/src-tauri/src/ipc.rs:118`（`DaemonHandle::call` 同步 `read_line` **无读超时**）+ `lib.rs:64`（`daemon_call` 把 daemon 任意本地方法原样透传给 UI，含重活）——daemon 线程池饥饿/挂死（DESK-13 前科同族）时 Tauri command 线程无限期挂起，UI 转圈无死因 | **W2 W5**（interprocess/标准库可用非阻塞+deadline 组合，现全同步） | 未覆盖 | **开卡 NET-11**（L1：本地 socket 加固定保险丝 + 超时报错带方法名，禁按方法动态推算） |
| T1 | `crates/daemon/src/telemetry.rs:126`（`reqwest::Client::new()` 默认无超时）+ `:175`（`flush_now` 的 POST 半死端点可无限挂起 flush 循环→内存队列无上限增长——注释承诺「never grow unbounded」只覆盖了「失败即丢批」，没覆盖「挂而不死」） | **W1（缺值）W5**（reqwest 自带 timeout 配置未用） | 未覆盖 | **开卡 TEL-05**（L1：Client 配 total timeout + 队列封顶，best-effort 语义不动） |
| T2 | `infra/workers/update/src/index.ts:44,68`（Worker 外呼 GitHub 无 AbortSignal；半死上游由 CF 平台子请求硬限兜底，客户端 `catch→null` 静默，且更新检查本无账本） | W2（边缘） | 未覆盖 | **明确豁免**：平台超时即保险丝、失败不产生任何用户可见状态、无可查账本——三条件同时成立才豁免，写卡在此防复发 |
| — | `tools/testclient`、`tools/scenarios/*.sh`、`tools/dogfood/*.sh`、`win-smoke.ps1`（sleep 轮询/无界 await） | — | 非产品路径（开发与冒烟工具） | **豁免登记**（不受「LAN-only 不豁免」约束——豁免理由是「不在产品调用链上」，不是场景） |

### 形状正确的对照组（普查副产物：证明判据不是「有超时=焊点」）

- `BackupUiStateHolder.kt:177` epoch 自愈：`hello` 查询失败≠判死，`applyEpochRepairOutcome`
  只在拿到成功回音且 epoch 变化时才修账，失败留待下一轮——「先查账再动作」的现仓范例。
- `MainActivity.kt:719` unpair：5s 超时后**本地照断**，通知失败不改变任何账本事实——
  「意图先行、通知尽力而为」范例（NET-06 原则 1 的同型先行）。
- `lib.rs:440` restart 轮询：500ms 间隔 + 12s 上限 + 超时显式报错文案——轮询兜底的正确写法。
- `query.rs:122` thumb 生成：5s 预算超时返回占位图但生成任务不死、文件落盘下次可取——
  「超时只降级呈现、不判任务死刑」的 daemon 侧范例（NET-06 status 语义可参照）。
- 数据面长流不加固定总时长上限（`connectRaw`/upload plane 只闸拨号）是 NET-06 备注的
  既定设计（进度由字节流事件承载），N4/N5 的病在「无 idle 检测」而非「无总上限」。

### legacy 批量管线定性（卡面点名的 manifest/push/commit）

`BackupRunner.kt:73/82/113`（begin/manifest/commit 同步链，`BACKUP_COMMIT` 触发桌面
逐文件 ingest、大批次必 >15s）与 fetch 同形，但生产入口已被 REBUILD-00 冻结
（`BackupWorker.doWork` 只调 `runFlowWake`；全仓 `BackupRunner(` 除类定义与
androidTest 外零实例化，MainActivity 仅剩 import 残留）。其清理在 UI-10/MOB-69 的
legacy 尾巴范围内。**不开新卡**，
挂账：若 legacy 复活必须先过 NET-06 形状（写进本卡备注，不再单开）。

## 实施记录

（本卡只读审计，无代码改动；新卡 NET-09/10/11、TEL-05 已按 §C.2 模板开卡并入
docs/QUEUE.md 可接队列，`just queue-check` 通过。）

## 备注

- 本卡是 AGENTS.md「设计纪律」第 1/2/4 条的一次性全仓落地检查——纪律防
  未来，本卡清存量。
- 修完不等于关卡：后续卡（若有）逐个归档后，本卡以「清单闭环」为准归档。
