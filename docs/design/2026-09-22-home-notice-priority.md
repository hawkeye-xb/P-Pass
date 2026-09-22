# 首页（设置 tab）提示的优先级与互斥表

**状态**：设计口径，可直接作为 #350 / #328 / #361 的验收依据。
**不含实现**，不替代上述任何一张卡。

首页（设置 tab）的备份状态区与英雄卡同时被三张卡改写：#350 UI-16（英雄卡在失效时
仍绿字报「全部完成」）、#328 MOB-100（「已跳过 N 张」横幅无消除路径）、#361 UI-19
（暂停有理由却不说）。三张卡各自接线必然打架。本文定义：**同一时刻可能成立的每一
条提示是什么、谁压谁、哪些并存、每条怎么消除。**

全文每条结论带 `文件:行号`。行号基准 `f8ca921`（main，2026-09-22）。

---

## 0. 本表服从的既有口径

以下四条不是本表可以重新发明的，本表只负责把它们贯彻到每一行。

| 编号 | 口径 | 出处 |
|---|---|---|
| R-GREEN | 绿色只表示已确认成功或数据已安全存好，绝不表示进行中 | `assets/design/tokens.json` `rules[1]`（第 2 条） |
| R-UNKNOWN | 证据不足必须输出「未知」；「未知」不得渲染成「一切正常」 | #299 MOB-97 验收标准第 1 条；代码侧已落地为 `TransferProtection`（`FlowTransferForegroundService.kt:34-43`） |
| R-CLEARABLE | 任何常驻提示必须有用户自己走得通的消除路径；只有开发者能清不算；「重装 App」「解除配对」不算路径 | #328 第二条评论 |
| R-PAUSE | 暂停机制本身（`FlowAction.Pause` / gate 语义）已由 #353 / #362 定死 | `FlowUiProjection.kt:18-27`、`AndroidFlowRuntime.kt:353-356` |

⚠️ R-CLEARABLE **尚未落进 `tokens.json`**——当前 `rules` 只有 10 条，第 11 条是
#328 追加范围里的交付物。本表按该规则判定，并在 §3 给出它的违反清单；把规则写进
`tokens.json` 仍是 #328 的活。

---

## 1. 盘点表：首页（设置 tab）可能出现的每一条提示/状态

分四个渲染区。**NoticeHost 区不属于 HomeScreen**，它挂在 `TwoTabs` 顶部
（`MainActivity.kt:722-731`），照片/设置两个 tab 都可见，但它和英雄卡同屏，
所以必须进本表。

### 区 A — 英雄卡（`HomeScreen.kt:186-355`）

| # | 名字 | 渲染位置 | 数据源 | 触发条件（判定表达式） | 消除路径 | 常驻/瞬态 |
|---|---|---|---|---|---|---|
| A1 | `no_media_access_title` / `no_media_access_body` / `partial_access_action` | `HomeScreen.kt:192-224` | `mediaAccessOf(...)`（`TriggerPolicy.kt:147`），经 `MainActivity.kt:189` | `mediaAccess == MediaAccess.NONE` | 有：按钮 `onOpenAppSettings` → 系统设置授予相册权限 | 常驻 |
| A2 | `partial_access_title` / `partial_access_body` / `partial_access_action` | `HomeScreen.kt:192-224` | 同上 | `mediaAccess == MediaAccess.PARTIAL` | 有：同 A1 | 常驻 |
| A3 | 三元组主数字 `groupThousands(t.m)` + `hero_of_n` | `HomeScreen.kt:231-241` | `tripletOf(n, m, lastSuccessAt)`（`ConfirmedStore.kt:55-60`）；`n = MediaScanner.countAll(bucketIds)`、`m = flowAggregateOf(...).confirmed`（`BackupUiStateHolder.kt:295-298`） | `mediaAccess == FULL && triplet != null` | 不适用（状态显示，非提示） | 常驻 |
| A4 | `triplet_unavailable` | `HomeScreen.kt:256-259` | `_triplet == null` | `refreshTriplet` 抛 `Throwable` 被吞（`BackupUiStateHolder.kt:299-301`） | **无**（文案说「打开 App 时会再试」，用户无动作可做） | 常驻直到某次扫描成功 |
| A5 | `dog_last_success` / `last_success_never` + `pending_count` | `HomeScreen.kt:246-253` | `t.lastSuccessAt`（`flowAggregateOf` 的 `completedAt` 最大值）、`t.k = n - m`（`ConfirmedStore.kt:44`） | `triplet != null` | 不适用（状态显示） | 常驻 |
| A6 | 进行中状态行：`state_scanning` / `state_hashing` / `state_sending` / `state_sending_file` | `HomeScreen.kt:277-282` → `workingText`（`:731-742`） | `statusLineOf(state, k)`（`BackupStatus.kt:40-59`） | `line is StatusLine.Working` | 不适用（瞬态） | 瞬态 |
| A7 | 空闲态状态行：`state_no_albums` / `state_pending` / `state_safe` / `idle_auto_hint` / `backup_waiting_constraints` / `backup_round_cancelled` | `HomeScreen.kt:306-311` → `idleStatusText`（`:753-761`） | 同 A6 | `!busy`，分支见 `BackupStatus.kt:40-59` | 不适用（状态显示） | 常驻 |
| A8 | `backup_pause` / `backup_resume` / `backup_command_processing` | `HomeScreen.kt:319-331` | `heroActionOf(state, pairingLost)`（`BackupStatus.kt:80-85`） | `!pairingLost && (isBackupRunning(state) \|\| state is Paused)` | 不适用（动作） | 随状态 |
| A9 | `backup_cancel_current_round` | `HomeScreen.kt:344-351` | `cancelAffordanceVisible`（`BackupStatus.kt:105-106`） | `heroActionOf(...) == HeroAction.Resume` | 不适用（动作） | 随状态 |
| A10 | 6dp 进度条 | `HomeScreen.kt:297-304` | `RoundProgress`（`FlowUiProjection.kt:209-218`） | `busy && roundProgress.total > 0` | 不适用 | 瞬态 |

### 区 B — 英雄卡下方正文（`HomeScreen.kt:357-492`）

| # | 名字 | 渲染位置 | 数据源 | 触发条件 | 消除路径 | 常驻/瞬态 |
|---|---|---|---|---|---|---|
| B1 | `wifi_deferred_hint` | `HomeScreen.kt:359-373` | `shouldShowWifiDeferredHint`（`HomeScreen.kt:840-845`），`wifiDeferred` 来自 `MainActivity.kt:951/970` | `wifiOnly && wifiDeferred && !busy && mediaAccess == FULL` | 有：连上 Wi-Fi，或关掉「仅 Wi-Fi」开关（`HomeScreen.kt:554-558`） | 常驻直到条件变化 |
| B2 | Trouble 红卡：`state_trouble` + `run_failed` + `try_again`（+ `trouble_details_show/hide`） | `HomeScreen.kt:381-441` | `BackupUiState.Trouble`，由 `FlowUiState.NeedsUserAttention` 投影（`FlowUiProjection.kt:121`），即存在 `FAILED_NEEDS_USER` 项（`:24-25`） | `state is BackupUiState.Trouble && !pairingLost` | 有：按钮「再试一次」→ `FlowCommand.Retry`（`FlowUiProjection.kt:139`） | 常驻直到重试成功 |
| B3 | 配对失效红卡：`pairing_lost_title` + `pairing_lost_body` + `reconnect` | `HomeScreen.kt:444-477` | `holder.pairingLost`（`BackupUiStateHolder.kt:77-78`、`305-317`） | `pairingLost == true` | 有：按钮「重新扫码连接」→ `onRepairPairing`（`MainActivity.kt:699-705`） | 常驻直到重新配对 |
| B4 | `missing_source_notice_body`（NoticeCard，kind = `SOURCE_MISSING`） | `HomeScreen.kt:484-492` | `flowMissingSourceNotice`（`FlowUiProjection.kt:165-172`） | `count{deliveryState == SKIPPED_SOURCE_MISSING && sourcePresence == MISSING && disposition == UNRECOVERABLE} > 0` | **无**——卡片无 action、无 dismiss；账本无任何 prune/retain 代码 | 常驻，永久 |

### 区 C — 设置卡内（`HomeScreen.kt:501-566`）

| # | 名字 | 渲染位置 | 数据源 | 触发条件 | 消除路径 | 常驻/瞬态 |
|---|---|---|---|---|---|---|
| C1 | `cancelled_round_cell_label` + `cancelled_round_cell_value`（「已跳过的照片 / N 张 · 点击恢复」） | `HomeScreen.kt:521-531` | `flowCancelledRoundNotice`（`FlowUiProjection.kt:185-190`） | `count{deliveryState == CANCELLED_BY_USER_ROUND && cancellationRoundId != null} > 0` | 有：点击 → `restoreAllCancelledFlowRounds`（`AndroidFlowRuntime.kt:377-380`） | 常驻直到恢复 |
| C2 | `background_backup_needs_authorization`（开关行 hint） | `HomeScreen.kt:537-552` | `backgroundBackupStateOf`（`BackgroundBackupState.kt:14-24`），装配于 `MainActivity.kt:655-660` | `userEnabled && !systemWhitelisted` | 有：点 hint → `resolveBackgroundBackup`（`MainActivity.kt:673-690`）申请电池白名单；或用户自己关掉「自动备份」开关 | 常驻 |
| C3 | `background_backup_system_stopped`（开关行 hint） | `HomeScreen.kt:537-552` | 同上 | `userEnabled && systemWhitelisted && (watcherInterrupted \|\| !watcherScheduled)` | 有：同 C2 | 常驻 |

### 区 D — NoticeHost 槽位（`HomeNotices.kt:171-203`，挂在 `MainActivity.kt:722-731`）

| # | 名字 | 渲染位置 | 数据源 | 触发条件 | 消除路径 | 常驻/瞬态 |
|---|---|---|---|---|---|---|
| D1 | `background_backup_needs_authorization`（横幅，kind = `BACKUP_INTERRUPTED`） | `HomeNotices.kt:178-192` | 同 C2 | 同 C2 | 有：`background_backup_notice_action`「去处理」→ 同一个 `resolveBackgroundBackup` lambda | 常驻 |
| D2 | `background_backup_system_stopped`（横幅，kind = `BACKUP_INTERRUPTED`） | `HomeNotices.kt:178-192` | 同 C3 | 同 C3 | 有：同 D1 | 常驻 |
| D3 | `reupload_notice_body` + `reupload_notice_action`「知道了」（kind = `REUPLOAD`） | `HomeNotices.kt:193-200` | `flowReuploadNoticeCount`（`FlowUiProjection.kt:159-160`） | `count{disposition == NEEDS_DECISION} > 0` | **无**——「知道了」绑的是 `acknowledgeReuploadNotice()`，函数体是 `= Unit`（`BackupUiStateHolder.kt:172`）；计数每 tick 由账本重算（`:258`），点完立即原样回来 | 常驻，永久 |

### 区 E — 非卡片位

| # | 名字 | 渲染位置 | 数据源 | 触发条件 | 消除路径 | 常驻/瞬态 |
|---|---|---|---|---|---|---|
| E1 | 设置 tab 图标红点 | `MainActivity.kt:716-718` | `holder.pairingLost` / `backgroundBackupState` | `pairingLost \|\| state == NeedsSystemAuthorization \|\| state == SystemStoppedWatcher` | 随 B3 / C2 / C3 消除而消除 | 常驻 |
| E2 | `background_backup_resuming`（snackbar） | `MainActivity.kt:680-683` | 用户点击 `resolveBackgroundBackup` | 白名单已有时点「去处理」 | 自动消失 | 瞬态 |

**合计 22 条**（A 10 + B 4 + C 3 + D 3 + E 2）。

### 盘点中发现的三条结构事实（影响本表怎么读）

1. **`HOME_NOTICE_PRIORITY` 只管得住 NoticeHost 自己构造的候选。**
   列表里登记了 5 个 kind（`HomeNotices.kt:67-74`），但 `NoticeHost` 只构造
   `BACKUP_INTERRUPTED` 与 `REUPLOAD` 两个（`:177-201`）；`PAIRING_LOST` 与
   `PARTIAL_ACCESS` 从未被构造（它们走各自的红卡/英雄卡顶替），`SOURCE_MISSING`
   在 `HomeScreen.kt:486` 直接 `NoticeCard(...)` 渲染，**不经过 `topNotice`**。
   所以 `topNotice` 最多在 D1/D2 与 D3 之间二选一，跨区互斥它一条也管不到。
   **本表才是首页真正的优先级表**，`HOME_NOTICE_PRIORITY` 是它的一个子集实现。
2. **同一个事实被渲染两次**：C2/C3 与 D1/D2 输入同一个 `backgroundBackupState`、
   用同一个字符串资源、绑同一个 lambda，当前**同屏并存**。
3. **B4 与 C1 的中文文案都以「已跳过 N 张」开头**
   （`values-zh/strings.xml:80` 与 `:78-79`），但一条无出路、一条点击即恢复。

---

## 2. 优先级与互斥表

### 2.1 分层

| 层 | 含义 | 成员 |
|---|---|---|
| L0 | **数据不可信** —— 不得给出任何完成度结论 | A4、A3 的「对不上账」分支（见 §4.1） |
| L1 | **阻塞：备份完全停了** | B3（配对失效）、A1（无相册权限） |
| L2 | **系统限制/授权** | A2（部分权限）、D1/D2 = C2/C3（后台被系统停）、暂停理由（#361，待接线） |
| L3 | **本轮失败，用户可重试** | B2（Trouble） |
| L4 | **补充信息：用户不动手也不丢数据** | B4、C1、D3、B1 |

层序与 `HomeNotices.kt:65-66` 已写的 UI-04c 口径（阻塞 > 授权 > 补充）一致，
只是在最上面加了 L0——因为 R-UNKNOWN 要求「不知道」压过一切结论。

### 2.2 英雄卡绿色闸门（规则 G，可直接转成一条测试）

> 英雄卡主数字与 `hero_of_n` 使用 `PPColor.Safe`，**当且仅当**下面五条同时成立：
>
> - G1 `mediaAccess == MediaAccess.FULL`
> - G2 `triplet != null`
> - G3 `pairingLost == false`
> - G4 账本中不存在 `deliveryState == FAILED_NEEDS_USER` 的项
> - G5 `consumerGate != PAUSED_BY_USER`
>
> 任一条不成立 → 主数字不得为 `PPColor.Safe`。

G3/G4/G5 是 R-GREEN 的直接推论：配对已断、有待处理失败、或传输被按停，都不是
「已确认成功或数据已安全存好」。G4 与 G5 的判据取自 `flowUiStateOf`
（`FlowUiProjection.kt:18-27`）已有的输入，不需要新状态。

当前代码 `HomeScreen.kt:234/239` 恒用 `PPColor.Safe`，**五条闸门一条都没有**。

### 2.3 英雄卡内容闸门（规则 H）

英雄卡主位四选一，互斥、无第五种：

| 渲染 | 条件 | 内容 | 配色 |
|---|---|---|---|
| H-A 权限顶替 | `mediaAccess != FULL` | A1 / A2 | `PPColor.Act`（现状，`HomeScreen.kt:187/201`） |
| H-B 读不到 | `mediaAccess == FULL && triplet == null` | A4 | 非绿（现状 `Ink60`，`:258`） |
| H-C 对不上账 | `mediaAccess == FULL && triplet != null && m > n`（clamp 前的原始 `confirmedCount > n`） | **不渲染任何 m/n 分数**，改说「两个数对不上、正在核对」，出路指向对账 #139 MOB-87 | 非绿（建议 `PPColor.Waiting`：它不是错误，是证据不足） |
| H-D 三元组 | 其余 | A3 + A5 | 按规则 G 决定绿/非绿 |

H-C 的文案**当前不存在**，登记在 §5「应该有但没有」。不得复用
`triplet_unavailable`——那条说的是「读不到手机相册的数量」
（`values-zh/strings.xml:117`），与「两个数对不上」是两件事。

### 2.4 跨区两两裁决矩阵

11 个决策单元（把同源的合并）：

| 代号 | 指向 |
|---|---|
| HERO | A3/A4/A5 + 规则 G/H |
| ACCESS | A1/A2 |
| PAIR | B3 |
| TROUBLE | B2 |
| SKIP-MISS | B4 |
| CANCEL-ROW | C1 |
| BG | C2/C3 + D1/D2（同一事实） |
| REUP | D3 |
| WIFI | B1 |
| PAUSE-WHY | #361 的暂停理由（待接线，挂载点见 §2.5） |
| DOT | E1 |

读法：`并存` = 两者都渲染；`X` = X 压制另一方（另一方不渲染）；
`互斥` = 由代码构造决定不可能同时成立（给出出处）。

| | ACCESS | PAIR | TROUBLE | SKIP-MISS | CANCEL-ROW | BG | REUP | WIFI | PAUSE-WHY | DOT |
|---|---|---|---|---|---|---|---|---|---|---|
| **HERO** | ACCESS ¹ | 并存 ² | 并存 ² | 并存 | 并存 | 并存 | 并存 | 并存 | 并存 ⁷ | 并存 |
| **ACCESS** | — | 并存 | 并存 | 并存 | 并存 | 并存 | 并存 | ACCESS ³ | 并存 | 并存 |
| **PAIR** | — | — | PAIR ⁴ | 并存 | 并存 | 并存 | PAIR ⁵ | PAIR ⁵ | PAIR ⁶ | 并存 |
| **TROUBLE** | — | — | — | 并存 | 并存 | 并存 | 并存 | TROUBLE ⁵ | 互斥 ⁸ | 并存 |
| **SKIP-MISS** | — | — | — | — | 并存 ⁹ | 并存 | 并存 | 并存 | 并存 | 并存 |
| **CANCEL-ROW** | — | — | — | — | — | 并存 | 并存 | 并存 | 并存 | 并存 |
| **BG** | — | — | — | — | — | — | BG ¹⁰ | 并存 | 并存 | 并存 |
| **REUP** | — | — | — | — | — | — | — | 并存 | 并存 | 并存 |
| **WIFI** | — | — | — | — | — | — | — | — | PAUSE-WHY ¹¹ | 并存 |
| **PAUSE-WHY** | — | — | — | — | — | — | — | — | — | 并存 |

脚注：

1. 已由代码保证：`HomeScreen.kt:192` 的 `if` 与 `:225` 的 `else` 互为分支，
   权限不足时三元组整块不渲染。
2. 并存，但 HERO 受规则 G 约束：G3 使 PAIR 在场时英雄卡不得为绿，G4 使 TROUBLE
   在场时不得为绿。**真机组合 1（「配对已失效」红卡 + 绿字「10 / 10 张已回家」）
   落在这一格**——并存本身没错，错的是同屏的绿色，G3 就是堵它的那条闸门。
3. 已由代码保证：`shouldShowWifiDeferredHint` 要求 `mediaAccess == FULL`
   （`HomeScreen.kt:840-845`）。
4. 已由代码保证：`HomeScreen.kt:381` 的 `state is Trouble && !pairingLost`。
5. 新增裁决：L1 在场时，L4 的补充信息不出现。理由——配对已断时，「有 N 张在电脑上
   不见了正在重新传回」「将在连上 Wi-Fi 后进行」都是**当下不可能发生的承诺**。
   这与 R-UNKNOWN 同源：不知道就别说，做不到更别说。
6. 新增裁决：PAIR 在场时 `heroActionOf` 已返回 `null`（`BackupStatus.kt:81`），
   「继续」按钮不在场 ⇒ PAUSE-WHY 没有挂载点（见 §2.5），且「今天后台时间用完了」
   在配对已断时是误导。
7. 并存：PAUSE-WHY 挂在英雄卡状态行上，与主数字同区不同行；G5 保证此时主数字非绿。
8. 已由代码保证：`flowUiStateOf`（`FlowUiProjection.kt:18-27`）先判
   `consumerGate == PAUSED_BY_USER`（`:20`）再判 `FAILED_NEEDS_USER`（`:24`），
   一旦暂停就投影成 `PausedByUser`，`Trouble` 不可能同时成立。
9. 并存（**真机组合 2 落在这一格**），但必须满足 §4.3 的区分条件。
10. 已由代码保证 + 本表补一条：`topNotice` 按 `HOME_NOTICE_PRIORITY`
    让 `BACKUP_INTERRUPTED` 压 `REUPLOAD`（`HomeNotices.kt:67-74`、`:101-104`）。
    本表另加：C2/C3 与 D1/D2 是同一事实的两处渲染，**同屏只保留横幅**，
    设置卡的 hint 不得作为第二条独立提示计数（否则一件事说两遍，占掉 tokens.json
    `rules[4]`「每屏一个结论一句解释」的预算）。
11. 新增裁决：两者都在解释「为什么没在传」，同屏说两个不同原因即自相矛盾。
    暂停是已发生的事实，Wi-Fi 等待是尚未发生的条件，事实压条件。

### 2.5 暂停理由的挂载点（规则 P，#361 专用）

> PAUSE-WHY **不新增横幅**。它渲染为英雄卡状态行（A7）在
> `state is BackupUiState.Paused` 分支下的替换文案，紧挨着既有的「继续」按钮（A8）。

- 数据源：`FlowTransferForeground.protectionNoticeRes(context)`
  （`FlowTransferForegroundService.kt:258-259`）
- `SYSTEM_BUDGET_EXHAUSTED` → `state_background_budget_paused`（`values-zh/strings.xml:100`）
- `START_REFUSED` → `state_background_protection_unknown`（`:101`）
- `STARTED` / 空 / 不可读 → `transferProtectionNoticeRes` 返回 `null`
  （`FlowTransferForegroundService.kt:163-168`）→ **不渲染任何理由**，状态行退回
  既有的 `idleStatusText`。这就是 R-UNKNOWN 在本表里的落点：不知道就沉默，
  **不得**退回「一切正常」类文案。
- 前置约束见 §4.2：在数据源修好之前，这条理由是可以被静默改写的。

---

## 3. 消除路径与 R-CLEARABLE 违反清单

`常驻 = 是` 且 `消除路径 = 无` 的条目：

| # | 名字 | 为什么没有路径 | 归属 |
|---|---|---|---|
| **B4** | `missing_source_notice_body`「已跳过 N 张…不会再重传」 | `NoticeCard` 构造时只给了 `body`，`actionLabel` / `dismissLabel` 均为默认 `null`（`HomeScreen.kt:486-491`、`HomeNotices.kt:85-93`）；账本侧无任何条目删除/水位线机制 | #328 主目标 |
| **D3** | `reupload_notice_body` 的「知道了」 | 按钮存在、但 `onAcknowledgeReupload` → `holder.acknowledgeReuploadNotice()`，函数体是 `= Unit`（`BackupUiStateHolder.kt:172`）。计数由 `flowReuploadNoticeCount` 每 tick 从账本重算（`:258`、`FlowUiProjection.kt:159-160`），点击后下一 tick 原样恢复 | **#328 范围外的第二例**，见 §6 顺带发现 1 |
| **A4** | `triplet_unavailable` | 文案自称「打开 App 时会再试」，但用户没有任何可执行动作；`refreshTriplet` 把所有 `Throwable` 吞成 `null`（`BackupUiStateHolder.kt:299-301`），失败原因不可见也不可诉 | 见 §6 顺带发现 2 |

**违反 R-CLEARABLE 的常驻提示：3 条。**

D3 尤其要紧：它比 B4 更坏。B4 是「没给按钮」，用户至少知道自己无能为力；
D3 是**给了按钮、按钮不做事**——用户点一下，提示原地不动。按 R-CLEARABLE
的措辞（「用户自己走得通的消除路径」），一个 no-op 按钮不是路径。

---

## 4. 三个问题

### 4.1 `m > n` 时英雄卡显示什么，以及 `m / n` 相除成不成立

**渲染**：规则 H-C（§2.3）——不渲染任何 m/n 分数，不用 `PPColor.Safe`，
改说「两个数对不上、正在核对」，出路指向对账 #139 MOB-87。
**优先级归属 L0**（数据不可信），压过一切完成度结论，与其余各区提示并存。

删 clamp 会让「已备份 51 / 手机 10 张」回来，那是另一种假话；保留 clamp 是把假话
换成更危险的假话（绿色的「10 / 10」）。H-C 是第三条路：**既不编数字，也不藏事实。**

**`m / n` 在语义上不成立**，而且不是只在 `m > n` 时不成立。

两个数的作用域：

| | 表达式 | 出处 | 数的是 |
|---|---|---|---|
| `n` | `MediaScanner(context.contentResolver).countAll(bucketIds)`，`bucketIds = scopeStore.selectedBucketIds()` | `BackupUiStateHolder.kt:295-297` | **当前选中相册**的实时 MediaStore 文件数 |
| `m` | `flowAggregateOf(flowLedgerSnapshot(context)).confirmed` | `BackupUiStateHolder.kt:296-298` | **账本全量** `CONFIRMED` 条数——`flowAggregateOf` 遍历 `snapshot.items`，**无任何 bucket 过滤**（`FlowUiProjection.kt:38-59`） |

两个集合既非包含关系，也非同一单位：账本含历史上传过、后来移出选中范围或已从相册
删除的项；相册含从未入过队的项。所以 `m / n` 不是「同一集合的已完成比例」，
是两个不同集合的基数相除。

**`m > n` 只是这件事最显眼的表现，`m ≤ n` 时同样是假话。**
真机组合 3 就是证据：「23 / 23 张已回家」绿字，实有 4 张待传——此时 `m == n`，
clamp 是恒等变换，一行代码都没动，英雄卡仍然在撒谎。任何只改 clamp 的修法都拦不住
这一例。组合 1 与组合 3 同一根因。

**修法方向**（#350 拍板用，本表不替它拍）：

- `TransferItem` 已持有 `bucketId: Long`（`DiscoveryLedger.kt:251`），
  **按选中相册过滤 `confirmed` 不需要新字段、不需要新状态**。
- 但作用域对齐是必要条件、不是充分条件：`n` 里还有从未入过队的文件，账本里还有
  源已删除（`SKIPPED_SOURCE_MISSING`）因而不再计入 `n` 的项。唯一自洽的完成度
  分子分母必须同源——`confirmed / (confirmed + pending)`，这正是
  `backupUiStateOf` 已经在用的口径（`FlowUiProjection.kt:108-110`）。
- `n` 的正确角色是**独立的诚实校验量**（「你手机里有 N 张」），不是分母。
- ⚠️ 这需要改 `flowAggregateOf` 的取数范围，而 #350 的「不准动」列的是
  `flowAggregateOf` 的**状态归类**（`FAILED_NEEDS_USER` 归 pending）。两者不是
  一回事，但实施前应按 AGENTS.md 红线 2「范围即边界」先改 issue 范围段。

### 4.2 `protection` 数据源可信吗

**结论：当前不可信，#361 挂在它上面的前提不成立——需要先补一条写入优先级规则。**

`TransferProtectionStore` 有**两个写入者，证据分量完全不同，但写进去的值一模一样**：

| 写入者 | `start()` 实际执行的调用 | 出处 | `STARTED` 的含义 |
|---|---|---|---|
| W1 `FlowTransferForeground.sync` | `ContextCompat.startForegroundService(app, intent)` | `FlowTransferForegroundService.kt:247-249` | **「我们提交了一次启动请求」**——这个调用不走 `startForeground`，没有任何机会观测到系统是否同意保护 |
| W2 `FlowTransferForegroundService.onStartCommand` | `startForeground(NOTIFICATION_ID, notification, FOREGROUND_SERVICE_TYPE_DATA_SYNC)` | `FlowTransferForegroundService.kt:309-319` | 「系统确实同意了」 |

`transferProtectionOf` 把两者都映射成 `TransferProtection.EFFECTIVE`
（`:150-155`）——**W1 写出的 `EFFECTIVE` 是结构上不可证伪的**，它恰好是
`TransferProtection` 自己的文档声称不允许的东西（「only observed evidence may say
yes or no」，`:27-33`）。

`onTimeout` 确实 record 了。`FlowTransferForegroundService.kt:339-341`：

```kotlin
override fun onTimeout(startId: Int, fgsType: Int) {
    TransferProtectionStore(filesDir)
        .record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, System.currentTimeMillis())
```

所以 2026-09-22 E3 观测到的「timeout 之后 18 毫秒记的仍是 STARTED」不是「没记」，
是**记了之后被覆盖**。覆盖是允许的，因为：

- `record`（`:112-129`）无条件整体替换：`lastOutcomeAt` 只写不读，
  `ForegroundStartOutcome` 之间**没有任何优先级或单调性判据**。
- `FlowTransferForeground.sync` 挂在**每一次** ledger 状态变更之后
  （`AndroidFlowRuntime.kt:513`）以及每一次 `flushAuditOutbox`（`:529-531`），
  触发面极大；`onTimeout` 期间若有并发 Flow 触发（回执/唤醒）先于
  `haltUnprotectedTransfer` 把 gate 改成 `PAUSED_BY_USER`，
  `foregroundActionFor` 仍返回 `START`（`FlowUiProjection.kt:240-241`，
  判据是 `flowRoundActive`），W1 随即写下一条不带任何观测的 `STARTED`。
- 时间量级吻合 W1 而不吻合 W2：W1 是一次非阻塞 Binder 调用，W2 需要一整轮服务派发，
  且 W2 在配额已耗尽时会走 `isSystemBudgetExhausted` 分支（`:185-186`）写
  `SYSTEM_BUDGET_EXHAUSTED`，写不出 `STARTED`。
- 无任何测试覆盖 `onTimeout` 或写入顺序：`MOB101ForegroundBudgetTest` /
  `MOB102ProtectionStoreResilienceTest` 断言的是单次 outcome 判定与写盘韧性，
  没有一条断言「已记录的 `SYSTEM_BUDGET_EXHAUSTED` 不被后续 `STARTED` 覆盖」。

**这对 #361 意味着什么**：

- `NOT_EFFECTIVE` 只可能由系统自己的 "Time limit" 证据写出（`:185-186`、`:208-209`、
  `:340-341`），所以**它在场时是真的**——#361 要显示的那句人话，显示时不会撒谎。
- 但它**不是稳定可读的**：几毫秒内就可能被一条毫无观测分量的 `STARTED` 抹掉。
  #361 挂号段写的「暂停的理由也已经落盘且可读」在一般情况下**不成立**。
- 因此 #361 必须增加一条前置约束（二选一，实施时拍板）：
  - (a) `record` 引入写入优先级/单调性——已观测到的失败结论不被未观测到的
    `STARTED` 覆盖；或
  - (b) W1 与 W2 分成两个不同的 outcome 值（「已提交请求」≠「系统已同意」），
    只有 W2 的成功才映射成 `EFFECTIVE`。
- 在 (a)/(b) 之一落地之前，#361 的 E3 真机验收**必然是 flaky 的**：同一次配额耗尽，
  首页显不显示那句话取决于当时有没有并发 Flow 触发。

### 4.3 两条「已跳过」能并存吗

**能，而且真机已经同屏出现（组合 2）。** 它们是两个互不相交的集合，
分别由 `deliveryState == SKIPPED_SOURCE_MISSING`（`FlowUiProjection.kt:167`）与
`deliveryState == CANCELLED_BY_USER_ROUND`（`:187`）判定，一个 `TransferItem`
只有一个 `deliveryState`，所以**同一张照片不会被两边同时数进去**，两个计数没有
重叠、不需要互斥。

它们还落在**两个不同的区**：B4 是英雄卡下方的琥珀 `NoticeCard`
（`HomeScreen.kt:484-492`），C1 是设置卡里的一行 `CellRow`
（`HomeScreen.kt:521-531`）。

**用户分不清**，原因不在并存，在文案：

- B4：`已跳过 %1$d 张已从手机相册删除的照片，不会再重传。`（`values-zh/strings.xml:80`）
- C1：`已跳过的照片` / `%1$d 张 · 点击恢复`（`:78-79`）

两条都以「已跳过」三个字开头，而语义正好相反——一条**永久不可恢复**，
一条**点一下就全回来**。

**表里怎么处置**：

1. 并存（矩阵 §2.4 SKIP-MISS × CANCEL-ROW = 并存 ⁹），不做互斥。互斥会丢信息：
   MOB-59 的真机教训（`FlowUiProjection.kt:174-181`）正是「提示消失了，那批再也
   找不到」。
2. 但并存的**前置条件**是两条文案必须在第一行就可区分。当前不满足 ⇒ 登记为文案
   缺口（§5），归 #328 的范围（它本来就要动 B4 这条 NoticeCard 与其交互）。
3. 区分方向（不在本文造文案，只给判据）：**B4 的第一句必须带「无法恢复」语义、
   C1 的第一句必须带「可恢复」语义**，且两句不得共用同一个起首词。
   可判定形式：两条中文文案的前 4 个字符不得相同。

---

## 5. 应该有但没有的状态与文案（不混进主表）

本表不发明状态与文案。下面三项是盘点中发现的「主表需要、代码里没有」的缺口，
各自归属已注明。

| 缺口 | 主表哪一行需要它 | 归属 |
|---|---|---|
| 英雄卡「对不上账」文案（H-C） | §2.3 规则 H 第三行 | #350（其「关键判断 1」已经指向这条，本表把它固定成 L0 + 非绿 + 无分数） |
| B4 / C1 的可区分文案 | §4.3 处置第 2 条 | #328（已在其范围内） |
| `record` 的写入优先级或 outcome 拆分 | §2.5 规则 P 的前置 | #361（本表新增的前置，见 §4.2） |

---

## 6. 顺带发现

主表放不下、也不属于上述三张卡的缺陷，登记于此，不另开卡。

1. **`acknowledgeReuploadNotice()` 是空函数**（`BackupUiStateHolder.kt:172`
   全文即 `fun acknowledgeReuploadNotice() = Unit`）。`NoticeHost` 的
   `reupload_notice_action`「知道了」按钮（`HomeNotices.kt:193-200`、
   `MainActivity.kt:726`）绑的就是它。计数由 `flowReuploadNoticeCount` 每次
   `refreshFlowState` 从账本重算（`BackupUiStateHolder.kt:258`），
   **点击后下一 tick 原样恢复**。这是 R-CLEARABLE 的第二例违反，形状比 #328 更差：
   #328 是没给出路，这条是给了一个假的出路。
   `HomeNotices.kt:166-168` 的注释还写着「REUPLOAD…继续保留自己的一次性确认语义」
   ——那个语义没有实现。
2. **`computeTripletSafe` 在生产链路上已死**（`BackupUiStateHolder.kt:319-327`）。
   生产的 `refreshTriplet` 走 `flowAggregateOf`（`:296-298`），
   唯一调用 `computeTripletSafe` 的是 `MediaQueryFailureTest.kt:33`。该测试的注释
   仍写着「what refreshTriplet actually calls」（`MediaQueryFailureTest.kt:8`），
   已经不成立——它守的是一条生产上不再执行的路径，`ConfirmedStore.countInScope`
   的漂移行为因此无人盯着。
3. **`refreshTriplet` 在没选相册时留下过期数字**：
   `val bucketIds = scopeStore.selectedBucketIds() ?: return`
   （`BackupUiStateHolder.kt:295`）——`return` 直接退出函数，
   `_triplet.value` **保持上一次的值不变**，而不是置 `null`。
   用户把相册全部取消勾选后，英雄卡继续显示上一轮的 M / N。
   对照 `:299-301` 的 catch 分支是置 `null`（走 H-B「读不到」），两条失败路径
   给出两种不同的诚实度。
