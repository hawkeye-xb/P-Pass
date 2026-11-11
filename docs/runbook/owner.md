# owner 命令：分拣、出 test 包、记想法、停下

这些命令由 agent 在需要时跑（分拣新诉求、出 test 包、记想法、停下交人）。命令自带判定：红了或判定不了，就写 issue（`status:blocked`）
或评论到对应的卡、PR，然后非 0 退出。不补做、不绕过、不改判定，接着做别的。
脚本在 `tools/flow/owner-*.sh`，测试是 `tools/test-flow-owner.sh`（`just ci` 与 `just ci-docs` 都会跑）。

owner 只统筹，不当传声筒：这些命令是 owner 的工具，不是合入的必经之路。合入由 CI 与独立评审把关、自动完成
（角色分工见 [AGENTS.md](../../AGENTS.md)「角色」「通知」「机器与模型」）。

## 开工自检（doctor）

每条 owner 命令开头都会先跑 `just doctor`（`tools/flow/doctor.sh`）。它在你自己的外壳里检查：
当前目录是主副本或它的 worktree、bash 能否真执行（Windows 上必须是 Git Bash，不能是 WSL 桩）、
本地提交拦截已装、gh 能读本仓库 issue、提交身份在 `.github/allowed-identities.txt` 里、磁盘 ≥ 15G。
私仓模式与在线设备只报不判。任一必需项不满足就非 0 退出并打印怎么修，修好再重跑。

- 私仓：主副本旁边有 `../private` 就是**完整模式**；没有就是**协作者模式**——不写不公开内容，
  遇到要写私仓的活，`just stuck <号> "需要写私仓，本机是协作者模式"` 停下。
- `just owner-stuck` 是停下的出口，doctor 不过时也能用。
- 根目录放了 `.ppass-verify-clone` 标记的克隆是 Windows 回归专用克隆，doctor 看到就拒绝在里面开工。

## 命令

| 步骤 | 命令 | 通过时最后一行 |
|---|---|---|
| 记想法（任何会话） | `just idea "<原话>" [--discuss] [--from <来源>]` | `IDEA DISCUSSION #N` 或 `IDEA ISSUE #N status:inbox Feature` |
| 分拣新诉求 | `just triage <号> <方案文件>` | `TRIAGE <号> ready \| needs:product \| blocked`，下一行 `PRIORITY <号> P0–P3` |
| 出 test 包 | `just release-test <端...>` | `RELEASE-TEST OK v<X.Y.Z>-test.N <端...>` |
| 数自上个 test 包以来的用户可见 PR（每日同步报给产品负责人） | `just release-scope --since <上个 test 包 tag>` | `验收范围 …：N 个 PR 里 M 个用户看得见` |
| 出 test 包后更新验收台账 | `just release-scope --ledger <台账号> --pkg <test 包 tag>` | `台账 #N（…）：新增 a，待重验 b，仍待验 c，沿用 d` |
| 正式发版前查台账清零 | `just release-acceptance <台账号> [<候选 ref>]` | `✓ 发版前验收通过（…）`（退出码 1：待验 / 待重验逐项列出） |
| 合入前独立评审（兜底，平时由 CI 评审 job 做） | `just review <PR号> [--model <模型>]` | `✅ #N 独立评审通过，review/agent=success` |
| 查 PR 为什么合不进去（任何会话） | `just pr-status <PR号>` | `✅ 全清：…`（退出码 1 有卡点、3 还在等结果） |
| 回复并关闭评审线程（任何会话） | `just pr-thread <线程ID> "<理由>"` | `已关闭线程 PRRT_…` |
| 停下 | `just owner-stuck "<原因>" [--issue N \| --pr N] [--product "<一>" "<二>"] [--log 文件]` | `ok: ...` |

### 合入前独立评审（`just review`）

平时不用跑：CI 评审 job（`.github/workflows/ci-review.yml` → `tools/flow/ci-review.sh`）就是独立评审，每个头提交自动跑，
结论写成必需检查 `review/agent`（只认 GitHub Actions 写的状态）。`error` 是评审没跑成，在 Actions 里重跑那次评审即可。
本命令只在评审 job 不可用或产品负责人点名时由 owner 派新会话跑；它写的状态不顶替必需检查。

起一个没参与写这个 PR 的只读 agent（`claude -p`，只给 Read / Grep / Glob，不能改文件、不能跑命令），
对照 PR 正文 `closes #N` 的卡的「范围」「验收场景」查正确性问题，不评风格。结果写成 PR 评论
（「通过」或「未通过 + 问题清单」），并在 PR 头提交上写提交状态 `review/agent`（success / failure）。

- 判定看 agent 输出最后一行：`VERDICT: PASS` 才通过（success）；`VERDICT: FAIL`、评审期间改了检出是未通过（failure）；
  agent 崩了、没给 VERDICT 是「评审没跑成」（error），不算通过，也不当作代码有问题，重跑即可。
- 结论只对评审时的头提交有效，之后推了新提交要重跑。
- 换模型：`--model <名>`，或 `PPASS_REVIEW_MODEL`；换成别家的命令用 `PPASS_REVIEW_AGENT`
  （要接受同样的 `-p`、`--model`、`--allowedTools` 参数，提示词走 stdin）。
- 本机跑时，评审通过后对 PR 执行 `gh pr merge --auto --squash`（CI 上不开，自动合入由 `just done` 开 PR 时开）。碰核心路径的 PR
  多一个条件：与 CI 的 acceptance gate 同一判定（正文引用已采纳方案，看不见的核心还要带测试，见 `acceptance-gate.sh` 头注释），不满足就判未通过、不开自动合入，
  评论里写明缺什么。用户看得到的改动（`UI_GLOBS`、`apps/**` 下的非测试文件）合入不要验收行，随版本验收（AGENTS.md「按版本验收」）。
  级别判定与 `just done`、`just release-scope`、CI 的 acceptance gate 共用 `acceptance-gate.sh classify`；界面路径清单与 `owner-triage.sh` 的 `UI_GLOBS` 共用，核心路径规则取 `origin/main` 上的 `.github/core-paths.txt`。
- `review/agent` 进 main 的必需检查由产品负责人在仓库设置里做（命令见 #1435 的 PR 正文），脚本不改仓库设置。
  没进之前它只是评论与提交状态，不拦合入，`just done` 也不会开自动合入。

退出码：0 通过；1 停下了（已写 issue 或评论）；2 拒绝（用法错，或前置条件没满足，提示里给了下一条命令）。
看到 1 就不要重试同一条命令，先处理 issue。

## 每一步判什么

**idea**：默认建 Discussions 的 Ideas 帖，正文是原话（一字不改）加来源和日期，不进看板。`--discuss` 建
`status:inbox` 的 issue，类型设成 Feature。同标题已有打开的帖子或 issue 时，追加评论，不重复建。

**triage**：方案由模型写进一个 markdown 文件，去向由脚本判。方案必须有这些字段：`**做法**`、`**涉及端**`、
`**数据**`、`**用户可见行为**`、`**隐私**`、`**风险**`、`**影响**`、`**时间性**`、`**范围**`（后面跟 ``` 代码块）、`**验收场景**`、
`**复现路径**`（Bug 卡必填：100% 复现的步骤/命令，复现不了写「无」并转 blocked 找人对齐；Feature/Task 写「无」）；
可选字段 `**产品定案**`、`**owner 定案**`、`**标准依据**`，没有的写「无」。缺必填字段就拒绝。分流规则：

1. 范围命中核心：方案要有 `**ADR**：docs/decisions/<文件>.md`，而且在 `origin/main` 上是「已采纳」，
   否则打 `status:blocked`，写明先定 ADR。有就打 `core` 标签，接着往下判。
   `**产品定案**` 的评论链接不能替代 ADR；核心卡仍要引用已采纳方案。
2. 用户可见行为、隐私、数据任一项不是「无」，或者范围碰到界面与文案路径（i18n、设计 token、
   Android `res/` 与 `ui/`、桌面前端、iOS 界面、站点、更新说明），即使方案写了「无」，也打 `needs:product`。
   这时方案必须有 `**选项一**` 和 `**选项二**`，各写做法与影响，否则拒绝。
   例外（产品取向已经定过）：
   - `**产品定案**` 可以写两种依据，任一成立即可：
     - `docs/decisions/<文件>.md，产品负责人 <日期> 已确认`：引用的方案必须全部在 `origin/main` 上是「已采纳」，
       字段里必须写明产品负责人确认；
     - 本仓 issue/PR 评论链接 `https://github.com/<repo>/issues/<号>#issuecomment-<id>`（`pull` 同理）：
       `gh api` 核对评论存在，链接里的 issue/PR 号必须与评论实际所属一致；作者必须是产品负责人
       （对本仓有 admin 权限的 User）。字段里出现外仓评论链接就拒绝，不静默忽略。评论链接本身就是
       拍板依据，不要求另写「已确认」。
     两种依据同时出现时，所有方案引用都要已采纳、所有评论链接都要属于本仓且作者是产品负责人、编号一致；
     任一不满足就拒绝。满足就不打 `needs:product`、不要选项，按第 4 条走。写「无」等于没写。
     非核心卡的产品定案可以用评论链接，不要求另开一份方案文档；核心卡仍按第 1 条引用已采纳 ADR。
   - `**owner 定案**：AGENTS.md「<逐字原文>」` 和/或仓库 owner 账号的评论链接。原文必须在 `origin/main` 的
     AGENTS.md 里逐字出现（至少 8 个字）；评论用 `gh api` 核对存在、作者是仓库 owner。任一依据不成立就拒绝。
   - `**标准依据**`：写明 WAI-ARIA/WCAG/ARIA APG、Android 权限规范、NN/g、Google 或 Microsoft 写作指南、
     Apple HIG、Material Design 等业界标准。链接只认完整主机和适用路径：w3.org 的 `/WAI/` 或 `/TR/`、
     nngroup.com、developer.android.com、developers.google.com/style、learn.microsoft.com/…style、
     developer.apple.com/design、m3.material.io；其他主机或路径直接拒绝。没有链接时按标准名校验，
     写不认识的出处也拒绝，不静默放行。
   owner 定案或标准依据合格，且隐私、数据都是「无」、卡类型不是 Feature：不打 `needs:product`、不要选项，
   打 `decided:owner`，依据写进「实施方案」。隐私或数据不是「无」、或 Feature 卡，owner 定案 / 标准依据都不顶用，
   照常 `needs:product`。
   不带这些字段，行为与之前一样。
3. Bug 卡缺「复现路径」（写「无」或空）→ 打 `status:blocked`，写明先补复现，或转 `needs:product` 找人对齐。
4. 其余打 `status:ready`。

**优先级**（P0–P3，口径见 `AGENTS.md`「优先级口径」）也由脚本按 `**影响**`（不可挽回 / 面广 / 局部）×
`**时间性**`（停线 / 截止日 / 线性 / 无）算，三种去向都打：

| 影响＼时间性 | 停线 | 截止日 | 线性 | 无 |
|---|---|---|---|---|
| 不可挽回 | P0 | P1 | P1 | P1 |
| 面广 | P0 | P1 | P2 | P3 |
| 局部 | P0 | P2 | P3 | P3 |

- 打新标签时去掉这张卡上旧的 P0–P3，不叠加；产品负责人可直接改标签覆盖。重跑 triage（需先改回 `status:inbox`）即重算。
- 自动定级：标题以 `[MAIN-RED]` 开头 → P0；卡挂了带截止日的 milestone 且到期不足 3 天（含已过期）→ 在上表结果上升一级。
- 写错或缺 `**影响**` / `**时间性**` 就拒绝，不写 issue。
- **P3 复看**：owner 每次发版规划时列出 30 天未动的 P3，逐张决定升级或关闭；关闭写明「不做」与理由。
- **先核实实现状态**：triage 与复看时，先用 `git log`、`git grep` 查这张卡要做的事是不是已经做完，做完的直接关掉，不按标题判。

范围、验收场景、是否核心写进任务卡的对应字段（本地 hook 和 `just verify` 读这几处），其余内容写进正文末尾的
「实施方案」段。写回之后，脚本用 hook 的同一套解析再读一遍范围，读不出来就不写。

**release-test** 的判定：

- 版本号取远端最新 `v<X.Y.Z>-test.N` 的 N+1。X.Y.Z 必须高于 `release/versions.json` 里每一端的正式版本号，
  否则 test 设备收不到。不带 `--base` 且最新 test 的 X.Y.Z 不高于正式版本线时，自动取正式版本线的下一个补丁号、
  `-test.1`（例如正式 0.11.0 已发、最新 test 是 `v0.11.0-test.4` ⇒ `v0.11.1-test.1`）；`--base` 只做显式覆盖
  （必须高于最新 test tag 与正式版本线）与校验，不自动算。
- 触发发版之前先在 `origin/main` 上本地跑 `tools/release/plan-builds.sh`，它判「构建」的端必须正好等于参数里的端。
- 触发发版之前 `origin/main` 这个提交的 CI 要跑完且全绿：看这个提交上所有在 main 上 push 触发的 workflow 运行（不限名单），加上 commit status。同一提交上别的事件触发的运行（临时分支上手动触发的 Release 等）不算 main 红，所以失败的 Release 不挡同号重试。
- test tag 没有手写更新说明（[规则](../release-notes-rules.md)），脚本只做校验。
- 发版入口是手动触发 `release.yml`（`release=true`，tag 填算出的新 tag）：脚本在一条临时分支（指向判定用的 main 提交）上触发，等这次 run，**run 结论 success 后才删临时分支**；失败 / 取消 / 超时保留这条分支（重跑用它在同一提交上重新触发，确认不要了用 `git push origin --delete release-run/<tag>`），**脚本不推 tag**，tag 由流程在发版前验证全绿后才建。绿了再核对 test-channel 里各端清单的 version。
- 发版前验证就红了：没有建 tag，同一个版本号可直接重试。tag 已建（构建阶段红）：tag 保留不动，下一次用 `-test.N+1`；这类旧的 test 草稿与 tag 会在下一次成功的 test 发布时由 `cleanup-test-channel.sh` 清掉（被 test-channel 清单指向的保留；收敛失败只告警，不影响包）。
- 正式版本号、`--formal` / `stable` / `publish` 一律拒绝。正式发布只由产品负责人在网页上做。

## 产品取向的问题

用户感知的行为、隐私、数据去留这类问题不由 owner 定。用产品语言写两个选项，然后接着做别的卡：

```bash
just owner-stuck "导入时遇到重复照片怎么办" --product "保留两份，占盘翻倍" "只留一份，省空间"
```

脚本会开一个打了 `status:blocked` 与 `needs:product` 的 issue。少给一个选项会被拒绝。
