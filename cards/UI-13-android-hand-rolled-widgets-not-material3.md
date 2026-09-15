# UI-13 移动端多处手写控件应换成 Material3 标准组件（L2）

> ⬜ 状态：未开工
> 级别：L2 · 阻塞：无

## 问题

2026-09-15 全仓排查 `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/`
（15 个文件）+ `MainActivity.kt`，逐项核对"这个交互模式在 Material3 里有
没有对应组件"。结论：多处该用 Material3 标准组件的地方是手搓的
`Row`/`Box`/`Canvas` 拼接，视觉上模仿了设计稿，但缺组件自带的无障碍语义、
状态层反馈（涟漪）、标准触摸目标规范。清单：

| 文件位置 | 现状 | 应该用的 Material3 组件 | 差距 |
|---|---|---|---|
| `TwoTabs.kt` 底部两个 tab（`TabCell`） | 自拼 `Row+Column+clickable+2dp 顶条` | `NavigationBar`/`NavigationBarItem` | 手写，无涟漪反馈、无标准 selected 动效、a11y role 不标准 |
| `TwoTabs.kt` 设置图标红点（105-113 行） | `Box.size(8.dp).clip(CircleShape).background(Act)` | `Badge`/`BadgedBox` | 手写圆点，读屏读不出"有未处理事项"这个语义 |
| `PhotosScreen.kt:745` 私有 `FilterChip` | `Box+clip+background+clickable` 手写药丸，与 Material3 同名组件撞车 | `androidx.compose.material3.FilterChip` | 等于重新发明了一遍轮子，功能是子集（无 leadingIcon/无选中动效） |
| `HomeScreen.kt:747` `HeroSecondaryButton` | `Row+clip+background+border+clickable` 手写按钮 | `TextButton`/`OutlinedButton` | disabled 态靠手动改颜色透明度，非真正可访问的 disabled 语义 |
| `HomeScreen.kt:823` `CellRow`、`HomeScreen.kt:801` `RuleSwitchRow` | 自定义 `Row+Text`/`Row+Switch` | `ListItem`（headline/supportingText/trailingContent 插槽化） | 视觉达标但无 `ListItem` 自带的语义结构 |
| `TabIcons.kt` 全文件 | `Canvas` 手绘相机/齿轮 path | `androidx.compose.material.icons`（项目已引入，`VideoScreen.kt:149` 的分享图标已在用 `Icons.Filled.Share`） | **自相矛盾**：同一个 App 里分享图标走了图标库，tab 图标还是手绘 Canvas；`ICON-02`（已归档）范围写的是"功能小图标"，漏了 tab 图标这个死角 |

沿用组件、不改视觉观感的（不在本卡范围）：`Switch`（`RuleSwitchRow` 内部
本就直接用 Material3 `Switch`）、`LinearProgressIndicator`（备份进度条）、
`AlertDialog`（更新提示/权限拒绝/断开连接确认）——这些已经是 Material3
组件本体或产品已拍板的定制交互（断开连接"三层防误触"是设计稿明确要求，
不属于本卡"手写却该用组件"的问题类别）。

## 期望行为

逐项替换为对应 Material3 组件，**视觉观感与当前设计稿保持一致**（这是
组件层重构，不是重新设计）——颜色继续用 `PPColor`，字体继续用
`PPFont`，尺寸继续遵守 `PPSize`（`Tokens.kt` 是唯一设计语言来源）。
`NavigationBar` 替换 `TwoTabs` 内部实现涉及视觉重排版风险最高，需要先出
diff 截图确认与设计稿目视一致，再合入。

## 验收标准

- [ ] `TabIcons.kt` 删除，`TwoTabs.kt` 改用 `Icons.Filled.*`/`Icons.Outlined.*`
      的相机、设置图标（挑选与手绘版本视觉最接近的图标，允许描边风格
      略有出入，但不能变成完全不同的符号）。
- [ ] 设置图标角标改用 `BadgedBox`/`Badge`，保留现有触发条件
      （`settingsAlert` 判据不变，MOB-68 红线不动）。
- [ ] `TwoTabs.kt` 底部导航改用 `NavigationBar`/`NavigationBarItem`
      （或明确记录"因视觉差距过大暂不换，保留手写实现"的具体理由，需
      附对比截图，不能只凭"改动大"跳过）。
- [ ] `PhotosScreen.kt` 私有 `FilterChip` 删除，直接用
      `androidx.compose.material3.FilterChip`，`chip_all`/`chip_local`/
      `chip_family` 三个胶囊视觉与当前一致。
- [ ] `HomeScreen.kt` 的 `HeroSecondaryButton` 改用 `TextButton`/`OutlinedButton`
      定制 `colors`/`shape` 参数还原视觉，删除手写实现。
- [ ] `CellRow`/`RuleSwitchRow` 评估改用 `ListItem`（若 `ListItem` 的默认
      内边距/最小高度与设计稿 `CellRowHeight = 52.dp` 冲突过大，允许保留
      现状但必须在卡里写明冲突点，不能静默跳过）。
- [ ] Android JVM 全量测试保持绿（现有测试文件里对 `TabIcons`/
      `HeroSecondaryButton`/`FilterChip` 等私有函数名的字符串匹配测试，
      如 `BackgroundBackupPresentationContractTest` 等，如因组件替换需要
      调整断言方式，需逐一确认没有削弱原有契约）。
- [ ] 双端全页面走查（AGENTS.md 要求）：Photos/Backup/onboarding 全部页面
      截图对比替换前后，定性"还原/走样/未实现"三类，走样的必须回退或
      调参数至视觉一致。
- [ ] 真机验收：三星 SM-S9210（或当前可用真机）确认底部导航栏点击反馈
      （涟漪）、图标角标读屏可读、FilterChip/Button 交互正常。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/TwoTabs.kt`、
  `TabIcons.kt`（预计整个删除）、`PhotosScreen.kt` 的 `FilterChip` 定义与
  调用点、`HomeScreen.kt` 的 `HeroSecondaryButton`/`CellRow`/`RuleSwitchRow`
  定义与调用点、相关 JVM 测试文件。
- 不准动：`Tokens.kt` 的设计语言取值本身（颜色/字号/圆角数值不改，只改
  组件实现方式）；`AlertDialog`/`Switch`/`LinearProgressIndicator` 三处
  已经是 Material3 组件的不动；`BackgroundBackupState.kt` 判据、
  `backgroundBackupStateOf` 的业务逻辑；桌面端（`apps/desktop/`，已由
  DESK-15 收口，不重开）。

## 阻塞与依赖

无。与 UI-12（通知呈现层重做）相邻但不共享文件热点——UI-12 只碰
`HomeNotices.kt`/`MainActivity.kt` 的 notice 接线段，本卡碰
`TwoTabs.kt`/`TabIcons.kt`/`PhotosScreen.kt`/`HomeScreen.kt` 的组件定义，
两卡可并行认领，若发现 `HomeScreen.kt` 改动区域重叠需在各自卡片评论区
标注 `hotspot:` 并协调顺序。

---

## 实施记录

（留空，实施 agent 追加）
