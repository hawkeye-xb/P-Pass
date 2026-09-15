# MOB-81 legacy watch job 判据脱离 Flow 真实链路（backlog）

> 🔵 状态：backlog，无阻塞，非紧急
> 级别：L3（体验类边角，非数据安全风险）

## 背景

UI-12 这轮（2026-09-15）真机验证 `BackgroundBackupState.SystemStoppedWatcher`
时发现：这个状态的判据（`isMediaWatchScheduled` / `MEDIA_WATCH_JOB_ID`，见
`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/MediaWatchJob.kt`
与 `BackupHealth.kt`）查的是 **legacy JobScheduler 机制**，不是现在真正
执行媒体传输的 Flow 主链路（`backup/flow/AndroidFlowRuntime.kt`）。
`PPassApplication.kt` 的注释已经明确写了"Flow 是当前生产路径"。

真机 force-stop App 后系统会自动把这个 legacy job 重新排上
（`dumpsys jobscheduler` 可见 START/STOP 记录），没有触发 `ASK_USER`
分支，导致 `SystemStoppedWatcher` 这个 UI 状态在当前系统行为下很难
稳定复现——不是判定逻辑错（该逻辑有 `WatchRecoveryTest.kt` 16 个单测
覆盖判定表全组合，逻辑本身没问题），而是它监控的信号源已经不是
主路径的真实健康状况。

## 影响面（已确认，不紧急的理由）

- 这条 hint 只是"友好提示"层，不影响真实备份是否成功——Flow 有自己
  独立的传输状态呈现，用户即使错过这条提示，数据也不会因此丢失或
  静默停摆而无人知晓。
- 唯一风险：如果哪天用户反馈"开关正常但照片很久没传"，需要提醒
  排查方向——应该先查 Flow 侧状态，而不是这个 legacy hint，两者是
  两套独立信号源，容易查错方向。

## 期望方向（未拍板，供评估）

- 评估是否该把 `backgroundBackupStateOf` 的 `watcherScheduled`/
  `watcherInterrupted` 输入源从 legacy `MediaWatchJob` 改为查 Flow
  自身的运行健康信号（如上次成功心跳时间、Flow runtime 是否存活），
  使这个状态提示的信号源与生产链路对齐。
- 或者：如果 legacy watch 机制本身已经是可以退役的旧代码路径，
  评估直接移除它和相关判据分支，简化状态机。
- 两个方向都涉及改动 `backgroundBackupStateOf` 判据本身，按
  AGENTS.md「设计纪律」，需要先在卡内写清楚"标准做法是什么、为什么
  选择偏离"，不是本卡能直接动手改的范围。

## 验收标准（待细化，视选定方向而定）

- [ ] 明确 `SystemStoppedWatcher` 该基于哪个信号源判定（Flow 还是保留
      legacy，或两者都查）
- [ ] 若改判据来源，需要新的真机可复现的触发手段，验证时不能再依赖
      不可控的系统 job 调度行为
- [ ] 现有 16 个 `WatchRecoveryTest.kt` 单测按新信号源改写或确认仍适用

## 阻塞与依赖

无阻塞，用户后续回头确认方向再决定是否排期。
