# MOB-14 进程被杀窗口期的 MediaStore 通知丢失，且无人补捞　级别 L2

**用户报告**（2026-08-19）："我关了网络拍照，然后开网络连接 Wi-Fi，没有
触发同步啊""我等了 60 多秒了也都没有同步过来，为什么呢？"

## 现场时间线（真机 logcat + JobScheduler dump）

```
10:39:23  Displayed com.hawkeyexb.ppass/.MainActivity     ← 用户打开 App
10:39:50  Killing 26880 (adj 900): remove task            ← 用户从最近任务划掉
10:40:07~09  用户连拍（ProactiveSyncWorker 在跑，确认已落库）
10:40:18  Start proc 29137 for SystemJobService           ← 系统才拉起进程重排
10:44:30  下一个触发事件到来，整批一起传完（daemon backup_watermark
          last_gen 推到 3471 = 20260819_104009.jpg 的 generation）
```

即：拍照落在「进程被杀 → job 重排」的 28 秒窗口里，MediaStore 的变化
通知**无人接收**；job 重排后 `CONTENT_TRIGGER` 从零开始计时，那批照片
再也不会自己触发，只能等下一个事件（新照片 / 6h 周期 / 开 App）。

**照片没有丢**，只是延迟了约 4 分钟。用户等 60 秒就放弃，体感是"坏了"。

## 两个根因

### A. App 启动会 REPLACE 掉正在等待的 content trigger

```kotlin
fun scheduleAutoBackup(context: Context) {
    ...
    scheduleContentTriggerBackup(context)   // ← 默认 REPLACE
}
```

REPLACE 会取消**正在等待触发**的那个 job，它已经收到的 MediaStore 变化
通知随之丢失、`CONTENT_TRIGGER` 从零重新计时。用户拍完照顺手打开 App
看"传了没"，正好踩中 1s 防抖窗口，那张照片就再也不会自己触发。

**修**：App 启动路径改传 `ExistingWorkPolicy.KEEP`。约束变更不靠这条
路径生效——改设置走 `rescheduleAutoBackup`（REPLACE），每轮备份结束走
`ContentTriggerRearmWorker`（也是 REPLACE，且只在上一轮落终态后动手，
那时不存在待处理通知）。

### B. 事件④的 24 小时门槛让通知丢失无法被及时补捞

```kotlin
if (System.currentTimeMillis() - lastSuccess > MOB_APP_OPEN_GATE_MS) {  // 24h
    triggerUserPresentBackup(context)
}
```

MOB-02 定的门槛。后果：任何通知丢失的情况（进程被杀窗口、系统调度抖动）
都只能等 6h 周期兜底，而用户打开 App 的意图**恰恰就是**"看照片到家没有"
——这时候被门槛挡住不扫描，正是最反直觉的时刻。

**修**：门槛整个删掉，打开 App 无条件补跑一次。增量扫描 + hash 缓存很
廉价；`triggerUserPresentBackup` 内部走 unique work KEEP，连续切换也不
会叠加任务。

## 验证

- `:app:testDebugUnitTest --rerun-tasks` **184/184 绿**，新增两条回归锁
  `app_start_keeps_pending_content_trigger`、`app_open_has_no_time_gate`。
- **反证**：App 启动路径退回 REPLACE → 前者立刻红。

## 排查过程中的一次误判（记录，避免重演）

中途用 `stat -f "%SB" -t "%H:%M:%S"` 列电脑端文件并 `sort -r`，只输出
时分秒**没有日期**，于是昨天的 `17:25` 按字符串排在今天的 `10:44` 前面，
一度误判成"今天拍的一张都没传、数据丢失"。是查 daemon 的 `index.sqlite`
（`asset` 表 + `backup_watermark` 表）才发现整批 10:44:30 已入库。

**教训**：跨天的时间戳比较必须带日期；下结论前用第二个信源交叉验证
（这次是 daemon 的 sqlite 索引救了场）。
