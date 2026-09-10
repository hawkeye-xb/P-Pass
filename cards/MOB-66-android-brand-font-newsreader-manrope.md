# MOB-66 Android 品牌字体接入：Newsreader/Manrope 替换系统默认字体

> ⬜ 状态：未开工
> 级别：L2 · 阻塞：无

## 问题

`assets/design/tokens.json` 规定 desktop/mobile 共用同一套字体语义：
`font.serif` = Newsreader（标题/结论句），`font.sans` = Manrope（正文/
界面，中文场景配 Noto Sans SC）。桌面端已经把这两个字体接进
`tokens.css` → `app.css` 的 Tailwind theme。Android 端 `ui/Tokens.kt`
完全没有字体 token；`BucketScreen.kt`/`PhotosScreen.kt`/`HomeScreen.kt`/
`Onboarding.kt`/`ScanScreen.kt` 五个文件里散落 11 处硬编码
`FontFamily.Serif`，实际渲染的是 Android 系统默认衬线字体，不是设计
规定的 Newsreader；正文类文字也没有任何地方显式接 Manrope。品牌识别度
在 Android 端跟桌面不一致（2026-09-09 桌面 vs Android token 覆盖度核查
发现，颜色/尺寸/圆角均已对齐，字体是唯一真实缺口）。

## 期望行为

Android 界面标题/结论句用 Newsreader，正文/UI 用 Manrope（中文走 Noto
Sans SC 后备），视觉上与桌面一致；`Tokens.kt` 是字体 token 的唯一定义
处，组件层不再各自写裸 `FontFamily.Serif`。

## 验收标准

- [ ] `apps/android/app/src/main/res/font/` 下有 Newsreader（400/500/600）
      与 Manrope（400/500/700）字体文件，来源 Google Fonts、协议 SIL
      OFL 1.1（可免费商用、可打包分发，已在讨论中核实）
- [ ] `ui/Tokens.kt` 新增 `PPFont` object：`PPFont.Serif` / `PPFont.Sans`
      （Compose `FontFamily`，由 `Font(R.font.xxx, FontWeight.xxx)` 组
      成），字重映射对齐 `tokens.json` 的 `font.serif`/`font.sans`
- [ ] 5 个文件里全部 11 处 `FontFamily.Serif` 调用点改用 `PPFont.Serif`；
      当前隐式吃系统默认字体的正文 `Text` 改显式 `PPFont.Sans`
- [ ] `FontFamily.Monospace` 调用点（配对码/日志片段等技术信息展示）
      保留不动——这是故意的等宽语义，不属于品牌字体范围，不要连带改掉
- [ ] 真机或模拟器截图对比标题/正文渲染前后差异，确认不再是系统默认
      宋体/黑体
- [ ] `assets/design/README.md` 里 "*(future)* `Tokens.kt` | Android
      app (M2 T-055) — generate from `tokens.json`" 这行已经跟代码现状
      脱节（`Tokens.kt` 早已存在并被消费），本卡完成后一并改成如实的
      完成状态描述

## 范围

- 只准动：`apps/android/app/src/main/res/font/`、`ui/Tokens.kt`、上面
  列出的 5 个消费 `FontFamily.Serif` 的 Compose 文件、
  `assets/design/README.md` 对应那一行
- 不准动：颜色/尺寸/圆角等其余已对齐的 token；桌面端字体链路（已完成，
  不在本卡范围）；`FontFamily.Monospace` 的既有调用点

## 阻塞与依赖

无。字体文件属于外部资源引入（下载动作），实施前需按讨论中定的清单
（Newsreader 400/500/600 + Manrope 400/500/700，OFL 协议）逐项确认后
再拉取，不能替换成别的字重或来源。

---

## 已定设计决定（讨论产出，作为实现方式记录）

1. **授权**：字体来自 Google Fonts，协议 SIL Open Font License 1.1——
   免费商用、可打包进 APK 离线分发，不需要额外授权流程或署名弹窗；唯一
   限制是不能把字体文件本身单独转卖或去掉授权声明。
2. **离线优先**：字体文件直接拉到 `res/font/` 作为本地资源，不用
   Google Fonts 运行时下载 API——避免给 60 岁用户的设备增加"首次启动
   要联网拉字体"这种不可靠依赖。
3. **实现分两步，缺一不可**：
   a) 把字体文件放进 `res/font/`；
   b) 在 `Tokens.kt` 新增 `PPFont`，把 5 个文件里的裸
      `FontFamily.Serif` 调用点全部替换成 `PPFont.Serif`——保证以后
      换字体只改 `Tokens.kt` 一处，不再散落各页面。
4. `FontFamily.Monospace`（配对码、诊断信息等等宽展示场景）明确排除在
   外，那是等宽语义决定，不是遗漏的品牌字体缺口，不要顺手改掉。

## 实施记录

未开工。

## 备注

本卡由桌面 vs Android 设计 token 覆盖度核查中发现（2026-09-09）：颜色
17 项、`tap-min`/`radius.card` 等尺寸均已对齐且无漂移，字体是当时列出
的唯一真实缺口，故单独开卡跟踪，不与颜色/尺寸类 token 混在一起处理。
