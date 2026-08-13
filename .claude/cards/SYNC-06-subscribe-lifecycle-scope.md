# SYNC-06 订阅连接生命周期上提到 App 前台级别，脱钩 tab 切换　级别 L1【发现于 2026-08-13 用户 review，依赖 SYNC-04 已合并】

背景：SYNC-04 实现的前台订阅连接（`timeline.subscribe`，驱动"照片"
tab 家庭时间线的实时刷新）目前绑在 `PhotosScreen` 这个 composable 的
组合可见性上——只要切到"设置" tab，`PhotosScreen` 被移出组合树，订阅
连接跟着断，切回来又要重新建立。2026-08-13 用户 review 时指出这不
合理：只要 App 进程活着、处于前台（不管当前显示哪个 tab），订阅和
心跳都应该保持；只有"App 被系统回收进程"或"用户主动杀掉"才应该断开。
详细讨论过程见 `SYNC-04-android-foreground-subscription.md` 卡尾
"卡片信息更正（2026-08-13）"一节。

## 目标

订阅连接的生命周期跟 `ForegroundHeartbeat` 对齐（同一个 `ON_RESUME`~
`ON_STOP` 边界），不再跟"当前是不是显示照片 tab"挂钩。切到设置 tab
再切回来：**不重新建立连接，不丢失/延迟这期间到达的信号**。

## 范围

只准动：
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt`
  ——把订阅相关的状态（`subscribeAttempt`/`subscribeExhausted`/
  `subscribeConnected`/`subscribeHadFailure`/`items`/`next` 等）和驱动
  订阅的 `LaunchedEffect` 从 `PhotosScreen` composable 内部，抽到一个
  跟 `ForegroundHeartbeat` 同级、跟 Activity 前台生命周期绑定的地方
  （可以是一个新的小型 state holder 类，或者提升到 `MainActivity.kt`
  里跟 `heartbeat`/`loader` 并列持有，具体承载形式自定，但生命周期
  必须跟心跳一致）。`PhotosScreen` 只负责渲染这份状态，不再自己创建/
  销毁订阅连接。
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt`
  ——如果状态提升到这里，接线 `Lifecycle.Event.ON_RESUME`/`ON_STOP`
  （复用第 244~258 行附近 `ForegroundHeartbeat` 已有的
  `LifecycleEventObserver` 写法，别另起一套判断前台/后台的逻辑）。

## 不准动

- `ForegroundHeartbeat.kt` 本身的心跳逻辑（复用它的生命周期边界，不
  改它的实现）。
- `TimelineLoader`/`DaemonClient.subscribeTimeline` 的协议层实现
  （SYNC-03/SYNC-04 已验证，本卡只改"什么时候创建/销毁这个订阅"，
  不改订阅本身怎么工作）。
- `nextSubscribeRetry`/退避序列纯函数（`SubscribeRetryTest` 5 条已有
  测试覆盖，逻辑不变，只是触发它的生命周期容器变了）。
- daemon 侧任何代码（本卡纯 Android 端）。

## 设计要点

- 切到设置 tab 时，订阅连接**继续收信号**，只是不去刷新 Photos 相关
  UI（`items`/`next` 状态该更新还是更新，或者延迟到切回 Photos tab
  时再一次性用最新状态渲染——两种做法都行，但**连接本身不能断**，这是
  本卡的核心）。
- App 切后台（`ON_STOP`）：跟心跳一样停止——订阅连接主动关闭，不产生
  任何后台网络活动（呼应 PRES-01"后台绝不心跳"红线，这条连接现在才
  真正跟这条红线用同一套判断，而不是像 SYNC-04 那样只是文档里这么说、
  代码里没接）。
- App 回前台（`ON_RESUME`）：重新建立订阅（跟心跳的 `start()` 同一个
  触发点），走一次整页刷新补齐后台期间可能错过的变化——这条路径 SYNC-04
  已经设计过（"进后台再切回补齐离线期间变化"是它挂账的真机验收剧本
  ③），本卡不改这条语义，只是把"进后台"的判定从"tab 切换"改成
  "Activity 真正 onStop"。
- 跟本地相册变化监听（`ContentUriTrigger`/`BackupWorker`，MOB-02）
  是完全独立的两套机制，本卡不涉及、不合并——那套本来就不依赖 App
  前台/这条订阅连接，进程被杀也照常工作。

## 可执行验收

- Android 单测：现有 `SubscribeRetryTest` 5 条原样保持绿（退避逻辑
  纯函数不受影响，只验证调用位置变了不影响其行为）。
- 新增单测/断言：给定"tab 从 0 切到 1 再切回 0"的状态转换序列（用
  纯函数/state holder 层面断言，不需要起 Compose 测试环境）——订阅
  发起次数（`subscribeAttempt` 从 0 起的变化次数）应该是 0（一次都
  没重新触发），不是每次切 tab 都 +1。
- **真机验收（挂用户）**：①停留在设置 tab 时，daemon 侧发生变化 →
  切回照片 tab 立即看到最新状态，没有"重新连接中"的等待/转圈；
  ②反证：临时把订阅状态改回绑定 `PhotosScreen` 组合可见性（即还原
  本卡改动前的行为）→ 切 tab 来回 → 观察到订阅确实重新建立（比如加
  日志数进入订阅循环的次数），证明验收测的是真实机制。

## 证据要求

Android 单测输出摘要 + tab 切换场景的状态转换断言输出 + 真机验收
挂用户确认记录。

## 跨卡声明禁令

不许写"订阅生命周期已对齐前台"，除非真机验收①②两条都有用户确认的
截图/操作记录——单测绿只覆盖状态机部分，tab 切换不重连这件事必须有
真机实证。

## 收尾

android 全量单测绿 + PROGRESS.md 一行 + ROADMAP.md 状态行 + 真机验收
挂用户。
