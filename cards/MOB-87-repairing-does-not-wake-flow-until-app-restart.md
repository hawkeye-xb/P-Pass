# MOB-87 重新配对完成后不自动开始传输，必须杀掉 App 重开

状态：🟥 挂号
级别：L2（猜测；跨 UI 状态机与唤醒调度，且要真机验）
关联: 从 [NET-25](done/NET-25-flow-delivered-push-unverified-on-the-real-transfer-path.md) 的验收日志里捞出 ·
兄弟卡 [MOB-72](MOB-72-scope-selection-must-wake-flow-without-relaunch.md)（同一症状，触发条件是"选相册"）·
邻居 [MOB-62](MOB-62-unpair-must-reset-flow-runtime-and-wakes.md)（管的是断开后**旧**状态要清掉，不管新会话要不要起跑）

## 挂号段

- **现象**：App 内断开连接 → 重新扫码配对成功 → 沿用原来的相册选择（没有
  重新选）→ **什么都不发生**。验收人等了约 9 秒，把 App 划掉重开，1.7 秒后
  传输就开始了，25 张 5.4 秒跑完。
- **发现场景**：2026-09-17 做 NET-25 真机验收时，验收人自发做的一次断开重连，
  日志正好完整覆盖。
- **严重度猜测**：中。不丢数据、不卡死，传输最终会在下次 App 启动/后台唤醒时
  发生；但"配对完成了却毫无动静"在用户眼里就是坏了，而且验收人已经是第二次
  撞见这个形状（MOB-72 是选相册那条）。

## 备注（挂号时已核实，供接卡人省一次考古）

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

**候选根因（源码核实，但未做实验证伪，不得直接采信）**

`MainActivity.kt:230` 的 `foregroundCatchup`（负责 `scheduleAutoBackup` +
`triggerUserPresentBackup`）挂在 `LaunchedEffect(backupInterrupted)` 上
（`:238`）。它的触发键只有 `backupInterrupted`——**配对状态不在键里**。
`pairings.load() != null` 只是函数体内的门控，不是触发条件。于是：

- App 启动时首次组合 → 跑一次 → 已配对就补捞（这解释了为什么"重开就好"）；
- 会话内重新配对 → `backupInterrupted` 没变 → `LaunchedEffect` 不重跑 →
  没有任何人叫醒 Flow。

对照组就在同一个文件里：选相册那条路（`:901-903`）显式调了
`requestFlowScopeBackfillAndWake` + `triggerUserPresentBackup`——那是 MOB-72
的修法。**配对成功那条路没有对应的一行。**

⚠️ 接卡人注意：`foregroundCatchup` 的注释自己写着「提成函数不是为了少打字，
是为了**让「漏接一处」变得不可能**」，还列了 MOB-33/34/35/38 四个同形状的 bug。
本卡大概率就是第五个——修的时候应该想的是「还有哪些用户在场的状态跃迁没接」，
而不是只给配对补一行。

**这不是 MOB-62**：MOB-62 管的是断开后**旧** Flow 运行态/调度必须清干净
（症状是旧 offer 乱发、ANR、崩溃）。本卡症状相反——新会话**太安静**，
一个 offer 都没发。两张卡不冲突，但别合并。
