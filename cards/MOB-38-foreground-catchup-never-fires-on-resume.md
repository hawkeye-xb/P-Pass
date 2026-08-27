# MOB-38 回到前台不补捞——切去相机再切回来，那张照片没人管　级别 L0

> 🟡 状态：代码已合并，等真机验收
> 级别：**L0** · 阻塞：无

## 问题

验收人反馈（2026-08-26 真机，0.4.0-test.5）：

> 「在前台，一张照片很久也没有同步。……就是，从我们 app 切换到相机，这样就
> 不算前台了吗？我记得咱们针对不同的 app 状态有过讨论的啊。」

**答案是：算前台，但我们没在「回到前台」这个时机补捞。**

前台补捞挂在 `MainActivity` 的：

```kotlin
LaunchedEffect(backupInterrupted) {
    …
    triggerUserPresentBackup(context)
}
```

`LaunchedEffect` 的键只有 `backupInterrupted`——**composition 存活期间只跑一次**。
Activity 走 STOPPED → RESUMED（切去相机再切回来）**不会**让它重跑，composition
本身没被销毁。

反差在于：`MainActivity` 里**已经有** `LifecycleEventObserver` / ON_RESUME 的
处理，而且不止一处——部分授权态刷新（MOB-02 §二）、电池白名单状态刷新
（DOG-02）、前台轻心跳的起停（PRES-01）全都挂在生命周期上。**只有备份补捞
没挂。**

于是这条链断了：用户从 App 切到相机、拍照、切回来 → 期待「我人就在这儿看着，
它该传了」→ 什么都没发生。如果那一刻内容监听也没接住（被 OEM 清过、防抖窗口
边界、force-stop 之后还没恢复），这张照片就只能等 5h 周期兜底。

## 期望行为

**回到前台就补捞一次**，与「打开 App 补捞一次」同等对待——MOB-14 定的语义原文
就是「打开 App 无条件补跑一次……用户开 App 的意图正是『看照片到家没有』」，
而「切回来」跟「打开」在用户心里是同一件事。

## 验收人给的状态模型（2026-08-26）

> 「实在不行，就优先后台的进程，后台的启动，前台的就不管了（可以不启动），
> 因为后台肯定会触发传输。后台没启动，最大限度的发挥前台能力。两者都没有，
> 那就没办法。是这样吗」

**方向对，但不需要二选一** ——理由见「备注／为什么不做互斥」。三条通道**都跑**
才是覆盖最大的：

| 通道 | 职责 | 时延 |
|---|---|---|
| 内容监听（后台，`MediaWatchJob`） | 主路径：新照片即时触发 | 1–2 秒 |
| 回到前台补捞（本卡） | 兜住「监听漏了 / 被清了 / 还没恢复」 | 用户切回来那一刻 |
| 5h 周期 | 最后兜底 | ≤5h |

## 验收标准

- [ ] 单测：`ON_RESUME` 会调用前台补捞（判据不许是「`LaunchedEffect` 里有那行」
      ——那正是现在这个 bug 的形状）
- [ ] 反证：把补捞改回只挂 `LaunchedEffect(backupInterrupted)` → 上一条变红
- [ ] 单测：暂停态（`AutoBackupPrefs.paused()`）下 ON_RESUME **不**补捞
- [ ] 单测：中断待确认（`backupInterrupted`）下 ON_RESUME **仍然**补捞，但
      **不**重挂后台监听（MOB-35 的红线不许破）
- [ ] 单测：连续 resume（切走切回三次）不产生三轮并行备份——靠 MOB-33 的
      `backupInFlight` 门收敛，判据是「第二、三次抢不到门就早退」
- [ ] 真机：从 App 切到相机 → 拍一张 → 切回 App → **照片自动传上去**，不用点任何东西

## 范围

- 只准动：`MainActivity.kt`（补捞的触发时机）及其测试
- 不准动：`triggerUserPresentBackup` 自己的语义与约束档（`BackupTier.USER_PRESENT`）；
  `MOB-35` 拆出来的那个门控（`if (!backupInterrupted) scheduleAutoBackup`）；
  `MOB-33` 的互斥门

## 阻塞与依赖

无。⚠️ 依赖 `MOB-33` 的 `backupInFlight` 已经落地——没有那道门，「每次 resume
都补捞」会造出一串并行备份（那正是 MOB-33 的原症状）。**MOB-33 已在
0.4.0-test.5 里**，所以本卡可以放心让三条通道都跑。

---

## 备注

### 为什么不做「后台优先、前台就不管」的互斥

验收人担心的是「两者都跑会乱」。**在 `MOB-33` 之前这个担心是对的**——四条通道
各自一个 unique name、没有互斥，两轮并行会让进度条乱跳、暂停按钮失效。

`MOB-33`（0.4.0-test.5）加了进程级互斥门 `backupInFlight`：抢不到就以成功早退。
**「都跑」现在是安全的**，重复触发的代价降到一次 CAS。所以不需要在通道之间做
优先级，覆盖面越大越好——每条通道都可能在某些场景下失效（监听被 OEM 清、
force-stop 后不恢复、Doze 推迟周期任务），而它们失效的场景**不重叠**。

## 实施记录（2026-08-26）

**改了两处，核心是「只写一份」：**

1. **`MainActivity.kt`：把「回到前台该做什么」提成共用闭包 `foregroundCatchup`**
   —— 门控（配对 / 暂停 / 中断标志）只有这一份。
2. **挂进那个已有的 `LifecycleEventObserver` 的 `ON_RESUME` 分支**，与既有四处
   刷新（电池白名单 DOG-02、通知权限、失联天数 SENT-01、部分授权态 MOB-02）
   和两处 start/stop（心跳 PRES-01、时间线订阅 SYNC-06）并列。
   `LaunchedEffect(backupInterrupted)` 保留（冷启动也得补一次），但它现在只转调
   共用闭包，不再自己持有逻辑。

**为什么提成函数**：不是为了少打字，是**让「漏接一处」变得不可能**。两处各写
一遍门控的话，下次改其中一条就又会漏——`MOB-33`/`34`/`35`/`38` 四个 bug 全是这个
形状。测试里专门有一条 `the_catchup_logic_exists_in_exactly_one_place` 钉它。

**为什么放心「每次 resume 都补」**：`MOB-33` 的 `backupInFlight` 互斥门在管线
入口，重复触发的代价降到一次 CAS（抢不到就早退）。在 `MOB-33` 之前这么做会造出
一串并行备份——那正是 `MOB-33` 的原症状。

**测试**：新增 `ForegroundCatchupOnResumeTest` 4 例。判据刻意**不是**「
`LaunchedEffect` 里有那行」——那正是这个 bug 的形状。Android 全量 `--rerun-tasks`
**43 类 / 326 tests / 0 failures**（XML 14:43:13 确认本次生成），`assembleDebug` 绿。

**反证两条真跑**：删掉 `ON_RESUME` 里那行 → 1 红；门控退回 `LaunchedEffect`
内联（两处各写一遍的形状）→ 2 红。

**真机验收还欠（验收人自己跑）**：从 App 切到相机 → 拍一张 → 切回 App 摆着不动
→ 照片自动传上去，不用点任何东西。

### 顺带修了三条被误伤的既有测试（本轮第四次同款）

逻辑从 `LaunchedEffect` 块搬进 `foregroundCatchup` 之后，`MOB-35` 的三条源码断言
（`ForegroundSyncNotFrozenTest` ×2、`WatchRecoveryTest` ×1）全红——**它们守的三条
不变量一个没变，只是切片位置过时了**。改切片目标即可。

**这已经是本仓第四次「逻辑正当搬家 → 源码文本断言误伤」。** 判据本身是对的
（守的是真不变量），但**源码文本断言天生与位置耦合**。这条写进了
`ForegroundSyncNotFrozenTest` 的注释里，专门提醒 `MOB-39` 的实施者：那次重构会
搬动更多逻辑，这类断言会成批变红，届时要改的是切片位置，不是不变量。

### 还有一条我自己当场踩的坑

修那三条时我顺手加了一条正则断言「不许用 `!backupInterrupted` 把前台补捞包住」，
**当场就误报了**：Kotlin 的单语句 `if` 没有花括号，
`if (!backupInterrupted) scheduleAutoBackup(context)` 之后紧跟的
`triggerUserPresentBackup(context)` 其实在 `if` 之外，而正则按「N 个字符内出现」
判命中，**分不出作用域**。已删，并在原处留了注释：**别用正则去猜作用域，文本
匹配做不到这件事**——真正守住那条的是姊妹断言
`contains("if (!backupInterrupted) scheduleAutoBackup")`（单语句形式意味着门控
只作用于那一句）。
