# MOB-11 同步节奏改为「尽快送达」——content trigger 2min/15min → 1s/30s　级别 L1

**用户定稿**（2026-08-18）："我们不强行搞 2 分钟的 delay，只要能被系统
通知，content trigger，延迟一秒防止连拍，聚合的时间够，就快速的发起。"

## 背景

MOB-08 修好触发通道之后，用户真机实测两张照片的端到端延迟都是
**2 分 03 秒**——其中 2 分钟是 `CONTENT_UPDATE_DELAY_MS` 的安静窗口，
只有 ~3 秒是真正的传输。MOB-02 当时定这个参数是「连拍聚合 + 省电」
取向；实际体感是"拍完没反应"，用户明确要求改成尽快送达。

## 改动

```kotlin
CONTENT_UPDATE_DELAY_MS: 2min → 1s     // 防连拍抖动
CONTENT_MAX_DELAY_MS:   15min → 30s    // 持续 churn 封顶（非连拍）
```

### 两个参数的真实理由（⚠️ 2026-08-19 更正）

> **本卡初版（及 commit `8015e7b` 的 message、PROGRESS.md 那一行）写了
> 一句错话**："连拍会把计时不断重置，最后要等满 15 分钟才触发。"
> 用户当场戳穿："我们避免事件爆炸，不是避免触发事件。"——他是对的。

`setTriggerContentUpdateDelay` 是**尾沿防抖（debounce）**，不是节流
（throttle）：

> If there are more changes during that time, the delay will be reset to
> start at the time of the most recent change.

连拍期间计时不断重置，**连拍结束后 1s 只发一次**。所以 1s 能聚合任意
长度的连拍——它防的正是事件爆炸（20 张跑 20 轮备份），而不是推迟触发。
有限连拍的实际时间线是「连拍时长 + 1s + 调度」，**永远到不了 max
delay**。原话把"极端情况的保险"讲成了"1s 不够用"，是错的。

**max delay 15min → 30s 依然必要，但理由是另一个**：触发器挂在整个
images/video 集合上，截图、IM 收图、任何 App 写图都会重置计时。真有
进程在**持续**写 MediaStore 时，1s 的静默窗口永远等不到，max delay 是
从**第一次变化**起算的强制触发闸，防的是这种 churn 把备份饿死。15min
对"尽快送达"来说太长，收到 30s。

测试回归锁 `CONTENT_MAX_DELAY_MS <= CONTENT_UPDATE_DELAY_MS * 60` 保留，
但断言消息与注释已按上述理由重写。

## 同批的另一处：删掉「仅充电时备份」的后果解释文案

用户实机反馈"解释不清楚，白白占用空间"。删除
`R.string.req_charge_off_consequence`（en/zh 两份）及 `HomeScreen.kt`
里的 hint 接线。**仅 Wi-Fi 那行的提示保留**——流量后果是真金白银，
值得占这个位置。

## 验证记录

- `:app:testDebugUnitTest --rerun-tasks` **179/179 绿**（全量重跑，
  不走增量）。
- 真机 SM-S9210 实测：

```
注册参数确认：
  Trigger update delay: +1s0ms
  Trigger max delay:    +30s0ms

拍照 17:38:52
17:38:54.593 I PPassBackup: auto backup: offered=1 pushed=0 ingested=0
→ 端到端 1.6 秒（改前同一路径实测 2 分 03 秒）
```

（`pushed=0` 是测试图内容与前一张重复、hash 去重跳过，不影响时延结论。）

## 顺带修掉的既有红：Android 捆绑 i18n 副本漂移

`assets/i18n/{en,zh}.json` 新增了 `ui.photos_yesterday`/`ui.photos_week`
（desktop 照片墙分组三档→五档），但 `apps/android/.../assets/i18n/` 的
捆绑副本没同步，`DiagTextTest.bundled_assets_never_drift_from_repo_source`
红。已重新拷贝。

⚠️ **这个红在 main 上已经存在，之前被 gradle 增量构建掩盖**——只有改动
触发资源重编时才会跑到这个测试。教训：验收 Android 测试时用
`--rerun-tasks`，否则"全绿"可能只是没跑。

## ⚠️ 观察项：1s 节奏下的空扫描噪音（记录，暂不改）

用户提的"资源消耗不允许"正好戳中这里：1s 节奏下，**任何 App 写
MediaStore 都会触发一次 run**——截图、IM 收图、下载图片都算。而
`setForeground(foregroundInfo())` 在 `MediaScanner.scanSince` **之前**
（`BackupWorker.doWork`），所以哪怕扫描结果为空、立刻 `Result.success()`
早退，也已经闪过一次前台服务通知 + 建过一次本地 bind。

2min 时代这种噪音每两分钟封顶；1s 时代会成为常态。

缓解方向与取舍（**需要实测噪音量后再定，本卡不动**）：
- 把 scan 提到 `setForeground` 之前、空扫描直接返回 → 消除噪音，但
  FGS 提升推迟，长批次可能在提升前就被系统打断（削弱 S-04 的 Doze
  分段保护）。
- 或者只在 `scan.items.isNotEmpty()` 时才提升，扫描本身放在提升前的
  一小段"无保护窗口"里（扫描通常很快，风险可能可接受）。

## 本卡未做（留给后续）

- **ContentObserver 快路径**：进程存活时可以做到毫秒级感知。但本卡把
  系统通道从 2min 降到 1.6s 之后，快路径的边际收益大幅下降，是否还
  需要待观察。正确形态是「observer 感知 → enqueue expedited work」，
  不能在回调里直接跑备份（后台起 FGS 受 Android 12+ 限制，现在的
  豁免是走 WorkManager 拿到的）。
- ~~失败后的递增探测节奏~~ **（2026-08-19 用户否决，不做）**：曾提议
  失败后按 30min → 2h → 6h 递增探测。用户指出这**本质上还是轮询**，
  只是把主动方从 desktop 换成 mobile，没改掉"没事也要问一遍"的毛病。
  定案原则：**有活（新照片）才 touch，没活不 touch，6h 周期是最低
  限度的保险**。现有设计已经完整覆盖用户的连环追问——③兜的是"既没
  新照片也没开 App"的静默期；波动由 2 次短退避扛；desktop 真出错时
  "通知错误、不再自动重试"**已经存在**（UX-02 放弃本轮时通知 +
  SENT-01 连续不可达哨兵）。要动至多是调阈值，不加新机制。
  「daemon 上线主动通知手机」同样否决（用户："谁家云服务启动会通知
  所有客户"）。
- **暂停后台备份的入口**：机制（`pauseAutoBackup`/`resumeAutoBackup`）
  完整存在，但 UI 在 2026-08-18 上一轮被用户拍板隐藏「更多」卡时一起
  藏掉了。用户提出 mobile 端缺这个入口——建议只把暂停开关放回设置页
  底部、与「断开配对」同区（同为高风险低频操作），手动备份入口继续
  隐藏。
