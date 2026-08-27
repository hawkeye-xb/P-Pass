# DESK-07 桌面壳迁移到 Tailwind CSS + shadcn-svelte　级别 L2【用户 2026-08-14 拍板，建议拆成多轮，本卡只做第一轮】

背景：`apps/desktop` 前端目前零 UI 组件库——`package.json` 只有 Svelte
本身 + Tauri API + qrcode，所有按钮/卡片/列表样式都是手写 CSS，靠
`assets/design/tokens.css` 的变量 + 代码注释自律维持一致性，没有共享
组件强制约束。这是这两天反复挑出"这个按钮跟那个按钮不一样""分隔线
没贴边"这类问题的根本原因——没有组件层挡着，纯靠人（或 agent）记住
每一处该长什么样，必然会drift。用户拍板换成 Tailwind CSS +
shadcn-svelte（组件代码直接进仓库、不是 node_modules 里的黑箱，AI
读一眼就知道现状；shadcn/ui 系是训练数据里最常见的 UI 库之一，AI
生成的写法天然倾向一致）。

## 目标

`apps/desktop` 的样式体系换成 Tailwind CSS + shadcn-svelte，`assets/design/tokens.css`
继续是颜色/间距/字体的唯一真相源（Tailwind 只是"消费"这些 CSS
变量，不新建一套调色板、不重复定义）。**本卡只做地基 + 一个页面的
迁移验证，不要求一次性把整个 App 迁完**——验证"新体系能不能做出
跟现状一样的效果"，跑通之后再排后续卡逐页迁。

## 范围

只准动：
- `apps/desktop/`（Tauri 前端目录）：`package.json`/`vite.config.js`
  加 Tailwind 依赖与配置；`src-tauri/` 不动（这是纯前端样式改动）。
- shadcn-svelte 初始化产物（组件会落进 `apps/desktop/src/lib/components/`
  或其 CLI 默认的目录，跟着官方脚手架走）。
- Tailwind 主题配置文件——把 `--pp-ink`/`--pp-safe`/`--pp-act` 等
  颜色变量、`--pp-radius-*`、`--pp-font-*` 映射进 Tailwind theme（读
  CSS 变量，不是抄一份新数值）。
- **先迁一个页面验证**：建议选 `apps/desktop/src/App.svelte` 里的
  "家人与设备"页（`page === "devices"` 分支）——这块最近刚做过像素级
  还原，有明确的"对不对"判断基准，适合当验证用例。

## 不准动

- `assets/design/tokens.json`/`tokens.css` 里的**数值本身**（颜色/
  圆角/字号取值）——这些是仓库唯一真相源，Tailwind 配置只引用
  `var(--pp-xxx)`，不允许在 Tailwind config 里重新写一遍十六进制色值
  （那样以后改色就要两处同步，等于又造了一个 drift 源）。
- `apps/android/`——安卓是完全独立的 UI 栈（Jetpack Compose），跟这次
  桌面壳的 Tailwind 迁移没关系，不动。
- 任何 IPC/业务逻辑代码（`invoke(...)`/daemon 调用/状态管理的 `$state`/
  `$derived` 逻辑）——这是纯展示层重构，数据流不能变。
- 除"家人与设备"页之外的其它页面（总览/照片/活动记录/设置）——本卡
  只验证地基，其它页留给后续卡，不要贪多导致一个 PR 太大没法审。

## 设计要点

- **先验证兼容性,再动手**：shadcn-svelte 对 Svelte 5 的支持要先确认
  （本仓 `package.json` 是 `"svelte": "^5"`）——查 shadcn-svelte 官方
  文档/GitHub 确认当前版本对 Svelte 5 的支持状态。如果碰到硬性不兼容，
  允许换成同类的、一样走"组件代码进仓库+Tailwind"路线的方案（比如
  直接基于 Melt UI/Bits UI 手搭，或者 Skeleton），但要在验收记录里
  写清楚换了什么、为什么——不能默默换掉又不说。
- **token 桥接是这张卡最核心的技术决定**：Tailwind v4 用 CSS 里的
  `@theme` 指令定义主题（不一定是旧版的 `tailwind.config.js` JS 配置，
  取决于装的版本），具体怎么把 `var(--pp-ink)` 这类 CSS 变量接进
  Tailwind 的颜色系统（`bg-ink`/`text-ink` 这类工具类），照 Tailwind
  当前官方文档的推荐做法做，不要凭旧版本记忆瞎写。
- **迁移验证的"对不对"标准**：迁完"家人与设备"页后，下面这些最近
  刚修好的细节必须原样保持（这些是像素级验证过的基准，不是随口一说）：
  - 列表容器无 padding，每一行自己 padding 18px 22px，分隔线贴着卡片
    圆角边缘（不是缩进的）
  - "移除"是纯文字链接（颜色 `--pp-act`，无边框无底色无圆角胶囊），
    不是实心按钮
  - 标题 28px、副标题 14px（margin-top 6px）、提示文案 13px
  - 窗口 <1080px 时跟侧栏收起态联动正常（这个逻辑在 `App.svelte`，
    本卡不改，但页面结构改动后要确认没连带弄坏）
- **组件粒度自己判断**：shadcn-svelte 的组件目录里有很多现成组件
  （Button/Card/Dialog 等），不需要把每一种都装上——先装这一页真正
  用到的（大概是 Button 的几个变体：primary/次要/危险/纯文字链接，
  以及 Card），够用就好，不要为了"完整"批量装一堆当前用不上的组件。

## 可执行验收

- 依赖安装 + Tailwind/shadcn-svelte 初始化后，`npm run build` 绿
  （vite build，跟现有验证方式一致）。
- "家人与设备"页迁移后，逐条对照上面"设计要点"列的像素基准——用
  跟本次对话同款的方法验证（比如渲染成截图，或者直接跑真实 App
  用 headless chrome 截图对比），不能只凭肉眼扫一遍就说"看起来对"。
- 反证：随便挑一条基准（比如"移除"按钮的边框），临时改错，确认
  截图对比能看出差异——证明验证方法是真的在比对，不是摆设。
- 全量：`cargo test --workspace`（本卡不改 Rust，但收尾照旧全量跑
  一遍确认没有跨语言的意外联动）+ `npm run build`。

## 证据要求

依赖安装日志摘要 + 迁移前后截图对照（至少"家人与设备"页一张）+
build 输出。

## 跨卡声明禁令

不许写"桌面壳已全面迁移到 Tailwind/shadcn-svelte"——本卡范围明确
只有地基 + 一个页面，其余页面没做之前，只能写"地基验证通过，其余
页面排后续卡"。

## 收尾

`npm run build` 绿 + "家人与设备"页视觉对照通过 + PROGRESS.md 一行
（写清楚验证了什么、其它页面还没迁）+ ROADMAP.md 状态行 + NEXT.md
队列状态（列出后续还要迁哪些页面，方便排下一张卡）。

---

## 验收记录（2026-08-14 完成第一轮）

**结论：地基验证通过 + 家人与设备页迁移完成；其余页面未迁，排后续卡。**
（跨卡声明禁令遵守——不写「桌面壳已全面迁移」。）

### 兼容性确认
shadcn-svelte 1.5.0（2026-07 发布）peer dep 即 `svelte: ^5.0.0`，Svelte 5 支持是
主线（PR #1182 早已合入），**无硬性不兼容，未换方案**。

### 做了什么
1. **依赖/初始化**：`tailwindcss@4.3.3` + `@tailwindcss/vite`（vite.config.js 插件 +
   `$lib` alias）+ `shadcn-svelte init`（Vega preset → components.json、`src/lib/utils.ts`
   cn 工具、tsconfig.json 供 CLI/IDE）；`add button card` 只装这两组件。
2. **token 桥接（本卡核心技术决定）**：`src/app.css` 用 `@theme inline` 把
   `--color-*`/`--font-*`/`--radius-*` 全部映射到 `assets/design/tokens.css` 的
   `var(--pp-*)`——工具类（bg-ink/text-act/border-divider/rounded-sm…）运行时解析，
   不抄数值、无平行调色板。shadcn 语义槽位映射：primary=ink/paper（P-Pass 主按钮
   是墨不是绿）、destructive=act、secondary/muted/accent=linen/idle-bg。
3. **迁移页**：App.svelte「家人与设备」分支换 `Button`(link 变体) + `Card` +
   工具类；数据流/交互（改名/移除/状态推导）一字未动；设备页专属手写 CSS 已删，
   overview 仍用的 .device-rows/.statusdot/.dev-name/.dev-right 保留。
4. **preflight 副作用修复（回归中发现）**：`html { line-height: normal }` 抵消
   preflight 的 1.5 全局继承（否则其它页内容整体下移）；`code/kbd/samp/pre`
   还原 UA 默认 monospace（否则设置页库路径框字形变化）——**其它页渲染保持原样**。

### 可执行验收逐条
- ✅ `pnpm build` 绿（192 modules；CSS 40.84kB / JS 205.30kB gzip 66.76kB）
- ✅ 像素基准 19 项迁移前后 DOM 实测全等（Playwright 无头 + mock Tauri 桥，w1280+w1000）：
  标题 28px / 副标题 14px+mt6 / 提示 13px / 列表容器 padding 0 + 行 18px 22px /
  分隔线贴圆角边缘（行 x=255 vs 卡 x=254，差 1px=边框）/ 移除=纯文字链接
  （act 色 rgb(181,52,31)、bg 透明、border none、radius 12px 非胶囊、fs 14 fw 600）/
  <1080px 侧栏收起 64px / 状态点色 safe/wait/idle/act 四态正确
- ✅ 反证：故意给移除按钮加 `border-2 border-act` → 测量抓到 borderStyle=solid/2px
  （与 baseline none/0px 显著不同）→ 还原后复测归零 —— 验证方法真在比对
- ✅ 全页回归：其余四页（总览/照片/活动记录/设置）迁移前后**像素级 identical**
  （8/8 截图 diff 零差异）
- ✅ `cargo test --workspace` 全量绿（本卡未改 Rust）
- ✅ 交互闭环：改名（点击→输入→Enter→flash「已改名为」→刷新显示新名）、
  移除点击无异常；双视口 console 零错误

### 证据
- `docs/evidence/2026-08-14-desk07-tailwind/`：迁移前后设备页截图（w1280/w1000）
  + 前后 DOM 实测 JSON
- 依赖安装日志摘要：pnpm add tailwindcss@4.3.3/@tailwindcss/vite@4.3.3 →
  shadcn-svelte 1.5.0 init（bits-ui/tailwind-merge/tailwind-variants/clsx/
  tw-animate-css/lucide 等 8 包）→ add button card
- build 输出：见上

### 挂用户（真机一条）
Tauri 实际窗口观感确认（浏览器渲染已像素级对齐；真机窗口走查一次即可）。

### 后续页面（排卡顺序）
总览（DESK-08）→ 活动记录（DESK-09）→ 设置（DESK-10）→ 照片（DESK-11）；
shadcn 组件按页按需 add，不批量装。详见 docs/NEXT.md。
