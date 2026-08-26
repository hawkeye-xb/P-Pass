# UX-13 暂停之后按钮消失，首页没有续传入口　级别 L1

> 🟡 状态：代码已合并（commit 2315259），等真机验收
> 级别：L1 · 阻塞：无

## 问题

验收人反馈（2026-08-26 真机）：**「暂停之后，没有重新开始的按钮？」**

`ui/HomeScreen.kt` 的英雄区：

```kotlin
if (busy && !pairingLost) {
    HeroSecondaryButton(label = stringResource(R.string.backup_pause), onClick = onBackupNow)
}
```

`busy = line is StatusLine.Working`。**按钮只在备份进行中渲染**，一暂停
`busy` 变 false，按钮整个消失——首页没有任何「继续」入口。想续传只能进
设置页找那个低调的「立即备份」。

**这与 `UX-01` 卡面自己写的语义冲突**：那张卡的原文是「备份进行中再点 = 暂停
……**再点一次 = 续传**（重新 offer 全部候选，收敛缺 0）」。管线侧确实支持续传，
**但界面上没有那个「再点一次」可点**。

⚠️ 这不是 `MOB-33` 改出来的。`MOB-33` 之前那句 `_state.value = BackupUiState.Idle`
同样让 `busy` 变 false、按钮同样消失。**是既有缺陷，只是以前没人试着去点第二次。**

## 期望行为

同一个位置的按钮在两种状态间切换，暂停后仍然在原地：

| 状态 | 按钮 |
|---|---|
| 备份进行中 | 「暂停」 |
| 刚被用户暂停（还有活没干完） | 「继续」 |
| 空闲、没有待办 | 不显示（现状，别改） |

关键区分：**「用户主动暂停」和「本来就没事干」是两种不同的空闲**。现在两者都
映射到 `Idle`，界面分不出来。

## 验收标准

- [ ] 单测：状态从 Working → 用户暂停 → 界面状态里能区分出「被暂停」而不只是
      `Idle`（判据：有一个独立的状态或标志，不是靠 `Idle` 猜）
- [ ] 单测：被暂停态下英雄区按钮渲染为「继续」，点它走的是同一条管线
      （`triggerManualBackup`，不新增第二条路径——`MOB-19` 红线）
- [ ] 反证：把「被暂停」态去掉、退回统一 `Idle` → 上一条变红
- [ ] 单测：空闲且无待办时按钮**不显示**（现状不许回退成常驻按钮）
- [ ] 真机：备份中点暂停 → 按钮变「继续」且留在原地 → 点它 → 传输接着跑，
      缺口收敛到 0（不重传已完成的字节）

## 范围

- 只准动：`ui/HomeScreen.kt`（按钮的状态映射）、`BackupUiStateHolder`（区分
  「被暂停」）、`res/values*/strings.xml`（「继续」文案）及其测试
- 不准动：`MOB-33` 的暂停实现（按 id 取消正在跑的那条）；管线的续传语义
  （`UX-01` 定的「重新 offer 全部候选、dedup 收敛缺 0」）

## 阻塞与依赖

无。

---

## 备注

实现「区分被暂停」时注意 `MOB-33` 刚定的一条：**界面不许自己编状态**。
`MOB-33` 删掉了 `_state.value = BackupUiState.Idle`，理由是那会让界面与传输
脱钩。所以「被暂停」这个态也**不能**在点击时就地写死——要么从 WorkManager 的
`CANCELLED` 推导，要么落一个「用户暂停过」的标志再与 work 状态合成。

⚠️ WorkManager 取消时**拿不到 outputData**（`MOB-33` 实施时确认过），所以
CANCELLED 记录没有 `KEY_FINISHED_AT` 戳，在 `uiStateOf` 的时间戳选取里会被当
成最旧的——直接靠「最近一条终态是 CANCELLED」判断会不可靠。这是本卡最容易
踩的坑。

---

## 实施记录（2026-08-26）

### 方案：落一个「按下暂停的时刻」，与 work 真实状态合成

新增 `backup/PausePrefs.kt`（`pause_state.json`，tmp+rename，落在
`backup-state/<daemonNodeId>/` → 断开配对时随 `deleteRecursively` 一起清），
存**一个时刻**而不是布尔；判据是纯函数：

```kotlin
internal fun pausedAfterOf(pausedAt: Long, newestFinishedAt: Long, anyRunning: Boolean): Boolean =
    !anyRunning && pausedAt > 0L && newestFinishedAt < pausedAt
```

三条理由：

1. **不看那条 CANCELLED 记录**——取消拿不到 `outputData`，无戳记录在 MOB-31 的
   「按戳取最大」选取里恒被当上古记录，只要盘上还有一条带戳的历史成功记录，
   靠它判断「刚被暂停」就永远不成立（本卡点名的坑）。
2. **时刻不需要清除时机就能自证过期**：只要出现比它更新的完成记录，这次暂停
   就已经被后来的运行覆盖。布尔要有人负责清，清早了等于没记，清晚了得跟五条
   触发通道各自的开跑时机打交道。
3. **没破 MOB-33 的「界面不许自己编状态」**：合成时要求「没有 work 在跑」，
   所以点完暂停而字节还在传的那几帧，界面照旧显示进行中 + 「暂停」。记的只是
   「用户在这一刻按了暂停」这个**已发生的事实**，不是编出来的传输状态。

排除的做法：直接在点击时把状态写成 Paused（= MOB-33 删掉的那句的翻版）；
让 worker 在取消前留痕（`onStopped` 里写盘同样绕不开「谁负责清」，且取消是
协程被 cancel 的路径，写盘不可靠）。

### 改了哪几处

- `backup/PausePrefs.kt`（新）——落盘 + 纯判据 `pausedAfterOf`。
- `backup/BackupUiStateHolder.kt`——① 构造时**同步**读一次 `pausedAt`（异步读会
  跟 WorkManager 流的首帧抢跑，首帧赢了就算出 Idle，而下一次重算要等下一个 work
  事件，症状正是「暂停后杀 App 重开，继续按钮不见了」）；② 点暂停时**先**记时刻
  **再** `cancelWorkById`（顺序承重：标记要在 CANCELLED 那一帧之前就位）；
  ③ `uiStateOf(infos, pausedAt)` 按 `pausedAfterOf` 合成 `Paused`；④ 这次暂停被
  后来的运行覆盖时把标记清掉（内存 + 盘）——不清则 WorkManager 迟早清理终态记录，
  陈年 `pausedAt` 面对空列表又会让「继续」凭空复活。
- `ui/HomeScreen.kt`——新增 `BackupUiState.Paused`；英雄区按钮的渲染条件从
  `if (busy && !pairingLost)` 改为 `heroActionOf(...)`，**同一个位置换文案**，
  两个分支共用同一个 `onClick = onBackupNow`（MOB-19 红线：没有第二条管线）。
- `ui/BackupStatus.kt`（卡面「只准动」没列，**被迫要动**：`statusLineOf` 的
  `when` 对 sealed class 穷尽，加变体必须处理）——`Paused` 在状态**文案**上与
  空闲同档（Pending/Ready 照旧说欠账，不破 T-080 缺陷 a）；新增纯函数
  `heroActionOf` / `isBackupRunning`（后者同时是点击的裁决，于是「界面显示什么」
  与「点下去干什么」永远同一份判据）。
- `res/values{,-zh}/strings.xml`——新增 `backup_resume` = Resume / 继续。

**「继续」不加「待备份 K > 0」这道门**：`Paused` 的构造前提已经是「有一轮跑到
一半被打断、之后没有任何一轮跑完」，那本身就是「还有活没干完」；再拿三元组的 K
当门，会在三元组不可用（DOG-01d 退化为 null → K 传 0）时恰好把按钮藏起来——把本
卡要修的缺陷原样放回去。K = 0 时点一下最坏是跑一轮零新增的空转，跑完 `Paused`
自动过期。

### 测试

新增 `ResumeAfterPauseTest`（8 条）：被暂停 vs 本来就没事干判出两个不同状态、
字节还在传时不算暂停、暂停后跑完一轮就过期、**无戳 CANCELLED 不妨碍判定**、
接线（`uiStateOf` 真的按 `pausedAfterOf` 返回 `Paused` 且 holder 把 `pausedAt`
传进去、时刻真的落盘）、被暂停渲染「继续」且只有一个 `onClick = onBackupNow`、
空闲/都存好了/没相册/出错/配对失效一律不显示按钮、`Paused` 下 K>0 仍说欠账。

```
./gradlew :app:testDebugUnitTest --rerun-tasks   →  BUILD SUCCESSFUL
XML 统计（app/build/test-results/testDebugUnitTest/*.xml，时间戳
2026-08-26T07:01Z = 本次生成）：44 类 / 334 tests / 0 failures / 0 errors
（基线 43 类 / 326 → 本卡 +1 类 / +8 条）
./gradlew :app:assembleDebug                      →  BUILD SUCCESSFUL
```

### 反证（真跑）

把「被暂停」态去掉退回统一 `Idle`——删掉 `uiStateOf` 里那三行合成 + 删掉
`heroActionOf` 的 `Paused -> Resume` 分支：

```
> Task :app:testDebugUnitTest FAILED
ResumeAfterPauseTest > paused_renders_resume_in_the_same_place_and_reuses_the_one_pipeline FAILED
    java.lang.AssertionError at ResumeAfterPauseTest.kt:138
ResumeAfterPauseTest > a_user_pause_is_a_state_of_its_own_not_just_idle FAILED
    java.lang.AssertionError at ResumeAfterPauseTest.kt:70
ResumeAfterPauseTest > the_paused_state_is_actually_wired_into_uiStateOf FAILED
    java.lang.AssertionError at ResumeAfterPauseTest.kt:120
```

之后已还原，复跑 44 类 / 334 tests / 0 failures。

### 还欠真机（留给验收人）

备份中点暂停 → 按钮**留在原地**变「继续」→ 点它 → 传输接着跑、缺口收敛到 0
（不重传已完成的字节）。顺带看两条：① 暂停后**杀掉 App 重开**，「继续」必须还在；
② 一轮备份正常跑完之后，「继续」必须自己消失（不许常驻）。
