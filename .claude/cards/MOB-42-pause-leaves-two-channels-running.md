# MOB-42 「暂停自动备份」漏掉两条通道（L2）

**状态**：⬜ 未开工（2026-08-27 排查家中故障时查出，非验收人报告）

## 缺陷

`BackupWorker.kt:373` 的 `pauseAutoBackup` 取消了四样东西：

```kotlin
fun pauseAutoBackup(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(BACKUP_WORK_NAME)
    cancelMediaWatch(context)
    WorkManager.getInstance(context).cancelUniqueWork(MEDIA_WATCH_BACKUP_WORK_NAME)
    WorkManager.getInstance(context).cancelUniqueWork(PROCESS_CATCHUP_WORK_NAME)
    AutoBackupPrefs(context.filesDir).setPaused(true)
}
```

**漏了 `CATCHUP_WORK_NAME`**（`triggerUserPresentBackup` 用的通道，
`BackupWorker.kt:208`）。

`MANUAL_BACKUP_WORK_NAME` 也没取消——但那一条是**对的**，手动是当场指令，
不受「暂停自动备份」管（`triggerManualBackup` 的注释已经立了这条）。

## 后果

暂停之后，`CATCHUP_WORK_NAME` 下已经排着的 work 仍然会跑。

它在什么情况下已经排着：用户打开 App → `foregroundCatchup()` →
`triggerUserPresentBackup`。也就是**「打开 App 然后在设置里点暂停」这个
最自然的操作顺序**，恰好留下一条活的 catchup work。

`doWork` 里有 paused 判断吗？`PROCESS_CATCHUP_WORK_NAME` 那条的注释说
「PPassApp 里另有一道 paused 判断」——那是**入队侧**的判断，不是 worker
侧的。需要确认 worker 内部有没有 paused 闸门；如果没有，这条漏网的 work
会实打实地传一批照片。

## 顺带：这也堵死了一条排查手段

排查家中故障（`docs/evidence/2026-08-26-home-partial-upload.md`）时想用
「暂停 → 恢复」当作清掉卡死 work 的解锁动作——因为它是唯一不丢配对的重置
手段。漏了 `CATCHUP_WORK_NAME` 意味着**这个动作清不干净**，卡在退避里的
catchup work 会活下来，解锁不成立。

## 期望行为

暂停 = 所有**自动**通道停下，一条不漏。手动通道不受影响（现状正确）。

## 验收标准

- [ ] 打开 App（留下一条 catchup work）→ 点暂停 → `CATCHUP_WORK_NAME` 下
      不再有未完成的 work
- [ ] 暂停期间「立即备份」照旧能跑（不许为了修这条把手动也停了）
- [ ] 确认 worker 内部有 paused 闸门；没有就补——入队侧的判断挡不住已经
      排着的 work
- [ ] 源码断言钉不变量：`pauseAutoBackup` 必须覆盖**全部**自动通道常量。
      钉法是**遍历常量**而不是列举当前四个，否则下次新增通道又会漏
      （MOB-33/34/35/38 全是「漏一处」的形状）

## 范围

`apps/android/.../backup/BackupWorker.kt`（`pauseAutoBackup` + 可能的 worker
侧闸门）。

## 阻塞与依赖

无。
