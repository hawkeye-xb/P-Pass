# ARCH-01 备份核心流程：发现队列与严格单张消费（L2）

> 🟡 状态：设计已收口；ARCH-02~05 首批实施卡待验收人 review，未通过前禁止实施
> 级别：L2 · 传输裁决：单一原生 iroh-blobs fetch/resume；不新增 raw upload 重传协议
> 中英文设计归档：[中文](../docs/design/2026-08-29-arch01-backup-core/README.zh-CN.md) · [English](../docs/design/2026-08-29-arch01-backup-core/README.md) · [Case Matrix](../docs/design/2026-08-29-arch01-backup-core/04-case-matrix.zh-CN.md)

## 问题

当前备份以大批次 `scan → hash → manifest → push → commit → watermark` 运行。发现、待传、已确认、暂停、失败和远端对账散在多个 WorkManager 通道与状态文件中；一张文件中途失败或用户暂停时，系统很难明确回答“哪张已经交付、哪张待传、下一张能否开始”。远端外部删除与手机原图删除也没有独立的事实状态，容易把“观察到副本缺失”误作“应自动重传”。

## 期望行为

- 一张照片/视频/文件版本是上传、确认、失败、暂停和取消的最小单位；批次仅是发现分页、执行窗口和审计汇总。
- 触发只合并为发现请求；发现器将 MediaStore 增量可靠写入手机本地队列。
- 上传消费者用严格 UploadCursor 一张一张处理，只有当前项进入终态才前进。
- 500 项发现窗口控制活跃表规模；窗口未完成时新触发只记录 `discoveryRequested`，窗口终态后才发现下一窗。
- 当前项只通过原生 iroh-blobs fetch/resume 传输；业务层不自定义 offset、chunk map 或第二套 raw 上传协议。
- Pause、条件等待、范围修改与取消本轮分别表达；hash 仅在当前单项将要传输时计算/命中缓存。
- 远端对账独立低频分页，Desktop 外部缺失默认只产生待用户决定的事实，不自动补传或删除手机原图。

## 验收标准

- [x] 当前核心流程决策已在本卡“已收口设计”逐条落库。
- [x] `.hermes/` 仅保留指向本卡与 `docs/QUEUE.md` 的索引，不承载设计正文或任务事实。
- [x] `docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md` 同步本卡状态。
- [x] 当前项暂停、条件中断、范围修改、取消本轮与恢复的业务语义已收口；传输统一为原生 iroh-blobs fetch/resume。
- [ ] 以重整后的 case 为准，先写状态机与本地原子提交的失败测试，再开始生产实现。

## 范围

- 只准动：本卡、`docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md`、`docs/design/2026-08-29-arch01-backup-core/`、`.hermes/README.md`。
- 不准动：`apps/`、`crates/`、现有备份实现、现有未提交任务卡。

## 阻塞与依赖

- 设计无待拍板项。实施前须拆出手机账本、发现器、消费者、原生 blob provider/fetch 准入、范围与取消本轮、对账和 UI 卡；禁止直接把整套重构塞进一张卡。

---

## 已收口设计

### 1. 单位与职责

```text
单张文件
= 最小上传、确认、失败、暂停单位

批次
= 发现分页 / 500 项窗口 / 执行与审计汇总
= 不决定文件命运

触发器
= 只标记“可能存在新媒体”

发现器
= MediaStore 增量 → 手机本地队列

上传消费者
= UploadCursor 严格单张消费
```

审计只如实记录已经发生的状态转换，不是上传批次存在的理由。

### 2. 两个游标与触发合并

```text
DiscoveryCursor
= (lastGeneration, lastMediaId)
= 本地媒体已可靠写入队列的位置

UploadCursor
= 当前严格应处理的 queueSequence

DiscoveryRequested
= 任意 Watch / 前台 / 周期 / 手动触发的合并标记

ScopeRevision
= 当前相册范围的版本；减少范围时替换旧版本

CancellationRound
= 当前“取消本轮”的持久记录；取消尚未完成时，任何新入本轮待传列表的项直接取消
```

发现查询按 `(GENERATION_MODIFIED, _ID)` 升序；复合游标避免分页边界遗漏同 generation 的媒体。

### 3. 500 项发现窗口

```text
发现分页大小 = 500
上传窗口容量 = 500

发现一窗：
MediaStore 增量最多 500 条
→ 一次本地原子提交插入 TransferItem
→ 同时推进 DiscoveryCursor
→ 提交后唤醒消费者
```

当前窗口未全部终态时，新触发只置 `discoveryRequested=true`。当前 500 项全部成为 `CONFIRMED`、`FAILED_NEEDS_USER`、`SKIPPED_BY_USER`、`CANCELLED_BY_SCOPE` 或 `CANCELLED_BY_USER_ROUND` 后，若仍有未发现增量或触发标记，再发现下一窗。

### 4. TransferItem 手机本地表

```text
稳定身份：
itemId、pairingEpoch、scopeRevision、sourceRef、sourceVersion、bucketId、createdAt

动态队列：
queueSequence、deliveryState、attemptCount、nextAttemptAt、hash、错误与时间

副本事实：
sourcePresence、remotePresence、disposition
```

`pairingEpoch` 只防旧队列在重配对后误发到新电脑；队列物理上属于手机本地账本。

同一媒体版本重试不新建重复照片记录：保持 `itemId`，需要用户重试时更新 `queueSequence` 到下一窗队尾。

一台手机只绑定当前 `pairingEpoch` 的一台 Desktop；一台 Desktop 可服务多台手机。每台手机的队列、游标、范围版本、取消边界和 fetch lease 相互隔离。当前不设计多 Desktop RBAC；手机 blob provider 只准入当前已配对 Desktop，Desktop 只对本地有效队列发起 fetch。

### 5. 单张上传

```text
UploadCursor 指向当前项
→ 确认 sourceRef 可读
→ 用 sourceRef + sourceVersion 查询 HashCache
→ 未命中时计算 hash
→ 校验当前 pairingEpoch、ScopeRevision、消费者 gate 与无活动中的 CancellationRound
→ Desktop 对手机的同一 content hash 发起原生 iroh-blobs fetch
→ 已有 partial 时由原生协议续传；没有 partial 时同一协议自然从起点 fetch
→ 完整 blob 经原生校验后 materialize / ingest
→ Desktop 正式确认后才 CONFIRMED
```

发现阶段不计算 hash、不问远端、不读取完整文件。

### 6. 消费者门控、条件与重试

```text
用户 Pause：
- 只暂停上传消费者
- UploadCursor 停在当前项
- 后续项不开始
- 新触发只合并，不发现下一窗
- 当前 native fetch 立即停止，但有主 partial blob 保留
- 网络恢复本身不得自动 Continue；只有用户 Continue 才恢复

条件不满足（Wi-Fi 开关、电量低于阈值、Desktop 不可达等）：
- 消费者 WAITING_FOR_CONSTRAINTS
- 不改变范围、取消边界、队列归属或 UploadCursor
- 当前 native fetch 停止；有效 partial 保留
- 条件恢复后自动从当前队头继续；不消耗每项失败预算

每次唤醒的准入顺序：
backupEnabled + pairingEpoch + ScopeRevision + 无活动中的 CancellationRound
→ consumerGate 非 PAUSED
→ 条件满足
→ 取得当前 #18 的 fetch lease
→ 才允许 native fetch / finalise

单文件问题：
- 仅源不可读、完整性失败或协议永久错误消耗每项失败预算
- 当前项指数退避（首次 + 2 次重试）
- 耗尽后 FAILED_NEEDS_USER
- UploadCursor 才进入下一项
```

`WAITING_FOR_CONSTRAINTS` 不是 `PAUSED_BY_USER`。前者在条件恢复后自动继续；后者只响应用户 Continue。

### 7. 修改范围

```text
增加相册：
当前窗口与当前 #18 不变
→ 为新增相册记录历史补扫请求
→ 当前窗口终态后，按新增相册完整发现
→ 结果追加到后续窗口

减少相册：
先停止消费者并提示影响
→ 用户确认后 ScopeRevision: R1 → R2
→ R1 未获 Desktop 完整保存凭据的项 = CANCELLED_BY_SCOPE
→ 撤销 R1 fetch lease；没有完成凭据的 R1 partial 不得 finalise
→ R2 保持 PAUSED，等待用户 Continue
→ R2 对新范围完整发现，再从 R2 队头消费
```

增加相册不能沿用旧全局 DiscoveryCursor，否则新增相册中早于旧水位的媒体会漏掉。减少相册不逐项网络取消；先持久化新的 `ScopeRevision`，撤销未完成项的 fetch lease。已经拿到 Desktop“完整接收、验证并可靠保存”的完成凭据的项，无论回执何时抵达，都必须记为 `CONFIRMED`；没有这份凭据的旧项才不得在新范围下继续完成。已 `CONFIRMED` 的副本不随改范围自动删除。

### 8. 取消本轮与恢复

不提供逐文件 Cancel。仅在用户 Pause 后展示 `Cancel Current Round`；它表达“取消本轮所有未完成待传照片”。已经 `CONFIRMED` 的照片保留完成事实。

```text
Cancel Current Round：
→ 先持久化活动中的 CancellationRound
→ 当前 native fetch 已因 Pause 停止
→ 已物化的未确认 TransferItem = CANCELLED_BY_USER_ROUND
→ 按最多 500 项继续发现本轮其余候选；每项直接标记取消，不得上传
→ CancellationRound 活动期间新入待传列表的项，也直接标记取消
→ 重复直到本轮待传列表为空；原子结束 CancellationRound
→ 结束后才入队的照片属于下一轮，仍按原 consumerGate 处理

Restore Cancelled Round（仅用户显式操作）：
→ 对该轮取消项重新准入并按新窗口排序
→ 已确认内容去重，未确认内容重新入队

Discard Cancelled Round：
→ 关闭该轮快捷恢复入口；不影响以后新增照片的正常入队
```

`CancellationRound` 不是只取消眼前 500 项的标记，也不是按时间切一刀后任由未扫描旧项失踪；它是可重启的取消扫描过程。取消过程中崩溃时，从其进度继续；同一账本的提交顺序决定并发项归属：在结束记录前入队则取消，结束记录后入队则属于下一轮。`Discard` 不等于永久逐媒体黑名单，永久忽略属于独立的范围/排除规则能力。

### 9. 远端对账与删除

```text
5 小时周期：本地 MediaStore 增量发现兜底
低频对账：分页检查已确认 hash 是否仍在 Desktop
```

对账不重新 hash 全部手机媒体。Desktop 缺失时才检查本地 `sourceRef`：

```text
手机在、Desktop 缺失：
remotePresence=MISSING
sourcePresence=PRESENT
disposition=NEEDS_DECISION
→ 不自动补传，提示用户是否恢复

手机没、Desktop 缺失：
remotePresence=MISSING
sourcePresence=MISSING
disposition=UNRECOVERABLE
→ 明确提示无法恢复

手机没、Desktop 在：
= 正常备份结果，不报警
```

P-Pass 当前是单向备份，不是双向删除同步。Finder 外部删除只能被观察为 Desktop 缺失，不能被猜成明确删除意图；未来若提供 P-Pass 内删除，应通过回收站/tombstone 建立独立删除流程。

## 后续拆卡入口

```text
按以下边界拆实施卡：
- 手机账本：ScopeRevision、CancellationRound、消费者 gate、fetch lease 与状态迁移
- 发现器：新增相册补扫、减少相册重建、取消本轮期间的发现准入
- 消费者：严格 UploadCursor、条件重验、Pause/Continue/Cancel Current Round
- 传输 adapter：手机 blob provider、单配对 Desktop 准入、Desktop 原生 fetch/resume、完成证据
- partial 生命周期：有主保留、失主回收、重启恢复与 finalise 竞态
- UI：范围减少提示、暂停/等待差异、取消本轮/恢复/丢弃入口
```

实施顺序仍是：先以失败测试锁定本地原子提交与竞态，再接原生传输 adapter，最后接调度与 UI。不得在实现卡中重新定义本卡语义。
