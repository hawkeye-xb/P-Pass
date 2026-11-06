# CI lane 与必需检查（改 workflow 前必读）

[`AGENTS.md`](../../AGENTS.md) 只留一句红线：**job 的 `name:` 不许随手改，必需检查的
job 名必须写死**。理由和细节在这里。

## 什么时候跑什么

- **三层（#1468，产品负责人 2026-11-06 定）**：
  1. **PR 上快检**：只跑与改动相关的 job，是合入门禁。`test (windows)`、`clippy (windows)`、
     `desktop (windows-latest)` 在 `pull_request` 事件下被 job 层 `if:` 跳过（汇报 `skipped`，
     对必需检查算通过，名字不变）。
  2. **合入 main 后全量**：五条 lane（rust / desktop / android / ios / docs）都有 `push: branches: [main]`，
     push 事件下 `changes` 一律判全跑（含 Windows；android / ios / docs 也不按单次 push 的 diff 判，
     因为排队会替掉中间的 push）。`concurrency` 的 group 带事件名，`cancel-in-progress` 只对 push 为 false：
     同一时间只跑一次、正在跑的不取消、排队只留最新（GitHub concurrency 原生行为）。
     main 红了不冻结、不挡其他合入，只修或回滚元凶 PR。
  3. **发版前全量验证**：Release 用 `workflow_call` 调这五条 lane（事件是 `workflow_dispatch`），
     全跑，行为不变；只从全绿提交切 tag。
- **推分支不触发 CI**：`push` 限定 `branches: [main]`，只有合入才算。本地快验：
  纯文档 `just ci-docs`，动了代码 `just ci`。
- **开 PR 才跑 lane**，分两档：
  - `ci-rust` / `ci-desktop`：workflow 层**不设** `pull_request.paths`（CI-07 #189）。
    它们的检查在 `main` 的必需列表里，而被 paths 跳过的 workflow **根本不汇报状态**，
    必需检查会永久停在 Pending 并挡住合并——带 paths + 设必需 = 自锁。
  - 跳过被下放到 job 层（CI-11 #255）：`changes` job 用 `tools/ci-needs-full-lane.sh`
    判断，改动不落在依赖面上（文档、流程脚本、更新说明等）时下游 job 被 `if:` 跳过。被 `if:` 跳过的 job 汇报 `skipped`，
    `skipped` 对必需检查算通过（PR #260 实测）。
  - `ci-android` / `site` / `ci-docs` 仍按 paths 只在改到自己域时跑，不进必需列表，
    被跳过无害。

## 停用门禁 / 撤必需检查

停 workflow、改 branch protection 都是仓库设置动作：**不进 git、不产生提交、不走 PR**，
所以没有任何东西会提醒「这扇门关了」。2026-11-05 `CI Review` 被手动停了六小时，
第二天 AGENTS.md 还写着它是必需检查——这就是没有账的样子。

规矩见 AGENTS.md「工程纪律」：同一次操作里开一张卡，**标题里写出 workflow 的 `name:`**，
写明恢复条件与到期日；然后跑一次 `just gate-status` 确认它认得到这张卡。

`just gate-status` 报两块：停用中的 workflow 及各自的关联卡、main 的必需检查清单；
读不出来时一律 fail-closed（不当作「没有停用项」）。关联卡**只认标题**——
正文里顺口提到 `CI Review` 的卡不算这扇门的账。

## `tools/ci-needs-full-lane.sh` 的判据

- 判据是 **allowlist**：改动**全部**落在无害清单里才跳过，其余一律跑。往清单里加
  东西前先确认没有测试或构建脚本读它（`assets/i18n/**` 被 diag 测试消费，**不许加**）。
- 两个 lane（CI-17 #373），因为 6 个 job 的依赖面不同：
  - **默认** lane（无害 = `docs/`、`.claude/`、`*.md`，以及 #1467 按依赖面补进的
    `tools/flow/`、`tools/e3/`、`tools/hooks/`、它们的自测、`tools/ci-paths.sh`、
    `release/notes/`、`.github/ISSUE_TEMPLATE/`；完整清单与核实依据见脚本 `is_inert`）：给 `architecture enforcement`
    与 `ci-desktop` 用（`arch-check.sh` 扫 `apps/**`，桌面壳门禁编的就是 `apps/desktop`）。
  - **`rust-workspace`** lane 把 `apps/**` 也算惰性：给 `clippy` / `test` /
    `test (windows)` / `license+deny` / `fmt` 用（`src-tauri` 是独立 workspace，
    主 workspace 编不到它；`apps/` 的 Rust 由 `ci-desktop` 自己检查）。例外：主 workspace
    读到的 `apps/` 文件（桌面 i18n 字典、两个手机端低空间常量文件）单独登记成要跑。
- 不带 lane 参数 = 默认 lane，这是向后兼容契约；未知 lane 一律判要跑。
- 自测：`tools/test-ci-needs-full-lane.sh`（两个 lane 都做变异反证）。它从源码派生反向用例：
  `crates/` 里 `include_str!` / `include_bytes!` 指向 `crates/` 之外的文件，以及
  `ci-rust.yml`、`ci-desktop.yml` 与其 composite action 引用的 `tools/` 文件，两个 lane 都必须判要跑；
  新增这类读取不用手工登记也会被自测抓到。
- `ci-android` / `ci-ios` / `ci-docs` 是按正向路径触发的，#1467 已核对，没有收紧。

## job 名

- **任何 job 的 `name:` 都不许随手改**：`main` 的必需检查列表绑在名字上，改名 = 全部
  PR 永久 Pending。改名和改分支保护必须在同一次操作里成对完成。
- **进必需列表的 job，名字必须是写死的常量，不许用 `matrix` 现算。** 「job 被 `if:`
  跳过」与「`name: xxx (${{ matrix.os }})`」凑在一起时，GitHub 不展开 matrix，只汇报
  一条名叫模板原文的检查，分支保护要的名字一条都不来 ⇒ 永久 Pending（#240 + #261，
  探针 PR #271 撞出）。要跑多平台就拆成多个 job、`name:` 各写死，步骤抽进
  `.github/actions/<x>/action.yml` 共享（`ci-desktop` 的 `desktop-linux` /
  `desktop-windows` 就是这么做的）。
- composite action 里每个 `run` 步骤**必须**显式写 `shell:`；actionlint 默认不扫那个
  文件，语法错误要到 CI 真跑才暴露。

## acceptance gate（#1422）

`ci-docs.yml` 里名字写死的 job `acceptance gate`：PR 碰界面文案路径（`owner-triage.sh` 的 `UI_GLOBS`）、核心路径，或 `apps/**` 下的非测试文件（测试位置见 `acceptance-gate.sh` 的 `TEST_RE`）时，
按级别判（#1471 按版本验收）：用户看得到的改动（含只改更新说明）合入不要验收行，直接绿，发版前由 `just release-scope` 的台账兜住；
碰核心的要正文引用 origin/main 上已采纳的方案，看不见的核心（如发布链脚本）还要改动带测试，否则红；只改版本号行的核心文件不算核心
（`ci-paths.sh core --diff`）；自动级直接绿。改正文补方案引用后 `edited` 事件会重跑它。
它先只是一个检查，设为必需检查是 owner 在仓库设置里做的，和 job 名成对。判定见 `tools/flow/acceptance-gate.sh`，自测 `tools/test-acceptance-gate.sh`；同一个 job 还跑按版本验收的 `tools/test-release-scope.sh`、`tools/test-release-acceptance.sh`。

## 流程自测 flow-tests（#1493）

流程门禁脚本（`tools/flow/`、本地提交拦截、重编译锁、main 红了开卡等）的自测，清单只有一份：justfile 的 `flow-tests` recipe。
本地 `just ci` / `just ci-docs` 依赖它，CI 上 `ci-docs.yml` 里名字写死的 job `flow-tests` 在 ubuntu 上装 just 跑 `just flow-tests`，
在 `CI Docs gate` 的 needs 里；PR 上按自己的路径判（`tools/**`、`justfile`、`.github/**`、`AGENTS.md`），push 到 main 与发版调用时全跑。
已在别的 job 里跑的（md-check、token-check、shell-vars-check、identity-check、supply-chain-check）不进这份清单，免得重复。

新加 `*-test` recipe 时：能在 ubuntu 上跑的进 `flow-tests`；只能在别的 lane 跑的（要 Android SDK、Xcode 模拟器等），
登记进 `tools/test-flow-tests-wired.sh` 头部的例外表，写明 workflow 文件、该 workflow 里必须出现的字符串和原因。
元测试 `just flow-tests-wired-test` 核对每个 `*-test` 都接上了、例外登记的字符串真在那个 workflow 里、
gate 的 needs 里有 `flow-tests`，并带变异反证；它本身也在 `flow-tests` 里。

## 核心路径

`.github/core-paths.txt` 圈住的文件（门禁本身、配对 / 身份 / 加密 / 协议、存储与迁移、
更新链、依赖锁）改到了，就是 AGENTS.md 里的人控级任务，没有单独的审批 job。三道关把关：
开工前方案按红线 6 定案（卡上引用已采纳方案）；PR 正文有产品负责人真机验收行（`acceptance gate` 检查）；
独立评审通过（CI 评审 job 的 `review/agent`）。判定逻辑与语法见 `tools/ci-paths.sh` 头注释，
自测 `tools/test-ci-paths.sh`。

## 独立评审 `review/agent`

`ci-review.yml` 把评审结论写成**提交状态** `review/agent`（不是 job 名），进 main 必需检查时按状态名登记，
来源锁 GitHub Actions（`app_id` 15368），本机 gh 写的同名状态不算。job 名 `review (独立评审)` 不进必需列表，
job 永远成功，结论只看状态。它用 `pull_request_target`：评审工具取 main 上的版本，PR 头提交只当数据读，
别往里加执行 PR 代码的步骤（理由见该 workflow 头注释）。fork 的 PR 不跑、不出状态，合不进。
只评正式 PR（#1470）：草稿不评，`ready_for_review` 转正式时评，与 CI 并行；job 第一步（检出之前）就把头提交的 `review/agent` 写成 pending，
改正文（如删掉方案引用）后、新结论出来前不会挂着旧的 success。`review.sh` 写成状态后才打 `REVIEW_STATUS_WRITTEN=` 标记，
`ci-review.sh publish` 没看到标记就兜底写 error。
每次评审在评论末尾留隐藏标记（头提交、PR 整体 diff 的指纹、agent 结论），只认 `github-actions[bot]` 写的：头提交评过、或 PR 整体 diff
没变（只合进了 main）就复用结论、不调模型，用当前正文重判方案引用（acceptance gate）；上次评到的提交是头提交的祖先就只评增量（只看 PR 上次与现在改动的文件），
附上次的评审意见与已关闭线程的裁决；不是祖先或判不了就全量。意见分「阻断 / 建议 / 风格」，只看阻断行：有阻断行写 failure（模型写 PASS 也算），只有建议、风格写 success（模型写 FAIL 也算）。
owner 复核放行：PR 上评论 `/review-override <理由>` 触发 `issue_comment` 的 `review override (owner 复核放行)` job，
用 gh api 现查作者对本仓的权限（admin 才认，`author_association` 在组织仓库是 MEMBER，不作依据），通过后留 `agent=OVERRIDE` 标记，
只对当时的头提交有效。判据测试：`tools/test-ci-review.sh`、`tools/test-flow-review.sh`。

## main 红了自动开卡（#1469）

`main-red.yml`（`on: workflow_run`，监听 CI Rust / Desktop / Android / iOS / Docs）在 **main 上 push 触发**的 run 红了
（failure、timed_out）时，由 `tools/flow/main-red.sh` 开卡「[MAIN-RED] <workflow 名>」（打 `P0`），正文列出该 workflow
上次在 main 全绿的提交到本次红的提交之间的 PR（从 squash 标题末尾的 `(#N)` 取）与失败 job 链接；同名卡已开就追加评论，不重复开；
同一 workflow 之后在 main 转绿就评论并关卡。读不到上次全绿时改列最近 20 个提交并写明「无法确定区间」。
口径：main 不冻结、不挡其他合入；owner 二分找元凶，修起来简单就往前修，拿不准就回滚元凶 PR。
权限只有 `issues: write`、`actions: read`、`contents: read`，只检出 main。main 上的 push 触发由 #1468 加，在那之前这个 workflow 不会被触发。
判据测试 `just main-red-test`（假 gh，每条带反证）。

## 删接口 / 升依赖时的全 lane 核对

必需检查只是全部 lane 的子集。iOS FFI、Windows test、E2E 这些非必需 lane 专门覆盖
跨端、真进程路径，正是删协议最容易炸的地方。

- 删方法 / 协议：`git grep` 覆盖全仓所有语言（`*.swift` `*.kt` `*.sh` `*.py`、
  `tools/`、`apps/*/Tests`），本地验证按 `.github/workflows/` 的每条 lane 对一遍。
- 改 trait / 门禁清单：除了 `just ci`，再跑 `for t in tools/test-*.sh; do bash "$t"; done`。
- 升依赖：先 `git ls-files '*Cargo.lock'`，每一份锁（主 workspace + `src-tauri`）都要改到；
  本地 `cargo deny fetch` 拉最新公告库再验。
- 批 PR 合并前等**全部** lane 结束，不只看必需检查。
