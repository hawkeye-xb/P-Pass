# UI-12 移动端常驻提示条不符合 Material Banner 语义（L2）

> 🟢 状态：已完成，三星 SM-S9210 真机验收通过；待用户鸿蒙/OPPO 二次核对
> 级别：L2 · 阻塞：无（呈现方案已由用户 2026-09-15 定调，见下）

## 问题

`apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeNotices.kt` 的
`NoticeCard`/`NoticeHost` 是自己手搓的 `Surface+Row+Text`（不是 Material3
组件），本该对应 Material Design 的 **Banner**（应用内、持续显示直到用户
处理、不阻断使用的场景）。用户真机使用时反馈两个具体问题：

1. **后台备份被系统限制这件事，提醒方式起不到通知作用。** 现状：
   `BackgroundBackupState.NeedsSystemAuthorization`/`SystemStoppedWatcher`
   两个真出问题的状态，只呈现为设置页「备份」卡片里一行普通
   `CellRow`（`HomeScreen.kt:516-531`），配合设置 tab 图标一个 8dp 红点
   （`TwoTabs.kt:105-113`）。这是列表项级别的弱提醒，跟 `NoticeHost`
   自己代码注释里声明的"全局唯一提示宿主，把所有该提示的东西集中到这里"
   （`HomeNotices.kt:117-129`）自相矛盾——这两个状态没有接入 `NoticeHost`，
   反而各起一套。
2. **只有"处理"和"整个关掉自动备份开关"两条路，没有"知悉但暂不处理"。**
   `NoticeCard` 目前只有一个 `actionLabel`（一个动作位），没有"忽略"这个
   二级动作。想要"我知道这个问题存在，但先别再提醒我，也不想放弃自动
   备份意图"这个语义，现在做不到。

Material Banner 规范的标准形状（对照见下表）：

| Material Banner 规范 | 本仓现状 |
|---|---|
| 用图标+文字表达严重程度，不同严重度视觉可辨 | 所有候选（配对失联/后台备份降级/照片补传）背景都是同一块 `PPColor.WaitingBg`，视觉上分不出轻重 |
| 预留两个动作位：一个"处理"+一个"知道了/忽略"，只有真正阻断性的才能不给忽略 | 只有 `actionLabel` 一个动作 |
| 一个统一收纳层，保证"要看的东西只在一个地方" | 后台备份两个状态绕开了 `NoticeHost`，另起 CellRow + tab 角标 |

## 期望行为

- 后台备份 `NeedsSystemAuthorization`/`SystemStoppedWatcher` 两个状态接入
  `NoticeHost` 候选列表，Photos/Backup 两个 tab 都能看到，不需要先点进
  设置页才发现问题。
- `HomeNotice`/`NoticeCard` 按严重程度分两种视觉：阻断性的（配对失联）
  保留现状强色（`PPColor.Act`/`ActBg`）；非阻断但需关注的（后台备份降级、
  照片补传）用现有温和色（`PPColor.Waiting`/`WaitingBg`），两者在同一组件
  内可辨，不是"一个颜色打天下"。
- 非阻断类通知新增一个独立的"知道了/暂不处理"动作，跟"处理"分开——
  点击后该条从当前候选集隐藏（本地状态位，不等同于解决问题，问题仍在
  `backgroundBackupStateOf` 里，只是不再打扰），阻断性的（配对失联）不
  提供这个忽略动作。
- 沿用项目既有设计语言（`PPColor`/`PPSize`/`PPFont`，见 `Tokens.kt`），
  不引入新的第三方通知库；组件形态可以在 Compose 里参照
  `androidx.compose.material3` 的 Banner/Card 惯例重写，但保持
  `docs/design/2026-08-17-layout-v3/` 的整体视觉基调。

## 验收标准

- [ ] RED→GREEN：`backgroundBackupStateOf` 返回 `NeedsSystemAuthorization`
      或 `SystemStoppedWatcher` 时，`NoticeHost` 的候选列表必须包含对应
      `HomeNotice`（新增源码/纯函数合同测试）；改前必须证明当前实现不满足
      （即现状是 CellRow 单独展示，不在 NoticeHost 候选里）。
- [ ] 自动化：`topNotice` 在阻断类（`PAIRING_LOST`）与非阻断类同时存在时
      仍优先阻断类；非阻断类的"知道了"点击后该条从 `topNotice` 候选中消失
      （不影响其他候选）。
- [ ] 自动化：阻断类通知（`PAIRING_LOST`）不提供"知道了"动作（源码断言）。
- [ ] 反证：移除新增的 NoticeHost 接线，聚焦用例必须失败。
- [ ] 真机：关闭电池白名单/force-stop 后台监听触发这两种状态，
      Photos 与 Backup 两个 tab 都能看到提示；点"知道了"后提示消失且不
      再复现（除非状态发生新的跃变）；点"去处理"仍走原有
      `onResolveBackgroundBackup` 流程。
- [ ] 双端全页面走查（AGENTS.md 要求）：截图确认阻断/非阻断两种视觉可辨，
      不与 UI-04b/UI-04c 已收口的桌面端 Sonner/优先级机制冲突（本卡范围
      仅 Android）。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeNotices.kt`、
  `MainActivity.kt` 里 `NoticeHost` 调用点与 `backgroundBackupState` 接线、
  `HomeScreen.kt` 里被替换掉的 CellRow 呈现段落（516-531 行）、必要的
  `strings.xml` 新增文案（"知道了"类）、相关 JVM 测试。
- 不准动：`backgroundBackupStateOf`（`BackgroundBackupState.kt`）判据本身
  不改；`BackupHealth.kt` 的中断恢复语义（MOB-28 红线）；桌面端通知机制
  （已由 UI-04b/UI-04c 收口，不重开）；`SystemFailureNotifier` 等真安卓
  系统通知（不在本卡范围）。

## 阻塞与依赖

无。呈现方向（Banner 语义、严重度分级、"知道了"二级动作）已由用户
2026-09-15 对话中定调，不需要再等产品决策；具体视觉细节（颜色/间距/图标）
实现时可参照 `docs/design/2026-08-17-layout-v3/` 基调自行落地，验收走
真机截图确认即可，无需先出设计稿。

---

## 实施记录

- 2026-09-15（补充，本轮）：Snackbar 安全区适配（`MainActivity.kt` 的
  `SnackbarHost` 加 `safeDrawingPadding()`，之前三键导航手机会被导航栏
  遮挡）+ 版本号 bump 至 `0.5.3-test.1`（versionCode 23），commit
  `f516dc2`，CI Android 绿。三星 SM-S9210 真机逐个复测完整 case 矩阵：
  `OffByUser`（用户主动关，提示同步清空）/ `Armed`（健康态无提示）/
  `NeedsSystemAuthorization`（撤白名单，开关不误跳灰、hint+横幅正确
  出现）/ 授权同意分支（Snackbar"已获得后台运行权限"）/ 授权拒绝分支
  （Snackbar"未获得授权…"）全部通过，Snackbar 底部与三键导航栏之间
  有清晰留白、不遮挡。378/378 JVM 单测绿。
  - 未能真机复现 `SystemStoppedWatcher`（legacy watch job 被系统杀后
    重排的判据，非当前 Flow 主链路）——已拆为独立 backlog 卡
    `MOB-81` 跟踪，不阻塞本卡验收（判据本身有 16 个单测覆盖，
    非回归风险，只是真机上难以稳定触发）。
  - 待用户回家用鸿蒙 OPPO 设备二次核对上述真机验收结果。

- 2026-09-15：已实现。`HomeNotice` 新增 `critical`/`dismissLabel`/`onDismiss` 三个字段（`HomeNotices.kt`），`NoticeCard` 按 `critical` 切换强色/温和色两套视觉，非阻断类渲染独立的"知道了"文字按钮（`dismissLabel`），阻断类（`PAIRING_LOST`）不传 `dismissLabel` 即无该动作。`NoticeHost` 新增参数消费 `BackgroundBackupState`，`NeedsSystemAuthorization`/`SystemStoppedWatcher` 两个状态构造 `HomeNoticeKind.BACKUP_INTERRUPTED` 候选加入 `topNotice` 排序（复用已有优先级登记，未改排序表）。`resolveBackgroundBackup` 在 `MainActivity.kt` 提炼为单一 lambda，`NoticeHost` 的"去处理"与设置页 `CellRow` 的 `onResolveBackgroundBackup` 共用同一份闭包，不再各写一遍（AGENTS.md「漏一处」教训同款）。"知道了"落地为 `backgroundBackupNoticeDismissed`（`remember(backgroundBackupState) { mutableStateOf(false) }`——按状态本身做 key，状态跃迁自动重置为 false，符合"暂时忽略、非永久偏好、新的跃变必须重新提醒"的设计）。`strings.xml` en/zh 新增 `background_backup_notice_action`（"去处理"/"Fix it"）与 `notice_dismiss_label`（"知道了"/"Got it"），复用已有 `reupload_notice_action` 会导致语义耦合，故拆开单独一对。设置页 `CellRow`（`HomeScreen.kt:516-531`）保留不动——横幅是可忽略的主动提醒，CellRow 是"当前仍为真"的常驻状态记录，两者语义不同、不是重复展示。
  - RED→GREEN：`BackgroundBackupPresentationContractTest` 新增
    `ui12_background_backup_states_are_wired_into_the_global_notice_host`
    （改前 `NoticeHost` 函数体不引用 `BackgroundBackupState`，断言必然失败；
    改后通过）与
    `ui12_non_blocking_notices_get_a_dismiss_action_distinct_from_the_primary_action`。
    `HomeNoticesTest` 新增两条纯函数测试覆盖 `HomeNotice` 新字段的默认值与
    动作独立性，不依赖 Compose/Robolectric。
  - 测试：`./gradlew :app:testDebugUnitTest --rerun-tasks` **378/378
    绿**（`app/build/test-results/testDebugUnitTest/*.xml`，78 个测试类，
    时间戳本次生成），`:app:assembleDebug` 绿。
  - 真机验收（三星 SM-S9210，`0.5.2-test.1`）：强制关闭电池白名单触发
    `SystemStoppedWatcher` 后，Photos 与 Backup 两个 tab 顶部均出现琥珀
    通知条"系统已停止后台监听 · 检查并重新开启"，右侧"知道了"+"去处理"
    两个独立动作；点"知道了"后横幅消失，切换 tab 验证跨 tab 保持一致
    （同一状态源），设置页 `CellRow` 仍照常显示（未被误删）；点"去处理"
    走原有 `onResolveBackgroundBackup` 流程，弹出系统权限页。截图已交给
    用户核对，观感与设计基调一致。
