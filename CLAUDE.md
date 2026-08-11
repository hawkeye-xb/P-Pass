# P-Pass 执行 agent 工作规范（仓库级）

> 读这个文件的你多半是执行 agent（Hermes/macOS 或云端）。先读
> `docs/AGENT_PROTOCOL.md`（架构铁律 + 任务卡协议），再读本文件（流程纪律）。

## 工作入口

- **任务队列**：`.claude/cards/*.md`，一卡一文件，做完移 `done/` 并附验收记录。
- **交接件**：`docs/NEXT.md`——每轮收口更新「当前状态/等用户」。
- 卡外的活不做；发现新问题写成卡（按 §C.2 模板）放进队列，不顺手修。

## 推送纪律（2026-08-10 用户特批：速度优先阶段）

允许直推 main / 自 merge，**不用等 review**。代价是三条底线，破一条视为事故：

1. **CI 绿不过夜**：push 后必须盯 main 的 PR Checks 到结论；红了立刻修或
   revert（8/7 的 fmt 红是反面教材——push 前本地过 `cargo fmt --check`）。
2. **每批交付必更文档**：PROGRESS.md 每卡一行 + NEXT.md 队列状态 +
   ROADMAP.md 状态行（ROADMAP 是用户看进度的唯一入口）。零记录 = 事故。
3. **验收人事后抽检有 revert 权**：内容被打回就返工，不争辩已合并事实。

速度优先阶段到有外部用户/第二个贡献者为止，届时恢复走 PR。

## 提交与构建纪律

- **纯文档/卡片提交（只动 docs/ 或 .claude/）commit message 末尾加
  `[skip ci]`**——GitHub 原生跳过 push 触发的 workflow，别为一张卡烧
  四个 job（CI-01 落地路径过滤后此规则自动失效，可删）。
- 小步提交本地攒，**一张卡一次 push**，别按保存键式碎推。

## tag 纪律

- 调发布管线用 **workflow_dispatch**（release.yml 已支持），不许拿正式
  tag 试错（8/9 一个周末烧了 test.3~test.10 八个 tag，是反面教材）。
- tag 只打给准备真发的版本；已打的 tag 绝不覆盖/挪动。

## 仓库卫生

- **绝不把构建产物 commit 进 main**。bin-* 孤儿分支是唯一例外通道
  （artifacts.yml 管理，带 paths 过滤）。
- 开发机排除产物分支：`git config --add remote.origin.fetch '^refs/heads/bin-*'`
  （2026-08-10 教训：不排除的话 .git 会膨胀到 GB 级）。

## 语言与文档

- 面向用户/贡献者的文档英文为主 + zh 姊妹篇（docs/ 既有惯例）。
- UI 文案进 assets/i18n 字典（en/zh 对称测试兜底），不写死在组件里。
- 设计基准：`docs/design/2026-08-05-layout-v1/` 是 UI 唯一基准；UI 卡
  验收必须含双端全页面走查（还原/走样/未实现三定性 + 截图）。
