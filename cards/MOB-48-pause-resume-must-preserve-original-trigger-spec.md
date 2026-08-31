# MOB-48 暂停/继续/重试必须恢复原始触发策略（L2）

> ⏸ 状态：冻结——ARCH-01 已定义 Pause / Continue / 条件等待与严格消费者的
> 新状态语义；本卡依赖的旧 `TriggerSpec` / enqueue facade 形状不许直接实施，
> 待按 ARCH-01 case matrix 重拆实施卡。
> 级别：L2 · 阻塞：依赖 MOB-39 的集中 `TriggerSpec` / enqueue facade

## 问题

当前 `BackupUiStateHolder.backupNow()` 在一轮运行中时写入 `pausedAt` 后取消
当前 WorkManager work；但在「已暂停」或失败时，下一次点击无条件调用
`triggerManualBackup`。因此本来由 `UserPresent`、`Watch`、`ProcessStart` 或
`Periodic` 触发的工作会被错误升级为 `MANUAL`：绕过 Wi-Fi/电量约束，并从水位
0 开始全量扫描。

同时，`AutoBackupPrefs.paused` 同时承担「自动备份开关」与 worker 全局闸门的
职责，现状会连真正的手动备份一起拦住；它也无法表示用户到底暂停了哪一种
触发策略。取消 work 后再落盘暂停态还留有竞态窗口。

## 期望行为

- 「暂停当前备份」是持久的管线暂停：先落盘，再取消当前 work；在用户点
  「继续」前，不让既有计划继续跑。
- 「继续」和失败后的「再试一次」恢复该轮原始 `TriggerSpec`，保留 tier、
  WorkManager constraints、`fullRescan`、`calibrate`、unique name 与 policy；
  不得暗中升级为 `MANUAL`。
- 自动备份开关只停止自动 kind；用户明确的 `Manual` 仍可运行。两种暂停状态
  不能复用同一个布尔值。

## 验收标准

- [ ] 单测：暂停 `UserPresent` / `Watch` / `ProcessStart` / `Periodic` / `Manual`
      任一运行 work 后，保存的 resume spec 与原始 spec 完全相同；「继续」入队
      使用相同 constraints、fullRescan 与 WorkManager policy。
- [ ] 单测：失败后的「再试一次」同样复用失败 work 的原始 spec；仅「立即备份」
      新建 `MANUAL` spec。
- [ ] 单测：管线暂停先持久化、后取消；在暂停未清除时，任何已经排队的执行 kind
      都不能进入校准/扫描/传输；「继续」原子清闸并恢复 work。
- [ ] 单测：`AutoBackupPrefs.paused` 只拦自动 kind，`Manual` 在自动开关关闭时仍能
      进入同一条管线。
- [ ] 反证：将 Paused/Retry 路径改回 `triggerManualBackup`，或丢失任一保存字段，
      恢复策略测试必须变红。
- [ ] Android 全量单测全绿；真机依次验证自动触发运行中暂停→继续、手动运行中
      暂停→继续、关闭自动备份后立即备份三条路径。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/` 内
  `PausePrefs`、`BackupUiStateHolder`、`BackupWorker` 的暂停闸与其相关测试。
- 可以消费：MOB-39 产出的 `TriggerSpec` / enqueue facade。
- 不准动：WorkManager 约束的产品策略、周期频率、MediaWatchJob 重挂红线、
  MOB-34 的校准/定向补偿语义、桌面端与 Rust crates。

## 阻塞与依赖

先完成 MOB-39：本卡不能从 unique name 或 `WorkInfo` 反推策略，必须直接保存并
恢复集中定义的 `TriggerSpec`。MOB-42 仍负责自动备份开关取消所有自动通道的覆盖面。

---

## 设计依据

ARCH-01 已定：`Resume` 不是新的执行 kind，而是消费保存的原始 `TriggerSpec` 的恢复
动作；管线暂停与自动备份开关是不同产品语义。这样既保住「手动明确指令可绕过
Wi-Fi/电量」，又不会让暂停后的自动任务悄悄变成无限制全量备份。
