# P-Pass 执行 agent 工作规范

唯一必读。其余一切按需从文末索引获取，读到不代表要用。

## 入口（按 session 类型分）

- **执行卡**（验收人给了卡号）：`git fetch origin --prune`，确认不落后于远端，
  读 `cards/<卡号>.md` 即全部任务上下文。卡是唯一事实源：干什么、怎么算完、
  不许碰什么，都在卡里。卡声明了 `requires:` 才去读对应文档，否则不读。
- **状态对齐**（问进度 / 下一张做什么 / 该验收什么）：`git fetch`，读
  `docs/QUEUE.md`（当前状态）+ `docs/PROGRESS.md` **顶部表格**（最近交付——
  该文件按完成时间倒序，最新一条在第一行；*末尾*是 2026-08-26 就停了的
  旧编年段落）。
  对齐完要执行某张卡时，回到上一行。

## 红线（违反=事故）

1. **卡外的活不做。** 发现新问题按下方「发现分岔」处理，不顺手修。
2. **范围即边界。** 只动卡内列出的文件；确需扩大范围时，先改卡（范围与验收），
   再改代码，同批 push——不许静默扩 scope。产品红线：只做图片，不做文件
   备份/同步。
3. **不捏造。** 报绿必须附命令 + 真实输出；故障/安全类判据必须带反证
   （去掉故障条件必须变红）。"CI 绿"不等于验收。
4. **凭据只在 GitHub Secrets。** 不进代码、卡、文档；本机路径/设备状态
   只写 `local-state.md`（不进 git）。
5. **红测不进 main。** 一卡一分支本身就是隔离：红测状态停下时，把红留在自己分支上、别开 PR（或把 PR 标 draft），并在卡面写明停在哪、剩什么。

## 验收证据分级

核心重构后 legacy 测试不自动作数。卡里每条验收标准标注证据等级：

- **E1** 编译 + `just ci` 硬门（arch-check 等机器强制）——永远可信
- **E2** 针对当前架构 case matrix 写的 contract 测试——可信
- **E3** 真机/真环境实证输出（日志/截图/测试计数）——L3 必需
- **E4** legacy 测试——仅参考，不许单独作为验收通过依据

报绿时说明每条结论出自哪一级证据。

## 发现分岔（会话中撞见新问题时）

agent 有挂号权和建议权，没有改道权——优先级由验收人裁决。

- **属于当前卡既有范围** → 同卡做掉，卡尾记录"实施中追加"。
- **独立可验证、不阻塞当前卡** → 挂号新卡（按 `cards/TEMPLATE.md` 挂号段：
  现象/发现场景/严重度猜测，写明"从 X 分出"），继续当前卡。
- **更严重或动摇当前卡根基**（如根因是架构形状错了，当前卡在打症状补丁）
  → 停手：挂号新卡（附证据）；当前卡改「阻塞：等 <新卡> 拍板」，写清
  做到哪、剩什么；当场汇报并给建议（继续 vs 换卡）。

换卡必换会话；同卡继续不必换。卡间关系只以卡面「关联」字段为准，双向都写，
不靠对话记忆。

## 交付

- **一卡一分支，走 PR 合入，不直推 main。**
  `git fetch origin && git switch -c <type>/<卡号>-<slug> origin/main`
  （type ∈ feat/fix/docs/test/ci）。干完 `git push -u origin <分支>` 就**停下**，
  把分支名、自验结果、和一条**预填好的开 PR 链接**一起汇报：
  `https://github.com/hawkeye-xb/P-Pass/compare/main...<分支>?expand=1&title=<urlencode>&body=<urlencode>`
  验收人点开即已填好标题与正文，开 PR 与合并由他完成。agent 不许直接改 main。
- **分支上快验，PR 上全验。** 推分支**不触发任何 CI**（四条 lane 的 `push` 都
  限定 `branches: [main]`），所以分支阶段自己跑最快的那档就行：纯文档
  `just ci-docs`，动了代码 `just ci`。开 PR 才跑受影响域的 lane（`pull_request`
  四条 lane 早已配好，paths 过滤照旧），合入 main 再跑一次 push lane。
- PR 开出后盯受影响域 CI 到结论，红了立刻在同一分支上修，不留红 PR。
- **本机 `gh` 不用于本仓**（未绑定本仓账号）：agent 不许调 `gh` 看 CI、建 PR、
  触发 workflow、发 Release——这些一律在 GitHub 网页上由验收人自己做，agent
  只负责把结论问清楚。git 只走个人 SSH remote。
  （`.github/workflows/` 里的 `gh` 跑在 runner 上用 `GITHUB_TOKEN`，不在此列。）
- 一批交付 = 卡横幅（含 commit）+ 卡尾验收记录 + `docs/PROGRESS.md` 一行，
  同批 push。会话结束汇报 = 卡结果 + 本次挂号清单（每张一行 + 建议优先级）。
- tag 只给真发版本（tag push 触发 release.yml）。**调管线不发版**走 GitHub 网页
  Actions → Release → Run workflow（`workflow_dispatch`，入参 `tag` /
  `platforms`），别拿正式 tag 试错。
- 构建产物、日志不进 main。
- **PR 合并后清本地**：`just cleanup-local`（默认只预览，删除要 `--apply` 加显式 scope）。它会列出可移除的 worktree 与全部 Cargo target 占用。**注意本仓用 Squash and merge，`git branch --merged` 检测不
  到已合并的分支**（squash 后提交不是 main 的祖先），别拿它判断能不能删——
  看「上游 `: gone]`」，且删除要用 `-D` 不是 `-d`。构建产物实测能占到 20G+，
  而 `.git` 只有几百 M：占地方的从来不是历史。

## 机器兜底（不用背，`just ci` 会挡）

- 架构隔离：iroh 只在 `crates/transport/`，平台 cfg 只在 `crates/platform/`。
- 工具链版本唯一真相：`rust-toolchain.toml`（Rust）、CI `java-version`（JDK）。
- 卡与队列索引一致性由 `just queue-check` 校验。

## 索引（需要时才打开）

| 你要做什么 | 去哪 |
|---|---|
| 开卡/补卡 | `cards/TEMPLATE.md` |
| 状态对齐（进度/下一张/待验收） | `docs/QUEUE.md` + `docs/PROGRESS.md` 顶部表格 |
| 本地跑测试、可用命令 | `just --list`（入口 `justfile`） |
| 发版、签名、版本纪律 | `docs/RELEASING.md` |
| 验收协议细则（L 分级由来、抽检法） | `docs/AGENT_PROTOCOL.md` |
| UI/设计基准 | `docs/design/` 当前版（见目录 README 指针） |
| 历史事故与教训 | `docs/lessons/` |
