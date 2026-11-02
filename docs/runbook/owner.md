# owner 流程：攒批 → 验证 → PR → test tag

owner 每一步只跑下面的命令。命令自带判定：红了或判定不了，就写 issue（`status:blocked`）
或评论到对应的卡、PR，然后非 0 退出。owner 不补做、不绕过、不改判定，接着做别的。
脚本在 `tools/flow/owner-*.sh`，测试是 `tools/test-flow-owner.sh`（`just ci` 与 `just ci-docs` 都会跑）。

## 命令

| 步骤 | 命令 | 通过时最后一行 |
|---|---|---|
| 看哪些卡能合批 | `just batch-plan`（`--dry-run` 不改 issue） | `PLAN BATCH <序号> <号>...` |
| 开批次 | `just batch-open <主题> <issue...>` | `BATCH-OPEN OK batch/<日期>-<主题> <号>...` |
| 本地全量验证 | 在批次 worktree 里 `just batch-verify` | `BATCH-VERIFY PASS <提交>` |
| 开 PR 并合入 | `just batch-pr` | `BATCH-PR MERGED #<PR> <提交>` |
| 出 test 包 | `just release-test <端...>` | `RELEASE-TEST OK v<X.Y.Z>-test.N <端...>` |
| 停下 | `just owner-stuck "<原因>" [--issue N \| --pr N] [--product "<一>" "<二>"] [--log 文件]` | `ok: ...` |

退出码：0 通过；1 停下了（已写 issue 或评论）；2 拒绝（用法错，或前置条件没满足，提示里给了下一条命令）。
看到 1 就不要重试同一条命令，先处理 issue。

## 每一步判什么

**batch-plan / batch-open**：每张卡必须同时满足下面几条。

- issue 打开，带 `status:review`（worker 已交卡）。
- 远端恰好有一条 `<type>/<号>-<slug>` 分支，并且包含最新 `origin/main`。
- 卡分支上没有带 `Hook-Bypass:` 尾行的提交。有这种提交，说明本地拦截被绕过过，要人工核对。
- DCO 签名齐全（`tools/check-dco.sh`），改动全部落在 issue 的「范围」内。
- 命中核心（`.github/core-paths.txt`）的卡要带 `core` 标签，正文还要引用 `docs/decisions/` 下的 ADR，
  而且这份 ADR 在 `origin/main` 上的状态是「已采纳」，写成「提议」也不算。

需要 worker 返工的卡会被打回 `status:blocked`，并写明原因。两张卡改了同一个文件，或者试合并
（`git merge-tree`）有冲突，就分到不同批次。batch-open 用同一套判据，从最新 `origin/main` 开一个新的
worktree（主仓旁边的 `P-Pass-wt/batch-<日期>-<主题>`），逐张执行 `git merge --no-ff --signoff`。
分支名不复用：开失败了，就换个主题名重开。

**batch-verify** 按下面的顺序跑，任何一步红就停：

1. 工作区里有 `ppf-decoder` 这个 bin 时先构建它。daemon 的测试要拉起它，裸 `cargo test` 不会顺带构建。
2. 跑 `just ci`。
3. 跑全部 `tools/test-*.sh`。跑之前把 `GIT_TEMPLATE_DIR` 设成空目录：本机全局 git 模板里的身份 hook 会拦下
   测试夹具用的假身份，造成和改动无关的红。
4. 受影响端按 `tools/ci-paths.sh` 判定，再跑对应端的真机验证：
   - Mac 与 Android：`just verify --smoke <端>`。场景库在才跑，最后一行必须是 `VERIFY PASS`。
   - Windows：`tools/flow/owner-win-test.sh`，用交互会话的计划任务跑。经 ssh 直接跑测试时，令牌是网络登录，
     命名管道与 ACL 测试会红或挂死，结论不可信。
   - iOS：场景库还没收编。

   没跑成的端记为「未覆盖」，既不算绿也不算红，会写进报告与 PR 正文，留给 test 回归。

批次报告存在 `<git 公共目录>/ppass-batch/<批次>/verify-<提交>/report.md`，与验证时的提交绑定，不进 git。

**batch-pr** 在下面几种情况拒绝：

- 当前 HEAD 不是验证通过的那个提交。验证之后又加了提交，就重跑 batch-verify。
- 批次已经落后 main：按同样的卡重开一批。
- 卡分支在合批之后又变了。
- 批次改到的核心文件不来自任何「带 core 标签、引用已采纳 ADR」的卡。

条件满足时，脚本推送批次分支并开 PR。正文逐卡写 `closes #N`，附验证证据与未覆盖项。
批次碰了核心时，脚本代 owner 批准 core review，批准意见里写上 ADR。然后用 `gh pr checks --watch`
等全部检查（不只看必需检查）。全绿就执行 `gh pr merge --squash --match-head-commit <已验证提交>`；
红了就把失败 job 和日志末尾写进 PR 评论，然后停下。

**release-test** 的判定：

- 版本号取远端最新 `v<X.Y.Z>-test.N` 的 N+1。X.Y.Z 必须高于 `release/versions.json` 里每一端的正式版本号，
  否则 test 设备收不到；不满足时给出建议的 `--base`。
- 打 tag 之前先在 `origin/main` 上本地跑 `tools/release/plan-builds.sh`，它判「构建」的端必须正好等于参数里的端。
- test tag 没有手写更新说明（[规则](../release-notes-rules.md)），脚本只做校验。
- 推送 tag 后等 Release run 出结论。绿了再核对 test-channel 里各端清单的 version。
- 失败的 tag 保留不动，下一次用 `-test.N+1`。
- 正式版本号、`--formal` / `stable` / `publish` 一律拒绝。正式发布只由产品负责人在网页上做。

## 已知坑，脚本已处理

- **本机私有 pre-push 误判身份**：重推一条已经存在的远端分支时，它把 main 上由 GitHub 提交的 squash
  （committer `GitHub <noreply@github.com>`）也算进待推范围，报身份不在白名单。batch-pr 只在被拦的身份
  全部是这一个时，才换新分支名（`-r2`、`-r3`）重推，不用 `--no-verify`。远端已有同名分支且内容不同时，
  也换新名，不强推。
- **Windows 测试**：需要本机配置 `~/.config/ppass/owner.env`，内容是 `OWNER_WIN_HOST`、`OWNER_WIN_CLONE`
  （owner 专用的克隆，不要用别人在用的那份）和 `OWNER_WIN_WORK`。代码用 `git bundle` 送过去，
  `owner-win-run.ps1` 注册临时计划任务（LogonType Interactive），跑完删掉。主人没登录桌面时任务跑不起来，
  按「判定不了」停下。
- **重编译互斥**：`just ci` 与 ppf-decoder 的构建套 `lockf -k /tmp/ppass-heavy-build.lock`；
  `just verify` 自己会取这把锁，外面不再套。

## 产品取向的问题

用户感知的行为、隐私、数据去留这类问题不由 owner 定。用产品语言写两个选项，然后接着做别的卡：

```bash
just owner-stuck "导入时遇到重复照片怎么办" --product "保留两份，占盘翻倍" "只留一份，省空间"
```

脚本会开一个打了 `status:blocked` 与 `needs:product` 的 issue。少给一个选项会被拒绝。
