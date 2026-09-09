# MOB-65 自动备份开关不得伪装成「暂停当前轮」（L2）

> 🟡 状态：代码完成（commit `717e4a2`），待共享真机验收
> 级别：**L2** · 阻塞：无
> 协同分支：`main` · 当前节点：实现与本地验证完成，下一步进行真机回归。

## 问题

关闭设置页「自动备份」当前会调用 `pauseAutoBackup()`，它同时写
`AutoBackupPrefs.paused=true` 并调用 `pauseFlow()`。后者把 Flow 的
`consumerGate` 写成 `PAUSED_BY_USER`，首页因而把「禁止后续自动触发」误投影成
「用户暂停了当前轮」，展示「继续」和「取消当前轮」；即使不存在当前轮也会出现。

两个动作的业务事实不同：自动备份开关只决定系统能否自行发起备份；暂停当前轮才
暂停已有的队列消费者。它们复用同一暂停事实，UI 不可能正确区分。

## 期望行为

- 关闭自动备份：持久化自动触发策略为关闭，取消所有自动唤醒与媒体监听；不改
  Flow 的 `consumerGate`，不改变当前轮，不触碰「继续 / 取消当前轮」语义。
- 开启自动备份：持久化策略为开启，恢复周期任务与媒体监听；后续是否开工仍由
  原有触发条件和约束决定。
- 当前已在传的轮次不由自动开关中断；用户要中断当前轮，使用既有「暂停当前轮」。
- 显式手动通道不被自动策略取消。

## 验收标准

- [ ] JVM：策略默认开启；关闭/开启持久化后重新读取保持一致；旧 JSON 的
  `paused=true/false` 分别迁移为 `autoEnabled=false/true`。
- [ ] JVM：自动开关关闭时，所有自动 WorkManager/媒体监听通道被取消；显式
  `MANUAL_BACKUP_WORK_NAME` 不在取消集合中。
- [ ] JVM：关闭或开启自动策略不会写 `ConsumerGate.PAUSED_BY_USER`；已有
  `PAUSED_BY_USER` 不被自动开关清掉。
- [ ] JVM：Flow 账本处于 `PAUSED_BY_USER` 时，自动开关关闭后再开启，原有
  「继续」语义仍由该账本事实决定，而不是由设置开关制造或清除。
- [ ] 反证：把关闭路径改回 `pauseFlow()`，相应测试必须失败。
- [ ] Android 全量 JVM 单测、debug APK、`just ci` 通过；测试计数以本次 XML
  为准。
- [ ] 真机：空闲时关闭自动备份不出现「继续 / 取消当前轮」；进行中的轮次不被
  开关打断；仅「暂停当前轮」才出现继续/取消。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/` 内的自动
  策略存储、自动唤醒/监听调度与设置页接线；对应 Android JVM 测试；本卡、
  `docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md`。
- 不准动：`backup/flow/` 的 `ConsumerGate`、暂停/继续/取消状态机和 Native
  delivery；桌面端；备份约束策略与周期频率。

## 阻塞与依赖

无。

---

## 设计约束

开关与当前轮是两条状态轴：`autoEnabled` 只能控制自动 producer（周期、前台
补捞、进程补捞、媒体监听）；`ConsumerGate.PAUSED_BY_USER` 只属于用户对当前轮的
暂停。禁止用 UI 隐藏条件掩盖仍被错误写入的 Flow 状态。

## 实施记录

- `AutoBackupPrefs` 从 `paused` 改为唯一策略事实 `autoEnabled`；旧 JSON 的
  `paused` 字段按反义兼容读取，下一次保存写新字段。
- `disableAutoBackup` 只持久化策略、取消自动 work / media watcher；删除
  `pauseFlow` / `continueFlow` 接线，也不取消 `MANUAL_BACKUP_WORK_NAME`。
  自动 worker 用 input data 标注；策略关闭后旧的自动 wake 无操作，显式 manual
  wake 仍可进入同一 Flow。
- 设置 UI 改传 `autoBackupEnabled`；前台/进程补捞、周期、媒体监听和 health
  对账均只读该策略。Flow ledger、英雄区暂停/继续/取消投影未改。
- RED：新偏好 API 尚不存在时 `AutoBackupPrefsTest` 编译失败（10 个
  `enabled` / `setEnabled` unresolved references）。反证：在关闭路径临时加入
  `pauseFlow(` 标记，`disabling_automatic_backup_never_turns_into_a_current_round_pause`
  实测 **8 tests / 1 failed**；已还原。
- GREEN：Android JVM **62 XML / 322 tests / 0 failures / 0 errors / 4 skipped**；
  `:app:assembleDebug`、`just ci` 均通过。

## 真机验收

- 空闲关闭/开启自动备份：英雄区不出现「继续 / 取消当前轮」。
- 自动传输中关闭开关：当前轮继续收尾；之后新增照片不得由自动通道启动。
- 仅点英雄区「暂停」：才出现「继续 / 取消当前轮」；关闭再开启自动开关不得
  制造或清掉该用户暂停。
