# 本地提交拦截（本机安全链 + 核心禁区黑名单）

`git commit` 那一刻先经转发器执行本机私有安全钩子（`~/.git-allowed-identities` 身份白名单、个人/公司隔离钩子、`gitleaks` 密钥扫描），再由仓库 git hook 校验**核心禁区黑名单与独立 worktree 保护**（自 #1953 起，单卡普通业务与配套单测文件路径白名单已移除）。`git push` 时再判卡分支与最新 `origin/main` 是否有冲突。只靠 git 自身，不依赖任何 agent 外壳的 hook 机制。

## 判什么

| 当前分支 | 判定 |
|---|---|
| `batch/*`（owner 的批分支） | 不拦 |
| `<type>/<issue号>-<slug>`，type ∈ feat/fix/docs/test/ci | 必须在独立 worktree 里（在主仓工作区直接拒绝）；用 `gh` 查该 issue，核验核心禁区黑名单 |
| 其它分支名、detached HEAD | 拒绝 |

1. **核心禁区黑名单**：暂存改动用 `tools/ci-paths.sh core` 判定，规则优先读取不可变基线 `origin/main:.github/core-paths.txt`（离线时回退 `HEAD` 规则），和 CI 的 acceptance gate 与独立评审用的是同一套。命中核心、而 issue 没有 `core` 标签时拒绝。这时按 AGENTS.md 红线 6，只写复现、根因和两个修法。
2. **普通业务与单测文件放开**：不再强制校验 issue 正文里的单卡文件范围白名单，执行会话可自由修改相关普通业务代码与配套单测，消除因漏填关联单测导致的卡壳与衍生碎卡。

暂存列表按 `--no-renames` 取，改名时旧路径和新路径都要判。空提交不判。

**多卡分支**：同一个功能的几张卡可以领到一条分支上（`just start <号> <号>… [--name <功能名>]`）。分支名里是第一张卡的号，全部卡号记在本地分支配置 `branch.<分支>.ppasscards`（空格分隔）。命中核心时只要有一张关联卡带 `core` 标签就放行。`just done` 读同一个配置：回执贴到每张卡，开 PR 时正文 `closes` 全部卡。

**主仓工作区**：主仓目录是产品负责人与其他会话共用的现场，卡分支只许在 `git worktree add` 出来的独立目录里提交。`batch/*` 不受此限。

**落后 main（提交时）**：卡分支提交时先现取一次 `origin/main`，下面两种情况拒绝，并提示 `git fetch origin && git rebase origin/main`：落后超过 20 个提交（`PPASS_HOOK_MAX_BEHIND` 可调）；或 main 上已有本卡还没拿到的提交改过本次暂存的同一个文件（合并必冲突）。取不到 `origin/main`（离线）时只告警，不拒绝。

**合并 main 解冲突**：卡分支上 `git merge origin/main` 解完冲突后提交，与 MERGE_HEAD 内容完全相同的文件
是从 main 原样带进来的、已经过审，不算本卡改动；冲突解法和顺手做的改动照常判基线核心禁区。
合并的不是 main（MERGE_HEAD 不在 `origin/main` 里），或离线认不出来时，按全部改动判。
`git rebase` 过程中解冲突不触发 pre-commit，不受影响。

**有人 / 无人模式交卡与自动变基重验（#1955）**：
- 本机专属安全层（`~/.git-allowed-identities`、个人/公司隔离钩子、`gitleaks`、`.claude/settings.local.json`）永远只留在本机并经 `dispatch.sh` 优先执行；远端守身份白名单、基线核心禁区、正式单测反假考卷检查与全量 diff `review/agent`。
- 无人模式（`just done --unattended` 或 `--rebase`）在推送前若检测到 `origin/main` 前进，会自动执行 `git rebase origin/main` 并重跑门禁与基线反证（使用 `--force-with-lease` 安全更新已推过的卡分支）；发生行冲突时立即 `git rebase --abort` 零残留退出（`SUSPENDED_CONFLICT`）；连续 2 轮未过门禁触发 `SUSPENDED_CIRCUIT_BREAK` 熔断跳过。

**推送（pre-push）**：推送卡分支前，hook 会现取一次远端的 `main`。卡分支与它有冲突时拒绝
（`git merge-tree --write-tree` 判），并提示 `git rebase origin/main`；只是落后、没有冲突，只提示落后几个提交，照推。
理由：合入门禁在 PR 上的 CI，测的是合并后的结果；main 保护不要求分支跟上最新（strict=false），按「落后」拒推只拖节奏。
本机 git 太旧判不了冲突时只提示，冲突看 PR 页面。`just done` 推送前用同一口径。
`batch/*` 不管。
查不到 issue 时一律拒绝，包括没装 `gh`、没登录、离线、issue 不存在这几种情况。

## 防篡改

hook 脚本、`tools/ci-paths.sh` 和 `.github/core-paths.txt` 都从 **HEAD** 读，
不从工作区读。在工作区里删掉一条规则、或者把 hook 改成 `exit 0`，都改变不了这次提交的判定。
另外，这些文件本身就在核心名单里，要提交对它们的修改，同样得先过核心这一关。

## 安装与自检

```bash
just setup        # 装 pre-commit 框架（gitleaks）+ 本拦截
just hooks-check  # 检查是否已装好，没装好时非 0 退出
just hooks-test   # 判据测试（临时仓库 + 假 gh），已接进 just ci / ci-docs
```

安装做的事（`tools/hooks/install.sh`）：把 `core.hooksPath` 指向
`<git 公共目录>/ppass-hooks/`，然后往里面放转发器（`tools/hooks/dispatch.sh` 的副本）。
转发器每次触发时，先跑 `<git 公共目录>/hooks/<名字>`，也就是 pre-commit 框架和本机原有的私有 hook，
再跑 HEAD 里的 `tools/hooks/<名字>`。

为什么这样装：

- 不用 pre-commit 框架装：它要求本机有 Python 包，agent 外壳里经常没有。
- 不把 `core.hooksPath` 直接设成 `tools/hooks`：这个配置是所有 worktree 共用的，
  还没合入 `tools/hooks/` 的旧 worktree 会一个 hook 都不跑，连本机原有的 hook 也一起失效。
  转发器放在公共目录里，任何 worktree 都能找到；HEAD 里没有 `tools/hooks/` 的分支只跑原有 hook。
  新开的 worktree 不需要重新安装。
- 之后如果在 `.git/hooks/` 里新加了别的 hook，要重跑一次 `just setup`，它才会被转发。

## 紧急逃生

```bash
PPASS_HOOK_BYPASS=1 PPASS_HOOK_BYPASS_REASON='<为什么必须绕过>' git commit -s ...
```

这样会跳过核心和范围检查，原有 hook 照常跑，并且 `commit-msg` 会在提交说明末尾追加一行
`Hook-Bypass: <原因>`，方便事后审计（`git log --grep '^Hook-Bypass:'`）。原因为空时拒绝。

## 已知局限

- `git commit --no-verify` 和改 `core.hooksPath` 都能绕过全部本地检查，这一层只能拦住守规矩的提交。
  兜底仍然是 PR 上的独立评审与 CI；核心改动还有 acceptance gate 的已采纳方案引用检查，用户可见改动按版本验收随台账验。
- 通行证本身挡不住故意绕过的人：任何能编辑 issue 的账号都可以给卡打 `core` 标签、改「范围」。
  这一层防的是忘了规矩，故意绕过的情况仍然要靠 PR 上的独立评审、CI 与 acceptance gate 兜底。
- 自己开 PR、自己在 GitHub 上操作，本地 hook 管不到。
- 每次在卡分支上提交都要请求一次 GitHub API，并取一次 `origin/main`（合计约 1～2 秒）。
- 仓库从 `origin` 的 URL 解析（支持 SSH 别名，例如 `git@github-personal:owner/repo.git`）。解析不出来时，
  设置 `PPASS_HOOK_REPO=<owner>/<repo>`。
