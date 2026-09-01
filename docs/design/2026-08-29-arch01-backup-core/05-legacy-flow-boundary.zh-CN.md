# REBUILD-00：Legacy / Flow 边界与测试分类

> 2026-09-01 · 依据：REBUILD-00、ARCH-01、Case Matrix
> 这份清单只定义生产切换的边界；不改变旧批次行为，也不把旧测试当作新 Flow 门禁。

## 代码边界

| 区域 | 职责 | 规则 |
|---|---|---|
| `backup/`（legacy） | 旧 `BackupWorker → BackupRunner → manifest/push/commit`、`ConfirmedStore`、`ReuploadQueue` 及其 WorkManager/批次状态 | 仅维持当前可编译；不得新增功能、不得成为新 Flow 依赖。入口和状态文件均标记 `LEGACY`。 |
| `backup/flow/` | `DiscoveryLedger`、严格 `UploadCursor` 消费、Pause/约束 gate、fetch lease、completion receipt、取消轮、pairing epoch、对账事实及后续生产 adapter | 新生产核心唯一落点；不得 import 或全限定引用 `BackupWorker`、`BackupRunner`、`ConfirmedStore`、`ReuploadQueue`、`WatermarkStore`。`FlowBoundaryTest` 强制检查。 |

`backup/flow/` 当前是 ARCH-02～09 的未接生产骨架。REBUILD-01 只可在此边界接 Android blobs provider；REBUILD-03 才将触发、发现、严格消费和 completion receipt 接成真实生产路径；REBUILD-04 才把 Worker 降为 framework wake adapter。

## 旧测试分类

分类针对触碰旧生产批次线的测试。**冻结**表示文件暂留、可继续编译，但不允许为了它改回旧机制，也不作为 REBUILD-01～04 的行为门禁。保留的产品语义必须以 ARCH-01 Case Matrix 重新表述后才可成为新门禁。

### 仍属产品不变量：重写，不复用旧测试形状

| 现有测试 | 保留的用户语义 | 新 Flow 对应 |
|---|---|---|
| `NoScopeNoBackupTest` | 未选范围时不得传任何照片 | Flow discovery 的范围准入；待 REBUILD-03 新 case |
| `BadMediaRecordTest` | 单个不可读源不得卡死后续项目 | C-05：当前项最终 `FAILED_NEEDS_USER` 后严格前进 |
| `ScopeBackfillTest` | 范围变动不得漏掉或误传项目 | E-02/E-03 与 ARCH-01 scope/backfill 规则 |
| `ResumeAfterPauseTest` | 用户 Pause 后只有明确 Continue 才恢复 | C-01～C-03 |
| `FailedRetryIsNotPausedTest` | 条件/失败与用户 Pause 必须可区分 | C-02/C-04/C-05 |

这些旧测试保持冻结；REBUILD-03/04 在用户确认的新行为后，以 `backup.flow` 的公开账本投影新增失败 case，而不是迁移 WorkManager 文本断言。

### Legacy 机制：冻结，不再作为新 Flow 门禁

| 测试 | 被取代的机制 |
|---|---|
| `ConfirmedStoreTest`、`CalibrationTest`、`ReuploadCompensationTest`、`ReuploadNoticeTest` | 旧 confirmed cache / exist-check / 定向重传队列 |
| `DaemonBackupTest` | `manifest → push → commit` 端到端批次 |
| `WatermarkStoreTest`、`BackupAttemptStoreTest` | 全局 watermarked batch 与 batch retry 计数 |
| `OneBackupPipelineTest`、`OnePipelineOnePauseTest` | WorkManager 多通道聚合、旧进度与暂停模型 |
| `TriggerPolicyTest`、`MediaWatchJobTest`、`WatchRecoveryTest`、`BackupHealthTest`、`ForegroundSyncNotFrozenTest` | 旧 Worker/JobScheduler 调度与后台恢复接线 |
| `MediaQueryFailureTest` | 旧 confirmed triplet UI 口径 |

### 未定：在对应生产切换卡重新裁决

| 测试 | 原因 | 裁决卡 |
|---|---|---|
| `HashCacheTest` | 缓存可复用，但 ARCH-01 改为仅在当前队头即将 fetch 时计算/命中，旧“批次预哈希”时序不可继承 | REBUILD-03 |
| `PairingLostTest` | “配对失效必须可见并阻止交付”仍可能成立，但旧 raw push 错误文本不是新 blobs adapter 契约 | REBUILD-01 / REBUILD-04 |

其余不触碰旧批次生产链的偏好、设置或 UI 单元测试不在本次冻结清单内；它们不代表新 Flow 的传输或消费者契约。
