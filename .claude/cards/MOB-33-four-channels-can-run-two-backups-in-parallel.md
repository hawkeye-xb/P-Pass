# MOB-33 四条备份通道各自一个 unique name，两个 BackupWorker 可以并行扫同一水位　级别 L2

> ⬜ 状态：未开工
> 级别：L2 · 阻塞：无

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
