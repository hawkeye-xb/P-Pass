# Token 复用清单（DESK-15）

对照 `tokens.json` 的每一类数值，核实桌面端组件是否已经复用、是否存在
真实缺口。**结论优先于过程**——这份清单是判断结果，不是调研记录；调研
证据（v3 设计稿像素值统计、App.svelte 现状扫描）见
[DESK-15 实施记录](../../cards/DESK-15-desktop-design-system-convergence.md#实施记录)。

## 已有 token，已复用（不重复定义）

| tokens.json 类别 | 派生到 | 组件消费方式 |
|---|---|---|
| `color.*` | `tokens.css` `--pp-*` → `app.css` `@theme inline` `--color-*` | shadcn 语义槽位（`--color-primary`/`--color-destructive`/…）直接映射到 `--pp-*`，Button/Card/Dialog/Notice/NavItem 全部走 Tailwind 颜色 class（`bg-primary`/`text-act`/`bg-waiting-bg`…），不直接写 `--pp-*` 或十六进制 |
| `font.serif` / `font.sans` | `--pp-font-serif` / `--pp-font-sans` → `--font-serif` / `--font-sans` | Tailwind `font-serif`/`font-sans`（标题/正文），组件层未额外声明字体栈 |
| `radius.card` (20px) | `--pp-radius-card` → `--radius-xl` | Card/Dialog 面板 `rounded-xl` |
| `radius.control` (14px) | `--pp-radius-control` → `--radius-md` | Button 默认 `rounded-md` |
| `radius.control-sm` (12px) | `--pp-radius-control-sm` → `--radius-sm` | NavItem `rounded-sm` |
| `radius.pill` (999px) | `--pp-radius-pill` | 未在新组件里直接用到（service-pill 仍是页面级 class，不在本轮范围） |
| `size.desktop.tap-min` (44px) | `--pp-tap-min`（tokens.css 已定义） | Button 默认 `h-11`/`min-h-11`——数值与 token 一致，但组件类里是字面量 `h-11` 不是 `h-(--pp-tap-min)`；`h-11` 已经等于 44px，跟 token 同源但不是变量级联，见下方「已知不精确」 |
| `size.desktop.body-min` (16px) | `--pp-body-min`（tokens.css 已定义） | 同上：正文类内容用字面量 `text-[16px]`，数值一致但非变量级联 |

**已知不精确，故意接受**：`tap-min`/`body-min` 目前是"数值恰好相等的字面量"，不是"变量级联"（Button 写 `h-11` 不是 `h-[var(--pp-tap-min)]`）。原因：Tailwind 的默认间距刻度（`h-11`=44px）已经是这两个值的天然表达，级联反而要额外造一层 `h-(--pp-tap-min)` 语法且没有实际收益（44px 不会变——它是"电脑鼠标最小可靠点击尺寸"这类物理常量，不是随主题换的调色值）。`tools/check-token-drift.py` 目前只查 `color`/`font`/`radius`/`size.desktop.{body-min,tap-min}` 这几类数值型 token 在 `tokens.css` 里的字面量是否漂移，组件里的字面量是否跟 tokens.css 一致目前**没有**自动检查——这是一个已知的、可接受的剩余缺口（见下方「仍未做」）。

## 判断为不需要新增 token 的缺口

| 疑似缺口 | 判断 | 依据 |
|---|---|---|
| Spacing 刻度（按钮内边距、卡片间隔…） | **不新增** | 对 v3 设计稿 `.dc.html` 做了像素值频次统计，高频值（2/4/6/8/…/48px）几乎全部落在 Tailwind 默认 4px 刻度上；再建一套 P-Pass spacing token 属于卡片明令禁止的"另建平行数值" |
| 840px / 400px / 360px 等重复出现的宽度 | **暂不建布局别名 token** | 2026-09-09 用户拍板："先用字面量做，回头改也快"——这几个值目前只在弹窗/向导宽度里各出现，还没有多处复用到值得抽象成命名 token 的程度；等真的出现第二处需要复用再补，不是现在就抽象 |
| `radius.pill`（999px） | 暂不消费 | 现有胶囊状元素（`service-pill`）还是页面级手写 class，不在 Button/Card/Dialog/Notice/NavItem 五个组件的范围内，等它被收编时再接上 |

## 组件层引入、tokens.json 没有对应条目的数值

这些是组件自己的结构/行为决定，不是"该收进 token 但漏了"：

- Button `variant=danger` 的具体 class 组合（`border-[1.5px] border-border-strong bg-paper`）——这是**语义到颜色的映射规则**，颜色本身来自 token（`border-act`/`bg-act-bg` 等），但"危险按钮长什么样"是组件的结构决定，不是数值
- Button `size=compact`（40px/14px）——显式文档化的例外，不是新默认值，见 `button.svelte` 注释
- Dialog 面板宽度 `420px`/`max-w-[92vw]`——来自现有弹窗实测尺寸，非 v3 设计稿里的通用值

## 仍未做（如实记录，不冒领）

- 组件内的字面量（`h-11`/`text-[16px]` 等）跟 `tokens.css` 对应变量的一致性，目前没有自动检查——`check-token-drift.py` 只查 `tokens.css` vs `tokens.json`，不查 `.svelte` 组件文件里的字面量。如果以后 `tap-min`/`body-min` 改了数值，组件不会自动跟着变，也不会有检查报错。这是一个已知、可接受的剩余缺口，不是本轮遗漏。
