# ICON-02 功能小图标改用开源图标库　级别 L1【独立，无依赖，可拆两半分别做】

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
