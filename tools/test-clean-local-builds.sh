#!/usr/bin/env bash
# Integration test for tools/clean-local-builds.sh; operates only in a temp repo.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cleanup_script="$script_dir/clean-local-builds.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ppass-clean-local.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# DEV-03: 断言必须真的能让测试失败。
# 原来每条断言都是裸 `[[ ... ]]`，依赖 `set -e` 中断——但在 macOS 自带的
# bash 3.2 下，失败的裸 `[[ ]]` **不触发 errexit**，脚本照常往下跑并以 0
# 退出。实测：本文件的全部断言一直是空转的，连「正在构建的 worktree 被
# 删掉」这种安全回归都照样报 ok。与 QA-02 记录的「变异 C 空转」同型。
fail() { printf 'ASSERT FAILED: %s\n' "$1" >&2; exit 1; }


remote="$tmp/remote.git"
repo="$tmp/repo"

git init --bare "$remote" >/dev/null
# --template= forces an empty hook template. Without it the fixture inherits
# whatever init.templateDir points at on the developer's machine, and a
# machine-local identity-allowlist pre-commit hook then rejects the fixture's
# deliberately fake identity below — the test would fail for reasons that have
# nothing to do with what it tests. Fixture commits also pass --no-verify for
# the same reason: they are test data, not contributions.
git clone --template= "$remote" "$repo" >/dev/null
# macOS 的 $TMPDIR 是 /var/folders/...，而 /var 是指向 /private/var 的符号
# 链接。git worktree list 和 pwd -P 都返回解析后的 /private/var/... 形式，
# mktemp 返回未解析的 /var/... 形式。夹具必须统一到解析后的路径，否则
# ①断言里的 $repo 和实际输出对不上 ②has_active_build 拿进程命令行里的
# /var/... 去匹配 worktree 的 /private/var/...，永远匹配不上——测试会把
# 「正在构建的 worktree 被删」当成正常。这是夹具的路径问题，不是被测脚本
# 在真实仓库（/Users/... 无符号链接）里的行为。
repo=$(cd "$repo" && pwd -P)
# DEV-04: 被测脚本打印的是 `git worktree list` 的路径写法。在 Windows 上那是
# `C:/Users/...`，而 mktemp / `pwd -P` 给的是 `/c/Users/...`（大小写还可能不同）。
# 断言必须对着脚本**实际会输出**的写法比，否则会红在路径格式上——DEV-04 实测
# 就是这样：测试确实变红了，但红的原因掩盖了真正的安全回归（正在构建的
# worktree 被删）。文件系统层面的断言仍然用 $repo。
repo_as_printed=$(cd "$repo" && git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)
git -C "$repo" config user.name 'P-Pass test'
git -C "$repo" config user.email 'test@example.invalid'
printf 'fixture\n' > "$repo/README.md"
# 真实的 Cargo target 旁边一定有 Cargo.toml。夹具必须长得像真的：判据一旦
# 开始按「这是不是真的 Cargo target」筛选，不像的夹具会整批落选，而空转的
# 断言不会告诉你。放进初始提交，所有 worktree 继承且保持干净（写成未跟踪
# 文件会让 worktree 变成「有未提交改动」而被跳过，那是另一种假失败）。
printf '[package]\nname = "fixture"\nversion = "0.0.0"\n' > "$repo/Cargo.toml"
git -C "$repo" add README.md Cargo.toml
git -C "$repo" commit --no-verify -m 'fixture' >/dev/null
git -C "$repo" branch -M main
git -C "$repo" push -u origin main >/dev/null

git -C "$repo" worktree add -b merged "$repo/.worktrees/merged" main >/dev/null
git -C "$repo" worktree add -b dirty "$repo/.worktrees/dirty" main >/dev/null
git -C "$repo" worktree add -b active "$repo/.worktrees/active" main >/dev/null
git -C "$repo" worktree add -b pending "$repo/.worktrees/pending" main >/dev/null

mkdir -p "$repo/target" "$repo/.worktrees/merged/target" \
  "$repo/.worktrees/dirty/target" "$repo/.worktrees/active/target"
printf 'keep source, not cache\n' > "$repo/.worktrees/dirty/DIRTY"
printf 'not yet merged\n' > "$repo/.worktrees/pending/PENDING"
git -C "$repo/.worktrees/pending" add PENDING
git -C "$repo/.worktrees/pending" commit --no-verify -m 'pending' >/dev/null

# Default mode is a non-destructive preview.
preview=$(cd "$repo" && bash "$cleanup_script")
[[ "$preview" == *'Mode: PREVIEW'* ]] || fail "[[ \"$preview\" == *'Mode: PREVIEW'* ]]"
[[ -d "$repo/target" ]] || fail "[[ -d \"$repo/target\" ]]"
[[ -d "$repo/.worktrees/merged/target" ]] || fail "[[ -d \"$repo/.worktrees/merged/target\" ]]"

# Explicit cache cleanup does not remove any worktree source directory.
(cd "$repo" && bash "$cleanup_script" --apply --targets >/dev/null)
[[ ! -e "$repo/target" ]] || fail "[[ ! -e \"$repo/target\" ]]"
[[ ! -e "$repo/.worktrees/merged/target" ]] || fail "[[ ! -e \"$repo/.worktrees/merged/target\" ]]"
[[ -d "$repo/.worktrees/merged" ]] || fail "[[ -d \"$repo/.worktrees/merged\" ]]"
[[ -d "$repo/.worktrees/dirty" ]] || fail "[[ -d \"$repo/.worktrees/dirty\" ]]"
[[ -d "$repo/.worktrees/pending" ]] || fail "[[ -d \"$repo/.worktrees/pending\" ]]"

# A process whose command line represents a build in this worktree blocks removal.
mkdir -p "$repo/.worktrees/active/target"
# DEV-04: 传给夹具进程的路径要用**脚本会看到的那种写法**。Windows 上 MSYS 的
# /tmp 是个挂载点（`git worktree list` 给的是 C:/Users/.../Temp/...，而 mktemp
# 给的是 /tmp/...），拿 /tmp/... 当参数的话占用检查永远匹配不上——测试就会把
# 「正在构建的 worktree 被删」当成正常。这与上面 macOS 那条 /var 注释同源：
# 夹具必须统一到脚本视角的路径写法。macOS/Linux 上两者相同，此改动是空操作。
# DEV-04: 不能硬写 python3。Windows 上它常常是 Microsoft Store 的**应用执行
# 别名**——`command -v` 找得到、退出码 0，但**什么都不做**（实测
# `python3 --version` 无任何输出）。于是夹具进程根本没起来，占用检查「查不到
# 活跃构建」反而是对的，而测试会把「正在构建的 worktree 被删」当成正常。
# 与 QA-07 (#178) 在 justfile 里踩的是同一个坑，用同样的三级探测；这里的探测
# 要求**真的有输出**，否则那个静默的 stub 会通过。
sleeper=""
for candidate in python3 python py; do
  if [[ "$("$candidate" -c 'print(3)' 2>/dev/null)" == "3" ]]; then
    sleeper="$candidate"
    break
  fi
done
[[ -n "$sleeper" ]] || fail 'no working Python 3 (tried python3 / python / py); cannot fabricate an active build'
# 睡 300s 而不是 30s：夹具进程必须活过整个脚本运行。Windows 上 git 操作和
# du 明显更慢，30s 曾经在断言通过之后、收尾 kill 之前就到期了。
"$sleeper" -c 'import time; time.sleep(300)' "$repo_as_printed/.worktrees/active" 'cargo build' &
active_pid=$!
trap 'kill "$active_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
sleep 1

worktree_apply=$(cd "$repo" && bash "$cleanup_script" --apply --worktrees)
[[ "$worktree_apply" == *"REMOVED    $repo_as_printed/.worktrees/merged"* ]] || fail "[[ \"\$worktree_apply\" == *\"REMOVED    $repo_as_printed/.worktrees/merged\"* ]]"
[[ ! -d "$repo/.worktrees/merged" ]] || fail "[[ ! -d \"$repo/.worktrees/merged\" ]]"
[[ -d "$repo/.worktrees/dirty" ]] || fail "[[ -d \"$repo/.worktrees/dirty\" ]]"
[[ -f "$repo/.worktrees/dirty/DIRTY" ]] || fail "[[ -f \"$repo/.worktrees/dirty/DIRTY\" ]]"
[[ -d "$repo/.worktrees/pending" ]] || fail "[[ -d \"$repo/.worktrees/pending\" ]]"
[[ -f "$repo/.worktrees/pending/PENDING" ]] || fail "[[ -f \"$repo/.worktrees/pending/PENDING\" ]]"
[[ -d "$repo/.worktrees/active" ]] || fail "[[ -d \"$repo/.worktrees/active\" ]]"
[[ -d "$repo/.worktrees/active/target" ]] || fail "[[ -d \"$repo/.worktrees/active/target\" ]]"
[[ "$worktree_apply" == *"SKIP       $repo_as_printed/.worktrees/pending — HEAD is neither merged into origin/main nor tracking an upstream"* ]] || fail "[[ \"\$worktree_apply\" == *\"SKIP       $repo_as_printed/.worktrees/pending — HEAD is neither merged ...\"* ]]"
# DEV-04: 这条是本文件的安全核心——「正在构建的 worktree 不许被删」。
# Windows 上它曾经真的被删掉（占用检查靠 `ps -axo`，msys 的 ps 不认）。
[[ "$worktree_apply" == *"SKIP       $repo_as_printed/.worktrees/active — active build:"* ]] || fail "[[ \"\$worktree_apply\" == *\"SKIP       $repo_as_printed/.worktrees/active — active build:\"* ]]"

# 收尾的 kill 不得让测试失败：夹具进程可能已经自己退出（`set -e` 下
# `kill` 对已退出的 pid 会报 "No such process" 并中断脚本——实测踩过）。
# 真正的判据是上面那条 `active build:` 断言，它已经过了。
kill "$active_pid" 2>/dev/null || true
wait "$active_pid" 2>/dev/null || true
trap 'rm -rf "$tmp"' EXIT

printf 'ok: clean-local-builds safety integration test\n'
