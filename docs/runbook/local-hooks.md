# 本地提交拦截（核心 + 范围）

`git commit` 那一刻由 git hook 判两件事，不对就拒绝提交：改动有没有碰核心、
有没有改出卡的「范围」。`git push` 时再判一件：卡分支有没有跟上最新的 `origin/main`。只靠 git 自身，不依赖任何 agent 外壳的 hook 机制，
所以不管提交是谁发起的，规则都一样。

## 判什么

| 当前分支 | 判定 |
|---|---|
| `batch/*`（owner 的批分支） | 不拦 |
| `<type>/<issue号>-<slug>`，type ∈ feat/fix/docs/test/ci | 必须在独立 worktree 里（在主仓工作区直接拒绝）；用 `gh` 查该 issue，下面两条都要过 |
| 其它分支名、detached HEAD | 拒绝 |

1. **核心**：暂存改动用 `tools/ci-paths.sh core` 判定，规则是 `.github/core-paths.txt`，
   和 CI 的 `core review` 用的是同一套。命中核心、而 issue 没有 `core` 标签时拒绝。
   这时按 AGENTS.md 红线 6，只写复现、根因和两个修法。
2. **范围**：issue 正文里「**范围（只许动这些）**：」下面那个 ```` ``` ```` 代码块，一行写一个
   路径或 glob（`**` 可以跨目录，`*` 和 `?` 不跨 `/`；以 `/` 结尾的行视为 `目录/**`；空行和 `#` 开头的行忽略）。
   暂存的文件有任何一个不在范围内就拒绝，并列出越界的文件。没有这个代码块，或者代码块是空的，也拒绝，
   需要先把范围补进 issue。范围不认项目符号列表和 `{a,b}` 写法。

暂存列表按 `--no-renames` 取，改名时旧路径和新路径都要判。空提交不判。

**主仓工作区**：主仓目录是产品负责人与其他会话共用的现场，卡分支只许在
`git worktree add` 出来的独立目录里提交。`batch/*` 不受此限。

**推送（pre-push）**：推送卡分支前，hook 会现取一次远端的 `main`。卡分支没有包含它时拒绝，
并提示 `git rebase origin/main`。这条放在推送而不是提交：交付时才要求跟上 main，
和 GitHub 的「require branches up to date」是同一个口径；干活途中 main 前进了，不会打断提交。
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
  兜底仍然是 CI 的 `core review` 和 owner 合批时的审查。
- 通行证本身挡不住故意绕过的人：任何能编辑 issue 的账号都可以给卡打 `core` 标签、改「范围」。
  这一层防的是忘了规矩，故意绕过的情况仍然要靠 `core review` 和 owner 审查兜底。
- 自己开 PR、自己在 GitHub 上操作，本地 hook 管不到。
- 在卡分支上解决合并冲突后用 `git commit` 收尾时，暂存区里会带上对方分支的全部改动，
  可能被判为越界或碰了核心。卡分支本来就不该合别的分支；确实需要时，走紧急逃生并写明原因。
- 每次在卡分支上提交都要请求一次 GitHub API（约 1 秒）。
- 仓库从 `origin` 的 URL 解析（支持 SSH 别名，例如 `git@github-personal:owner/repo.git`）。解析不出来时，
  设置 `PPASS_HOOK_REPO=<owner>/<repo>`。
