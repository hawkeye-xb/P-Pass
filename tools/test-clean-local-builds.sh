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

# #1490: the shared Cargo cache is located through tools/e3/lib/dev-cache.sh.
# Point it at a fixture parent so the test can never see — let alone sweep —
# the developer's real cache. `just` loads CARGO_TARGET_DIR from .env.ppass-dev
# into every recipe, so it must be cleared too, or a broken locator would
# silently "pass" by falling back to the real cache in the environment.
unset CARGO_TARGET_DIR
cache_parent="$tmp/cache-parent"
cache="$cache_parent/P-Pass-cache/cargo-target"
mkdir -p "$cache/debug/deps"
printf 'artifact\n' > "$cache/debug/deps/libfixture.rlib"
printf 'CARGO_TARGET_DIR=%s\n' "$cache" > "$cache_parent/.env.ppass-dev"
export PPASS_DEV_CACHE_PARENT="$cache_parent"
cache_real=$(cd "$cache" && pwd -P)
# Our own heavy-build lock, so the test neither waits for nor blocks real builds.
export PPASS_HEAVY_LOCK="$tmp/heavy.lock"
unset PPASS_HEAVY_LOCK_HELD
# A cargo-sweep stub that only records how it was called.
stub_bin="$tmp/stub-bin"
sweep_log="$tmp/sweep.log"
mkdir -p "$stub_bin"
cat > "$stub_bin/cargo-sweep" <<EOF
#!/usr/bin/env bash
printf 'CARGO_TARGET_DIR=%s args=%s\\n' "\$CARGO_TARGET_DIR" "\$*" >> "$sweep_log"
EOF
chmod +x "$stub_bin/cargo-sweep"
# PATH without any real cargo-sweep (the developer may have one installed).
no_sweep_path=""
IFS=: read -r -a path_entries <<< "$PATH"
for entry in "${path_entries[@]}"; do
  [[ -n "$entry" && ! -x "$entry/cargo-sweep" ]] || continue
  no_sweep_path="${no_sweep_path:+$no_sweep_path:}$entry"
done


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
# #1490: a Claude Code session directory that is clean and merged — exactly what
# --worktrees would otherwise remove while the session is still open.
git -C "$repo" worktree add -b session "$repo/.claude/worktrees/session" main >/dev/null
mkdir -p "$repo/.claude/worktrees/session/target"

mkdir -p "$repo/target" "$repo/.worktrees/merged/target" \
  "$repo/.worktrees/dirty/target" "$repo/.worktrees/active/target"
printf 'keep source, not cache\n' > "$repo/.worktrees/dirty/DIRTY"
printf 'not yet merged\n' > "$repo/.worktrees/pending/PENDING"
git -C "$repo/.worktrees/pending" add PENDING
git -C "$repo/.worktrees/pending" commit --no-verify -m 'pending' >/dev/null

# Default mode is a non-destructive preview.
preview=$(cd "$repo" && bash "$cleanup_script")
[[ "$preview" == *'Mode: PREVIEW'* ]] || fail "[[ \"$preview\" == *'Mode: PREVIEW'* ]]"
# #1490: the shared cache is found through dev-cache, and only named in a plain preview.
[[ "$preview" == *"CACHE      $cache_real (preview and sweep it with --cache)"* ]] || fail "plain preview does not locate the shared cache: $preview"
[[ ! -e "$sweep_log" ]] || fail 'plain preview ran cargo-sweep'
# Counter-proof: without the dev-cache env file there is nothing to find.
mkdir -p "$tmp/no-cache-parent"
no_cache=$(cd "$repo" && PPASS_DEV_CACHE_PARENT="$tmp/no-cache-parent" bash "$cleanup_script")
[[ "$no_cache" == *'ABSENT     no shared cache configured'* ]] || fail "cache found without dev-cache config: $no_cache"
[[ "$no_cache" != *"$cache_real"* ]] || fail "cache path printed without dev-cache config: $no_cache"
[[ -d "$repo/target" ]] || fail "[[ -d \"$repo/target\" ]]"
[[ -d "$repo/.worktrees/merged/target" ]] || fail "[[ -d \"$repo/.worktrees/merged/target\" ]]"

# Explicit cache cleanup does not remove any worktree source directory.
(cd "$repo" && bash "$cleanup_script" --apply --targets >/dev/null)
[[ ! -e "$repo/target" ]] || fail "[[ ! -e \"$repo/target\" ]]"
[[ ! -e "$repo/.worktrees/merged/target" ]] || fail "[[ ! -e \"$repo/.worktrees/merged/target\" ]]"
[[ -d "$repo/.worktrees/merged" ]] || fail "[[ -d \"$repo/.worktrees/merged\" ]]"
[[ -d "$repo/.worktrees/dirty" ]] || fail "[[ -d \"$repo/.worktrees/dirty\" ]]"
[[ -d "$repo/.worktrees/pending" ]] || fail "[[ -d \"$repo/.worktrees/pending\" ]]"
[[ -f "$cache/debug/deps/libfixture.rlib" ]] || fail '--targets touched the shared cache'
# #1490: a session worktree's target is not cleared by default either.
[[ -d "$repo/.claude/worktrees/session/target" ]] || fail '--targets removed a Claude Code session target'

# #1490 --cache: never rm -rf when cargo-sweep is missing — refuse and say how to install it.
missing_status=0
missing=$(cd "$repo" && PATH="$no_sweep_path" bash "$cleanup_script" --apply --cache) || missing_status=$?
[[ $missing_status -ne 0 ]] || fail "--apply --cache without cargo-sweep exited 0: $missing"
[[ "$missing" == *'cargo install cargo-sweep --locked'* ]] || fail "no install hint: $missing"
[[ -f "$cache/debug/deps/libfixture.rlib" ]] || fail 'cache touched without cargo-sweep'
[[ ! -e "$sweep_log" ]] || fail 'stub ran although PATH had no cargo-sweep'

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
# #1490: session directories are not removed by default…
[[ -d "$repo/.claude/worktrees/session" ]] || fail "--worktrees removed a Claude Code session worktree: $worktree_apply"
[[ "$worktree_apply" == *"SKIP       $repo_as_printed/.claude/worktrees/session — Claude Code session worktree"* ]] || fail "session worktree not reported as skipped: $worktree_apply"
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

if command -v lsof >/dev/null 2>&1; then
  # …and even when asked, not while a process still works inside it (a live
  # session's shell has its cwd there).
  (cd "$repo/.claude/worktrees/session" && exec "$sleeper" -c 'import time; time.sleep(300)') &
  session_pid=$!
  trap 'kill "$session_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
  sleep 1
  in_use=$(cd "$repo" && bash "$cleanup_script" --apply --worktrees --session-worktrees)
  [[ -d "$repo/.claude/worktrees/session" ]] || fail "--session-worktrees removed a session worktree in use: $in_use"
  [[ "$in_use" == *"SKIP       $repo_as_printed/.claude/worktrees/session — Claude Code session worktree in use"* ]] || fail "in-use session worktree not reported: $in_use"
  mkdir -p "$repo/.claude/worktrees/session/target"
  in_use_targets=$(cd "$repo" && bash "$cleanup_script" --apply --targets --session-worktrees)
  [[ -d "$repo/.claude/worktrees/session/target" ]] || fail "--targets --session-worktrees removed the target of a session in use: $in_use_targets"
  kill "$session_pid" 2>/dev/null || true
  wait "$session_pid" 2>/dev/null || true
  trap 'rm -rf "$tmp"' EXIT
fi

# …only when asked for explicitly and nobody is inside it (counter-proof that
# the skips are the new rules, not something else keeping the fixture alive).
session_apply=$(cd "$repo" && bash "$cleanup_script" --apply --worktrees --session-worktrees)
[[ ! -d "$repo/.claude/worktrees/session" ]] || fail "--session-worktrees did not remove the merged session worktree: $session_apply"

if command -v lsof >/dev/null 2>&1; then
  # #1490: a file held open inside the cache (a build using it) blocks the sweep.
  "$sleeper" -c 'import sys, time; f = open(sys.argv[1]); time.sleep(300)' "$cache/debug/deps/libfixture.rlib" &
  holder_pid=$!
  trap 'kill "$holder_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
  sleep 1
  held=$(cd "$repo" && PATH="$stub_bin:$PATH" bash "$cleanup_script" --apply --cache)
  [[ "$held" == *"SKIP       $cache_real — files open in it"* ]] || fail "open cache file did not block the sweep: $held"
  [[ "$held" == *"$cache_real/debug/deps/libfixture.rlib"* ]] || fail "open file not named: $held"
  [[ ! -e "$sweep_log" ]] || fail 'cargo-sweep ran while a file in the cache was open'
  [[ -f "$cache/debug/deps/libfixture.rlib" ]] || fail 'open cache file was removed'
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  trap 'rm -rf "$tmp"' EXIT

  if command -v lockf >/dev/null 2>&1; then
    # The in-use check happens inside the heavy-build lock, not before queueing:
    # a build that starts while the sweep waits for the lock must still stop it.
    # The lock is released only after the holder's open file is visible to lsof,
    # so the outcome does not depend on how fast Python starts.
    lockf -k "$PPASS_HEAVY_LOCK" bash -c 'while [ ! -e "$1" ]; do sleep 0.1; done' _ "$tmp/go" &
    lock_pid=$!
    sleep 1
    (cd "$repo" && PATH="$stub_bin:$PATH" bash "$cleanup_script" --apply --cache > "$tmp/waited.out") &
    waiter_pid=$!
    "$sleeper" -c 'import sys, time; f = open(sys.argv[1]); time.sleep(300)' "$cache/debug/deps/libfixture.rlib" &
    holder_pid=$!
    trap 'kill "$holder_pid" 2>/dev/null || true; touch "$tmp/go"; rm -rf "$tmp"' EXIT
    for _ in $(seq 1 100); do
      lsof -nP -Fn -p "$holder_pid" 2>/dev/null | grep -qF "libfixture.rlib" && break
      sleep 0.1
    done
    lsof -nP -Fn -p "$holder_pid" 2>/dev/null | grep -qF "libfixture.rlib" || fail 'fixture holder never opened the cache file'
    touch "$tmp/go"
    wait "$waiter_pid" || fail "sweep that waited for the lock failed: $(cat "$tmp/waited.out")"
    wait "$lock_pid" 2>/dev/null || true
    [[ "$(cat "$tmp/waited.out")" == *"SKIP       $cache_real — files open in it"* ]] || fail "build started while waiting for the lock was not seen: $(cat "$tmp/waited.out")"
    [[ ! -e "$sweep_log" ]] || fail 'cargo-sweep ran although a build started while it waited for the lock'
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    trap 'rm -rf "$tmp"' EXIT
  fi

  # An incomplete lsof listing (non-zero exit, partial output) is "cannot tell",
  # never "nobody uses it".
  mkdir -p "$tmp/partial-lsof-bin"
  printf '#!/usr/bin/env bash\nprintf "p1\\nn/unrelated/file\\n"\nexit 1\n' > "$tmp/partial-lsof-bin/lsof"
  chmod +x "$tmp/partial-lsof-bin/lsof"
  partial_status=0
  partial=$(cd "$repo" && PATH="$tmp/partial-lsof-bin:$stub_bin:$PATH" bash "$cleanup_script" --apply --cache) || partial_status=$?
  [[ $partial_status -ne 0 && "$partial" == *'cannot tell whether a build is using it'* ]] || fail "partial lsof listing was trusted: $partial"
  [[ ! -e "$sweep_log" ]] || fail 'cargo-sweep ran on a partial lsof listing'

  # A failed sweep is a failure in preview too, not a silent exit 0.
  printf '#!/usr/bin/env bash\nexit 7\n' > "$tmp/broken-sweep"
  mkdir -p "$tmp/broken-bin" && mv "$tmp/broken-sweep" "$tmp/broken-bin/cargo-sweep" && chmod +x "$tmp/broken-bin/cargo-sweep"
  broken_status=0
  broken=$(cd "$repo" && PATH="$tmp/broken-bin:$PATH" bash "$cleanup_script" --cache) || broken_status=$?
  [[ $broken_status -ne 0 && "$broken" == *'FAILED     cargo-sweep sweep'* ]] || fail "failed dry run reported success: $broken"

  # Preview is a cargo-sweep dry run against the shared cache, for both policies.
  (cd "$repo" && PATH="$stub_bin:$PATH" bash "$cleanup_script" --cache >/dev/null)
  [[ "$(grep -c -- '--dry-run' "$sweep_log")" == 2 ]] || fail "preview did not dry-run both sweeps: $(cat "$sweep_log")"
  grep -qF -- "CARGO_TARGET_DIR=$cache_real args=sweep --dry-run --time 7 $repo" "$sweep_log" || fail "time sweep not aimed at the shared cache: $(cat "$sweep_log")"
  grep -qF -- "CARGO_TARGET_DIR=$cache_real args=sweep --dry-run --maxsize 40GB $repo" "$sweep_log" || fail "size sweep not aimed at the shared cache: $(cat "$sweep_log")"
  rm -f "$sweep_log"

  # Apply (nothing open any more) sweeps for real, with the given limits.
  swept=$(cd "$repo" && PATH="$stub_bin:$PATH" bash "$cleanup_script" --apply --cache --cache-days 3 --cache-max 10GB)
  [[ "$swept" == *"SWEPT      $cache_real"* ]] || fail "apply did not report the sweep: $swept"
  grep -qF -- "CARGO_TARGET_DIR=$cache_real args=sweep --time 3 $repo" "$sweep_log" || fail "time sweep not applied: $(cat "$sweep_log")"
  grep -qF -- "CARGO_TARGET_DIR=$cache_real args=sweep --maxsize 10GB $repo" "$sweep_log" || fail "size sweep not applied: $(cat "$sweep_log")"
  ! grep -q -- '--dry-run' "$sweep_log" || fail "apply still dry-ran: $(cat "$sweep_log")"
else
  # No lsof (Git Bash on Windows): cannot tell whether the cache is in use → refuse.
  blind_status=0
  blind=$(cd "$repo" && PATH="$stub_bin:$PATH" bash "$cleanup_script" --apply --cache) || blind_status=$?
  [[ $blind_status -ne 0 && "$blind" == *'cannot tell whether a build is using it'* ]] || fail "sweep without lsof was not refused: $blind"
  [[ ! -e "$sweep_log" ]] || fail 'cargo-sweep ran without lsof'
fi

printf 'ok: clean-local-builds safety integration test\n'
