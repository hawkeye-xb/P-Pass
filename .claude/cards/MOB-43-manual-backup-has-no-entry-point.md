# MOB-43 手动备份没有入口（L0）

**状态**：⬜ 未开工（2026-08-27 验收人第三次说「没有」之后我才去查源码，
实证他是对的）

## 缺陷

`R.string.backup_now`（"现在备份" / "Back up now"）在两个 strings.xml 里
都定义了，**UI 代码里零引用**：

```
apps/android/.../res/values/strings.xml:62    <string name="backup_now">Back up now</string>
apps/android/.../res/values-zh/strings.xml:60 <string name="backup_now">现在备份</string>
（HomeScreen.kt / MainActivity.kt 里没有任何 R.string.backup_now）
```

`holder.backupNow()` —— 手动备份的唯一入口 —— 只有三个调用点：

| 位置 | 触发条件 |
|---|---|
| `MainActivity.kt:512` | 权限授予回调（`grants.values.any { it }`） |
| `MainActivity.kt:630` | `if (needed.isEmpty())` —— 权限流程收尾 |
| `HomeScreen.kt:292` 英雄区按钮 | `if (heroAction != null)` |

前两个都在**权限流程**里，不是常驻入口。第三个受
`heroActionOf(state, pairingLost)` 门控——它在 `Idle` / `AllSafe` /
`NoAlbums` / `Trouble` 时**返回 null，按钮不渲染**（`ResumeAfterPauseTest`
的 `no_button_when_idle_with_nothing_to_do` 正是在钉这个行为）。

**后果：界面认为「没事干」或「都存好了」的时候，用户没有任何办法手动触发
备份。** 验收人 2026-08-27 原话：「立即备份的按钮我只能杀了重启，触发备份。」

## 这条卡的另一半是我的错

`BackupWorker.kt:63` 和 `triggerManualBackup` 的注释都写着「设置页低调
入口」（MOB-19）。**那个入口不存在**——注释描述的是设计意图，不是代码
现状。我据此让验收人去设置页找了三次，他三次说没有，我第三次才去查源码。

**教训：卡面注释不是事实来源。** 「代码里写着有」和「代码里有」是两件事，
后者只能靠 grep 引用点确认。这与本仓「源码断言只许钉什么必须成立」是同一条
纪律的另一面——注释说的话也要能被 grep 证伪。

## 为什么是 L0

它把用户堵死在一个无出路的状态里：

```
自动通道因为任何原因没跑（网络/退避/约束/未知）
        ↓
界面显示 Idle / AllSafe（UX-15：不说自己在等什么）
        ↓
heroAction == null → 按钮不渲染
        ↓
    用户唯一的办法：杀掉 App 重新打开
```

「杀 App 重启」能触发是因为 `triggerProcessStartCatchup` +
`foregroundCatchup`——那是**副作用**，不是设计给用户用的操作。一个照片备份
App 要求用户 kill 进程才能备份，等于没有手动备份。

## 期望行为

设置页（或任何常驻可达的位置）有一个**无条件渲染**的「现在备份」入口。

- **不受任何界面状态门控**——`Idle`、`AllSafe`、`Trouble` 时都在
- 走 `holder.backupNow()`（现有那条唯一管线，`MANUAL` 档零约束 + 全量重扫）
- 配对失效时可以禁用/说明原因，但**不许消失**——消失就回到本卡的缺陷
- 与英雄区那个条件按钮**不冲突**：英雄区是进行中/暂停时的主操作，这个是
  兜底出路。两者共用 `backupNow()`，不许出现第二条管线（MOB-19 红线）

## 验收标准

- [ ] 界面状态为 `AllSafe` 时，设置页仍有可点的「现在备份」
- [ ] 点它触发的是 `holder.backupNow()`，不是新开的路径
- [ ] `R.string.backup_now` 在 UI 代码里**被引用**（本卡的直接判据）
- [ ] 源码断言：`backup_now` 字符串存在 ⟺ 至少一处 UI 引用。**这条断言的
      形状是本卡的核心产出**——它能抓住"定义了字符串却没接线"这一整类缺陷
- [ ] 英雄区按钮在 `Idle`/`AllSafe` 时**仍然不渲染**（不许为了修这条把英雄区
      改成常驻按钮——UX-13 的 ③ 是刻意的）

## 范围

`apps/android/.../ui/HomeScreen.kt`（设置页区块）。

**不准动**：`heroActionOf` 的门控逻辑（UX-13 立的规矩）、
`BackupUiStateHolder.backupNow()` 的实现。

## 阻塞与依赖

需要验收人拍一个产品决定：这个入口**放在设置页哪个位置、叫什么**。默认
提案：设置页「备份」区块最下面一行，文案用现有的 `backup_now`。

## 与 UX-15 的关系

UX-15（重试中的备份两端都不可见）是「不告诉用户在等什么」，本卡是「不给
用户出路」。**两张卡合起来才是验收人遇到的那个死结**，单修一张都不够：
只修 UX-15 → 用户知道卡住了但还是只能杀 App；只修本卡 → 用户有按钮可点但
不知道为什么要点。
