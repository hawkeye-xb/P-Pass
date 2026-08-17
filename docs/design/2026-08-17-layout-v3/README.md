# 2026-08-17 布局与交互 v3（离线归档，源自 claude.ai/design 项目）

> 本目录是设计稿的**离线副本**，通过官方 `claude_design` MCP（`https://api.anthropic.com/v1/design/mcp`）
> 从 claude.ai/design 的可编辑项目直接读取原始文本源码存档，不是像
> `2026-08-05-layout-v1`/`2026-08-14-layout-v2` 那样的 8MB 自包含离线导出——
> 这份是**纯文本、可读、可 diff** 的项目源文件本身，配合 `support.js`
> （dc-runtime）和 `android-frame.jsx`（Android 设备边框组件）即可在浏览器
> 里离线渲染。

## 来源

- 项目：claude.ai/design 项目 `P-Pass 设计稿交付`
  （projectId `dcc1862c-337d-4590-8fc4-4c8381027a76`）
- 文件：`P-Pass 布局与交互.dc.html`（项目内主文档，依赖同目录的
  `support.js`/`android-frame.jsx`）
- 归档方式：`claude_design` MCP 的 `get_file` 方法直接读取纯文本内容落盘，
  未经渲染/截图，是项目当时的确切源码状态。
- 归档时间：2026-08-17（当天设计稿本身也在随对话迭代更新，本次落库前已
  核对内容是当时最新版本）。

## 跟 v1/v2 的关系

v1（`2026-08-05-layout-v1`）已过期；v2（`2026-08-14-layout-v2`）是
Discord 附件提供的 8MB 自包含导出（同一份内容的另一种打包形式，JS
atomics 编码不便于 grep/diff）。本目录 v3 是同一个设计工作的延续，
内容上比 v2 更新（v2 归档后设计稿仍在改：Android onboarding 从"三步"
收缩到"一步到位"、断开连接交互从设想中的滑动确认改成了点按钮展开
确认卡、tab 文案改回"设置"等），且格式对 agent 更友好（纯文本 diff
即可看出改动，不需要起浏览器渲染）。**后续 UI 卡验收改以本目录为
准**，v1/v2 保留仅供历史追溯。

## 内容覆盖

跟 v2 README 记录的范围一致（桌面端四页+断点、Android 端欢迎/扫码/
时间线/设置+onboarding+大图页），细节改动见上一节。

## 更新规则

- 设计稿仍是活的 claude.ai/design 项目，会持续迭代；每次基于新一轮
  设计稿实施改动前，建议用 `claude_design` MCP（`get_file` 方法）重新
  拉一次最新内容核对，而不是假设本目录快照永远最新。
- 新一轮归档：新目录 `docs/design/YYYY-MM-DD-*/`，本 README 跟着指过去，
  旧目录标记过期，不覆盖旧快照（保留 diff 追溯能力）。
