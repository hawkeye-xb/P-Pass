# P-Pass 备份核心流程：决策记录（当前规范，未实施）

> **状态：** 本文是当前备份核心流程的唯一规范来源。只记录已对齐的业务语义与架构边界；不代表生产代码已实现。此前的探索稿保留为讨论历史，但不得作为实现依据。

## 1. 一句话原则

```text
一张照片 / 一个视频 / 一个文件版本
= 一个最小传输与确认单位

批次
= 发现分页、执行窗口、审计汇总
= 不能决定任何文件的成功、失败、暂停、取消或确认
```

审计是对已经发生的状态转换的如实记录，不是传输批次存在的理由，也不拥有业务状态。

---

## 2. 手机本地的三个角色

```text
触发器
  只说明“可能有新的本地变化”；触发可以合并。

发现器
  读取 MediaStore 增量，向手机本地 TransferItem 表可靠写入待传项。

上传消费者
  严格按上传游标，一次处理一张文件；只有终态才前进。
```

手机本地 SQLite / Room 是队列和状态的唯一事实源。Desktop 不拥有手机队列。

---

## 3. 两个游标与一个发现请求标记

### DiscoveryCursor：本地媒体发现游标

```text
含义：MediaStore 本地变化已可靠写入 TransferItem 表到哪里。

建议值：
(lastGeneration, lastMediaId)

排序：
GENERATION_MODIFIED ASC, _ID ASC

下一页条件：
generation > lastGeneration
OR (generation = lastGeneration AND mediaId > lastMediaId)
```

分页必须使用复合游标；只保存 generation 时，同 generation 的后续媒体可能被分页边界跳过。

### UploadCursor：严格上传消费游标

```text
含义：当前严格顺序中，唯一应处理的 TransferItem sequence。

只有下列终态才前进：
- CONFIRMED
- FAILED_NEEDS_USER
- SKIPPED_BY_USER
- CANCELLED_BY_SCOPE
```

`UPLOADING`、`RETRYING`、`PAUSED`、`WAITING_NETWORK` 都不允许跨过当前队头。

### discoveryRequested：触发合并标记

```text
任意 Watch / 前台 / 周期 / 手动事件
  → discoveryRequested = true

它不是待传任务，也不必逐条持久保存。
MediaStore 增量与 DiscoveryCursor 才是媒体变化的事实源。
```

---

## 4. 500 项发现窗口

```text
发现分页大小：500
上传窗口容量：500
```

首次或积压发现时：

```text
发现器从 DiscoveryCursor 取得最多 500 条
  → 一个数据库事务：插入 500 条（或实际条数）TransferItem
  → 同时推进 DiscoveryCursor
  → 提交后唤醒消费者
```

当前 500 窗口未全部进入终态时：

```text
新触发只把 discoveryRequested 置为 true。
不扫描下一窗，不创建新上传任务。
```

当前窗口全部终态后：

```text
如果 discoveryRequested = true
或已知初始增量仍未发现完
  → 从 DiscoveryCursor 发现下一窗最多 500 条。
```

这控制活跃表规模，也不丢任何新媒体：尚未物化的增量仍在 MediaStore 的 DiscoveryCursor 之后。

> “窗口完成”指 500 条都不再阻塞 UploadCursor，不要求 500 条全部成功。

---

## 5. TransferItem：一张媒体版本的一条稳定记录

同一媒体版本的失败、暂停、重试、恢复不创建重复照片记录。

```text
稳定身份字段
- itemId
- pairingEpoch：这条手机本地记录属于哪次配对目标；防止旧队列误发到新电脑
- sourceRef：本地 MediaStore URI / ID
- sourceVersion：generation / 修改时间 / 大小
- bucketId
- createdAt

动态队列字段
- queueSequence：本次排队位置
- deliveryState：QUEUED / UPLOADING / RETRYING / CONFIRMED /
                 FAILED_NEEDS_USER / SKIPPED_BY_USER / CANCELLED_BY_SCOPE
- attemptCount
- nextAttemptAt
- attemptId
- hash（可空）
- lastErrorCode / lastErrorDetail / lastErrorAt
- startedAt / finishedAt

副本存在状态
- sourcePresence：PRESENT / MISSING / UNKNOWN
- remotePresence：PRESENT / MISSING / UNKNOWN
- disposition：NONE / NEEDS_DECISION / REPAIR_REQUESTED /
               KEEP_REMOTE_DELETED / UNRECOVERABLE
```

用户主动重试已失败项时：

```text
itemId 不变
queueSequence 更新为下一窗队尾位置
deliveryState = QUEUED
```

因此上传游标单调前进，旧失败原因也不会被覆盖。

---

## 6. 单张上传流程

```text
UploadCursor 指向 #18
  ↓
确认 sourceRef 对应本地文件能否打开
  ├─ 不可用：分类为临时等待或永久失败
  └─ 可用：继续
  ↓
查询 HashCache：key = sourceRef + sourceVersion
  ├─ 命中：使用已有 hash
  └─ 未命中：此时才计算 hash 并缓存
  ↓
询问 Desktop 是否已有正式 hash
  ├─ 已有：#18 = CONFIRMED
  └─ 没有：上传 #18
  ↓
Desktop 确认进入正式档案
  ↓
#18 = CONFIRMED，UploadCursor 前进
```

发现阶段不计算 hash、不问远端、不读取完整媒体文件。

---

## 7. Pause、网络与电量

### 用户 Pause

```text
Pause 只暂停上传消费者。

- UploadCursor 保持在当前队头
- 当前上传项请求在安全点停止
- 后续项不开始
- 当前发现窗口不补下一窗
- 新触发只置 discoveryRequested
- Continue 清除暂停并唤醒消费者，从当前队头恢复
```

### Wi‑Fi / 电量 / 连接条件

这些也只拦上传消费者，但和 Pause 语义不同：

```text
PAUSED_BY_USER
  用户授权撤回；只能 Continue 恢复

WAITING_NETWORK / WAITING_POWER
  系统条件暂不满足；条件恢复后自动重试当前队头
```

发现器不受 Wi‑Fi/电量产品条件拦截；它不联网、不计算 hash，负责低成本记录本地增量。

---

## 8. 重试与失败

```text
全局条件问题：
没网、Desktop 不可达、Wi‑Fi/电量不满足、系统停止
  → 消费者整体 WAITING_*
  → UploadCursor 不动
  → 不消耗每项失败预算

单文件问题：
本地文件打不开、流异常、协议明确拒绝、hash 不一致
  → 当前 item 指数退避重试
  → 建议：首次尝试 + 2 次重试

预算耗尽：
  → FAILED_NEEDS_USER
  → UploadCursor 前进
  → 用户以后可决定重新尝试或跳过
```

严格顺序意味着临时重试期间不上传后项；只有当前项进入终态后，才处理下一项。

---

## 9. 历史与垃圾控制

```text
活跃队列表
  只保留待传、上传中、重试中和近期待用户处理项。

已确认项
  迁移/压缩为轻量 delivery_evidence：
  sourceRef、sourceVersion、hash、confirmedAt、pairingEpoch、remotePresence。

失败/跳过项
  保留到用户处理或保留期结束；之后归档/清理。

审计事件
  以后独立 append-only 表，独立保留期；不污染活跃队列。
```

---

## 10. 低频远端对账与删除语义

### 对账不是正常上传的前置步骤

```text
5 小时周期：
  本地 MediaStore 增量发现兜底。

远端对账：
  独立低频、分页检查 delivery_evidence 的 hash。
  例如每日、充电 + Wi‑Fi、用户手动，或 Desktop 库变化后。
```

对账不重新 hash 全部手机媒体。Desktop 回报 hash 缺失时，才根据 `sourceRef` 检查手机源是否还在。

### 默认删除策略

P-Pass 当前是单向备份，不是双向删除同步。

```text
手机原图删除、Desktop 副本仍在：
sourcePresence = MISSING
remotePresence = PRESENT
= 正常，不补传、不报警。

Desktop 外部删除、手机原图仍在：
sourcePresence = PRESENT
remotePresence = MISSING
disposition = NEEDS_DECISION
= 不自动补传、不自动删手机；提示用户是否恢复。

Desktop 外部删除、手机原图也没了：
sourcePresence = MISSING
remotePresence = MISSING
disposition = UNRECOVERABLE
= 明确提示无法恢复。
```

Finder 外部删除只能被观察为“Desktop 缺失”，不能被系统猜成明确删除意图。未来若提供 P-Pass 内删除，应使用回收站/tombstone 形成明确删除工作流；本轮不实现。

---

## 11. 还未讨论、留给下一 session 的问题

1. **当前文件 #18 的暂停恢复协议**：现有 Desktop staging 是否能提供 attemptId、可靠 offset、分块校验与 idempotent abort；没有时如何安全地从头重传。
2. **Desktop 缺失后的用户交互**：谁被通知、通知频率、恢复/保持删除的操作入口、外部删除和未来 tombstone 的关系。
3. **远端对账策略**：对账周期、每页 hash 数、Desktop 库重建/版本变化的加速触发、对账中断的 ReconciliationCursor。
4. **手机数据库 schema 与迁移**：配对解绑、重配对、状态库损坏、历史 JSON 状态迁移。
5. **审计模型**：哪些 item 状态转换必须记录，事件保留期与 Desktop 展示汇总。
6. **窗口参数压测**：500 是否合适、发现分页的 API 兼容性、首传大库和大量删除的真实耗时。

---

## 12. 实现前的边界

```text
本轮没有生产代码变更。

下一步实现前：
先把本文映射为领域状态机测试与数据库事务测试，
再接入现有 MediaStore 扫描和 Desktop 传输适配器。

禁止再以 WorkManager name、WorkInfo、JSON 偏好文件或批次 commit
作为上传业务状态的唯一事实来源。
```
