# SYNC-04 Android 前台常驻订阅 + 整页覆盖 + 断线重连　级别 L2【依赖 SYNC-02+SYNC-03 已合并；真机验收挂用户】
> ## ✅ 状态：代码已合并，2026-08-20 归档（真机验收挂用户）
>
> 三条要求逐条核对，全部在位：
> 1. 常驻订阅取代轮询 — `DaemonClient.subscribeTimeline` +
>    `TimelineSubscriptionHolder`（`PhotosScreen.kt:163/217`）
> 2. 进后台断开 — `MainActivity` 的 `LifecycleEventObserver`（ON_RESUME 起 /
>    ON_STOP 停）
> 3. 退避重连 + 超限亮错误 — `SUBSCRIBE_RETRY_DELAYS_MS`
>    （1/2/4/8/15/30s）+ `subscribeExhausted` / `subscribeConnected` /
>    `subscribeHadFailure` 三个 UI 态（`PhotosScreen.kt:344/354`）
>
> ⚠️ **本卡也造成过一次误报**：2026-08-20 盘点时我用错了文件名去 grep
> （查 `TimelineLoader.kt` 而订阅在 `PhotosScreen.kt`），报成"未实施"。
> 教训同 DESK-06：核实要对着卡面要求逐条找，不能一个宽泛 grep 了事。


背景与全部裁决点见 `docs/product/2026-08-12-metadata-sync-decisions.md`
（§③④⑥，本卡实现这三条）。**前置条件**：SYNC-03 已合并进 main——本卡
是它在手机端的第一个真实消费者。

## 目标

`PhotosScreen`/`TimelineLoader` 换掉现在的"仅追加 15s 轮询"，改成前台
开一条常驻订阅连接，收到信号就整页覆盖刷新；进后台立即断开；断线按
退避重连，超限亮错误交给用户。

## 范围

只准动：
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt`
- 新增连接管理相关文件（如 `SubscriptionSession.kt`，具体命名自定）
- 涉及生命周期接线的部分（`onResume`/`onPause` 或对应 Compose
  生命周期挂钩）

## 不准动

- daemon 侧任何代码（SYNC-02/03 已完成，本卡只是消费方）
- `CacheRedlineTest` 的断言本身——**全工程只许一处 `LruCache` 声明**
  这条红线不能因为本卡新增连接管理类而被放宽（UX-10 已经撞过一次，
  当时是复用现有缓存加 key 前缀解决，不是新开缓存/放宽测试）
- `proto::AssetMeta` 字段（SYNC-05）

## 设计要点

- 前台（进入 Photos tab 或 App 回到前台，具体触发点跟现有生命周期
  管理对齐）：发起订阅连接。
- 收到 `timeline.invalidated`（包括订阅建立后立刻收到的那一次"当前
  态"信号）：调用现有的 `loader.page(null)` + `loader.onTimelineRefreshed`
  ——**整页覆盖语义，不是 `onTimelineAppended`**。这是本卡最容易做
  反的地方：如果图省事沿用现有的"仅追加"路径，删除不可见的问题不会
  被真正修掉，只是换了个触发方式。
- 后台：立即关闭订阅连接（呼应 PRES-01"后台绝不心跳"红线，这条连接
  的存在时长跟前台心跳应该是同一个生命周期，不是另开一套判断）。
- 断线重连：只在前台发生；退避有上限（次数或总时长封顶，具体数值
  自定但必须有上限，不能无限重试）；超限后停止静默重试，把"连不上"
  的状态展示给用户，给一个手动重试入口；重开 App（进程重启）让重试
  计数器自然清零重来，不需要额外设计"重置"逻辑。
- **删除**现有的 15s 仅追加轮询代码路径；换成一个**远低于原轮询频率
  的整页刷新兜底**（对齐桌面端已有的 60s 兜底，防真实丢事件场景），
  这个兜底不是主通道，只在长时间没收到任何信号时才触发。
- 连接活性检测复用 PRES-01 已有的前台心跳，不新起一套独立的心跳/
  keepalive 机制。

## 可执行验收

- Android 单测：能测的部分——重连退避的状态机（触发次数、退避间隔
  递增、超限后停止并进入"需要手动重试"状态）、"收到信号后走的是覆盖
  路径而不是追加路径"这条可以用假 loader 断言调用了哪个函数验证。
- **真机验收（挂用户，agent 无法自测）**：
  1. daemon 侵入删除一张照片 → 手机前台停留在照片 tab → 确认该照片
     从时间线消失（不是像现在这样永久停留到进程重启）。
  2. 切换飞行模式/断网再恢复 → 确认自动重连成功，重连期间不无限
     转圈（有明确的"重连中"或类似状态提示）。
  3. 切到后台再切回前台 → 确认能重新建立订阅并补齐离线期间的变化。
  4. 杀进程重开 → 确认重连计数器状态是全新的，不是继承上次失败状态。
  5. 长时间断网（超过退避上限）→ 确认亮出"连不上"的报错文案 + 手动
     重试按钮可用，不是无限期静默重试。
- 反证（可人工推理，不强求自动化）：把"整页覆盖"临时改回"仅追加"→
  场景 1 必须复现删除不可见（证明验收测的是真实机制，不是巧合通过）。

## 证据要求

单测输出摘要 + 真机验收逐条截图/操作记录（挂用户，本卡不因为单测绿
就自称完成）。

## 跨卡声明禁令

不许写"真机验收已通过"直到用户实际确认——单测绿只覆盖状态机部分，
上面五条真机剧本是本卡验收的主体，不能用单测绿代替。

## 收尾

android 全量单测绿 + `just arch-check`（若涉及）绿 + 真机验收挂用户 +
PROGRESS.md 一行（先记"待真机验收"，用户确认后补验收记录）。

---

### 执行记录（2026-08-12，代码完成，真机验收进行中）

- `proto/Proto.kt`：`Methods.TIMELINE_SUBSCRIBE`。
- `transport/DaemonClient.kt`：新增 `subscribeTimeline(peer, onConnected,
  onInvalidated)`——发订阅请求后半关闭发送方向，循环读帧；读到第一帧
  就调 `onConnected`（见下方"真机发现的缺口"），`event ==
  "timeline.invalidated"` 才调 `onInvalidated`。
- `ui/PhotosScreen.kt`：
  - `TimelineLoader.subscribe` 包一层转发。
  - 删掉原来的 15s"仅追加"轮询；`refreshFullPage()`（page(null) +
    `onTimelineRefreshed`，整页覆盖语义）被首次加载/订阅信号/60s 兜底
    轮询/手动重试四处共用。
  - 断线重连状态机抽成纯函数 `nextSubscribeRetry`（不用起 Compose
    测试环境就能单测），退避序列 1/2/4/8/15/30 秒，耗尽后
    `subscribeExhausted` 亮"连不上"+手动重试；`wasLive`（连上并撑过
    5 秒才断）会把退避清零重来，不带上次失败的档位。
  - 新增单测 `SubscribeRetryTest`（5 条：首次退避/连续退避递增/耗尽/
    wasLive 清零/手动重试从头开始）。`CacheRedlineTest`/
    `StringsSymmetryTest` 复跑确认没破坏（LruCache 仍唯一声明，红线
    注释仍在位，新增字符串 en/zh 对称）。
- **真机验收中发现并当场修的缺口**：真机（三星 SM-S9210）飞行模式
  测试时，用户反馈"没有任何状态展示"——原设计只在退避**全部耗尽**
  （累计 ~60 秒）之后才亮提示，中间六次重试全程界面沉默，跟卡里
  "重连期间要有明确的重连中提示"这条验收要求不符，是我漏做的一半。
  修法：`subscribeTimeline` 加 `onConnected` 回调（读到第一帧——也就是
  订阅确认本身——就触发一次），`PhotosScreen` 拿它 + 新增的
  `subscribeHadFailure` 状态区分三态：还没连上第一次 / 已连上安静
  监听 / 断线重试中，重试中显示"正在重新连接电脑…"小字提示。
  `subscribeHadFailure` 跟 `subscribeAttempt`（LaunchedEffect 的 key）
  解耦——直接用 attempt 计数器判断会在第一次失败后的第一档退避窗口
  漏一次提示（key 还没来得及变）。
- **待办（不是本次漏做，是本来就该在真机上测的下一步，尚未确认）**：
  ①外部删除可见性（daemon 侵入删文件+重启触发一次 reconcile→手机上
  不用重启就该看到那张照片消失）②断网重连成功且有提示③切后台再切回
  补齐离线变化④杀进程重开重试计数器归零⑤长时间断网亮"连不上"+
  手动重试可用——用户正在验证中，还没有一条被确认通过。
- **范围外发现，不在本卡修**：①用户反馈"点立即备份，飞行模式下没
  反应，过一会儿开始传输"——查证是 `BackupWorker`
  `setRequiredNetworkType(NetworkType.CONNECTED)` 既有行为（WorkManager
  原地挂起等网络恢复），跟本卡订阅机制无关。②用户反馈桌面壳某处显示
  "连接中"——查了 `apps/desktop/src` 全部源码没找到这个字面文案（现有
  文案只有已直连/经中继连接/在线/离线/等待下次备份上报），已跟用户要
  截图定位，不是本卡确认的问题，不臆测归因。
- 证据：`./gradlew :app:testDebugUnitTest` 全绿（新增 5 个单测）；
  debug APK 已编译安装到真机（`adb install -r`，两轮，第二轮带上面
  的重连提示修复）；桌面壳用本地新编译的 daemon sidecar（release
  build）跑在 `pnpm tauri dev` 里。**真机验收 5 条剧本尚未有任何一条
  被用户确认通过**，本卡不能移入 `done/`。

---

### 卡片信息更正（2026-08-13，用户 review 发现文档与实际代码不符）

**第 38~39 行"后台：立即关闭订阅连接"这条设计要点，实际代码里没有
实现，而且经用户重新讨论后，这条设计本身被推翻了——不是"漏做"，是
"原设计就不对"。** 记录下来避免以后有人以为这条已经生效。

**实际代码是什么样**：`PhotosScreen.kt` 里订阅所在的
`LaunchedEffect(subscribeAttempt)` 没有绑定任何 `Lifecycle`/`ON_STOP`
钩子（`ForegroundHeartbeat` 才有，绑在 `MainActivity.kt`）。订阅连接
只在两种情况下被取消：①切到"设置" tab（`TwoTabs.kt` 是简单的
`if (tab==0) photos() else backup()`，切走 tab 把 `PhotosScreen`
整个移出组合树）；②Activity 被销毁（进程被杀/系统回收）。也就是说
"整个 App 切到后台但进程没死"这种情况下，订阅连接实际上**一直开着**，
不是设计出来的，是漏写了断开逻辑的副作用。

**讨论后确定的正确设计**（推翻原第 31/38~39 行）：订阅连接和心跳应该
共用同一个生命周期边界——**只要 App 进程活着且在前台（不管当前显示
哪个 tab），订阅和心跳都应该保持**；只有"进程被系统回收"或"用户主动
kill"这两种情况才断开、停止心跳。理由：
- 按 tab 切换断开重建，会导致切到设置页再切回来时有个重新连接的空窗
  期，且可能错过这期间到达的信号——工程上没必要，"收到通知但不消费/
  不刷新 UI"远比"强制断开重连"简单。
- 这跟"后台常驻监听本地相册变化 → 触发备份上传"是两回事，不要混——
  后者（`ContentUriTrigger` + WorkManager，MOB-02 已实现）本来就不
  依赖 App 是否在前台、不经过这条订阅连接，进程被杀也照常工作。这条
  订阅连接只服务于"照片 tab 的家庭时间线 UI 是否实时刷新"这一个体验，
  跟核心备份链路（新照片→上传）完全独立，别把两者的生命周期决策揉到
  一起。

**修复方案见新卡 `SYNC-06-subscribe-lifecycle-scope.md`**（把订阅生命
周期从 `PhotosScreen` 组合可见性上提到跟 `ForegroundHeartbeat` 同一层，
解耦 tab 切换）。
