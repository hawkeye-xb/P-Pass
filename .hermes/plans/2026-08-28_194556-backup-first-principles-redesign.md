# P-Pass 备份流程第一性原理重设计（仅设计，不实施）

**目标：** 不再围绕现有五个 WorkManager 入口和补丁历史修语义；先定义「用户把一张照片交给 P-Pass 后，系统究竟欠用户什么」的稳定模型，再反推调度与代码。

**本轮边界：** 不改 Android/Rust 源码、不改任务卡、不改既有测试、不提交。本文是讨论草案，不是实现计划。

---

## 0. 已核实的现状（不是目标架构）

- 现有一条 `BackupWorker` 管线，五个触发通道各自创建 WorkManager work；跨通道由进程内 `backupInFlight` 互斥。
  - `BackupWorker.kt:204-389, 443-476`
- 当前水位只在一整批 `BackupRunner.run(...)` 成功后推进；因此中断后会从旧水位重扫并靠去重收敛。
  - `BackupWorker.kt:553-558, 690-697`
- 现有 `PausePrefs` 只保存暂停时刻，主要用于 UI 合成；`AutoBackupPrefs.paused` 同时被 worker 当作全局执行闸门。
  - `PausePrefs.kt:42-72, 118-147`; `AutoBackupPrefs.kt:1-38`; `BackupWorker.kt:472-476`
- `confirmed` 是「曾被远端确认拥有」的 hash 缓存；现有校准每轮都可能执行，发现远端缺失后把 hash 从 confirmed 移除，并由补偿队列重新查找本地媒体。
  - `Calibration.kt:55-70`; `BackupWorker.kt:520-525, 559-577`

这些事实解释了当前的复杂性，但**不应反过来限制目标模型**。

---

## 1. 从第一性原理得到的产品契约

### 用户真正委托的是什么

用户选定备份范围并启用自动备份后，P-Pass 的承诺不是「某个 WorkManager job 运行过」，而是：

> 已被系统发现、属于用户选定范围的每一个媒体版本，要么有可验证的远端确认，要么仍作为可见、可恢复的待处理项存在；若用户明确取消或文件已不可恢复，也必须留下可诊断的终态理由，绝不能静默消失。

### 不变量

1. **发现与传输分账。** 发现到的媒体版本一旦进入可靠本地账本，就不能仅因传输未完成而重新依赖扫描游标找回。
2. **游标只表示「已可靠发现」，不表示「已上传」。** 推进游标的前提是候选已经与游标一起持久化。
3. **队列才是未完成工作的真相；WorkManager 只是叫醒执行器。** 系统取消、进程重启和不同触发来源都不能改变队列语义。
4. **每次控制动作只表达一种意图。** Pause、Continue、Cancel、Retry、关闭自动备份不能共享一个布尔值或一个「非 running」分支。
5. **约束是执行准入规则，不是数据删除规则。** Wi-Fi/电量不满足时，工作保持待处理；既不算失败，也不因重建 work 改写用户意图。
6. **远端确认是逐文件的 durable fact；批次只是运行优化。** 一个文件确认成功后立即记账；没有「整批 commit 成功才算交付」的产品语义。
7. **范围先于任何发现或传输。** 未选择范围与空范围都必须保证不创建可传输候选。

---

## 2. 最小持久模型（目标）

```text
BackupPolicy
  scope                 用户选择的相册/范围
  backgroundAutoEnabled 是否允许 App 不在前台时自动发现与自动消费；关闭后，前台打开 App 仍默认自动备份
  constraints           自动执行要求（Wi‑Fi / 电量等）
  reconciliationDueAt   下一次远端对账时间

DiscoveryCursor
  source + scopeVersion + generation
  含义：到此处的本地变化已可靠写入 TransferItem，不代表已上传

TransferItem
  identity              MediaStore stable key + version（generation/mtime/size）
  source                automatic-discovery | manual-full-scan | reconciliation
  state                 queued | leased | retryAt | confirmed | cancelledByUser | failedPermanent
  attempt/error         暂时错误的重试信息，或不可恢复错误的可诊断原因；等待/暂停不写入
  remoteEvidence        已确认 hash / 时间 / remote presence 状态

PipelineControl
  userPaused            用户暂停整个传输管线；只能由 Continue 清除
  stopRequested         仅用于让当前执行器尽快退出；不是产品状态
```

### 原子性边界

```text
scan(cursor)
  -> transaction: insert/merge TransferItem(s) + save next DiscoveryCursor
  -> transaction committed

只有事务提交后，扫描结果才算“发现完成”。
```

若事务前崩溃，旧 cursor 会重扫，最多重复发现；若事务后崩溃，队列仍在，绝不丢候选。

---

## 3. 先讲语义，再讲流程

| 事件 | 用户/系统目的 | 持久事实 | 调度器效应 | 合法的下一步 |
|---|---|---|---|---|
| 自动触发 | 提醒系统检查新的本地媒体；App 前台时默认允许自动备份 | 无需保存每一个事件；cursor 是事实源 | 请求一次 wake | discovery 或等待约束 |
| 手动全量 | 用户明确要求重新检查选定范围 | 新建 `manual-full-scan` discovery 请求 | 立即 wake，可有独立豁免 policy | discovery |
| Pause | 用户要求当前管线绝不自动继续 | `userPaused=true` | 取消/停止当前执行器 | 只能 Continue 或 Cancel |
| Continue | 用户允许已欠的工作继续 | `userPaused=false` | wake consumer | 从第一个未确认 TransferItem 继续 |
| Cancel paused transfer | 用户明确放弃这次已暂停的传输 | 相关未确认项 = `cancelledByUser`，保留审计原因 | 取消本地/远端的活跃传输或 staging 记录 | 不重传这些版本；不等于关闭后台自动备份 |
| Retry | 某一 item 的暂时失败重试 | 保留 item、更新 attempt/retryAt | 到期 wake | 重试该 item；不是重新全量扫描 |
| 不可恢复文件错误 | 某一文件已不能读或协议确认不可重试 | item = `failedPermanent(reason)`；保留错误原因 | 清理手机与电脑两侧的活跃传输/staging 记录 | 跳过该项，继续消费其余队列 |
| 条件不满足 | 系统暂不可运行 | 队列不变；可记录派生状态 | scheduler 等条件 | 自动恢复消费 |
| Disable background auto | 用户不再允许 App 在后台自行工作 | `backgroundAutoEnabled=false` | 停止后台 wake / 后台服务 | App 打开并在前台时，仍默认自动发现/消费 |
| Cancel execution | 系统或内部要求停止当前执行器 | 不改变产品意图、不删除队列 | stop 当前执行器 | 下次由 policy 决定是否重跑 |
| Reconcile | 低频检查远端是否仍保存已确认项 | 更新 remote presence；缺失项入同一队列 | 单独低频 wake | 普通 consumer 重传 |

**关键区别：**

- `Pause` 是用户授权的撤回，禁止自动恢复。
- `WaitingConstraints` 是系统条件，允许自动恢复。
- `Retry` 是单项传输错误的时间安排。
- `Cancel execution` 是机械停止，不能伪装成前三者任何一个。
- `Cancel paused transfer` 是明确放弃当前传输，不等于关闭后台自动备份；只有它会让队列项进入用户取消终态。
- `Disable background auto` 只撤销后台自动权利，不等于删除已经发现的数据，也不等于暂停按钮；用户打开 App 后前台自动备份仍可执行。

---

## 4. 目标流程（先数据，后调度）

```text
(1) 收集本地变化
    目的：把“相册发生变化”转成一次检查机会，而非 N 条业务任务。

Watch / foreground / cold start / periodic
                |
                v
          requestWake(AUTO_DISCOVERY)
                |

(2) 发现并可靠入账
    目的：让“已看见的照片”脱离 WorkManager 与进程生命周期。

control + scope +（后台时须 backgroundAutoEnabled）+ constraints允许？
    | no: 保留 cursor/queue 原样；调度器稍后唤醒
    v yes
scan(DiscoveryCursor)
    |
    v
[atomic: upsert TransferItem + advance DiscoveryCursor]
    |
    v
queue now represents every discovered-but-unconfirmed media version

(3) 消费队列
    目的：逐项取得远端确认，不把批次会话当作可靠性边界。

first transferable TransferItem
    |
    +-- userPaused ---------> do not run; only Continue may wake
    +-- background auto off --> App 后台不运行；App 前台时默认仍可自动运行
    +-- constraints missing --> waiting; keep item unchanged; auto wake when eligible
    +-- retryAt in future ----> waiting retry; wake at due time
    |
    v
lease item -> hash/dedupe -> offer/push -> remote confirms
    |
    +-- confirmed -----------> mark confirmed immediately; consume next item
    +-- transient error ------> set retryAt/error on this item only
    +-- permanent file error --> mark failedPermanent(reason), clear phone + desktop active transfer/staging records,
    |                           then consume the next item
    +-- execution cancelled --> release lease to queued; do not call it retry/pause

(4) 低频远端对账
    目的：发现“本地未变但远端被删”的失真，不干扰日常本地增量。

reconciliationDue
    |
    v
check remote presence of confirmed records
    |
    +-- still present -------> retain evidence
    '-- missing -------------> mark remote missing + upsert same TransferItem
                              -> normal consumer restores it
```

---

## 5. 调度器的正确角色

WorkManager / JobScheduler 只负责两件事：

1. **在可能合适的时机叫醒 controller**（OS 约束、退避、省电策略）；
2. **尽快停止已经被取消的执行器**。

它不拥有以下业务事实：待上传清单、用户暂停意图、单项重试归属、上传是否已确认、发现游标。

因此“调度约束 + 管线约束双门”不需要再被当作棘手的补丁问题：

- scheduler constraint 是节能/少唤醒的**前置优化**；
- controller admission check 是正确性的**最终权威**；
- 两者不一致时，controller 只把状态派生为 `WaitingConstraints`，不消耗队列、不记失败、不创造新的触发类型。

---

## 6. 已确认的产品决定

### A. 关闭自动备份 = 关闭后台自动服务

关闭后，App 不在前台时不再自动发现或消费；既有 `TransferItem` 保留。用户打开 App 后，前台路径默认仍可自动发现和消费，不要求额外点“立即备份”。

### B. 暂停后提供 Continue 与 Cancel

`Continue` 清除暂停并从队列首个未确认项恢复；`Cancel` 明确放弃这次暂停的传输，相关项记为 `cancelledByUser`，并清理手机与电脑两侧的活跃传输记录。两者都不能被偷换成手动全量扫描；手动全量仍是独立动作。

### C. 不可恢复的文件错误

若文件在 mobile 备份期间异常、确定不可重试：留下可供 UI 展示的错误原因，将该项标为 `failedPermanent(reason)`，清理手机与电脑两侧的活跃传输/staging 记录，并继续传输后续内容。不得无限重试，也不得静默当作已备份。

---

## 7. 三张图：状态、流程与数据流

### 7.1 不做一张巨型状态机：三个正交状态空间

一张「Idle / Running / Paused / Retry …」总状态图会把三件独立事实混成一团：
后台自动权、用户管线控制、每一个文件的交付状态。目标模型把它们分开；UI
只从三者派生文案与可用操作。

```text
┌────────────────────────────────────────────────────────────────────┐
│ A. 后台自动权（BackupPolicy，持久）                                 │
│                                                                    │
│  [BACKGROUND_ENABLED] --关闭后台自动--> [BACKGROUND_DISABLED]     │
│           ^                                      |                 │
│           └-----------重新开启-------------------┘                 │
│                                                                    │
│  含义：只决定 App 不在前台时能否自动 wake / discover / consume。   │
│  App 在前台时，两态都允许默认自动备份。                             │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ B. 用户管线控制（PipelineControl，持久）                           │
│                                                                    │
│  [UNPAUSED] --Pause--> [PAUSED]                                    │
│       ^                     |                                      │
│       |                     +--Continue--> 清 pause，保留队列      │
│       |                     |                 → consumer 从队头跑 │
│       |                     |                                      │
│       └-----Cancel----------+--取消本次待传项、清两侧 staging、      │
│                              清 pause → 等待后续自动/前台触发       │
│                                                                    │
│  含义：Pause 撤回“自动继续”的授权；Cancel 明确放弃当前传输。        │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ C. 单个 TransferItem（每个媒体版本各一份，持久）                  │
│                                                                    │
│ discovered ──原子入账──> QUEUED ──取得 lease──> LEASED             │
│                              ^                     |               │
│                              |                     +--远端确认--> CONFIRMED
│                              |                     |               │
│              retry due ------+                     +--暂时错误--> RETRY_AT
│                                                    |               │
│                                                    +--系统取消--> QUEUED
│                                                    |               │
│                                                    +--不可恢复--> FAILED_PERMANENT(reason)
│                                                                    │
│ QUEUED / RETRY_AT --用户 Cancel 本次传输--> CANCELLED_BY_USER     │
│                                                                    │
│ CONFIRMED --低频对账发现远端缺失--> QUEUED（source=reconciliation）│
│                                                                    │
│ FAILED_PERMANENT / CANCELLED_BY_USER 是可诊断终态，不是“成功”。    │
└────────────────────────────────────────────────────────────────────┘
```

### 7.2 控制器流程图：先发现入账，再消费队列

```text
触发源
  Watch / 前台打开 / 冷启动 / 周期 / 手动全量 / 低频对账
       |
       | 目的：请求一次 controller wake；触发本身不是待传任务
       v
[Backup Controller]
       |
       +-- App 后台且 BACKGROUND_DISABLED?
       |      └─ 是：停止本次后台执行；数据和队列均不改
       |
       +-- Pipeline PAUSED?
       |      └─ 是：不消费；只有 Continue / Cancel 改变它
       |
       +-- scope 未选 / 空?
       |      └─ 是：不发现、不传输；给可解释的范围状态
       |
       +-- 当前来源需要 discovery?
       |      |
       |      +-- 条件不满足?
       |      |      └─ 是：WAITING_CONSTRAINTS；不失败、不改队列，等待下次 wake
       |      |
       |      └─ 否：scan(cursor)
       |              |
       |              v
       |        [一笔原子事务]
       |        upsert TransferItem(s) + advance DiscoveryCursor
       |
       v
[Consumer 从首个可传 TransferItem 取 lease]
       |
       +-- 条件不满足 / retryAt 未到? --> 保留项，等待合适 wake
       |
       +-- hash / dedupe / offer / push
               |
               +-- 成功 --> CONFIRMED，立刻消费下一项
               +-- 暂时错误 --> RETRY_AT，仅延后这一项
               +-- 永久错误 --> FAILED_PERMANENT(reason)
               |              + 清手机与电脑两侧 active transfer/staging
               |              + 继续下一项
               '-- 系统取消 --> 释放 lease 回 QUEUED；不叫 Retry/Paused
```

### 7.3 数据流图：谁是事实源、谁只是执行器

```text
                 ┌──────────────────┐
                 │ MediaStore        │
                 │ 本地媒体事实源    │
                 └────────┬─────────┘
                          │ scan(cursor)
                          v
┌─────────────┐    ┌─────────────────────────┐
│ Trigger /   │--->│ Discovery transaction    │
│ Scheduler   │    │ TransferItem upsert      │
│ (wake only) │    │ + DiscoveryCursor save   │
└─────────────┘    └───────────┬─────────────┘
                               │ atomic commit
                               v
                 ┌─────────────────────────┐
                 │ Local TransferQueue      │
                 │ 未确认项的唯一真相       │
                 └───────────┬─────────────┘
                               │ lease one item
                               v
                 ┌─────────────────────────┐
                 │ Transport adapter        │
                 │ hash → offer → push      │
                 └───────┬─────────┬───────┘
                         │         │
      temporary failure  │         │ successful remote confirmation
                         v         v
                 ┌────────────┐  ┌─────────────────────────────┐
                 │ retryAt /  │  │ Remote storage + staging     │
                 │ error      │  │ 远端保存和短暂传输状态       │
                 └────────────┘  └───────────┬─────────────────┘
                                              │
                                              v
                                  ┌──────────────────────────┐
                                  │ Confirmed evidence       │
                                  │ hash + confirmed time    │
                                  └────────────┬─────────────┘
                                               │ low-frequency reconcile
                                               v
                                  remote missing? ──yes──> upsert TransferItem
```

**边界规则：** `Trigger / Scheduler` 不拥有待传事实；`Remote staging` 也不是
完成事实。只有本地队列中已确认的 `CONFIRMED` 加上远端确认回执，才代表一项交付完成。

---

## 8. 现在不该做的事

- 不为五条现有 WorkManager name 补更多 cancel/paused 分支。
- 不把 `PausePrefs` 再扩成万能状态机。
- 不用 `WorkInfo` 或 unique name 反推原始业务意图。
- 不先讨论“会话内动态追加”还是“批次末尾消费”；目标模型中队列是 durable truth，daemon 会话仅是可替换的 transport adapter。
- 不让校准挤进每次正常触发的主路径。

---

## 9. 设计确认后的实施顺序（暂不执行）

1. 只建纯 Kotlin domain model 与状态迁移测试（无 WorkManager、无网络）。
2. 引入 durable `TransferItem` + cursor 的原子持久化；先证明崩溃前后不丢候选。
3. 让 discovery 写队列，暂不改变 transport；以现有传输代码作为 consumer。
4. 将 Pause / Continue / Retry / Disable auto 映射到控制状态，而非入口函数。
5. 最后将五种触发改成 wake source；保留不同的 OS 调度形态，但去除业务语义分叉。
6. 将 reconciliation 改为低频 producer，缺失项进入同一队列。

**验收原则：** 每一阶段先证明 durable facts 的正确性，再做 UI 与调度收口；不得以“整批重扫 + 去重”替代真正的可恢复语义。
