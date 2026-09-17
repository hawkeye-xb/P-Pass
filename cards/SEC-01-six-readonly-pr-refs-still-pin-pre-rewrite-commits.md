# SEC-01 历史重写后 6 个只读 PR ref 仍钉着重写前的提交　级别 L1

状态：⬜ 可接（执行动作不在 agent 手上：提工单 + 一周后核查）
级别：L1（不动代码，只动仓库托管侧状态）
关联：与 [QA-04](QA-04-no-written-rules-for-parallel-sessions-on-main.md) 的分支保护配置相邻（本卡执行时临时放行过 `protect-main` 与经典分支保护，已还原）。

## 挂号段

- 现象：6 个提交的 `author`/`committer` 字段带着不属于本项目身份白名单的邮箱。全史已用 `git filter-repo --mailmap` 改写并强推到全部 8 个分支 + 9 个 tag，分支与 tag 侧已清零；但 GitHub 的 `refs/pull/*` 是**只读 ref**，本地无法删改，其中 6 个仍可走到重写前的旧提交。
- 发现场景：2026-09-17 例行核查 `git log --all --format='%an <%ae>'` 时发现非白名单身份，随后列举远端 96 个 ref 逐个比对确认波及面。
- 严重度猜测：中。公开仓任何人执行 `git fetch origin 'refs/pull/*:refs/pull/*'` 即可取回旧提交，无需知道 SHA，且永久有效——`refs/pull/*` 由 GitHub 维护，PR 关闭后不回收，GC 判定这些对象「可达」，因此**不会随时间自行消失**。

## 可接段

context:
  - 重写工具 `git filter-repo --mailmap`，映射表与新旧 SHA 对照表在仓库外：`~/personal/P-Pass-backup-20260917/`（`ppass.mailmap`、`commit-map-old-to-new.txt`）。
  - 同目录有重写前完整快照 `P-Pass-ORIGINAL-all-branches-tags.bundle`（457M，含全部 11 分支 9 tag），以及工单草稿 `github-support-ticket.md`。
  - 已完成：8 个分支 + 9 个 tag 强推；5 个**开着**的 dependabot PR（#60–64）的 `refs/pull/N/head` 随分支自动更新，已脱钩；文档内 335 处失效 SHA 引用已按对照表重映射。
  - 未完成：6 个已合并/已关闭 PR 的 ref 仍指向旧提交。这些 PR 的 head 分支已删除，**推不动**。
  - 副作用已知并接受：`filter-repo` 会剥离 GPG 签名，30 个网页合并提交的 "Verified" 徽章消失，改写范围因此从 469 扩到 961 个提交。

问题:
  下列 6 个只读 ref 仍可走到重写前的 6 个旧提交：

  | PR | ref | 状态 |
  |---|---|---|
  | #53 | `refs/pull/53/head` | 已关闭/已合并，head 分支已删 |
  | #56 | `refs/pull/56/head` | 已关闭/已合并，head 分支已删 |
  | #65 | `refs/pull/65/head` | 已关闭/已合并，head 分支已删 |
  | #66 | `refs/pull/66/head` | 已关闭/已合并，head 分支已删 |
  | #67 | `refs/pull/67/head` | 已关闭/已合并，head 分支已删 |
  | #68 | `refs/pull/68/head` | 已关闭/已合并，head 分支已删 |

  重写前的 6 个旧提交 SHA：`544f9c33` `473dd14e` `9efd9ea1` `a4e8c9ce` `7c68b487` `8005ec2b`

期望行为:
  远端全部 ref（含 `refs/pull/*`）中，走不到任何带非白名单身份的提交。

验收标准:
  - [ ] [E1] 以仓库所有者账号向 GitHub Support 提交工单，要求①解引用/删除受影响 PR ②服务端 GC ③清除缓存视图；工单号记录在本卡实施记录里。
  - [ ] [E1] 客服处理后重跑下方核查命令，输出为 `0`。
  - [ ] [E2] 反证：核查命令在**当前**（未处理）状态下必须输出 `6`——判据若在没处理时也报 0，说明判据本身失效，不可采信。
  - [ ] [E3] 旧 SHA 直链 `https://github.com/hawkeye-xb/P-Pass/commit/544f9c337caf44fa3937b26aae589c1abc342502` 返回 404。

  核查命令（不依赖 `gh`，走个人 SSH remote；判据是「旧提交是否仍从某个 ref 可达」）：

  ```sh
  D=$(mktemp -d) && git init -q --bare "$D" && cd "$D" \
    && git remote add o git@github-personal:hawkeye-xb/P-Pass.git \
    && git fetch -q o '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' '+refs/pull/*:refs/pull/*' \
    && for r in $(git for-each-ref --format='%(refname)'); do \
         git merge-base --is-ancestor 544f9c337caf44fa3937b26aae589c1abc342502 "$r" 2>/dev/null \
           && echo "$r"; \
       done | tee /dev/stderr | wc -l
  ```

  > 若旧提交已被服务端 GC，`fetch` 后该 SHA 在本地根本不存在，`merge-base` 会
  > 静默失败并计 0——这正是期望结果；命令同时把命中的 ref 名打到 stderr，
  > 方便确认剩的是哪几个。

范围:
  只动 GitHub 托管侧状态（工单）与本卡文件。**不准动**：任何分支/tag 的再次改写（已完成，重复改写会再次作废文档里的 SHA 引用）、`refs/pull/*`（只读，推不动）、`.github/` 下任何文件。

阻塞与依赖:
  - 必须以仓库所有者账号提交工单，不能用协作者账号，更不能用非本项目身份的账号。
  - 客服处理周期不可控，**一周后先核查一次**；未处理则在原工单追问，不要重开新单。
  - 不可用 `gh`（见 `AGENTS.md` 的账号隔离约定）。

## 实施记录

已完成部分（2026-09-17）：

- 备份：`~/personal/P-Pass-backup-20260917/`，重写前完整快照 457M bundle，19 个 ref 全覆盖；另存新旧 SHA 对照表。
- 改写：`git filter-repo --mailmap`，3 条映射（两个非白名单身份 + `dependabot[bot]`）统一归并到白名单身份。
- 完整性核验：1081 个提交逐个比对 tree 哈希，**1081/1081 一致、0 处差异**——只改元数据，内容零变更。
- 强推：8 个分支（`main`、`archive/rules-v1-2026-09-16`、5 个 `dependabot/*`、`docs/net15-closure`）+ 9 个 tag，全程 `--force-with-lease` 钉旧 SHA，未覆盖任何他人提交。`bin-*` 三个分支 SHA 未变，跳过。
- 实测复核：重新拉取远端全部 103 个 ref 逐个统计，带非白名单身份的 ref **16 → 6**；分支与 tag 上的作者只剩白名单内 4 个身份。
- 文档修复：335 处失效 SHA 引用按对照表重映射（`PROGRESS.md` 117、`NEXT.md` 56、`ROADMAP.md` 30 为大头），前缀歧义 0 处；176 个新写入 SHA 全部可解析。
- 防复发（待办，另立）：本机 `~/.gitconfig` 的 `includeIf gitdir:~/personal/` 是 2026-08-28 才加的，而这 6 个提交是 2026-08-26 从**另一台机器**推的——本机配置管不到那台。服务端白名单校验（CI 检查提交作者是否在白名单，白名单本身不含任何敏感字样）才是能覆盖所有机器的硬约束。

待办：见上方验收标准。
