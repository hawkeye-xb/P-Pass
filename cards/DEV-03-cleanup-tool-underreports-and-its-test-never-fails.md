# DEV-03 清理工具漏报一半，而它的测试从来不会失败　级别 L1

状态：🟡 代码完成待你过目
级别：L1（只动 tools/ 与 justfile/AGENTS.md，不碰产品代码）
关联：与 QA-02 同型——都是「门禁/测试在空转，绿色不代表通过」。

## 挂号段

- 现象：三件事叠在一起。
  ⒜ `tools/test-clean-local-builds.sh` 的 18 条断言全是裸 `[[ ... ]]`，靠 `set -e` 中断——但在 macOS 自带的 **bash 3.2 下失败的裸 `[[ ]]` 不触发 errexit**，脚本继续跑并以 0 退出。**这个测试从来不会失败。**
  ⒝ `clean-local-builds.sh` 只看 `$worktree/target`，嵌套的 Cargo target 完全不可见。本仓实测：预览报 18G，另有 2.6G 从未被提及。
  ⒞ worktree 的「已合并」判据是 `merge-base --is-ancestor HEAD origin/main`。本仓所有 PR 走 **Squash and merge**，squash 后分支提交不是 main 的祖先，**该判据对每个 squash 合并的 worktree 永远为假**。实测两个已完全合并的分支仍被判为未合并。
- 发现场景：2026-09-17 验收人要求加「合并后清理 worktree 与构建垃圾」的引导，动手前查有没有现成工具时撞见。
- 严重度猜测：中。⒜ 让 ⒝⒞ 可以长期不被发现；⒝⒞ 让工具在「本该能清」和「本该报出来」两个方向同时失效，于是人不再用它、垃圾继续堆——本机实测仓库 22G，其中 `.git` 只有 572M。

## 可接段

context:
  - 已有 `just cleanup-local`（`tools/clean-local-builds.sh`）设计是好的：默认预览、`--apply` 必须配显式 scope、跳过有活跃构建的目录。问题只在上面三条实现细节，**不需要另起一个工具**。
  - bash 3.2 的 errexit 行为实测：`set -euo pipefail; [[ "abc" == *"zzz"* ]]; echo AFTER` → 打印 AFTER、退出码 0。
  - 一个**差点写进卡里的错误结论**：修好断言后测试报「正在构建的 worktree 被删除」，一度判定为生产安全漏洞。复查是夹具问题——macOS `$TMPDIR` 是 `/var/folders/…`，`/var` 是指向 `/private/var` 的符号链接，`git worktree list` 与 `pwd -P` 返回解析后的路径而 `mktemp` 返回未解析的，于是 `has_active_build` 拿两种形式互相匹配必然失败。**真实仓库路径 `/Users/…` 没有这层间接，该保护在生产环境是有效的。**

问题:
  清理工具漏报嵌套 target、对 squash 合并的 worktree 永不放行；其测试无论被测行为对错都报 ok。

期望行为:
  预览列出全部 Cargo target；squash 合并的 worktree 可被识别；测试在被测行为错误时真的红。

验收标准:
  - [x] [E1] 预览同时列出根 `target`（18G）与 `apps/desktop/src-tauri/target`（2.6G）——改前只有前者
  - [x] [E2] **测试真的会失败**：本轮修复过程中它连续 4 次以 `ASSERT FAILED: …` 中断（根 target 未删 / worktree 因未跟踪 Cargo.toml 被跳过 / 文案不匹配 / 路径不匹配），全部修掉后才转绿。这就是「判据有效」的直接证据。
  - [x] [E1] `bash -n` 两个脚本语法通过；`just cleanup-local` 预览在真实仓库跑通
  - [ ] [E1] 验收人本机跑一次 `just cleanup-local` 确认输出与本机实际占用相符

范围:
  只准动：`tools/clean-local-builds.sh`、`tools/test-clean-local-builds.sh`、`justfile`、`AGENTS.md`、本卡、`docs/QUEUE.md`。
  **不准动**：产品代码、`.github/workflows/`。

## 实施记录

**`clean-local-builds.sh`**
- 「已合并」判据增加第二个信号：上游分支已从远端消失（GitHub 合并后自动删 head 分支）。ancestry 与 upstream-gone 任一成立即认。
- target 发现从写死的 `$worktree/target` 改为遍历：目录名为 `target` 且（同级有 `Cargo.toml` **或** 目录内有 `CACHEDIR.TAG`）。两个条件是「或」不是「且」——实测本仓 18G 的根 target 没有 `CACHEDIR.TAG`，只认标记会把最大的那个整个漏掉，而漏报是静默的，比报错危险。

**`test-clean-local-builds.sh`**
- 18 条裸断言全部改为 `… || fail "…"`，`fail` 打印断言原文并 `exit 1`。
- 夹具统一到解析后的路径（`repo=$(cd "$repo" && pwd -P)`），否则 `has_active_build` 永远匹配不上，测试会把「正在构建的 worktree 被删」当成正常。
- 夹具加上 `Cargo.toml`（进初始提交，所有 worktree 继承且保持干净），让它长得像真的 Cargo 仓库。
- `git clone --template=` + 夹具提交 `--no-verify`：否则夹具会继承本机 `init.templateDir` 的身份白名单钩子，而夹具用的正是一个故意的假身份，测试会因为与被测内容无关的原因失败。

**`justfile` / `AGENTS.md`**
- 未新增重复的 recipe（`cleanup-local` 已存在且设计合理）。
- `AGENTS.md` 交付段加一条：PR 合并后跑 `just cleanup-local`，并写明 squash 合并下 `git branch --merged` 不可用、删分支要 `-D`。

## 留白 / 挂号

- **`node_modules` 与 Android `build/` 不在工具覆盖范围内**（实测分别 257M 与 695M）。它们的重建代价与 Cargo target 不同（要重装依赖 / 要 gradle），是否纳入同一个 `--targets` scope 需要单独决定，本卡不擅自扩。
- **bash 3.2 的 errexit 陷阱可能不止这一处。** 本仓其他测试脚本若同样用裸 `[[ ]]` 断言，就同样是空转的。没有逐个排查，建议单开一张卡全仓扫一遍 `^\[\[ ` 开头的断言行。
