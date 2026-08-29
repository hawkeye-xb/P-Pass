# P-Pass 备份：从业务 Case 推导的干净架构（仅设计）

> **边界：** 本文不实施、不改任务卡。它替代「先看五个 WorkManager 入口，再给每条补 pause/retry 判断」的思路。

**目标：** 把备份定义为一个可恢复的本地交付账本；将 Android 调度、MediaStore、网络传输、UI 都降为可替换 adapter。每一条边界都由 case catalog 的某类行为证明其必要性。

---

## 1. 架构先回答的三个问题

```text
Q1：用户把哪些媒体交给了系统？
    → DiscoveryCursor + TransferItem（持久事实）

Q2：现在谁有权处理这些项？
    → BackupPolicy + PipelineControl + AppVisibility（业务准入）

Q3：一项怎样成为“已经交付”？
    → RemoteArchiveGateway 返回 durable confirmation，才写 CONFIRMED
```

任何模块不得同时拥有两项以上答案。尤其：

- WorkManager 不回答 Q1/Q3；它只负责可能合适时唤醒执行器。
- UI 不回答 Q1/Q2；它只显示投影并发出命令。
- daemon session / staging 不回答 Q1；它是 transport 的暂态。

---

## 2. 从 Case 到职责：为什么必须这样拆

| Case 族 | 真正问题 | 单一职责模块 |
|---|---|---|
| `POL-*` | 哪些范围、前台/后台自动权、约束下允许自动做 | **Policy / Admission** |
| `DSC-*` | 发现与游标如何原子落账、不丢候选 | **Discovery + BackupStateRepository** |
| `ADM-*` | OS 条件只是准入，不能篡改队列事实 | **AdmissionPolicy + RuntimeEnvironment port** |
| `XFR-*` | 单项 lease、去重、重试、永久失败、确认 | **TransferEngine + RemoteArchiveGateway** |
| `CTL-*` | Pause / Continue / Cancel 是用户命令，不是 Work 状态 | **PipelineControl + TransferIntent** |
| `REC-*` | 远端对账只产生待处理项，不触碰日常发现游标 | **ReconciliationService** |
| `RCV-*` | 崩溃、换 remote、并发时仍不串账/不丢账 | **BackupStateRepository + RemoteIdentity boundary** |
| `OBS-*` | 状态文案来自事实投影，不能反推/篡改领域状态 | **BackupStatusProjector** |

这不是按“现有文件名”拆，而是按**哪类 case 会一起变化**拆。

---

## 3. 逻辑模块图（先是 package boundary，稳定后再升 Gradle module）

```text
apps/android/.../backup/
│
├─ domain/                         纯 Kotlin；零 Android / 网络 / 文件 I/O
│  ├─ model/
│  │  ├─ BackupPolicy              scope、后台自动、约束 policy、对账到期
│  │  ├─ PipelineControl           Unpaused | Paused(intentId)
│  │  ├─ TransferIntent            “本次传输”的持久归属和取消范围
│  │  ├─ TransferItem              media version、状态、attempt、reason、remote、cleanup 状态
│  │  ├─ DiscoveryCursor           已可靠发现的位置
│  │  └─ RemoteIdentity            queue / evidence 的严格隔离键
│  ├─ rules/
│  │  ├─ AdmissionPolicy           前后台、开关、scope、Wi‑Fi/电量的准入裁决
│  │  ├─ ItemStateMachine          QUEUED/LEASED/RETRY/CONFIRMED/FAILED/CANCELLED
│  │  ├─ QueueSelection            “最早可传项”，retry 未到不堵后项
│  │  ├─ ScopePolicy               缩范围、扩范围、范围外项的终态
│  │  └─ StatusProjection          领域事实 → 可展示状态（无 UI 文案）
│  └─ events/                      DomainEvent，只描述已发生事实
│
├─ application/                    用例编排；只依赖 domain + ports
│  ├─ BackupController             唯一命令入口；串行化一次 controller run
│  ├─ DiscoverMedia                scan → 原子入账 cursor + item
│  ├─ ConsumeTransferQueue         lease → deliver → state transition
│  ├─ ControlPipeline              Pause / Continue / Cancel
│  ├─ RemoteCleanupDispatcher      可靠执行远端 staging abort；不重试文件传输
│  ├─ ReconcileRemote              confirmed evidence → requeue 精确项
│  └─ BackupStatusQuery            读取投影给 UI / 通知
│
├─ ports/                          application 定义的接口，不含实现
│  ├─ BackupStateRepository        所有 durable state + transaction + lease
│  ├─ MediaCatalog                 scan since / fetch by reference / count
│  ├─ RemoteArchiveGateway         deliver、abort staging、reconcile presence
│  ├─ RuntimeEnvironment           前后台可见性、网络/电量条件
│  ├─ WakeScheduler                request/cancel background wake（无业务状态）
│  ├─ Clock / Logger / Notifier
│  └─ RemoteIdentityProvider
│
├─ adapters/                       Android / Iroh / SQLite 的实现
│  ├─ storage/                     Room/SQLite BackupStateRepository
│  ├─ media/                       MediaStoreCatalog
│  ├─ runtime/                     AndroidRuntimeEnvironment
│  ├─ scheduler/                   WorkManager + JobScheduler watch adapter
│  ├─ transport/                   DaemonRemoteArchiveGateway
│  └─ lifecycle/                   foreground/background visibility adapter
│
└─ presentation/                   Compose/ViewModel；只能 Command / Query
   ├─ BackupViewModel
   ├─ BackupStatusMapper
   └─ BackupCommands               Pause / Continue / Cancel / set policy/scope
```

### 依赖方向（硬规则）

```text
presentation ───────┐
adapters ───────────┼──> application ───> domain
                    │          │
                    │          └──> ports  <── adapters implement ports
                    │
                    └── 禁止 domain/application 反向 import Android、WorkManager、DaemonClient
```

`ports` 由 application 拥有：这保证业务用例决定“我需要什么能力”，而不是被
MediaStore、WorkManager 或现有协议的形状绑架。

---

## 4. 领域模型：只保存业务事实

```text
BackupState（按 RemoteIdentity 隔离）
├─ policy
│  ├─ scopeVersion + selected albums
│  ├─ backgroundAutoEnabled
│  ├─ automatic constraints
│  └─ reconciliationDueAt
│
├─ control
│  └─ Unpaused | Paused(transferIntentId)
│
├─ discovery
│  └─ DiscoveryCursor per scope/source
│
├─ intents
│  └─ TransferIntent
│       id, source(Auto | ManualFull | Reconciliation), createdAt,
│       cancellation boundary, lifecycle
│
├─ items
│  └─ TransferItem
│       id = remote + stable media ref + media version
│       intentId, state, lease, retryAt, attempt, terminal reason,
│       hash / confirmed evidence when available,
│       cleanup = NotNeeded | Pending(remoteHandle) | Completed
│
└─ evidence
   └─ RemoteEvidence
        remote has confirmed hash/version at time T; remote-missing is a fact,
        not a request to rewind the discovery cursor
```

### 不再允许的“状态”

```text
✗ WorkManager unique name
✗ WorkInfo state
✗ 最近一次 finished timestamp
✗ 某个 JSON 偏好布尔值
✗ daemon staging 文件是否还在
```

它们都可以是 adapter 细节或观测数据，但不能独自决定 Pause、Retry、Cancel、
已交付或待传。

---

## 5. 用例如何组合：一个 Controller，两个生产者，一个消费者

```text
WakeCause
  ├─ Watch / foreground / cold start / periodic
  ├─ explicit manual full scan
  └─ reconciliation due
          │
          ▼
   BackupController.handle(wake)
          │
          ├─ AdmissionPolicy
          │    决定：本次能否在当前前后台/约束下运行
          │
          ├─ Discovery producer
          │    scan(cursor)
          │    → transaction(upsert items + advance cursor)
          │
          ├─ Reconciliation producer
          │    remote presence check
          │    → transaction(upsert only missing items)
          │
          └─ Transfer consumer
               claim next eligible item
               → RemoteArchiveGateway.deliver(item)
               → transaction(confirm | retry | permanent failure)
```

### 控制命令不走 Wake 分支

```text
Pause
  → transaction(control = Paused(intentId))
  → request running executor stop

Continue
  → transaction(control = Unpaused)
  → requestWake(CONTINUE)

Cancel
  → transaction(mark cancellation requested + create durable cleanup outbox)
  → RemoteCleanupDispatcher → RemoteArchiveGateway.abort(active staging)
  → transaction(record cleanup completed + clear control)
```

**重要：** `TransferIntent` 是 Cancel 语义必需的领域对象。持续队列没有天然的
“这一轮”；没有它就只能从 Work name 或 UI 猜取消范围，必然复发旧问题。

---

## 6. 事务与并发边界

### 唯一需要强原子性的地方

```text
A. discovery transaction
   upsert TransferItem(s) + advance DiscoveryCursor

B. item transition
   verify lease ownership + state transition + evidence/retry/reason

C. control command
   persist Pause/Cancel intent before scheduler/executor side效应

D. remote cleanup saga
   本地不能与 daemon staging 做一个数据库事务；Cancel/永久错误先持久化
   cleanup outbox，再幂等调用 abort。abort 失败只重试 cleanup，不得重新传文件。
```

因此 durable state 不能继续散在 `WatermarkStore`、`ConfirmedStore`、
`ReuploadQueue`、`PausePrefs`、`AutoBackupPrefs` 等各自 JSON 文件中；它们无法
提供跨账本事务、lease compare-and-set 和按 intent 查询。

推荐一个 per-remote SQLite/Room store，或单库所有表带 `remote_id`；两者均可，
但 API 必须呈现为单一 `BackupStateRepository` transaction，而不是 controller
手工协调五个 store。

### 并发模型

```text
Wake 并发             → controller run lock：合并，不并行扫描
Item 并发             → repository lease：同一项最多一个 consumer
OS stop / process kill → stale lease timeout/recovery：LEASED 回 QUEUED
Remote duplicate ack   → item idempotency：CONFIRMED 是幂等终态
```

这保留“单一管线”原则，但不再用进程内 `AtomicBoolean` 当作唯一正确性保障。

---

## 7. Transport 是可替换 adapter，不是领域边界

现有协议事实：`backup.begin → manifest → push missing files → backup.commit`，
并由 daemon 的 peer session 与 staging 管理批次；`commit` 才报告 ingest/duplicate。
这意味着当前 `BackupRunner` 的确认边界是**批次**，不是单项。

```text
现有 BackupRunner
  candidates[] → begin → manifest(all) → push(all) → commit(batch)

目标 RemoteArchiveGateway
  deliver(item) → Delivered(hash, durableEvidence)
  abort(item/session) → active staging cleaned or safely expired
  reconcile(hashes) → remote-missing hashes
```

### 正确的演进方式

1. **领域层只认识 `deliver(item)` 的 durable confirmation。**
2. 第一版 adapter 可以把一个 item 翻译为现有的单-item begin/manifest/push/commit
   会话；这可能不是最高吞吐，但能先满足逐项成功、坏项不堵后项、Cancel 精确清理。
3. 后续再演进 Rust protocol 为“一个 transport session 内多 item 的逐项确认/abort”，
   优化吞吐而不改变 domain/application case。

所以不让 daemon 当前“批次会话”决定 Android queue、Pause、Cancel 的业务语义；
它只是一个可升级的传输实现。

**两侧清理的可靠性：** `abort` 的网络调用不能与本地 `CANCELLED_BY_USER` /
`FAILED_PERMANENT` 原子提交。因此终态可先对用户可见，但必须带
`cleanup=Pending`；`RemoteCleanupDispatcher` 以 outbox 重试 abort，直到拿到
确认或 daemon 的会话 TTL/查询证明 staging 已安全失效。这个重试永远不是重传。

---

## 8. 现有代码的迁移归宿（不代表现在要改）

| 当前物 | 目标归宿 |
|---|---|
| `MediaScanner` / `ScopeBackfill` | `MediaCatalog` adapter；扩范围/范围变更规则归 domain/application |
| `WatermarkStore` | `BackupStateRepository.discovery cursor` |
| `ConfirmedStore` | `RemoteEvidence` 表/Repository projection |
| `ReuploadQueue` | 普通 `TransferItem(source=Reconciliation)`，不再独立队列 |
| `PausePrefs` / `AutoBackupPrefs` | `PipelineControl` / `BackupPolicy` |
| `BackupAttemptStore` | `TransferItem.retryAt/attempt`，不再是整批失败计数 |
| `BackupRunner` | `DaemonRemoteArchiveGateway` 的 transport adapter |
| `BackupWorker` | 极薄 `WakeScheduler`/entry adapter，不含扫描、上传、暂停业务 |
| `MediaWatchJob` / foreground / periodic | 都只产生 `WakeCause` |
| `BackupUiStateHolder` | ViewModel + `BackupStatusQuery`；不再自己决定恢复/取消策略 |

已验证的现状约束：当前 `BackupRunner` 的 `commit` 是批次确认，当前 daemon 也按
peer 维护 backup session/staging。因此“每项可确认、可取消、后项不停”要求将
transport session 从 application domain 中隔离出来，而不是继续在 Worker 内补分支。

---

## 9. 按架构风险排序的后续设计顺序（暂不实施）

```text
1. 先冻结 case catalog，补齐 Cancel 的 TransferIntent 边界。
2. 为 domain 写纯状态迁移测试：POL / DSC / XFR / CTL，不依赖 Android。
3. 设计 BackupStateRepository 的 schema 与三个事务；先验证 crash cases。
4. 接入 MediaCatalog discovery；只完成“发现可靠入账”，不改 transport。
5. 用 per-item RemoteArchiveGateway adapter 消费队列；先跑单项确认/错误跳过。
6. 接入 Pause / Continue / Cancel 与 staging cleanup。
7. 最后让 WorkManager、JobScheduler、UI 都收敛为 adapter。
8. 协议优化（多 item session / per-item ack）单独作为 transport 卡，不阻塞领域正确性。
```

**验证门：** 每一步只能消费 case catalog 中对应 case；先 RED，再最小实现，再 GREEN。
任何“为了兼容现有 Worker 名称/偏好文件而把业务状态塞回 adapter”的改动，都视为违背本架构。

---

## 10. 可编辑架构图（Excalidraw）

- `../diagrams/backup-architecture-modules.excalidraw`：模块边界与依赖方向。
- `../diagrams/backup-runtime-composition.excalidraw`：Wake、Controller、producer、consumer 与结果写回。
- `../diagrams/backup-durable-data-flow.excalidraw`：Cursor、队列、确认、重试、终态与对账输入。
- `../diagrams/backup-control-cleanup-saga.excalidraw`：Pause / Continue / Cancel / 永久错误的两侧清理 saga。

同目录的 `.png` 是手机阅读导出；`.input.json` 是 CLI 的可复现输入。四张 PNG 已经渲染检查：无裁切、无标签重叠、箭头端点明确。
