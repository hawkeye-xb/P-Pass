# MOB-37 重传告知只发一条通知，发失败就永久静默　级别 L1

> ✅ 状态：代码已合并（commit 94574b1），2026-08-27 真机验收通过，验收人认定归档
> 级别：L1 · 阻塞：无

## 问题

`MOB-29` 的手机端告知（「资源在客户端丢失，正在重传」）**只有一条系统通知**，
而且**天然一次性**：校准算出 `lost` → 发通知 → `removeMissing` 把这批 hash 从
`confirmed` 剔除 → 下一轮算不出同一批 → **不会再提示**。

我（Claude）当初把这个「一次性」写成了优点（「连去重窗口都不用做」）。
**那是把缺陷说成了优雅**：一次性 = 没有重试 = **那一次发失败就永久静默**。

失败的路子不止一种：通知权限没授（Android 13+ 不主动申请永远拒绝）、渠道被
用户关掉、系统丢弃、用户手滑划掉、锁屏时没看见。

### 真机现场（2026-08-26）

验收人在访达里删了 3 张，**重传确实发生了**（09:58:50 删 → 09:59:11 自动传
回来，21 秒），但他**没有看到任何手机端提示**。通知权限当时的状态存疑
（通知设置在 10:01:53 有一次变更，晚于 09:59:11 那次告知）。

验收人原话：「desktop 删照片后，mobile 没有任何提示。是我们的预期吗？」
以及：**「通知没发送，本地 UI 需要有状态吗？还是通知通知出来就好了。」**

## 期望行为

**通知退化成「提醒你去看」，不再是唯一载体。**

- 告知状态**落盘**，在 App 内可见（与 `MOB-28` 的中断提示同款呈现），
  用户下次打开 App 就能看到「有 N 张照片被重新传了回来，因为电脑上少了它们」。
- 通知**不重试**——重试通知只会制造骚扰，而且解决不了「用户当时没看」。
  正确的兜底是「状态在 App 里等他」。
- 用户看过之后可消（acknowledge），消掉就不再显示。

## 验收标准

- [x] 单测：校准算出 `lost` → 状态落盘；**即使通知发送抛异常，状态仍在盘上**
- [x] 反证：去掉落盘、只发通知 → 上一条变红
- [x] 单测：App 内呈现读的是落盘状态，不依赖通知是否送达
- [x] 单测：acknowledge 之后不再显示；新一批 `lost` 会重新显示
- [x] 单测：**不重试通知**（同一批状态不许发第二条系统通知）
- [ ] 真机：关掉通知权限 → 在访达里删几张 → 打开 App，**App 内必须能看到这件事**

## 范围

- 只准动：`apps/android/.../backup/`（告知状态的落盘与读取）、承载呈现的
  那个界面、`res/values*/strings.xml`（文案）及其测试
- 不准动：`MOB-29` 的语义（重传是正确行为，不拦）；`MOB-34` 的定向补偿逻辑；
  `MOB-28` 的中断提示状态机（同款但独立，别混成一个）

## 阻塞与依赖

无。呈现方式建议复用 `MOB-28` 中断提示那套（`BackupHealthPrefs` 同款的
落盘 + acknowledge 模式），**但要独立存储**——两件事语义不同，混在一个标志里
会互相清掉。

⚠️ 与 `UI-04` 有交集：那张卡在改「提示只出现在总览 / 多条提示堆叠」。本卡新增
一条提示，**呈现位置与优先级要跟 UI-04 对齐**，别又造一条只在总览可见的提示。

---

## 备注

顺带记一条给未来的自己：**「天然一次性，连去重窗口都不用做」这种话要警惕。**
省掉一套机制的时候，先问「省掉的那套机制本来在防什么」——这里防的是
「投递失败」，而通知的投递恰恰是最不可靠的一环。

---

## 实施记录（2026-08-26，commit 94574b1）

### 改了哪几处

| 处 | 改动 | 为什么 |
|---|---|---|
| `apps/android/.../backup/ReuploadNotice.kt`（新） | 落盘状态 `ReuploadNoticeState`（**hash 并集**，不是累加计数）+ `ReuploadNoticePrefs`（tmp+rename，`record` 返回「是否从无到有」）+ `noteReuploadNotice`（**先落盘、再发通知，通知的异常吞掉**） | 告知的载体从「一条系统通知」变成盘上一条状态；形状照 `BackupHealthPrefs`，**存储独立**（两件事语义不同，混一个标志会互相清掉） |
| `apps/android/.../backup/BackupWorker.kt` | `calibrateIfReachable` / `calibrateTail` 多收一个 `ReuploadNoticePrefs`；`onLost` 里 `postReuploadNotification` 改为经 `noteReuploadNotice` 调用 | 后台那条校准门（含收尾补校准）落盘；通知退化成「提醒你去看」，发不出去不影响告知 |
| `apps/android/.../backup/BackupUiStateHolder.kt` | 第二条校准门（App 打开那次）也落盘（**不发系统通知**）+ 新增 `reuploadNoticeCount` 状态、`acknowledgeReuploadNotice()`、`refreshReuploadNotice()`（init + WorkManager 状态流里各读一次盘） | 少这一处，这条门上的告知就丢——而它正是真机验收那个场景的发生地（打开 App 才发现电脑上少了照片）。人就在看着 App，这里发通知是噪音 |
| `apps/android/.../ui/HomeNotices.kt`（新） | `HomeNoticeKind` + `HomeNotice` + `HOME_NOTICE_PRIORITY` + 纯函数 `topNotice` + 统一渲染的 `NoticeCard` | 给 `UI-04` 留的接口（见下节）。新增这条提示从第一天就是可接入的形状，不硬编码进 HomeScreen 某个位置 |
| `apps/android/.../ui/HomeScreen.kt` + `MainActivity.kt` | 新参数 `reuploadNoticeCount` / `onAcknowledgeReupload`，经 `NoticeCard` 呈现；数据来自 holder | App 内可见 + 可 acknowledge |
| `res/values{,-zh}/strings.xml` | `reupload_notice_body`（带 `%1$d`）+ `reupload_notice_action` | 中断提示那套用的是 Android 自己的 `R.string`，照同一处放（`StringsSymmetryTest` 守 en/zh 对称）。**没动** `assets/i18n` / `crates/diag`——那是 MOB-29 通知文案的家，本卡一行未改 |

### 语义上刻意如此的三条（别读成 bug）

1. **系统通知只在 acknowledged → unacknowledged 那一次跃变时发。** 已经有一条
   待看告知时又来一批新的 lost，App 内的张数会跟上，但**不发第二条通知**——
   「不重试通知」是卡面定调，重试只制造骚扰且治不了「用户当时没看」。
2. **App 打开那条校准门只落盘、不发通知。** 人就在看着 App，App 内那条提示
   就是呈现。卡面只要求两处都落盘。
3. **告知存在 `backup-state/<daemonNodeId>/`**，所以断开配对时既有的
   `deleteRecursively` 顺手把它清掉——告知不会比它描述的那段配对活得更久。

### 张数为什么是 hash 并集而不是累加

`MOB-33`：手动通道与周期通道可以并发校准，两轮都可能在对方 `removeMissing`
之前看到**同一批** missing。累加 `count += lost.size` 会把 3 张记成 6 张——
一个编出来的数字。并集让重复登记幂等，张数由集合大小导出。

### 给 UI-04 留了什么接口

`ui/HomeNotices.kt`：

- `HomeNoticeKind`——六个类别（配对失效 / 中断 / 部分授权 / 电池白名单 /
  通知权限 / 重传告知），单测钉「每个类别都必须登记在优先级表里」。
- `HomeNotice(kind, body, actionLabel, onAction)`——一条提示的全部数据，
  文案已解析成字符串，所以这个类型能进 JVM 单测。
- `HOME_NOTICE_PRIORITY` + 纯函数 `topNotice(list)`——「同时有多条只显示最要紧
  的一条」的判据在这里，已有单测。**排序是提案**，UI-04 可以重排（那张卡建议
  「阻塞备份的 > 需要授权的 > 补充信息的」，重传告知属于补充信息，现在排末位）。
- `NoticeCard(notice)`——琥珀底一句话 + 右侧下划线动作，与既有四条提示同一族视觉。

**刻意没做的**：既有那几条提示**没有**迁进这个骨架。迁移是 UI-04 的活，而且
会跟正在进行中的 `HomeScreen` 改动撞车。本卡只保证新增的这条是可接入的形状，
UI-04 把其余几条包成 `HomeNotice` 丢进 `topNotice` 即可，不用返工。同理，
「提示在所有页面可见」也整条留给 UI-04——本卡没有把这条提示做成只能在总览
显示的东西（它是数据 + 一个可复用组件），但也没有去改 tab 架构。

### 测试输出

```
$ export JAVA_HOME=/opt/homebrew/opt/openjdk ANDROID_HOME=<sdk>
$ ./gradlew :app:testDebugUnitTest --rerun-tasks
BUILD SUCCESSFUL
  40 个类 / 302 tests / 0 failures / 0 errors / 4 skipped
  （XML 全部于本次运行重新生成，最旧 = 最新 = 11:10:48）
  TEST-...backup.ReuploadNoticeTest.xml   tests=7 failures=0
  TEST-...ui.HomeNoticesTest.xml          tests=5 failures=0
  TEST-...backup.CalibrationTest.xml      tests=10 failures=0   （MOB-29 未回归）

$ ./gradlew :app:assembleDebug
BUILD SUCCESSFUL
```

rebase 到 `MOB-33`（59ecab3，动了同两个文件）之上后**重跑一遍**（合并语义
按派卡人交代手动确认：那边改的是暂停/选取与进度条，这边加的是提示呈现）：

```
$ ./gradlew :app:testDebugUnitTest :app:assembleDebug --rerun-tasks
BUILD SUCCESSFUL
  41 个类 / 310 tests / 0 failures / 0 errors / 4 skipped
  （XML 全部于本次运行重新生成，最旧 = 最新 = 11:15:44；app-debug.apk 同刻产出）
```

只动 `apps/android/**` → 受影响 CI 域只有 **ci-android**（`crates/`、
`assets/`、`apps/desktop/` 一行未动）。

### 反证（真跑了，不是声称）

把 `noteReuploadNotice` 改成**只发通知、不落盘**
（`if (lost.isEmpty()) return; notify()`）：

```
ReuploadNoticeTest > state_survives_a_notification_that_throws FAILED
  java.lang.SecurityException: no POST_NOTIFICATIONS permission
ReuploadNoticeTest > calibration_prunes_the_cache_even_when_the_notification_throws FAILED
  java.lang.AssertionError: 交互成功即算可达
ReuploadNoticeTest > a_pending_notice_never_sends_a_second_system_notification FAILED
  java.lang.AssertionError: 同一条待看告知只许发一次系统通知 expected:<1> but was:<3>
ReuploadNoticeTest > acknowledge_hides_it_and_a_new_batch_shows_again FAILED
  java.lang.AssertionError: expected:<1> but was:<0>
ReuploadNoticeTest > the_same_batch_twice_never_inflates_the_count FAILED
  java.lang.AssertionError: expected:<3> but was:<0>
7 tests completed, 5 failed
```

第二条那个红值得看一眼：去掉落盘之后，通知的异常一路冒到
`calibrateConfirmed` 的 catch，于是 `removeMissing` 被跳过——这批 hash 留在
`confirmed` 里，**下一轮校准会重新算出同一批、再发一条通知**。所以「先落盘 +
吞掉通知异常」同时守着两条判据：状态在盘上，以及同一批不发第二条通知。

如实记录：7 条里另外两条在反证下仍绿——`in_app_notice_reads_the_disk_not_the_notification`
直接调 `ReuploadNoticePrefs.record`（它是呈现侧的判据，不经过那个 helper），
`nothing_lost_writes_nothing` 断言的是空集早退（两版都有）。

### 还差什么

- **真机验收（验收人自己跑，agent 做不了）**：验收标准最后一条——
  ①把 P-Pass 的通知权限关掉；②在访达里从库里删几张已备份的照片；
  ③打开 App 的「设置」页（备份页），**必须**看到「有 N 张已备份的照片在
  电脑上不见了，正在重新传回……」那条琥珀提示；④点「知道了」它消失，
  再删几张后它会重新出现。
- 一条继承自 `MOB-29` 的边界原样成立：提示**不是拦截点**，校准与重传在同一趟
  里，中间没有让用户反应的窗口。提示是事后解释 + 教学。
- `UI-04` 的三条（提示只在总览可见 / 瞬时反馈占布局 / 多条堆叠实际收敛）
  留给那张卡——本卡只搭了可接入的骨架并把优先级判据先钉上单测。

## 验收记录（2026-08-27）

验收人真机验收通过（批量清理 QUEUE 待验收区），归档。
