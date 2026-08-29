# ARCH-01 备份核心流程：发现队列与严格单张消费（L2）

> 🟡 状态：设计已收口，待拆实施卡
> 级别：L2 · 阻塞：当前上传项暂停后的 Desktop staging / 断点续传协议尚待定

## 问题

当前备份以大批次 `scan → hash → manifest → push → commit → watermark` 运行。发现、待传、已确认、暂停、失败和远端对账散在多个 WorkManager 通道与状态文件中；一张文件中途失败或用户暂停时，系统很难明确回答“哪张已经交付、哪张待传、下一张能否开始”。远端外部删除与手机原图删除也没有独立的事实状态，容易把“观察到副本缺失”误作“应自动重传”。

## 期望行为

- 一张照片/视频/文件版本是上传、确认、失败、暂停和取消的最小单位；批次仅是发现分页、执行窗口和审计汇总。
- 触发只合并为发现请求；发现器将 MediaStore 增量可靠写入手机本地队列。
- 上传消费者用严格 UploadCursor 一张一张处理，只有当前项进入终态才前进。
- 500 项发现窗口控制活跃表规模；窗口未完成时新触发只记录 `discoveryRequested`，窗口终态后才发现下一窗。
- Pause 只暂停消费者；hash 仅在当前单项将要上传时计算/命中缓存。
- 远端对账独立低频分页，Desktop 外部缺失默认只产生待用户决定的事实，不自动补传或删除手机原图。

## 验收标准

- [x] 当前核心流程决策已在本卡“已收口设计”逐条落库。
- [x] `.hermes/` 仅保留指向本卡与 `docs/QUEUE.md` 的索引，不承载设计正文或任务事实。
- [x] `docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md` 同步本卡状态。
- [ ] 下一轮先收口当前上传项暂停时的 Desktop staging / attempt / offset / abort 协议，再据此重整可执行 case。
- [ ] 以重整后的 case 为准，先写状态机与数据库事务的失败测试，再开始生产实现。

## 范围

- 只准动：本卡、`docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md`、`.hermes/README.md`。
- 不准动：`apps/`、`crates/`、现有备份实现、现有未提交任务卡。

## 阻塞与依赖

- 当前上传项在 Pause 时，Desktop 是否具备稳定 `attemptId`、可验证 byte offset / chunk map、幂等 abort 与 staging cleanup 语义尚待讨论。
- 本卡设计完成后，需按范围拆出数据库、发现器、消费者、传输协议、对账与 UI 的实施卡；禁止直接把整套重构塞进一张卡。

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
```

发现查询按 `(GENERATION_MODIFIED, _ID)` 升序；复合游标避免分页边界遗漏同 generation 的媒体。

### 3. 500 项发现窗口

```text
发现分页大小 = 500
上传窗口容量 = 500

发现一窗：
MediaStore 增量最多 500 条
→ 一个数据库事务插入 TransferItem
→ 同时推进 DiscoveryCursor
→ 提交后唤醒消费者
```

当前窗口未全部终态时，新触发只置 `discoveryRequested=true`。当前 500 项全部成为 `CONFIRMED`、`FAILED_NEEDS_USER`、`SKIPPED_BY_USER` 或 `CANCELLED_BY_SCOPE` 后，若仍有未发现增量或触发标记，再发现下一窗。

### 4. TransferItem 手机本地表

```text
稳定身份：
itemId、pairingEpoch、sourceRef、sourceVersion、bucketId、createdAt

动态队列：
queueSequence、deliveryState、attemptCount、nextAttemptAt、attemptId、hash、错误与时间

副本事实：
sourcePresence、remotePresence、disposition
```

`pairingEpoch` 只防旧队列在重配对后误发到新电脑；队列物理上属于手机本地数据库。

同一媒体版本重试不新建重复照片记录：保持 `itemId`，需要用户重试时更新 `queueSequence` 到下一窗队尾。

### 5. 单张上传

```text
UploadCursor 指向当前项
→ 确认 sourceRef 可读
→ 用 sourceRef + sourceVersion 查询 HashCache
→ 未命中时计算 hash
→ 问 Desktop 是否已有正式 hash
→ 已有则确认；缺失则上传
→ Desktop 正式确认后才 CONFIRMED
```

发现阶段不计算 hash、不问远端、不读取完整文件。

### 6. Pause、条件与重试

```text
用户 Pause：
- 只暂停上传消费者
- UploadCursor 停在当前项
- 后续项不开始
- 新触发只合并，不发现下一窗

网络/电量/Desktop 不可达：
- 消费者 WAITING_*
- 条件恢复后自动从当前队头重试
- 不消耗每项失败预算

单文件问题：
- 当前项指数退避（首次 + 2 次重试）
- 耗尽后 FAILED_NEEDS_USER
- UploadCursor 才进入下一项
```

### 7. 远端对账与删除

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

## 下一 session 启动与关闭

### 启动

只讨论、不实施：先解决当前上传项 Pause 时的 Desktop staging 协议。

```text
需要确认：
- stable attemptId / stagingId
- 已验证 offset / chunk map
- 本地版本不变判定
- 幂等 abort 与 cleanup
```

有可靠 offset 才允许字节级续传；否则当前项仍为队头，但从文件起点重传，partial staging 只作为待清理残留。

### 关闭

本轮若有新结论，只更新本卡“已收口设计”并同步 `docs/QUEUE.md`；未得到用户明确许可前，不改生产代码、不提交、不推送。
