# MOB-33 四条备份通道各自一个 unique name：暂停按钮对自动备份无效、进度条乱跳、可能并行　级别 L0

> 🟡 状态：代码已合并，等真机验收
> 级别：**L0**（2026-08-26 从 L2 升级，理由见下）· 阻塞：无

## 问题

Android 端把备份的四种触发各自排在**独立的 WorkManager unique name** 上
（`BackupWorker.kt`）：

| 触发 | unique name | 策略 |
|---|---|---|
| 用户在场补捞（MOB-02 事件①④） | `CATCHUP_WORK_NAME` | KEEP |
| 手动「立即备份」（MOB-19 事件⑥） | `MANUAL_BACKUP_WORK_NAME` | KEEP |
| 进程启动补捞（MOB-15 事件⑤） | `PROCESS_CATCHUP_WORK_NAME` | KEEP |
| 周期兜底 5h（事件③） | `BACKUP_WORK_NAME` | UPDATE |

`ExistingWorkPolicy.KEEP` 只在**同一个 unique name 内部**去重。四个名字互不
相干，所以「用户打开 App」+「周期任务到点」这类时间上撞在一起的组合，会让
**两个 `BackupWorker` 实例同时跑**。`backup/` 包里搜不到任何互斥
（`Mutex` / `synchronized` / `withLock` / `AtomicBoolean` 零命中），两个实例
读的是同一个水位、offer 的是同一批候选。

后果是**浪费而不是损坏**：存储端 ingest 会去重（`dup=N`），索引不会脏；但
流量、电量、传输时间都翻倍，进度条分母也会互相打脸（MOB-31 那类现象的另一个
可能来源）。

这个问题在 MOB-27（监听与干活分家）之前就存在，不是 MOB-27 引入的。

## 期望行为

同一时刻只有一个 `BackupWorker` 在推字节。四种触发仍然各自能发起，但撞上
正在跑的那个时收敛成「不重复入队」而不是「并行再来一遍」。

⚠️ 注意别把手动「立即备份」的语义改坏：UX-01 定的是「跑着的时候再点 = 暂停」
（`cancelManualBackup`），手动通道有自己的取消入口，合并 unique name 会让
「取消手动」连带取消自动通道。

## 验收标准

- [ ] 单测：模拟两条通道在同一时刻发起 → 只有一个 worker 真正进入传输阶段
- [ ] 反证：去掉互斥/合并逻辑后该测试变红
- [ ] 单测：手动通道被取消后，自动通道不受影响（UX-01 语义不回退）
- [ ] 真机：`dumpsys jobscheduler` / WorkManager 日志确认同一时间窗内只有
  一个 `BackupWorker` 在 RUNNING

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/`
  （`BackupWorker.kt` 排队入口 + 必要的互斥实现）及其测试
- 不准动：存储端去重逻辑（它是兜底，不是本卡的修法）；`MediaWatchJob` 的
  监听语义（MOB-27 已定）

## 阻塞与依赖

无。可随时开工。

---

## 备注

改法有两条路，实施时择一并写清理由：

- **A. 合并到一个 unique name**（`APPEND_OR_REPLACE` / `KEEP`）——最简单，
  但会把四种触发的取消语义捆在一起，UX-01 的「手动暂停」要另找抓手。
- **B. 保留四个名字，加一道进程内/落盘的运行标记**——`doWork` 开头抢标记，
  抢不到就早退（`Result.success()`，不是 retry）。语义最贴近现状，代价是要
  处理进程被杀后标记残留（需带时间戳或用 WorkManager 的 `getWorkInfos` 实查）。

来源：`docs/NEXT.md`「未开卡」清单（2026-08-20 盘点），2026-08-25 按模板开卡，
代码层已核实（四处 `enqueueUnique*` + `backup/` 包零互斥）。

---

## 2026-08-26 重定级 L2 → L0：它不是「浪费不损坏」

原卡把后果写成「浪费而不是损坏：存储端会去重，索引不会脏」。**这个定性是错的。**
真机走查暴露出两个直接影响主路径的症状，根因都是这四个 unique name。

### 症状①：暂停按钮对自动触发的备份完全无效，而且界面会说谎

```kotlin
// BackupUiStateHolder.backupNow()
if (running) {
    cancelManualBackup(context)        // 只取消 MANUAL_BACKUP_WORK_NAME
    _state.value = BackupUiState.Idle  // ← 界面当场置 Idle
    return
}
```

而进度条的数据源是 `getWorkInfosByTagFlow(BackupWorker::class.java.name)`
——**按 tag 观察，覆盖全部四条通道**。于是自动触发的备份也会显示进度条、
也会出现暂停按钮，点下去：

- `cancelManualBackup` 取消不了它（它不在 MANUAL 通道上）
- 但 `_state.value = Idle` 让界面**立刻假装停了**
- **字节还在传**

验收人原话：「暂停按钮没有任何用处」。

### 症状②：进度条状态乱跳

验收人原话：「正在读文件后，有长时间 pending，然后在展示读文件，再上传。」

同一个根因：按 tag 观察会同时拿到多条通道的 `WorkInfo`，而
**`getWorkInfosByTagFlow` 不保证按时间排序**——`BackupUiStateHolder` 自己的
注释里就写着这句。列表里有两条 work（一条刚跑完、一条在跑）时，界面就在它们
之间来回跳。

### 验收人定的原则（2026-08-26）

> 「咱们的传输不是只有一个路径吗？那暂停是不是也得在一个路径？你这还分什么
> 自动手动？上传都不分自动手动了，只有触发会区分自动手动。」

**这条是对的，而且是 `MOB-19` 的既有定调**（「备份只有一条管线，手动是第 6 种
触发方式」）。所以：**暂停是管线级动作，不是通道级动作。**

## 追加的验收标准（本卡新增，原有几条不变）

- [ ] 单测：**自动触发**的备份进行中点暂停 → 那条 work 真的被取消
      （判据：`cancelWorkById` 收到的是**当前 RUNNING 那条**的 id，而不是
      固定的 MANUAL unique name）
- [ ] 反证：改回 `cancelManualBackup` → 上一条变红
- [ ] 单测：点暂停后**界面不许自己置 Idle**——状态必须来自 WorkManager 的
      真实回报（否则界面与传输脱钩，就是现在这个"说谎"的 bug）
- [ ] 单测：`uiStateOf` 在列表里有多条 work 时，选取**不依赖列表顺序**
      （给它一个乱序列表 + 一条 RUNNING，必须选中 RUNNING 那条）
- [ ] 反证：把选取改回「取列表第一条」→ 上一条变红
- [ ] UI：`LinearProgressIndicator` 传 `gapSize = 0.dp` 且不画末端圆点
      —— Material3 1.3（本仓 `compose-bom:2024.12.01`）的默认值是
      `gapSize = 4.dp` + `drawStopIndicator` 画一个圆点，这正是验收人说的
      「有断层，像有个和背景颜色一样的圆点在移动」
- [ ] 真机：自动触发的备份进行中点暂停 → 传输真的停下，进度条不再动

## 范围（追加）

- 也准动：`BackupUiStateHolder`（暂停动作与 `uiStateOf` 的选取）、
  `ui/HomeScreen.kt` 的进度条参数
- 仍不准动：手动通道自己的取消语义（`UX-01` 定的「跑着的时候再点 = 暂停」
  这条**语义**不变，变的只是「取消谁」）

## 实施记录（2026-08-26）

**改了四处：**

1. **`BackupWorker`：进程级互斥门 `backupInFlight`（AtomicBoolean）。**
   `doWork` 入口 CAS 抢门，抢不到早退；原 `doWork` 的正文抽成 `runBackup(ctx)`，
   门在 `finally` 里放（否则一次异常就永久卡死备份）。抢不到时返回**成功**而不是
   retry——重排一轮没意义，那一轮的活正在被别人干。
2. **`BackupUiStateHolder.backupNow()`：暂停按 id 取消正在跑的那条。**
   `cancelWorkById(runningWorkId)`，拿不到 id 才退回 `cancelManualBackup` 兜底。
   **删掉 `_state.value = BackupUiState.Idle`**——状态必须等 WorkManager 回报
   CANCELLED，界面不许自己编。
3. **提出 `runningInfoOf(infos)`：RUNNING 的选取确定化**（`filter { RUNNING }` +
   `minByOrNull { id.toString() }`）。`uiStateOf` 与暂停共用它，保证「界面在显示
   谁的进度」和「暂停会停掉谁」永远是同一条。
4. **`ui/HomeScreen.kt`：进度条覆盖 M3 1.3 的两个默认值**——`gapSize = 0.dp`、
   `drawStopIndicator = {}`。那道跟着进度头走的缝就是验收人说的「和背景颜色
   一样的圆点在移动」。

**顺带处理了一处冲突（值得记）：** 加互斥门等于新增一个终态返回点，撞上
`OneBackupPipelineTest.every_terminal_outcome_carries_a_finish_stamp`（MOB-31 立的
不变量：每个终态都要盖 `KEY_FINISHED_AT`，否则那条路径在 `uiStateOf` 眼里永远是
上古记录）。**直接盖戳会引入新 bug**：空转那轮 output 里没有 ingested，盖了戳就
可能盖过用户暂停留下的 CANCELLED（取消拿不到 outputData → 无戳 → 被当最旧），
界面显示「已备份 0 张」而不是 Idle。
解法是把两件事分开表达：新增 `KEY_SKIPPED`，空转走 `successStamped(KEY_SKIPPED to true)`
（满足盖戳不变量），`uiStateOf` 把带这个标记的记录 `filterNot` 掉。

**测试**：新增 `OnePipelineOnePauseTest` **8 例**。Android 全量 `--rerun-tasks`
**39 类 / 298 tests / 0 failures**（XML 时间戳 11:11:11 确认本次生成），
`assembleDebug` 绿。

**反证四条真跑，全部命中：**
- 暂停改回 `cancelManualBackup` + 自置 Idle → **2 红**
- RUNNING 选取改回 `firstOrNull` → **1 红**
- 去掉互斥门 → **1 红**
- 进度条去掉两个覆盖 → **1 红**

**真机验收还欠（验收人自己跑）**：自动触发的备份进行中点暂停 → 传输真的停下、
进度条不再动；进度条是一根标准直条（无断层、无末端圆点）；连续操作下进度文本
不再来回跳。

### 一条方法论教训（本轮第三次踩）

`only_one_backup_runs_at_a_time` 我自己写的时候钉的是 `return Result.success()`
这个**字面形状**，于是把早退改成 `successStamped(…)`（为满足盖戳不变量的正当
改动）就被自己的测试误伤变红。改成钉不变量：不许 retry / 不许 failure / 必须以
成功收场。**今天同一个坑踩了三次**（MOB-28 那条钉 `if (backupInterrupted) return@LaunchedEffect`、
MOB-34 那条钉整串参数表、以及这条）——**守卫测试要钉「不变量」，钉「形状」就会
在正当重构时误伤，而它并没有多守住任何东西。**
