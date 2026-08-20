# ICON-02 功能小图标改用开源图标库　级别 L1【独立，无依赖，可拆两半分别做】
> ## ✅ 状态：代码已合并，2026-08-20 归档（真机观感挂验收人）
>
> `Icons.Filled.*` 已在 UI 各处使用（如 `VideoScreen.kt:139` 的分享图标，
> 注释记着"旧的自绘 ic_share.xml 抄的就是同一条 pathData，形状零差异"）。
> 真机观感按本项目当前阶段的分工挂在验收人那边，不阻塞归档。


用户 2026-08-17 提出："尽量地去用一些开源的 Icon Font 或者是 SVG Icon
Code 去替换我们本地的一些图标"——当时不清楚现状是怎么实现的，已经
调研清楚，本卡记录现状 + 目标，留给下一个 agent 实施。**跟 App 图标
本身（`scripts/icons/generate.sh` 生成的 icon.icns/ico/launcher 图标）
无关，本卡只管界面里的功能性小图标**（设置齿轮、刷新箭头、相机、
关闭 X、分享等）。

## 现状（2026-08-17 调研结论，非猜测）

- **桌面端**（`apps/desktop/src/App.svelte`）：功能小图标全是手写内联
  SVG path 字符串（第 49/54/59/64/69 行附近，箭头/相机/手机/时钟/
  齿轮设置等 5 个），通过 `{@html n.icon}` 注入到一个复用的
  `<svg class="nav-icon">` 容器里；关闭按钮（×）是文本字符不是 SVG。
  `package.json` 已经声明了 `@lucide/svelte ^1.31.0`，但**全仓库零处
  实际 import/使用**——是个装了没用的依赖，改起来最省事，直接换现成
  的（不用新增依赖）。
- **Android 端**：没用 `androidx.compose.material.icons`（图标库，跟
  `androidx.compose.material3` 组件库是两个不同的东西——组件库
  Material3 本身已经在用，`Button`/`Text`/`Switch`/`Checkbox`/
  `AlertDialog` 等 8 处 import，这块不用动，见下方"跟组件库的关系"）。
  图标目前只有 3 个自制矢量 drawable：`res/drawable/ic_share.xml`、
  `ic_notification.xml`（通知小图标，`BackupWorker.kt` 多处
  `.setSmallIcon` 引用）、`ic_launcher_monochrome.xml`。其余界面（`ui/
  PPScreen.kt` 等）基本是文字按钮，没有图标。

## 跟组件库的关系（容易混的两件事，分开说清楚）

- **组件库**（Button/Card/Switch 这类交互控件）：桌面端 2026-08 已迁到
  Tailwind + shadcn-svelte（DESK-07/08）；Android 端本来就在用
  Compose Material3（不是本卡范围，不用动）。
- **图标库**（图标怎么画出来）：桌面端手写 SVG + 装了没用的
  `@lucide/svelte`；Android 端自制 drawable，没用图标库。**本卡只管
  这一层**。

## 目标

- 桌面端：把 `App.svelte` 里 5 个手写 SVG path 换成 `@lucide/svelte`
  对应图标组件，删掉 `{@html n.icon}` 这种字符串注入模式；关闭按钮
  的 `×` 文本可以保留（不是必须换，纯文本符号没有一致性问题）。
- Android 端：引入一个开源图标库（候选 `androidx.compose.material.
  icons.extended`——Google 官方、跟已有的 Material3 组件库同源、
  Compose 生态最主流，除非有具体理由否决），把现有 3 个自制 drawable
  换成图标库对应图标；新增图标需求（分享/关闭/设置等）优先从图标库
  取，不再手绘新的 vector drawable。

## 范围

只准动：
- `apps/desktop/src/App.svelte`（图标定义 + 引用处）
- `apps/desktop/package.json`（如果要动版本，`@lucide/svelte` 已经在
  `dependencies` 里，正常不需要改这个文件）
- Android 端图标相关引用点（`grep -rn "R.drawable.ic_share\|R.drawable.
  ic_notification"` 定位全部消费点）+ 新增的图标库依赖声明
  （`apps/android/app/build.gradle.kts`）

## 不准动

- `scripts/icons/generate.sh` 及其生成的 App 图标产物（icon.icns/ico/
  launcher png 系列）——那是另一条完全独立的生成管线，跟本卡无关。
- 组件库本身（shadcn-svelte / Compose Material3）——本卡只换图标画法，
  不动交互控件。
- `res/drawable/ic_launcher_monochrome.xml`——这个是 Android 13+ 主题
  图标的一部分，属于 App 图标管线不是功能小图标，别跟着一起换掉。

## 设计要点

- 功能驱动阶段（用户 2026-08-17 明确指令）：不需要跟设计稿像素对齐，
  换图标库以"视觉上不违和、语义清楚"为验收标准，不是像素级复刻当前
  手绘图标的形状。
- 桌面端换完以后 `package.json` 里就不再有"装了没用"的依赖了，这本身
  也是收益之一。
- 两端可以拆成两张独立子卡分别派（互不依赖，谁先谁后都行）。

## 可执行验收

- 桌面端：`pnpm run build` 绿 + 实机窗口打开确认图标渲染正常（用户
  直接验证，不要求 agent 自行截图，按本项目当前阶段的验证纪律）。
- Android 端：`./gradlew :app:assembleDebug` 绿 + 全量单测绿 + 实机
  确认分享/通知等原有功能点图标正常显示。
- 两端都要求：`grep` 确认旧的手写 SVG path / 自制 drawable 引用点已经
  清空（没有半途只换了一部分又留着旧代码）。

## 证据要求

改动前后对照（哪些图标换了、换成了图标库里的哪个组件/图标名）+ 上面
验收命令的真实输出。

## 收尾

两端各自 `just` 全绿（如适用）+ PROGRESS.md 一行 + 完成后移
`.claude/cards/done/`。

---

# 实施记录（2026-08-19）

## 桌面端：✅ 已做完

`apps/desktop/src/App.svelte`，5 个手写 SVG path 字符串 → `@lucide/svelte`
组件（深路径 import，只打包用到的图标）：

| 侧栏项 | 旧（手抄 path） | 新（lucide 组件） |
|---|---|---|
| 总览 overview | 房子轮廓 2 条 path | `@lucide/svelte/icons/house` |
| 照片 photos | rect+circle+折线 | `@lucide/svelte/icons/image` |
| 家人与设备 devices | 圆角 rect + 短横 | `@lucide/svelte/icons/smartphone` |
| 活动记录 log | circle + 指针 path | `@lucide/svelte/icons/clock` |
| 设置 settings | circle + 齿轮 path | `@lucide/svelte/icons/settings` |

配套改动：
- 删掉 `{@html n.icon}` 字符串注入 + 那个复用的 `<svg class="nav-icon">`
  容器；改成 `{@const NavIcon = n.icon}` + `<NavIcon class="nav-icon"
  size={20} />`。
- CSS：`.nav-icon` 现在长在子组件的 svg 上，拿不到本组件的 scope 类，
  三条规则改成 `.nav-item :global(.nav-icon)` / `.nav-item.active
  :global(.nav-icon)`（限定在 nav-item 子树，不是裸全局）。
- 关闭按钮 `×` 按卡里说的保留文本字符，没换。
- `package.json` 没动。**订正卡里一处口径**：`@lucide/svelte` 在
  `devDependencies` 不是 `dependencies`（vite 打包产物场景无害，本卡
  不顺手改）。

视觉：尺寸/线宽/对齐跟旧的完全一致（浏览器实测渲染属性
`20x20 | stroke-width=2`，跟旧内联 svg 的 `width/height=20
stroke-width=2` 逐项对齐）；形状只有 house 略有差异（lucide 的房子带
门），其余 4 个几乎不可辨。

## Android 端：部分做（1/3 可迁移点已换），其余有硬约束不迁

### 已换

- `ui/VideoScreen.kt:132` 分享图标：`painterResource(R.drawable.ic_share)`
  → `Icons.Filled.Share`（`androidx.compose.material.icons`）。删掉
  `res/drawable/ic_share.xml` 和已无用的 `painterResource` import。
- `app/build.gradle.kts` 显式声明
  `implementation("androidx.compose.material:material-icons-core")`（BOM
  管版本）。

**体积代价实测 = −759 字节（不是零，是负的）**：
`material-icons-core-android:1.7.6` 本来就随 `material3` 传递进
debugRuntimeClasspath，而且**它的 class 早就躺在 APK 的 dex 里了**（解包
改动前的 APK，`classes*.dex` 里能直接搜到
`androidx/compose/material/icons/filled/ShareKt`）——跟桌面端
`@lucide/svelte` 一个剧本：库早就付过费了，只是从来没人用。显式声明
只是把隐式依赖写明；净减的 759 字节来自删掉的 `ic_share.xml` 资源项。
A/B 原始输出见下方证据。

`ic_share.xml` 里那条 pathData 抄的就是 Material 官方 share glyph 的
同一条路径，所以 `Icons.Filled.Share` 是**形状零差异**的纯机制替换。

### 不迁：`ic_notification`（平台硬约束，不是取舍）

`BackupWorker.kt` 4 处 `NotificationCompat.setSmallIcon(R.drawable.
ic_notification)`。`setSmallIcon` 收的是 **resource id**，图标由 SystemUI
在本进程之外渲染——任何 Compose `ImageVector` 都顶不上这个位置。
自制 vector drawable 是这里唯一可行形态，本卡不改。

### 不迁：`ui/TabIcons.kt`（**卡的现状调研漏了这个文件**）

底部 tab 两个图标是手绘 Compose Canvas（`PhotosTabIcon` 相机、
`SettingsTabIcon` 齿轮，文件头注释自己写了「ICON-02 卡另算」），也属
本卡语义范围。这轮**故意不换**，理由：

- `material-icons-core` 只有 49 个常用图标 × 5 风格，**没有相机/照片类
  图标**（实测解包 aar 列全表：Home/Settings/Share/Search… 有，
  Photo/Camera/Image 全无）。
- 相机图标只能靠 `material-icons-extended`。但 **release 没开
  `minifyEnabled`**（`app/build.gradle.kts` 的 buildTypes.release 只配了
  签名），没有 R8 裁剪 → extended 会实打实往 APK 塞几 MB。照片备份 App
  体积敏感，为一个相机图标不划算。
- 只换齿轮不换相机 = 一对 tab 图标分属两套图标系统（Material 填充 vs
  手绘描边），视觉上比现在这对同源手绘更糟。

**留给后续**：哪天开了 `minifyEnabled`（R8 会把没用到的 extended 图标
裁到近似 0），可重新评估把 TabIcons.kt 两个 + 未来新图标一起收编到
`material-icons-extended`。在那之前 TabIcons.kt 保持现状。

### 澄清一处历史决策（避免 review 时看岔）

MOB-06 卡记的「自绘 ic_share.xml（不引 material-icons-extended 控体积）」
前提是**以为要引 extended**。实际 `Share` 在 **core** 里，而 core 早就
在 APK 中了——所以本次不是推翻当时的权衡，是当时的前提不成立。

## 证据

### 桌面端

```
$ cd apps/desktop && pnpm build
✓ 205 modules transformed.
dist/index.html                   1.01 kB │ gzip:  0.66 kB
dist/assets/index-BHNkhk-g.css   35.75 kB │ gzip:  7.69 kB
dist/assets/index-CdvYGMfI.js   220.59 kB │ gzip: 69.49 kB
✓ built in 726ms
```

（3 条 `css_unused_selector` 警告全是既有的 `.qr-fallback *`，与本卡无关；
`.nav-icon` 零警告。）

grep 清空判据：

```
$ grep -rn "@html\|<svg\|<path \|<rect \|<circle " apps/desktop/src/
apps/desktop/src/App.svelte:52:  // {@html} 注入」改成 @lucide/svelte 图标组件——标准图标库用法，形状
```
（唯一命中是注释里提到旧写法，代码里零残留。）

浏览器实测（vite dev + headless Chromium，收起态 900px 宽）：

```
$ 每个 .nav-item svg 的 class|尺寸|线宽|display|color
lucide-icon lucide lucide-house      nav-icon|20x20|sw=2|disp=block|color=rgb(251,248,242)  ← active
lucide-icon lucide lucide-image      nav-icon|20x20|sw=2|disp=block|color=rgb(74,69,62)
lucide-icon lucide lucide-smartphone nav-icon|20x20|sw=2|disp=block|color=rgb(74,69,62)
lucide-icon lucide lucide-clock      nav-icon|20x20|sw=2|disp=block|color=rgb(74,69,62)
lucide-icon lucide lucide-settings   nav-icon|20x20|sw=2|disp=block|color=rgb(74,69,62)
```

- 展开态 1280px：5 个 svg `display` 全 `none`，只显示文字 label——跟设计稿
  交互原型一致，无布局位移。
- active 态换页（`#/settings`）后颜色翻转正确（选中项 `--pp-paper`，
  其余 `--pp-ink-60`），跟改动前行为一致。
- 改动前/后侧栏截图逐项对照，尺寸/间距/对齐无差异。

### Android 端

⚠️ **验证环境说明（重要，看结果前先读）**：跑本卡时主工作区里有**另一个
并行 session 未提交的在制品**（BackupHealth/ConfirmedStore/BackupWorker
一线共 9 改 3 新，含 +220 行新测试），而且它跟我共用同一个
`app/build/` 和 gradle 构建缓存——主工作区里跑出来的测试结果和 APK
体积都被污染，不可用作判据（实测撞车：`Could not delete
'.../caches-jvm'`；测试结果 XML 被对方的 run 覆盖）。

所以 Android 的全部判据都在**隔离 worktree**（`git worktree add ... HEAD
--detach`，纯 HEAD + 只打本卡这 3 个文件的补丁）里跑，并且加
`--no-build-cache` + `clean` 断掉跨树缓存复用（第一次没加，被缓存喂了
假数字，已作废重跑）。

**APK 体积 A/B**（同一 worktree，先纯 HEAD 后打补丁，各自 clean +
`--no-build-cache`）：

```
### A: pure HEAD (clean, no build cache)
BUILD SUCCESSFUL in 4s
A_BYTES=28267326
### B: HEAD + ICON-02 (clean, no build cache)
BUILD SUCCESSFUL in 4s
B_BYTES=28266567
DELTA=-759
```

**机制佐证**（解包两个 APK 查 dex + 资源表）：

```
A-head:    ShareKt_in_dex=1  ic_share_resource_entries=1
B-icon02:  ShareKt_in_dex=1  ic_share_resource_entries=0
```

即：改动**之前**的 APK 里就已经有
`androidx/compose/material/icons/filled/ShareKt` 了（material3 传递带进来
的、没人用的库）。本卡只是开始用它，并删掉那份多余的自绘 drawable。

**全量单测**（同一隔离 worktree，`--no-build-cache`）：

```
$ ./gradlew --no-build-cache :app:testDebugUnitTest
> Task :app:testDebugUnitTest
BUILD SUCCESSFUL in 2s

$ 汇总 test-results/testDebugUnitTest/*.xml
test classes=30  tests=187  skipped=4  failures+errors=0
```

（主工作区跑是 206 个用例——多出来的 19 个是并行 session 那批新测试，
不属本卡基线。）

**「4 秒构建 / 2 秒跑完全量单测，是不是又被缓存喂了假数字？」——不是，
两条自证**：

1. A/B 两个 APK 的**内容差**正好是本卡改的那一处（A 有 `ic_share` 资源
   项、B 没有；`ShareKt` 两边都在）。缓存复用出来的陈旧产物不可能恰好
   呈现这个内容差。
2. 隔离 worktree 的测试结果是 **187** 个用例，主工作区是 **206** 个。
   如果 XML 是从主工作区的 task 输出里恢复的，它只会是 206。187 这个数
   本身就是「确实在这棵纯净树上真跑了」的判别式。

**grep 清空判据**（隔离 worktree）：

```
--- ic_share refs in apps/android (excluding build/) ---
apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/VideoScreen.kt:134:
    // ic_share.xml 抄的就是同一条 pathData，形状零差异。
--- material.icons imports ---
VideoScreen.kt:17: import androidx.compose.material.icons.Icons
VideoScreen.kt:18: import androidx.compose.material.icons.filled.Share
```

（唯一命中是注释，代码零残留；`ic_notification` 按上文平台约束照旧保留，
是有意为之不是漏改。）

**实机未做**：分享图标在真机上的显示由验收人挂账（按本项目当前阶段的
验证纪律）。理由上风险极低——`Icons.Filled.Share` 与被删的
`ic_share.xml` 是同一条 Material pathData，`Icon()` 的默认尺寸 24.dp 与
tint 用法都没变。

## 未做的收尾（**故意留给验收人**）

用户明确要求本轮**不 commit / 不 push**，工作区留着人工 review。因此：

- 卡**没有**移进 `.claude/cards/done/`（Android 端 TabIcons 部分本就
  未完，卡应保持在队列里）。
- **没有**动 `docs/PROGRESS.md` / `docs/ROADMAP.md` / `docs/NEXT.md`——
  这三处跟着合并动作一起更，由验收人决定。
- 注意：ROADMAP.md:462、NEXT.md:851、PROGRESS.md MOB-06 行都写了「自绘
  ic_share.xml」，合并本卡时需要同步订正。
