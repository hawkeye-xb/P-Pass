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
CONTENT_MAX_DELAY_MS:   15min → 30s    // 连拍封顶
```

### ⚠️ 为什么两个参数必须一起改

`setTriggerContentUpdateDelay` 的 AOSP 语义是**每次新变化都重置计时**：

> If there are more changes during that time, the delay will be reset to
> start at the time of the most recent change.

连拍速度远快于 1s（三星连拍可达 10 张/秒），若只把 update delay 改成
1s 而 max delay 仍留在 15min，计时会被连拍不断重置，**最后要等满 15
分钟才触发——比改之前更慢**。所以 max delay 同步收到 30s：单张 ~1s
就走，连拍最坏 30s 兜住。

测试里加了回归锁 `CONTENT_MAX_DELAY_MS <= CONTENT_UPDATE_DELAY_MS * 60`，
防止后人只改一个。

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

## 本卡未做（留给后续）

- **ContentObserver 快路径**：进程存活时可以做到毫秒级感知。但本卡把
  系统通道从 2min 降到 1.6s 之后，快路径的边际收益大幅下降，是否还
  需要待观察。正确形态是「observer 感知 → enqueue expedited work」，
  不能在回调里直接跑备份（后台起 FGS 受 Android 12+ 限制，现在的
  豁免是走 WorkManager 拿到的）。
- **失败后的探测节奏**：现在失败重试 2 次就放弃、干等 6h 兜底。用户
  实测撞到过一次电脑没响应导致 12 分钟延迟。可改成 30min → 2h → 6h
  递增探测，仍是 mobile 主动 touch（符合用户定的「desktop 被动存在，
  mobile 主动 touch」方向），不需要 daemon→手机的新通道。
- **暂停后台备份的入口**：机制（`pauseAutoBackup`/`resumeAutoBackup`）
  完整存在，但 UI 在 2026-08-18 上一轮被用户拍板隐藏「更多」卡时一起
  藏掉了。用户提出 mobile 端缺这个入口——建议只把暂停开关放回设置页
  底部、与「断开配对」同区（同为高风险低频操作），手动备份入口继续
  隐藏。
