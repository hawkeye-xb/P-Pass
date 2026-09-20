# MOB-87 对账机制全线未接：重新配对不开传、桌面缺失永不补传、静默失败无痕迹

状态：🟥 挂号
级别：L2（跨 UI 状态机、唤醒调度与账本对账，要真机验）
关联: 从 [NET-25](done/NET-25-flow-delivered-push-unverified-on-the-real-transfer-path.md) 的验收日志里捞出 ·
兄弟卡 [MOB-72](MOB-72-scope-selection-must-wake-flow-without-relaunch.md)（同一症状，触发条件是"选相册"）·
邻居 [MOB-62](MOB-62-unpair-must-reset-flow-runtime-and-wakes.md)（管的是断开后**旧**状态要清掉，不管新会话要不要起跑）·
桌面侧对位警告 [MOB-29](done/MOB-29-confirmed-store-lies-between-backups.md)（`apps/desktop/src/lib/externalDelete.js`，已上线）

---

## 这张卡管什么

原挂号只有一条症状（重新配对后不开传）。2026-09-20 顺着它往下查，发现它是
**同一条链上的第五环**——这条链从头到尾没有一处接上过，所以合并成一张卡。

链的两端：

```
手机账本说"这张我传成功了(CONFIRMED)"
  → 【谁去核实？】 ← 这一环从来没人接
桌面上这张还在不在
```

六件事，同一批文件，一个分支：

| # | 缺陷 | 位置 |
|---|---|---|
| 1 | 重新配对成功后没有任何人叫醒 Flow | `MainActivity.kt:228,237` |
| 2 | 对账函数**生产零调用方** | `ReconciliationCoordinator.reconcilePage` |
| 3 | 对账**永远只看前 500 条**，没有游标 | `ReconciliationCoordinator.kt:17-18` |
| 4 | epoch 过滤会让保留下来的账本项**全部落空**（3 处） | `ReconciliationCoordinator.kt:13`、`RemoteReconciliation.kt:10,37` |
| 5 | 对不上账时**静默 return**，外面分不出正常和故障 | `ReconciliationCoordinator.kt:20` |
| 6 | 桌面缺失后没有补传路径 | `RecoveryDisposition` 只有计数，没有消费者 |
| 7 | 断开时删掉账本，#4 的迁移无从谈起 | `AndroidFlowRuntime.kt:323` |

**桌面侧一行不用改。** `backup.presence`（`backup.rs:231` / `router.rs:708`）
已完整实现并接线，收一批 hash 回一批"我没有的"，行为正确。

### ⚠️ 本卡推翻 MOB-62 的一条验收标准

[MOB-62](MOB-62-unpair-must-reset-flow-runtime-and-wakes.md)（issue #82，已关闭）
验收标准写着「旧 remote Flow ledger **删除**」。本卡要求**保留**。

这不是打架，是把手段和目的分开：MOB-62 要的是「断开后旧会话不能再运行」
（症状是旧 offer 乱发、ANR、崩溃），删账本只是它当时选的手段。保留账本文件、
断开时照常关 runtime / provider / 取消所有 wake，MOB-62 的目的依然满足——
**保留的是数据，关掉的是执行**。

已核实**没有任何测试锁定删除行为**（`apps/android/app/src/test` 下的
`deleteRecursively()` 全是 tmpdir 清理，不是断言）。MOB-62 卡面那一条本卡合入
后作废，改动记在这里，不回改已归档的卡。

---

## 产品规则（2026-09-20 验收人定调）

> **手机上还有源 → 桌面上就必须有。桌面为什么没有，不问。**

想让备份里没有某张照片，**去手机上删**。手机没源了，对账自然不会补，桌面
也就干净了。

这跟 ADR-006「originals 是真相」是同一条规则的两端：对桌面库而言磁盘是真相，
对备份而言手机相册是真相。

### 由此推出的三条，写死，实现时不要再发挥

1. **补传不做归因。** 不区分"桌面用户主动删的"和"文件意外没了"。做了归因，
   桌面误删就会被判成"故意"而不补传，手机上那份后来再被清理 → 彻底丢失。
   **备份的稳定性正好死在这个分支上。** 墓碑（`audit_tombstone`）在本卡范围内
   **不参与任何判断**——它是 `Reconcile` 被动发现"文件不见了"的记录，不是
   一个删除功能的授权凭证。

2. **手机端零新增 UI。** 补传就是备份，走首页已有的备份状态显示。该被警告的
   是在这台电脑上删东西的那个人，警告已经在桌面上了（MOB-29，2026-08-25
   验收人定调，已上线：24 小时窗口 + 可 dismiss + 再删再现）。手机这边的家人
   什么都没做错，也什么都做不了，给他弹窗只会变成第二个"已跳过"——不紧急、
   不强烈、点了没用，看几次就开始被无视。

3. **`UNRECOVERABLE` 只落审计，不提示。** 「手机源没了 + 桌面也没了」这个组合
   拦不住（桌面被误删、或维护者明确知道自己在干嘛），跟用户自己 copy 文件出去
   一样管不了。它**唯一的价值是给我们查"账本说谎"**——我们标了 CONFIRMED 但
   桌面其实从来没有过，只有在手机源也删掉之后才会暴露成这一类。读者是我们，
   不是用户。

---

## 根因（逐条，均已源码核实）

### 1. 重新配对不唤醒

`MainActivity.kt:228` 的 `foregroundCatchup`（负责 `scheduleAutoBackup` +
`triggerUserPresentBackup`）挂在 `LaunchedEffect(backupInterrupted)` 上
（`:237`）。触发键只有 `backupInterrupted`——**配对状态不在键里**。
`pairings.load() != null` 只是函数体内的门控，不是触发条件。于是：

- App 启动时首次组合 → 跑一次 → 已配对就补捞（这解释了"重开就好"）；
- 会话内重新配对 → `backupInterrupted` 没变 → `LaunchedEffect` 不重跑 →
  没有任何人叫醒 Flow。

`foregroundCatchup` 还有第二个调用点——`Lifecycle.Event.ON_RESUME`（`:401`，
MOB-38 补的）。**它也接不住这一例**：会话内扫码重新配对，用户人一直在 App 里，
Activity 没走过 STOPPED → RESUMED，`ON_RESUME` 根本不触发。两个调用点一个按
composition 键、一个按生命周期，**配对成功这个状态跃迁两个都不在其中**。

对照组就在同一文件里：选相册那条路（`:900`）显式调了
`requestFlowScopeBackfillAndWake` + `triggerUserPresentBackup`——那是 MOB-72
的修法。**配对成功那条路没有对应的一行。**

⚠️ `foregroundCatchup` 的注释自己写着「提成函数不是为了少打字，是为了**让
「漏接一处」变得不可能**」，还列了 MOB-33/34/35/38 四个同形状的 bug。本卡
是第五个——修的时候该想的是「还有哪些用户在场的状态跃迁没接」，而不是只给
配对补一行。

### 2. 对账生产零调用方

`reconcilePage` 全仓引用只有三处：定义本身 + `ARCH01ReconciliationCoordinatorTest`
的两处。**生产代码零调用。** 因果链一路走到底：

```
对账从没跑过
  → remotePresence 恒为默认 UNKNOWN (DiscoveryLedger.kt:231)
  → disposition 从没被写过，恒为 NONE
  → flowReuploadNoticeCount 恒为 0 (FlowUiProjection.kt:159)
```

代码注释自证：

> `BackupUiStateHolder._reuploadNoticeCount` has no production writer —
> `reuploadNoticeCount > 0` is permanently **false**, so the notice card can
> **never** appear
> — `FlowUiProjection.kt:148`

5 小时的周期 Worker（`PERIODIC_FALLBACK_HOURS = 5`）确实在跑，但它醒来只调
`runFlowWake`——**扫新照片、传新照片**，顺着游标往前走，不回头。对账是另一个
函数，那个闹钟没叫过它。

### 3. 永远只看前 500 条

```kotlin
.sortedBy { it.queueSequence }
.take(REMOTE_PRESENCE_PAGE_SIZE)   // = 500
```

没有游标，过滤条件里也**不排除上一轮已确认 PRESENT 的项**。跑一百轮都是同一批
前 500 张。库里有 10000 张，第 501 张往后的**一次都不会被核实**。这不是
"分页慢慢对完"，是"永远对不到"。

### 4. epoch 过滤三处

`item.pairingEpoch == snapshot.pairingEpoch` 出现在三个地方：

| 文件 | 行 | 作用 |
|---|---|---|
| `ReconciliationCoordinator.kt` | 13 | 决定 page 里有谁 |
| `RemoteReconciliation.kt` | 10 | `recordRemotePresent` 写回时 |
| `RemoteReconciliation.kt` | 37 | `recordRemoteMissing` 写回时 |

`pairing_epoch` 本身是 16 字节随机数（`pairing.rs:327` `fresh_pairing_epoch`），
**不是密钥**——稳定密钥是 `identity.key`，它从不轮换（`main.rs:276` 有硬校验）。
epoch 作为**授权凭证版本**轮换是正确的，本卡不动这一点。

缺陷是 epoch **同时**被当成了内容账本的分区键。内容传没传过，跟"这次授权是第几轮"
没有关系。后果已实测：95 张照片、4 次重连，桌面 `flow_delivery` 记了 603 行。

一旦账本在断开后保留（见下），保留项带旧 epoch、snapshot 已是新 epoch，
三处判据全部落空。只放宽第 13 行没用——后两处写回照样一条都匹配不上，而且
**更隐蔽**：`remoteMissing()` 网络请求真发出去了、回调真跑了，只是
`ledger.update` 里没有一个 item 命中。

### 5. 静默 return

```kotlin
if (page.isEmpty()) return      // 不抛、不打日志、不落审计，返回 Unit
```

调用方拿到的**"对完账了，全都在"**和**"一条都没对上"**是同一个返回值。

`page.isEmpty()` 在写的时候是对的：刚装好、还没传过东西，账本里就是没有
CONFIRMED 项，本来就该安静返回。它错在"保留账本"这个新语义让「空」长出了
第二种含义：

- 空 ①：确实没东西可对 → 安静返回，正确
- 空 ②：有 N 条 CONFIRMED，但全被 epoch 过滤掉了 → 这是故障

同一个 `isEmpty()` 现在同时承载正常和异常，而代码分不出来。

对照同一个包里别处怎么写的：`CompletionAndScope.kt:29` 遇 epoch 不匹配是
`snapshot.rejected("receipt", "pairing_epoch_changed", ...)` 落审计；
`RemoteReconciliation.kt:31` 遇 `UNKNOWN` 直接 `error(...)` 抛。**这套代码到处
都把"我拒绝了"记下来，唯独这一行是裸 `return`。**

### 6. 没有补传路径

`RecoveryDisposition.NEEDS_DECISION` 唯一的消费者是
`flowReuploadNoticeCount`（一个计数）。没有任何东西把这些项退回队列，UI 上
也没有触发重传的入口。

---

## 期望行为

1. **重新配对成功** → 立即叫醒 Flow（沿用原相册选择，不必重走 onboarding）
   ，并主动跑一轮对账。不需要杀 App 重开。
2. **5 小时周期 Worker 醒来** → 扫新照片之外，顺带跑一轮对账（兜底）。
3. **对账翻页翻到底** → 跨轮推进，全部 CONFIRMED 项最终都被核实，不只前 500。
4. **桌面缺失 + 手机源还在** → 退回队列，无提示补传，走已有备份状态显示。

   **写死：原地把该项翻回 `QUEUED`，不新发条目。** 不能新发——
   `commitDiscoveryPage` 按 `stableId` 去重（`DiscoveryLedger.kt:390`），
   同一张照片第二次根本进不来。原地翻安全的理由已核实：`headOf`
   （`StrictConsumer.kt:324`）在 `uploadCursor` 为 null 时取
   `firstOrNull { QUEUED }`，而 `items` 恒按 `queueSequence` 排序，
   所以翻回去的老项会被自然选中；`acceptCompletionReceipt` 里
   `next = items.firstOrNull { QUEUED }` 同理，游标回退到老序号不会丢头。
   实现前先为这条写 contract 测试。

5. **探测失败（桌面离线/不可达）** → 这轮不对账，等下一轮，**不落任何审计**。
   `RemotePresenceProbe.missing` 里 `check(response.ok)` 会抛，`reconcilePage`
   现在没有 catch——挂到 5 小时 worker 上桌面一关机这轮就炸。纪律同
   `reconcile.rs:125`「对账是收敛手段，一轮失败等下一轮」。
   **别让离线把「静默失败」那条审计刷成噪音**——那条是留给
   「账本有 CONFIRMED 但 page 空」的。
6. **桌面缺失 + 手机源也没了** → 标 `UNRECOVERABLE`，落审计事实，**不提示**。
7. **重新配对后** → 保留的账本项认领到新 epoch（只改归属，`deliveryState` /
   `contentHash` / `completedAt` 等事实一个字不动）。
8. **账本里有 CONFIRMED 项、却一条都没进对账页** → 落一条审计事实走已有的
   审计 outbox。**不抛异常**。

---

## 验收标准（红→绿，去掉故障条件必须变红）

1. **E2** 重新配对成功后，无需重启进程，Flow 在约定时限内发出第一个 offer。
   去掉配对成功那条唤醒 → 红。
2. **E2** 一轮对账后，桌面缺失且手机源仍在的项回到 `QUEUED`。
   去掉补传路径 → 红。
3. **E2** 账本 1200 项、页大小 500 → 连续三轮对账覆盖全部 1200 项。
   **保留现在的 `take(500)` 无游标写法 → 红**（第 501 项起永远
   `remotePresence == UNKNOWN`）。

   ⚠️ **同一条测试必须再断言：全部核实成 PRESENT 之后再跑一轮，对账要
   重新从第 1 项开始。** 要的是**循环游标**（持久化
   `lastReconciledQueueSequence`，走到尾回头归零），不是「过滤掉已 PRESENT
   的项」。后者也能让这条测试的前半段变绿，但首轮对完之后 page 永久为空、
   **再也不复查**——桌面在那之后删掉一张就永远发现不了，正好是本卡要解决
   的问题，只是推迟到了首轮之后。没有这条断言，按字面实现会全绿而产品照样坏。
4. **E2** 重新配对后账本项被认领到新 epoch，且 `deliveryState` / `contentHash` /
   `completedAt` / `queueSequence` 逐字段不变。去掉迁移 → `page` 空 → 红。
5. **E2** 账本含 N 条 CONFIRMED 但对账页为空时，审计 outbox 里出现对应事实，
   且函数不抛。**去掉这条 → 红**（这条专门把「静默失败」钉成可检测）。
6. **E2** `recordRemotePresent` / `recordRemoteMissing` 在账本项 epoch 与
   snapshot 一致时写回成功——覆盖 `RemoteReconciliation.kt:10,37` 两处，防止
   只改了 Coordinator 就以为修完了。
7. **E2** `UNRECOVERABLE` 项不进入任何 UI 投影计数。
8. **E3 真机** 三星 SM-S9210：断开 → 重新扫码 → 沿用原相册 → 不杀 App，
   传输自动开始；桌面 Finder 里删掉若干张 → 断开重连一次触发对账 → 这些
   照片自动回到桌面，**手机端全程无新增提示**，桌面端出现 MOB-29 那条警告。

   **用「重新授权」这个触发点验，不要等 5 小时闹钟**——否则真机那天会卡在
   等待上。周期触发那条走 E2。

9. **E2** 桌面不可达时 `reconcilePage` 不抛、不落审计，下一轮正常对账。
10. **E1** `just ci` 全绿。

---

## 不在本卡范围

- **桌面侧任何改动。** `backup.presence` 行为已正确，墓碑只写不读，补传会被
  正常接收。
- **「相册里的照片有没有全部进过账本」。** 对账拿**账本**跟桌面比，不是拿
  **相册**跟桌面比。账本里压根没有的照片，对账看不见——这是另一个问题，
  另开卡。
- **epoch 轮换本身。** 它作为授权凭证版本轮换是对的，保留。
- **断开时到底清哪些别的文件**（`auto_backup_prefs.json` / `backup.watermark` /
  `backup_health.json` / `sentinel.json` / `pairing.json` /
  `iroh-blobs-provider/`）——本卡只动 `flow-state/` 下的账本（缺陷 #7），
  其余文件的清理策略另议。

---

## 原始挂号记录（2026-09-17，复现步骤保留）

- **现象**：App 内断开连接 → 重新扫码配对成功 → 沿用原来的相册选择（没有
  重新选）→ **什么都不发生**。验收人等了约 9 秒，把 App 划掉重开，1.7 秒后
  传输就开始了，25 张 5.4 秒跑完。
- **发现场景**：2026-09-17 做 NET-25 真机验收时，验收人自发做的一次断开重连，
  日志正好完整覆盖。

**时间线（两个独立来源对齐，全部有原始日志）**

| 时刻 | 事件 | 出处 |
|---|---|---|
| 13:28:57 | 上一轮 `flow.round.finished` | daemon 审计 |
| 13:29:24 | `device.unpaired`——用户断开 | daemon 审计 |
| 13:29:26 | `pair.requested` + `pair.accepted`——重新扫码完成 | daemon 审计 |
| 13:29:26→13:29:35 | **9 秒，手机侧 `PPassFlow` 零行** | logcat |
| 13:29:35.976 | `remove task`——用户把 App 划掉 | logcat |
| 13:29:36.042 | 新进程 12509 起来（`SystemJobService` 拉起） | logcat |
| 13:29:37.659 | `Flow epoch preflight`——第一次交付尝试 | logcat |
| 13:29:43 | `flow.round.finished`，25 项全部完成 | daemon 审计 |

logcat 从 12:37:32 到 13:31:29 连续无断档（全程 74 行 `PPassFlow` 逐条对得上），
所以"这 9 秒里手机侧一行都没有"是实测，不是采样漏了。配对前后 peer 都是
`be03d1d105…`，身份没换。

**这不是 MOB-62**：MOB-62 管的是断开后**旧** Flow 运行态/调度必须清干净
（症状是旧 offer 乱发、ANR、崩溃）。本卡症状相反——新会话**太安静**，
一个 offer 都没发。两张卡不冲突，但别合并。
