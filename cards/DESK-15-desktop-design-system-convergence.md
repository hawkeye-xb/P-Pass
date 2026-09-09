# DESK-15 桌面设计系统收口：现有风格映射为组件与 token

> 🟢 状态：基准/token 链 + Button/Card/Dialog/Notice/NavItem 组件合同 +
> 轻量门禁（Button/Card 变体锁测试）+ token 复用清单已完成，全量
> `just ci`（含 Rust fmt/clippy/nextest 345 passed）本地验证全绿 ·
> 当前节点：跨断点/Dialog 的自动化布局回归基础设施明确暂不做（2026-09-09
> 用户拍板"没到那个时候"，不是遗漏）；Button 图标动作变体移入 backlog
> （低优，见 `docs/QUEUE.md` 八、backlog）
> 级别：L2 · 阻塞：无

## 问题

桌面端已采用 Svelte、Tailwind 与 shadcn-svelte，`assets/design/tokens.json` 也已经统一了暖纸/墨字/语义色、字体、圆角、最小字号与控件高度；但这些规则没有完整映射为 P-Pass 自己的基础组件。当前页面同时存在 shadcn 默认组件、页面级 Tailwind 覆盖、原生 `<button>` 和旧手写 CSS。相同语义的动作、卡片和提示由不同路径实现，设计语言无法由一个修改自动传播到全桌面。

设计基准也尚未收口：v1/v2 已是历史快照，`2026-08-17-layout-v3` 明确为后续 UI 验收基准，但仓库入口仍有过时指向。

## 期望行为

保留现有 P-Pass 设计语言与现有技术栈：不换 Svelte、Tailwind 或 shadcn-svelte，不重新设计页面。以归档的 v3 为当前唯一工程基准；把已存在的 token 复用为唯一数值来源，并只补足其未覆盖的稳定规则。将设计稿中的高频、语义明确的桌面元素收口为 P-Pass 基础组件，使页面只组合业务状态和组件，不再各自定义主按钮、卡片、弹窗、状态提示的视觉规则。

后续设计迭代必须先以新目录归档成新的冻结版本，再切换工程验收基准；不得让外部活设计稿直接绕过仓库进入实现。

## 验收标准

- [ ] 仓库入口明确 v3 是当前 UI 工程基准；v1/v2 仅作历史追溯。新设计迭代的归档与切换规则写入仓库，`just queue-check` 通过。
- [ ] 对 `assets/design/tokens.json` 做复用清单：已有颜色、字体、圆角、最小字号/控件高度必须继续复用；只为缺失且稳定的 spacing、排版层级、布局别名和组件别名增 token，不复制现有数值或另建平行调色板。
- [ ] token 的派生链可验证：桌面 `tokens.css` 与 Tailwind 主题只消费 canonical token；新增或改动 token 有检查，缺失/漂移必须失败。
- [ ] shadcn-svelte 保留为源码入仓的行为/结构基础；按 v3 实际需要增入并改造 Button、Card、Dialog、Status/Notice、NavItem 等 P-Pass 组件。页面的标准 action、surface、dialog、status 不再直接拼视觉 class。
- [ ] P-Pass Button 至少提供主、次、危险、文字、图标动作；Card、Dialog、状态/提示组件的常见变体由组件自身定义。组件默认值遵守 `tokens.json` 的桌面文字和控件下限；紧凑控件只能是显式、已文档化的例外。
- [ ] 现有桌面页面和向导中可由上述组件表达的旧 `BTN*` 常量、裸 action button、旧全局 `button`/`.primary` 样式和 Card 默认值覆盖被迁走；导航、图片格子、输入等保留正确原生语义，但不再由页面重复定义同类视觉规则。
- [ ] 组件变体有可重复验证；保留少量布局锚点覆盖三档桌面宽度、向导、一个 Dialog 和卡内滚动。无需把每页做成重型像素回归，但 token 或组件改动不得静默破坏这些锚点。
- [ ] 每个实现子卡给出真实的相关命令输出；父卡收尾运行 `just ci`，更新 `PROGRESS.md`、`ROADMAP.md` 与 `docs/QUEUE.md`。

## 范围

- 只准动：`docs/design/` 中 UI 基准入口说明、`AGENTS.md` 中对应入口规则、`assets/design/tokens.json` 及其桌面派生链、`apps/desktop/` 的组件/样式/测试、关联 CI 或检查脚本、此卡及由本卡拆出的实现卡。
- 不准动：桌面业务语义、IPC/daemon 调用、Rust 业务逻辑、Android 视觉栈；不因本卡替换 Svelte、Tailwind 或 shadcn-svelte；不凭空批量安装未被 v3 或现有界面使用的组件。

## 阻塞与依赖

无。实现前必须先完成 token 复用清单和 v3 基准收口；二者是后续组件 API 的前置，而不是可在页面迁移时临时决定的事项。

---

## 已定设计决定

1. **当前工程基准**：`docs/design/2026-08-17-layout-v3/`。v1/v2 是历史快照；外部设计项目的变更先归档为新版本，再切换。
2. **token 的职责**：token 管稳定数值和语义；组件管结构、状态、可访问性和何时使用。不得把每条 CSS 都变成 token。
3. **组件的职责**：shadcn-svelte 组件源码已入仓，不是运行时黑箱。对产品通用元素，直接将其源码改造成 P-Pass 标准组件；页面不得通过长 class 覆盖其视觉合同。
4. **迁移边界**：不是消灭所有原生标签。原生标签保留语义；禁止的是页面为同类 action/surface/dialog/status 重复定义一套视觉语言。
5. **验证策略**：先由 token + 组件约束消除大部分漂移；只保留低成本的组件状态与关键布局锚点验证，不把全量像素回归当作日常开发门槛。

## 拆分原则（由本卡协调后创建实现子卡）

子卡按“先定义、后消费”和避免同文件并发冲突拆分：

1. **基准与 token 链**：校正 v3 入口、列出已有 token 的复用/缺口、建立派生检查；不迁页面。
2. **基础组件合同**：基于现有 shadcn 源码收口 Button/Card，并按已确认需求加入 Dialog/Status/Notice 等；不改业务数据流。
3. **页面迁移**：按 App shell、向导、弹窗/查看器等无共享文件冲突的批次，删除旧 action/surface 样式并接入组件。
4. **轻量门禁**：组件变体与关键布局锚点、禁止新增平行视觉值的检查；不与基础组件 API 同时决定。

先完成第 1 步并把组件 API 写入子卡，再并行派发不冲突的实现批次；任何新 token 或组件语义都只能由第 1/2 步的责任卡决定。

## 实施记录

**2026-09-09：第 1+2 步（基准/token 链 + Button 组件合同）合并完成**（12 个
桌面 `.svelte` 文件、体量小，未按拆分原则另开子卡分派，直接在本卡下做）：

- 现状核实推翻了卡片原始描述：DESK-07 已经把 shadcn 语义槽位接到
  `--pp-*`（`app.css` `@theme inline`：`--color-primary: var(--pp-ink)`
  等），颜色/圆角早已走 token，不是要重新映射的缺口。真正缺的只有
  两件事，已修：
  1. `AGENTS.md:164` 指向过期的 v1；`docs/design/2026-08-14-layout-v2/
     README.md` 仍自称"唯一基准"。已改指向 v3，v2 README 补齐"已被
     取代"声明（对齐 v1 README 已有写法）。
  2. `tools/check-token-drift.py` 新增，接入 `just ci`：`tokens.css`
     此前无任何机制防止漂离 `tokens.json`，已实测能抓真实数值差异
     （见脚本头注释与本次验证记录）。
- Spacing 未新增 token：v3 设计稿(`.dc.html`)像素值统计显示间距集中在
  Tailwind 默认 4px 刻度上，另建 token 属于卡片明令禁止的"平行数值"；
  用户拍板确认不建。840/400/360px 这类布局别名也**未做**（用户口头
  同意"先用变量，回头再改也快"，即暂不落 token，留作后续需要时再补）。
- Button 组件（`ui/button/button.svelte`）：`variant` 改为
  `primary/secondary/danger/link`（+`tone=safe` 供 link 变体）、
  `size` 增 `compact`（唯一显式文档化的紧凑例外）。数值原样收编自
  DESK-08 已像素验收过的 `BTN/BTN_OUTLINE/BTN_DANGER/BTN_LINK`
  常量，不是重新设计；默认高度 44px/字号 15px，44px 达标
  `tokens.json size.desktop.tap-min`，15px 低于 `body-min`(16px) 作为
  显式例外记录在组件注释里（按钮标签不算"正文"）。
- 页面迁移（App.svelte / Wizard.svelte / WizardWindows.svelte）：全部
  `BTN*` 常量、裸 `<button>`（弹窗/pending 列表/照片查看器）、全局
  `button`/`button.primary`/`.link-more*` CSS 规则已删，统一改调用
  `<Button variant=... />`。

**2026-09-09（同日第二轮）：Dialog / Notice / NavItem 三个组件补齐**
（用户明确要求"一口气全改完"，不再分批留给后续）：

- **Dialog**（`ui/dialog/dialog.svelte`）：收编原 App.svelte 三处各自
  复制的 `.modal-backdrop`/`.modal` 手写结构为一个组件。行为对齐原
  实现的真实差异——传 `onClose` 才让点遮罩关闭（配对二维码/大图查看
  器），待确认加入列表故意不传（不能靠误点背景关掉，必须显式选择）。
  三处调用（配对二维码弹窗、待确认加入列表、大图查看器）全部迁移，
  `.modal-backdrop`/`.modal`/`.photo-modal` 三条 CSS 规则已删。
- **Notice**（`ui/notice/notice.svelte`）：收编原两处（wizard-shell 头部
  / shell 内容区）完全重复的 toast 提示条 `.message`/`.message-close`。
- **NavItem**（`ui/nav-item/nav-item.svelte`）：收编侧栏 `.nav-item`/
  `.nav-icon`/`.nav-label`，含 `<1080px` 收起成纯图标的响应式覆盖
  （`max-[1079px]:` 变体），数值原样保留。
- 三者都不新增视觉数值，只是把已经存在、且在多处重复的规则收进组件，
  原 CSS 规则同步删除，不留第二份定义。
- **轻量门禁**：新增 `ui/button/button.test.js`（锁 Button 四个 variant
  + tone=safe + size=compact 的 class 契约）——**这条测试本身被验证过
  会抓 bug**：先用子串匹配写的版本被 `min-h-11` 包含 `h-11` 子串误判
  通过，改成 token 级精确匹配后，故意把 primary 的 `h-11` 改成 `h-9`
  重跑，测试真的红了，改回来再绿，才定稿。跨组件/跨页面的布局断点
  锚点（三档桌面宽度/向导/Dialog/卡内滚动的自动化回归）**没有做**——
  这个仓库目前没有任何浏览器级 E2E/像素回归基础设施（`e2e.yml` 只测
  Android iroh 协议，没有 Playwright 之类工具），要建这个是新的基础设
  施投入，不是这次顺手能做的量级；三档宽度/Dialog 我改完后用浏览器
  面板肉眼验证过（见下），但那是一次性人工验证，不是可重复的门禁。
- 验证：`pnpm build` 0 error（沿用与迁移前一致的既有 `.qr-fallback`
  unused-CSS 警告，`git stash` 对比过确认非本次引入）；`pnpm test`
  54/54 绿（47 条既有 + 7 条新 Button 合同测试；renameFeedback.test.js
  两条断言原本直接 grep App.svelte 的 `.modal-backdrop`/`.message` CSS
  文本，组件化后源码位置变了，已同步改成读 dialog.svelte/notice.svelte
  的 Tailwind class，而不是删掉测试);`just queue-check`/`md-check`/
  `token-check` 全绿。浏览器实测：主页/设置页/家人与设备页按钮真实
  计算样式（44px/15px/700/#171512/#FBF8F2/14px）与旧 BTN 常量像素一致；
  临时把 `showPairModal`/`message` 的初始值改真触发 Dialog 与 Notice
  渲染，确认背板点击关闭、× 关闭都生效（验证完已改回 `false`/`""`）；
  <1080px 收起态侧栏图标+active 高亮正确，验证完视口已还原。

**2026-09-09（同日第三轮）：Card 组件补齐**（用户追问"table 之类的还有
没有"时顺带排查出来的——发现这个组件跟 Button 有一模一样的病，之前
两轮没查到）：

- 排查发现 App.svelte 里全部 10 处 `<Card>` 调用，每处都手动覆盖同一套
  shell（`rounded-xl border shadow-none ring-0 ring-transparent`），
  且都要另外补一遍横向内边距——因为 `card.svelte` 原装的 shadcn 默认值
  （`shadow-xs ring-1 ring-foreground/10`、只有纵向 `--card-spacing`
  没有横向内边距）在这个 app 里**从未被直接用过一次**。跟 Button 当初
  的问题一模一样，只是我前两轮review 时漏查了 Card。
- 收编方案：`size` 从 shadcn 原装的 `default|sm`（未使用过）改成
  `default|flush`（22px/20px 内边距 vs 零内边距，两者都是从现有 10 处
  调用里原样提炼的真实值）；新增 `variant="danger"`（红边红底，对应
  设置页"停止后台服务"卡）。10 处调用全部迁移，只保留真正一次性的
  布局差异（`gap-[12px]`、`min-h-0 flex-1 overflow-y-auto`、响应式
  `col-span`、`flex-[1.2_1_0%]`、按内容需要的 `text-[16px]`）。
- 顺带把 `card.svelte` 重构成跟 `button.svelte` 一样的形状——导出一个
  纯函数 `cardVariants()`，不然没法脱离 DOM 渲染写合同测试。CardHeader/
  CardContent/CardFooter/CardTitle/CardDescription/CardAction 这几个
  shadcn 子件本 app 至今零使用，`--card-spacing` 变量原样保留供它们
  未来使用，没有精简掉。
- 轻量门禁：仿 `button.test.js` 加了 `card.test.js`，同样先验证过会
  抓 bug（故意把 danger 的 `border-act` 改成 `border-border`，测试真红，
  改回来再绿）。
- 验证：`pnpm build` 0 error（CSS 产物从 30.28KB 降到 29.95KB，量级上
  印证了重复确实被去掉了，不是我自己瞎猜）；`pnpm test` 58/58 绿
  （54 条既有 + 4 条新 Card 合同测试）；`just queue-check`/`md-check`/
  `token-check` 全绿。浏览器实测四个页面（总览默认卡、设置页 danger
  卡、家人与设备页 flush 卡、活动记录页 flush 卡），JS 读计算样式确认
  border-color/radius/shadow/padding/font-size 全部与迁移前吻合。

**2026-09-09（同日第四轮）：收尾**——用户追问 table/游标分页设计问题后
拍板三件事，一并办完：

1. **Button「图标动作」变体移入 backlog**（低优）：验收标准列了这一项，
   但目前代码里没有真实的 icon-only 按钮用例，不凭空加。见
   `docs/QUEUE.md` 八、backlog 区新增行。
2. **token 复用清单整理成独立文档**：新增
   [`assets/design/token-reuse-checklist.md`](../assets/design/token-reuse-checklist.md)——
   逐类核对 `tokens.json` 的复用情况：已复用的（颜色/字体/圆角/
   tap-min/body-min）、判断不需要新增的（spacing 走 Tailwind 默认刻度、
   840/400/360px 暂不建布局别名）、组件自己的结构决定（不是 token
   遗漏）三类分别列清楚；同时更新了 `assets/design/README.md` 说明
   `token-check` 现在是自动检查，不再是纯手工承诺。
3. **全量 `just ci` 已跑**：`cargo fmt --check` + `cargo clippy -D
   warnings`（全 workspace）+ `cargo nextest run --all-features`
   （345 passed / 1 skipped）+ `arch-check` + `queue-check` +
   `md-check` + `token-check`，全绿；顺手核对并修正了 `docs/QUEUE.md`
   里长期滞后的本机基线数字（nextest 320→345、桌面 pnpm test 24→58、
   src-tauri cargo test --lib 15→18，这几个数字之前就是错的，跟这轮
   改动本身无关，顺手修）。

**仍未做，明确不是本卡遗漏**：跨页面/跨断点的自动化像素回归基础设施
（需要引入 Playwright 之类工具）——2026-09-09 用户拍板"没到那个时候"，
先不动；桌面部分现有的验证手段是浏览器面板手动核对 + 组件合同测试，
对当前体量够用。
