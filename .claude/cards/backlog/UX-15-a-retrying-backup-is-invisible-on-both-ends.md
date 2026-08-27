# UX-15 传输失败后两端都不说话（backlog · 建议提级 L1）

**状态**：⬜ 未开工 · backlog（验收人 2026-08-27 点名：「连接成功之后，图片
传输失败，手机端都没有错误提示这些，desktop 也没有相关的状态提示」）

## 这不是「缺一句提示文案」

调查时找到了机制，它比「没写提示」严重：**重试中的备份在手机 UI 的状态机里
没有位置**。

`BackupUiStateHolder.uiStateOf` 的终态选取（`BackupUiStateHolder.kt:415`）：

```kotlin
val finished = infos.filter { it.state.isFinished }
```

`Result.retry()` 之后 WorkManager 把 work 置为 **`ENQUEUED`**（等退避，
`runAttemptCount` 自增）。而 `ENQUEUED` 的 `isFinished == false`。于是：

- 不进 `finished` → **永远不会渲染 `Trouble`**（那条红卡只对 `FAILED` 生效）
- `runningNow == null`（不是 `RUNNING`）→ 不显示进行中
- 落到最后的 `Idle` / `AllSafe` 分支 → **界面说「照片都存好了」或干脆沉默**

代码里那句注释正是缺口所在：

```kotlin
// 没有在跑的，看**最近**一条终态。ENQUEUED（等约束）不改状态行——
// 手动触发是零约束不会排队；自动触发排队时界面另有「已排队」提示行。
```

作者当时想到的 `ENQUEUED` 只有一种来源:**等约束**（充电/WiFi）。漏掉了
第二种:**等重试退避**。两种在 `WorkInfo` 里长得一模一样，区别只在
`runAttemptCount > 0`。

## 与 UX-14 同根，表现相反

UX-14 已经修了 `Result.retry()` 不留终态戳导致的一个后果——把中断显示成
「被暂停」。这一卡是**同一个根的另一个后果**：不留戳、状态又是 `ENQUEUED`，
于是连「被暂停」都判不出来，直接沉默。

`retry` 这条路在 UI 侧一共造成三种错误呈现，已知两种、修了一种：

| 后果 | 卡 | 状态 |
|---|---|---|
| 显示成「被暂停」（又冒出「继续」按钮） | UX-14 | ✅ 已修（test.9 待验） |
| 显示成 `Idle`/`AllSafe`——**失败了却说都存好了** | **本卡** | ⬜ |
| 退避期间新触发被 unique work 吞掉，界面无反应 | NET-01（上游） | ⬜ |

## desktop 侧另一半

验收人同时报告「desktop 也没有相关的状态提示」。daemon 视角下手机传一半断开
= 一个连接掉了，它**本来就不知道对方还想传多少**——所以 desktop 侧未必是缺
陷，而是缺一个「某设备上次传输未完成」的表达。这半边要先取证 daemon 日志里
有没有记录这次中断（见
`docs/evidence/2026-08-26-home-partial-upload.md` B 段），再决定是补 UI 还是
补 daemon 的事件。**不要先假设 desktop 该显示什么。**

## 期望行为

手机端：退避中的 work 必须是一个**用户能看见的状态**，且不许自称成功。

- `runAttemptCount > 0` 且 `state == ENQUEUED` → 「上次没传完，稍后自动重试」
  （若能拿到下次尝试时间就说出来）
- 这个状态下**绝不许**渲染 `AllSafe`（「照片都存好了」）——那是假话，与
  MOB-40 定的红线同一条
- 用户要有立即重试的出路（复用 UX-13 的英雄区按钮，不新开路径）

## 验收标准

- [ ] 纯函数级：给定 `state == ENQUEUED && runAttemptCount > 0` 的 WorkInfo，
      `uiStateOf` 返回的既不是 `AllSafe` 也不是 `Idle`
- [ ] 区分两种 `ENQUEUED`：`runAttemptCount == 0`（等约束）行为不变——不许
      为了修这条把正常排队也说成「重试中」
- [ ] 真机：传输中途断开 daemon → 手机界面出现重试态而**不是**「都存好了」
- [ ] 源码断言钉不变量：终态选取不许只看 `isFinished` 就决定「没事干」

## 范围

`apps/android/.../backup/BackupUiStateHolder.kt`（状态合成）、
`apps/android/.../ui/BackupStatus.kt` + `HomeScreen.kt`（新状态的呈现）、
`apps/android/app/src/main/res/values*/strings.xml`（文案，含 en）。

**不准动**：`BackupWorker` 的重试策略本身（退避参数是 NET-01 的范围）。

## 阻塞与依赖

无。但与 NET-01 有重叠——建议**先做本卡**：让失败可见，比调退避参数更急，
且它是调参之后能观察到效果的前提。

## 为什么建议提级 L1

「失败了却显示『照片都存好了』」和 MOB-40（还没选相册就说都存好了）是同一
类问题——**对着一个没备份成功的用户说他的照片安全了**。MOB-40 当时判 L0。
本卡差别在于它需要一次网络失败才触发，不是必现；但一旦触发，用户会以为照片
已经安全、然后删掉手机上的原图。
