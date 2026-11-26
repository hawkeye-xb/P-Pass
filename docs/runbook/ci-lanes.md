# CI lane 与必需检查（改 workflow 前必读）

[`AGENTS.md`](../../AGENTS.md) 只留一句红线：**job 的 `name:` 不许随手改，必需检查的
job 名必须写死**。理由和细节在这里。

## 什么时候跑什么

- **三层（#1468 / #2089，四端 PR 对称门禁）**：
  1. **PR 上快检**：五条 lane（rust / desktop / android / ios / docs）在 PR 上全部按影响图（`tools/ci/impact.py`）运行，四端（Linux / macOS / Windows / Android / iOS）对称拦截，`test (windows)`、`clippy (windows)`、`desktop (windows-latest)` 均在 PR 上直接运行，是合入门禁。`ci-ios.yml` 拆为 `ios-static`（ubuntu-latest）、`ios`（App XCTest，按 `--print-fingerprint` 缓存生成的 TransportFFI XCFramework）、`ios-packages`（SwiftPM）、`ios-ffi`（TransportFFI + daemon，PR 上按 `run_ffi` 判定）四路并行并汇入 `CI iOS gate`。
  2. **合入 main 后全量**：五条 lane 都有 `push: branches: [main]`，push 事件下 `changes` 一律判全跑（不按单次 push diff 判，因为排队会替掉中间的 push）。`concurrency` 的 group 带事件名，`cancel-in-progress` 只对 push 为 false：同一时间只跑一次、正在跑的不取消、排队只留最新。main 红了不冻结、不挡其他合入，只修或回滚元凶 PR。
  3. **发版前验证**：Release 用 `workflow_call` 调这五条 lane（调用方事件是 `workflow_dispatch`），五条都按全量跑，只从全绿提交切 tag。P-Pass 不发 Linux 安装包：#1555 起 Linux 桌面检查（`desktop-linux` / `desktop (ubuntu-latest)`）**永久移除**，桌面 lane 只剩 `desktop-windows`（检查名 `desktop (windows-latest)`）。
  - 第 1、2 层的不变量（三个 Windows job 在 PR 上不得跳过且保留 `!cancelled() &&`、五条 lane 有 `push: branches: [main]`、push 上 `cancel-in-progress` 为 false、`ci-docs` `AGENTS.md`/`CLAUDE.md` 与 `ci-ios` 并行门禁结构）由 `tools/test-ci-lane-invariants.sh`（`just ci-lane-invariants-test`，在 `flow-tests` 里）判红；
    #1555 的移除事实也由同一脚本判红，带「加回去必须变红」的反证。
- **推分支不触发 CI**：`push` 限定 `branches: [main]`，只有合入才算。本地快验（按改动路径精准挑选，清单在
  `tools/flow/flow.py` 的 `pick_gates`）：纯文档 `just md-check`，`AGENTS.md` 跑 `just ci-docs`，
  各端/crate 只跑对应单测与秒级 `arch-check` + `fitness-check`，绝不因未知配置文件罚跑全仓 `just ci`。
- **PR 上按路径判跑哪些 job**，分两档：
  - `ci-rust` / `ci-desktop`：workflow 层**不设** `pull_request.paths`（CI-07 #189）。
    它们的检查在 `main` 的必需列表里，而被 paths 跳过的 workflow **根本不汇报状态**，
    必需检查会永久停在 Pending 并挡住合并——带 paths + 设必需 = 自锁。
  - 跳过被下放到 job 层（CI-11 #255 / #2089）：`ci-rust` / `ci-desktop` 的 `changes` job 调 `tools/ci-needs-full-lane.sh`，`ci-android` / `ci-ios` / `ci-docs` 的 `changes` job 调 `.github/actions/changes`（`lane:`），全部统一委托 `tools/ci/impact.py`；仅 `site` 仍按 workflow 级 `paths` 触发。被 `if:` 跳过的 job 汇报 `skipped`，`skipped` 对必需检查算通过。

## Release 的 test-channel 收敛（#1546）

`release.yml` 里 `test-channel` 有两类动作，必须分开看：

- **写**：`upload-android`、`finalize-manifest`（macOS + 收口 Android）、`finalize-manifest-windows`、
  `finalize-ios` 并行调 `tools/release/point-test-channel.sh`，只上传自己那份安装包、写自己那份清单，
  **不删除任何东西**。任一步失败，那个 job 红，整轮 Release 红（fail-closed 不变）。
- **收敛**：唯一的 job `cleanup-test-channel`（`name: "收敛 test-channel（清理旧包与旧草稿）"`，写死）
  在四个 writer 之后跑一次 `tools/release/cleanup-test-channel.sh`，删没有清单指向的旧安装包与
  过期且无人引用的 test 草稿。`needs` 是上面四个 writer；`if:` 逐项要求它们不是 `failure`
  （被判 skip 的端是正常的），任一 writer 失败时本 job 跳过，失败不会被一次成功的清理盖住。
  `timeout-minutes: 10`；非 test tag 时脚本自己退出 0。

失败语义：收敛脚本失败，步骤打 `::warning::` 并退出 0；checkout / runner 这类基础设施失败由 job 级
`continue-on-error: true` 兜住。收敛失败只影响占盘——此时资产已上传、清单已指向，客户端能下载——
所以不判整轮红。上传 / 指向失败仍然红（writer job 不许加 `continue-on-error`）。

判据测试 `tools/test-release-channel.sh`（在 `ci-docs.yml` 的 `release-plan` job 里）：
stub `gh` 真跑两个脚本，再从 `release.yml` 抽收敛步骤的 run 块、用一定失败的假脚本执行。
三条反证：① 把收敛调用放回任一端 writer job ⇒ 红；② 收敛失败判红 ⇒ 红；③ 上传失败被吞 ⇒ 红。
设计见 [ADR](../decisions/2026-11-06-release-test-channel-single-writer.md)。

## 停用门禁 / 撤必需检查

停 workflow、改 branch protection 都是仓库设置动作：**不进 git、不产生提交、不走 PR**，
所以没有任何东西会提醒「这扇门关了」。2026-11-05 `CI Review` 被手动停了六小时，
第二天 AGENTS.md 还写着它是必需检查——这就是没有账的样子。

规矩见 AGENTS.md「工程纪律」：同一次操作里开一张卡，**标题里写出 workflow 的 `name:`**，
写明恢复条件与到期日；然后跑一次 `just gate-status` 确认它认得到这张卡。
让某个 job 在 `workflow_call`（发版调用）时被 `if:` 跳过，同样算停用一道发版门禁，也要卡
（#1535 的 `CI Desktop` 曾这样，已由 #1555 改为永久移除 Linux job，不再需要恢复条件）。

`just gate-status` 报三块：停用中的 workflow 及各自的关联卡、发版调用时被 job 级 `if:`
跳过的门禁及各自的关联卡、main 的必需检查清单；读不出来时一律 fail-closed（不当作「没有停用项」）。
关联卡**只认标题**——正文里顺口提到 `CI Review` 的卡不算这扇门的账。
发版跳过的检测认本仓约定的 `!inputs.release_call`，也认旧写法 `github.event_name != 'workflow_call'`
（它在可复用 workflow 里不成立，但同样表示想跳过发版）；只跑发版（`inputs.release_call` 不带 `!`、
`github.event_name == 'workflow_call'`）不算停用。测试用 `GATE_STATUS_WORKFLOW_DIR` 注入假 workflow 目录。

## 统一依赖图影响范围引擎（`tools/ci/impact.py`）与 `tools/ci-needs-full-lane.sh`

- **云端与本地同源（#2089）**：`.github/actions/changes/action.yml`（`android` / `ios` / `ios-ffi` / `docs` / `docs-flow`）、`tools/ci-needs-full-lane.sh`（`default` / `rust-workspace`，保留原 CLI 契约）、`tools/flow/flow.py` 的 `pick_gates`、`tools/e3/verify` 的 Android lane 判定统一委托 `tools/ci/impact.py`。
- **现场图推导**：直接解析 `Cargo.toml` / `apps/desktop/src-tauri/Cargo.toml` / `Cargo.lock`（含 `[patch.crates-io]` `third_party/noq-udp`）、跨目录 `include_str!` / `readFileSync` / `read_to_string` 契约消费者、`tools/build-ios-transport-xcframework.sh` 与 `apps/android/app/build.gradle.kts` `include(...)`、以及各 lane 活跃 workflow / action 的 `tools/` 引用闭包。
- **fail-closed 口径**：未知路径、空改动列表、未知 lane、git diff / git grep 异常、HEAD 不存在的 `tools/` 文件、workflow/action 里的动态 `tools/*$` 引用一律保守返回 `true`；不调用 `just` 的 CI lane 不会被 `justfile` 或 `tools/just/*.just` 误触。
- **两个 Rust/Desktop lane**：`default`（`arch-check.sh` 扫 `apps/**` 与 `ci-desktop`）与 `rust-workspace`（主 workspace 专属，把未消费的 `apps/**` 算惰性），包含关系 `run_heavy=true ⇒ run_arch=true` 由 `tools/test-ci-needs-full-lane.sh` 与 `tools/test-ci-impact.py` 双方检验。
- **justfile 拆分**：根 `justfile` 按领域拆至 `tools/just/` 并通过 `import` 引入；本地与 `ci-docs` 共用同一份 `flow-tests` 清单（在 `tools/just/checks.just`）。

## job 名

- **任何 job 的 `name:` 都不许随手改**：`main` 的必需检查列表绑在名字上，改名 = 全部
  PR 永久 Pending。改名和改分支保护必须在同一次操作里成对完成。
- **进必需列表的 job，名字必须是写死的常量，不许用 `matrix` 现算。** 「job 被 `if:`
  跳过」与「`name: xxx (${{ matrix.os }})`」凑在一起时，GitHub 不展开 matrix，只汇报
  一条名叫模板原文的检查，分支保护要的名字一条都不来 ⇒ 永久 Pending（#240 + #261，
  探针 PR #271 撞出）。要跑多平台就拆成多个 job、`name:` 各写死，步骤抽进
  `.github/actions/<x>/action.yml` 共享（`ci-desktop` 的 `desktop-windows` 就是这么做的；
  #1555 之前还有 `desktop-linux`）。
- composite action 里每个 `run` 步骤**必须**显式写 `shell:`；actionlint 默认不扫那个
  文件，语法错误要到 CI 真跑才暴露。

## acceptance gate（#1422）

`ci-docs.yml` 里名字写死的 job `acceptance gate`：PR 碰界面文案路径（`acceptance-gate.sh` 的 `UI_GLOBS`）、核心路径，或 `apps/**` 下的非测试文件（测试位置见 `acceptance-gate.sh` 的 `TEST_RE`）时，
按级别判（#1471 按版本验收）：用户看得到的改动（含只改更新说明）合入不要验收行，直接绿，发版前由 `just release-scope` 的台账兜住；
碰核心的要正文引用 origin/main 上已采纳的方案，看不见的核心（如发布链脚本）还要改动带测试，否则红；只改版本号行的核心文件不算核心
（`ci-paths.sh core --diff`）；自动级直接绿。改正文补方案引用后 `edited` 事件会重跑它。
它先只是一个检查，设为必需检查是 owner 在仓库设置里做的，和 job 名成对。判定见 `tools/flow/acceptance-gate.sh`，自测 `tools/test-acceptance-gate.sh`；同一个 job 还跑按版本验收的 `tools/test-release-scope.sh`、`tools/test-release-acceptance.sh`。

## 流程自测 flow-tests（#1493）

流程门禁脚本（`tools/flow/`、本地提交拦截、重编译锁、main 红了开卡等）的自测，清单只有一份：`tools/just/checks.just` 的 `flow-tests` recipe。
本地 `just ci` / `just ci-docs` 依赖它，CI 上 `ci-docs.yml` 里名字写死的 job `flow-tests` 在 ubuntu 上装 just 跑 `just flow-tests`，
在 `CI Docs gate` 的 needs 里；PR 上按影响图 `docs-flow` 判定（`tools/**`、`justfile`、`tools/just/*.just`、`.github/**`、`AGENTS.md` 等），push 到 main 与发版调用时全跑。
已在别的 job 里跑的（md-check、token-check、shell-vars-check、identity-check、supply-chain-check）不进这份清单，免得重复。

新加流程/门禁测试时：能在 ubuntu 上跑的进 `flow-tests`（核心流程引擎自测统一在 `tools/test-flow.py`）；在 ubuntu 上会 SKIP 的（如 `heavy-lock-test` 依赖 macOS 的 `lockf`）留在 `ci-docs` 的直接依赖里。

## 核心路径

`.github/core-paths.txt` 圈住的文件（门禁本身、配对 / 身份 / 加密 / 协议、存储与迁移、
更新链、依赖锁）改到了，就是 AGENTS.md 里的人控级任务，没有单独的审批 job。三道关把关：
开工前方案按红线 6 定案（卡上引用已采纳方案）；PR 正文引用已采纳方案（`acceptance gate` 检查）；
独立评审通过（CI 评审 job 的 `review/agent`）。判定逻辑与语法见 `tools/ci-paths.sh` 头注释，
自测 `tools/test-ci-paths.sh`。

## 独立评审 `review/agent`

`ci-review.yml` 把评审结论写成**提交状态** `review/agent`（不是 job 名），进 main 必需检查时按状态名登记，
来源锁 GitHub Actions（`app_id` 15368），本机 gh 写的同名状态不算。job 名 `review (独立评审)` 不进必需列表，
job 永远成功，结论只看状态。它用 `pull_request_target`：评审工具取 main 上的版本，PR 头提交只当数据读，
别往里加执行 PR 代码的步骤（理由见该 workflow 头注释）。fork 的 PR 不跑、不出状态，合不进。
只评正式 PR（#1470）：草稿不评，`ready_for_review` 转正式时评，与 CI 并行；job 第一步（检出之前）就把头提交的 `review/agent` 写成 pending，
改正文（如删掉方案引用）后、新结论出来前不会挂着旧的 success。`flow.py review` 写成状态后才打 `REVIEW_STATUS_WRITTEN=` 标记，
`ci-review.sh publish` 没看到标记就兜底写 error。
每次评审在评论末尾留隐藏标记（头提交、PR 整体 diff 的指纹、agent 结论），只认 `github-actions[bot]` 写的：头提交评过、或 PR 整体 diff
没变（只合进了 main）就复用结论、不调模型，用当前正文重判方案引用（acceptance gate）；只要 PR 整体 diff 变化一律全量审阅 `origin/main...HEAD` 完整 diff（废除增量盲区）。意见分「阻断 / 建议 / 风格」，阻断行写 failure。
owner 复核放行：PR 上评论 `/review-override <理由>` 触发 `issue_comment` 的 `review override (owner 复核放行)` job，
用 gh api 现查作者对本仓的权限（admin 才认，`author_association` 在组织仓库是 MEMBER，不作依据），通过后留 `agent=OVERRIDE` 标记，
只对当时的头提交有效。判据测试：`tools/test-ci-review.sh`。

## main 红了自动开卡（#1469）

`main-red.yml`（`on: workflow_run`，监听 CI Rust / Desktop / Android / iOS / Docs）在 **main 上 push 触发**的 run 红了
（failure、timed_out）时，由 `tools/flow/main-red.sh` 先检查是否为首次云端 runner 排队掉线（`run_attempt == 1` 且所有非通过的上游业务 job 未执行任何步骤）：若是则自动执行 `gh run rerun <RUN_ID> --failed` 重跑一次，暂不开卡；若 `run_attempt >= 2` 仍红或存在真实步骤失败，才开卡「[MAIN-RED] <workflow 名>」（打 `P0`），正文列出该 workflow
上次在 main 全绿的提交到本次红的提交之间的 PR（从 squash 标题末尾的 `(#N)` 取）与失败 job 链接；同名卡已开就追加评论，不重复开；
同一 workflow 之后在 main 转绿就评论并关卡。读不到上次全绿时改列最近 20 个提交并写明「无法确定区间」。
口径：main 不冻结、不挡其他合入；owner 二分找元凶，修起来简单就往前修，拿不准就回滚元凶 PR。
权限只有 `issues: write`、`actions: write`、`contents: read`，只检出 main。main 上的 push 触发由 #1468 加，在那之前这个 workflow 不会被触发。
判据测试 `just main-red-test`（假 gh，每条带反证）。

## 删接口 / 升依赖时的全 lane 核对

必需检查只是全部 lane 的子集（如 iOS / Android 等各自对应不同端），PR 上四端对称快检均按影响图触发。iOS FFI、Windows、E2E 这些 lane 专门覆盖跨端、真进程路径，正是删协议最容易炸的地方。

- 删方法 / 协议：`git grep` 覆盖全仓所有语言（`*.swift` `*.kt` `*.sh` `*.py`、
  `tools/`、`apps/*/Tests`），本地验证按 `.github/workflows/` 的每条 lane 对一遍。
- 改 trait / 门禁清单：除了 `just ci`，再跑 `for t in tools/test-*.sh; do bash "$t"; done`。
- 升依赖：先 `git ls-files '*Cargo.lock'`，每一份锁（主 workspace + `src-tauri`）都要改到；
  本地 `cargo deny fetch` 拉最新公告库再验。
- 批 PR 合并前等 PR 上**全部** lane 结束，不只看必需检查。Windows 三个 job 在 PR 上不跑，合入后看 main 上 push 全量的结果，
  红了按上面「main 红了自动开卡」处理。
