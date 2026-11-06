#!/usr/bin/env bash
# Preview or explicitly reclaim local build caches and stale worktrees.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/clean-local-builds.sh [--targets] [--worktrees] [--all] [--cache]
                                   [--cache-days N] [--cache-max SIZE]
                                   [--session-worktrees] [--apply]

Without --apply, this command only previews candidates.

Scopes:
  --targets     Remove target/ directories only. Source worktrees remain.
                Targets inside .claude/worktrees/ are skipped unless
                --session-worktrees is also given.
  --worktrees   Remove only registered worktrees that are clean, merged into
                origin/main, not the current worktree, and have no active build.
                Worktrees under .claude/worktrees/ (Claude Code session working
                directories, archived by the app) are skipped unless
                --session-worktrees is also given; even then one is kept
                while any process has its cwd or a file open inside it, or
                when that cannot be checked (no lsof).
  --all         Select --targets and --worktrees.
  --cache       Sweep the shared Cargo cache (#1375, located through
                tools/e3/lib/dev-cache.sh) with cargo-sweep: first artifacts
                older than --cache-days (default 7), then oldest artifacts
                until the cache is below --cache-max (default 40GB).
                Needs cargo-sweep (cargo install cargo-sweep --locked).

Safety:
  --apply is mandatory for deletion. --apply also requires an explicit scope.
  A target/ or worktree with an active Cargo/Rustc/Gradle/Node build is skipped.
  --cache waits for the heavy-build lock (tools/heavy-lock) and does not sweep
  while any process holds a file open inside the cache.
EOF
}

apply=false
clean_targets=false
clean_worktrees=false
clean_cache=false
session_worktrees=false
cache_days=7
cache_max=40GB
selected_scope=false

while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --targets) clean_targets=true; selected_scope=true ;;
    --worktrees) clean_worktrees=true; selected_scope=true ;;
    --all) clean_targets=true; clean_worktrees=true; selected_scope=true ;;
    --cache) clean_cache=true; selected_scope=true ;;
    --session-worktrees) session_worktrees=true ;;
    --cache-days|--cache-max)
      [[ $# -ge 2 ]] || { printf 'error: %s needs a value\n' "$1" >&2; exit 2; }
      if [[ "$1" == --cache-days ]]; then cache_days="$2"; else cache_max="$2"; fi
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if "$apply" && ! "$selected_scope"; then
  printf 'error: --apply requires --targets, --worktrees, --all, or --cache\n' >&2
  exit 2
fi

case "$cache_days" in
  ''|*[!0-9]*) printf 'error: --cache-days must be a whole number of days\n' >&2; exit 2 ;;
esac

# Previewing without a selector means show both categories; it cannot delete.
# The shared cache is only named here (its dry run walks ~100G and takes minutes);
# --cache previews it for real.
preview_cache_location=false
if ! "$selected_scope"; then
  clean_targets=true
  clean_worktrees=true
  preview_cache_location=true
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'error: run this from inside a Git worktree\n' >&2
  exit 2
}
repo_root=$(cd "$repo_root" && pwd -P)
current_worktree=$(pwd -P)
cd "$repo_root"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# #1490: the shared cache lives outside every worktree, so it can only be found
# the way the build finds it — through the same dev-cache helpers.
# shellcheck source=tools/e3/lib/dev-cache.sh
. "$script_dir/e3/lib/dev-cache.sh"

mapfile_worktrees() {
  git worktree list --porcelain | while IFS= read -r line; do
    case "$line" in
      'worktree '*) printf '%s\n' "${line#worktree }" ;;
    esac
  done
}

# DEV-04: 把路径归一成可比较的形式。同一个目录在这三处的写法各不相同：
#   pwd -P               -> /c/Users/.../p-pass     (MSYS 风格)
#   git worktree list    -> C:/Users/.../P-Pass     (Windows + 正斜杠)
#   进程命令行（CIM）    -> C:\Users\...\P-Pass      (Windows + 反斜杠)
# 归一 = 反斜杠转正斜杠 + 全小写 + 把 /c/ 前缀折成 c:/。
#
# 小写化在大小写敏感的文件系统上会放宽匹配，但这里只服务**占用检查**——
# 放宽只会让判定更保守（更容易判成「有构建在跑」而拒绝删除），方向是安全的。
normalize_for_match() {
  printf '%s' "$1" | tr '\134' '/' | tr 'A-Z' 'a-z' | sed -E 's#^/([a-z])/#\1:/#'
}

# DEV-04: 列出所有进程的「pid + 完整命令行」；拿不到就返回非 0，调用方必须
# 按 fail-closed 处理。
#
# msys 的 ps 不认 `-axo`（实测退出码 1、报 `ps: unknown option -- x`），而且
# 它的 `ps -W` 的 COMMAND 列**只有映像名、没有完整命令行**，所以换参数是修不好
# 的——判据要拿 worktree 路径去命令行里匹配。Windows 上改走 CIM 查询。
list_process_command_lines() {
  if ps -axo pid=,command= 2>/dev/null; then
    return 0
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    if powershell.exe -NoProfile -NonInteractive -Command \
      'Get-CimInstance Win32_Process | ForEach-Object { "{0} {1}" -f $_.ProcessId, $_.CommandLine }' \
      2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# 返回值：0 = 有活跃构建（命令行打到 stdout）；1 = 没有；2 = **判不了**。
# 2 和 1 必须分开——「查不出来」不等于「没人占用」，这是 DEV-04 的核心教训。
has_active_build() {
  local worktree="$1"
  local normalized_worktree normalized_process processes
  normalized_worktree=$(normalize_for_match "$worktree")

  if ! processes=$(list_process_command_lines); then
    return 2
  fi

  # 这里刻意不用管道：管道会把循环放进子 shell，`return` 就只退出子 shell，
  # 三态里的 0/1 分不出来（原实现靠 stdout 有无内容间接判断，加了「判不了」
  # 这一态之后那样不够用了）。
  while IFS= read -r process; do
    [[ -n "$process" ]] || continue
    normalized_process=$(normalize_for_match "$process")
    case "$normalized_process" in
      *"$normalized_worktree"*)
        case "$normalized_process" in
          *cargo*|*rustc*|*gradle*|*'tauri '*|*'vite '*|*'pnpm '*|*'npm '*)
            printf '%s\n' "$process"
            return 0
            ;;
        esac
        ;;
    esac
  done <<< "$processes"

  return 1
}

worktree_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}' || printf '?'
}

target_size() {
  du -sh "$1/target" 2>/dev/null | awk '{print $1}' || printf '?'
}

# #1490: 0 = some process holds a file open (or has its working directory)
# inside <dir> (paths on stdout); 1 = none; 2 = cannot tell. Same three states
# as has_active_build: not being able to look is not the same as nobody using it.
open_files_under() {
  local dir="$1" listing
  command -v lsof >/dev/null 2>&1 || return 2
  # lsof exits 1 when some process could not be read; the listing is still valid.
  listing=$(lsof -nP -Fn 2>/dev/null) || [[ -n "$listing" ]] || return 2
  listing=$(printf '%s\n' "$listing" | sed -n 's/^n//p' |
    awk -v d="$dir" '$0 == d || index($0, d "/") == 1' | sort -u | head -5)
  [[ -n "$listing" ]] || return 1
  printf '%s\n' "$listing"
  return 0
}

# #1490: runs inside tools/heavy-lock. 0 = swept; 3 = cache in use, skipped;
# 4 = cannot tell whether it is in use, refused; anything else = sweep failed.
locked_sweep() {
  local cache="$1" main_root="$2" days="$3" max="$4" held held_status=0 policy
  shift 4
  held=$(open_files_under "$cache") || held_status=$?
  if [[ $held_status -eq 0 ]]; then
    printf 'SKIP       %s — files open in it (a build is using it); try again later:\n' "$cache"
    printf '%s\n' "$held" | sed 's/^/             /'
    return 3
  elif [[ $held_status -ge 2 ]]; then
    printf 'SKIP       %s — cannot tell whether a build is using it (no usable lsof); refusing to sweep\n' "$cache"
    return 4
  fi
  for policy in "--time $days" "--maxsize $max"; do
    # shellcheck disable=SC2086 # policy is "<flag> <value>" on purpose
    if ! CARGO_TARGET_DIR="$cache" cargo-sweep sweep "$@" $policy "$main_root"; then
      printf 'FAILED     cargo-sweep sweep %s\n' "$policy"
      return 1
    fi
  done
}

worktree_is_removable() {
  local worktree="$1"
  local active

  # DEV-04: 不能用裸字符串相等。同一个目录在 `pwd -P` 和 `git worktree list`
  # 里的写法不同（Windows 上还差大小写：/c/...p-pass vs C:/...P-Pass），于是
  # 这道守卫在 Windows 上永不命中，当前工作树会被列成删除候选。
  # `-ef` 比的是 device+inode，即「是不是同一个文件」——顺带也解决了 macOS
  # 上 /var 与 /private/var 这类符号链接导致的写法差异。
  # `-ef` 要求两边都存在，所以前面加 -d 守一下，并保留字符串相等作为兜底。
  # #1490: .claude/worktrees/* are live Claude Code session directories. Their
  # branch is often pushed and merged (upstream gone) while the session is still
  # open, so the merged test below would delete a session from under itself —
  # it did on 2026-11-06, twice. The app archives them; we only touch them when
  # asked explicitly.
  case "$worktree" in
    */.claude/worktrees/*)
      if ! "$session_worktrees"; then
        printf 'Claude Code session worktree (add --session-worktrees to include)'
        return 1
      fi
      # Even when asked: a session that is still open has its shell (cwd) or
      # files inside the directory. Not being able to look means refusing.
      local held held_status=0
      held=$(open_files_under "$(cd "$worktree" 2>/dev/null && pwd -P || printf '%s' "$worktree")") || held_status=$?
      if [[ $held_status -eq 0 ]]; then
        printf 'Claude Code session worktree in use: %s' "$(printf '%s' "$held" | head -1)"
        return 1
      elif [[ $held_status -ge 2 ]]; then
        printf 'cannot tell whether this session worktree is in use (no usable lsof); refusing to remove'
        return 1
      fi
      ;;
  esac
  if [[ -d "$worktree" && "$worktree" -ef "$current_worktree" ]] ||
    [[ "$worktree" == "$current_worktree" ]]; then
    printf 'current worktree'
    return 1
  fi
  if [[ ! -d "$worktree" ]]; then
    printf 'path is missing'
    return 1
  fi
  if [[ -n $(git -C "$worktree" status --porcelain) ]]; then
    printf 'uncommitted changes'
    return 1
  fi
  if ! git rev-parse --verify --quiet origin/main >/dev/null; then
    printf 'origin/main is unavailable'
    return 1
  fi
  # DEV-03: "merged" cannot be decided by ancestry alone. This repo merges
  # every PR with Squash and merge, which rewrites the branch into a single
  # new commit on main — the worktree's own commits are therefore NEVER
  # ancestors of origin/main, and an ancestry-only test rejects every
  # squash-merged worktree forever. Measured: two fully merged branches were
  # still reported as unmerged by this check.
  #
  # Second accepted signal: the upstream branch is gone from the remote.
  # GitHub deletes the head branch when a PR merges, so "upstream configured
  # but no longer on the remote" means merged-and-cleaned-up. It requires a
  # pruned remote to be accurate, hence the fetch --prune below.
  if ! git -C "$worktree" merge-base --is-ancestor HEAD origin/main; then
    upstream=$(git -C "$worktree" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    if [[ -z "$upstream" ]]; then
      printf 'HEAD is neither merged into origin/main nor tracking an upstream'
      return 1
    fi
    if git rev-parse --verify --quiet "$upstream" >/dev/null; then
      printf 'HEAD is not merged into origin/main (upstream %s still exists)' "$upstream"
      return 1
    fi
  fi
  # DEV-04: 三态。`|| probe_status=$?` 是必需的——`set -e` 下命令替换失败
  # 会直接中断脚本。
  local probe_status=0
  active=$(has_active_build "$worktree") || probe_status=$?
  if [[ $probe_status -ge 2 ]]; then
    # fail-closed：查不出来不等于没人占用。
    printf 'cannot tell whether a build is running here (no usable process listing); refusing to remove'
    return 1
  fi
  if [[ -n "$active" ]]; then
    printf 'active build: %s' "$active"
    return 1
  fi
  return 0
}

printf 'Repository: %s\n' "$repo_root"
if "$apply"; then
  printf 'Mode: APPLY (explicit deletion enabled)\n'
else
  printf 'Mode: PREVIEW (nothing will be deleted)\n'
fi

worktrees=()
while IFS= read -r worktree; do
  [[ -n "$worktree" ]] && worktrees+=("$worktree")
done < <(mapfile_worktrees)

if "$clean_worktrees"; then
  printf '\n== Worktrees ==\n'
  for worktree in "${worktrees[@]}"; do
    if reason=$(worktree_is_removable "$worktree"); then
      printf 'CANDIDATE  %s (%s)\n' "$worktree" "$(worktree_size "$worktree")"
      if "$apply"; then
        # --force: our own worktree_is_removable() already verified no
        # uncommitted tracked changes and HEAD merged into origin/main.
        # Without --force, `git worktree remove` still refuses whenever
        # gitignored build cruft (.DS_Store, .gradle/, target/, build/)
        # is present — which is the normal case for every worktree that
        # ever ran a build. That's not an unsafety signal; it's noise.
        git worktree remove --force "$worktree"
        printf 'REMOVED    %s\n' "$worktree"
      fi
    else
      printf 'SKIP       %s — %s\n' "$worktree" "$reason"
    fi
  done
fi

if "$clean_targets"; then
  printf '\n== Build caches ==\n'
  for worktree in "${worktrees[@]}"; do
    [[ -d "$worktree" ]] || continue  # A selected worktree may have just gone away.
    # #1490: same rule as --worktrees — a live session may be building there
    # with a relative command line that has_active_build cannot attribute.
    case "$worktree" in
      */.claude/worktrees/*)
        if ! "$session_worktrees"; then
          printf 'SKIP       %s — Claude Code session worktree (add --session-worktrees to include)\n' "$worktree"
          continue
        fi
        held_status=0
        held=$(open_files_under "$(cd "$worktree" && pwd -P)") || held_status=$?
        if [[ $held_status -eq 0 ]]; then
          printf 'SKIP       %s — Claude Code session worktree in use: %s\n' "$worktree" "$(printf '%s' "$held" | head -1)"
          continue
        elif [[ $held_status -ge 2 ]]; then
          printf 'SKIP       %s — cannot tell whether this session worktree is in use (no usable lsof)\n' "$worktree"
          continue
        fi
        ;;
    esac

    active=$(has_active_build "$worktree" || true)
    if [[ -n "$active" ]]; then
      printf 'SKIP       %s — active build: %s\n' "$worktree" "$active"
      continue
    fi

    # DEV-03: the old code looked at "$worktree/target" and nothing else, so
    # every nested Cargo target was invisible. Measured in this repo: the root
    # target reported 18G while apps/desktop/src-tauri/target held another
    # 2.6G that no preview ever mentioned.
    #
    # Discovery rule: a directory named `target` whose *parent* holds a
    # Cargo.toml. That is precisely what a Cargo output directory is, so it
    # neither misses one nor sweeps up an unrelated source directory that
    # happens to be called `target`.
    #
    # Rejected alternative — matching CACHEDIR.TAG, the marker Cargo writes
    # into target dirs: measured in this repo, the 18G root target has no
    # CACHEDIR.TAG at all while the 2.6G desktop one does, so that rule
    # silently drops the single largest directory. A marker that is only
    # usually present is worse than no marker, because the failure is a
    # quiet under-report rather than an error.
    found_any=false
    while IFS= read -r target; do
      # 同级 Cargo.toml（Cargo target 的定义）或目录内 CACHEDIR.TAG（Cargo
      # 自己写的标记）任一成立即认。两个都要求会漏报——实测本仓 18G 的根
      # target 就没有 CACHEDIR.TAG；只认后者会把最大的那个整个漏掉。
      [[ -f "$(dirname "$target")/Cargo.toml" || -f "$target/CACHEDIR.TAG" ]] || continue
      found_any=true
      if [[ -L "$target" ]]; then
        printf 'SKIP       %s — target/ is a symlink\n' "$target"
        continue
      fi
      printf 'CANDIDATE  %s (%s)\n' "$target" "$(du -sh "$target" 2>/dev/null | awk '{print $1}')"
      if "$apply"; then
        rm -rf "$target"
        printf 'REMOVED    %s\n' "$target"
      fi
    # #1490: prune .claude/worktrees — session worktrees nest inside the main
    # checkout and are handled (or skipped) as registered worktrees of their own.
    done < <(find "$worktree" \( -type d -name node_modules -o -type d -name .git \
                  -o -type d -path '*/.claude/worktrees' \) -prune -o \
                  -type d -name target -print 2>/dev/null | sort)

    "$found_any" || printf 'ABSENT     %s — no Cargo target directory\n' "$worktree"
  done
fi

# #1490: the shared Cargo cache (CARGO_TARGET_DIR from .env.ppass-dev). Before
# this, nothing here ever looked at it: the cleanup only knew <worktree>/target,
# so the one directory that actually grows (104G on 2026-11-06) was invisible.
shared_cache_dir() {
  local dir
  dir=$(dev_cache_value CARGO_TARGET_DIR "$repo_root")
  [[ -n "$dir" ]] || dir="${CARGO_TARGET_DIR:-}"
  [[ -n "$dir" && -d "$dir" ]] || return 1
  (cd "$dir" && pwd -P)
}

free_space() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%.1fG", $4 / 1024 / 1024}'
}

cache_failed=false
if "$clean_cache" || "$preview_cache_location"; then
  printf '\n== Shared Cargo cache ==\n'
  if ! cache=$(shared_cache_dir); then
    printf 'ABSENT     no shared cache configured (%s has no CARGO_TARGET_DIR)\n' \
      "$(dev_cache_env_file "$repo_root" 2>/dev/null || printf '.env.ppass-dev')"
  elif ! "$clean_cache"; then
    printf 'CACHE      %s (preview and sweep it with --cache)\n' "$cache"
  elif ! command -v cargo-sweep >/dev/null 2>&1; then
    # Never fall back to rm -rf: the cache is shared by every session on this
    # machine, and cargo-sweep is what knows which artifacts are stale.
    printf 'SKIP       %s — cargo-sweep is not installed; run: cargo install cargo-sweep --locked\n' "$cache"
    "$apply" && cache_failed=true
  else
    main_root=$(dev_cache_main_root "$repo_root")
    sweep_args=()
    "$apply" || sweep_args+=(--dry-run)
    printf 'CACHE      %s (free before: %s)\n' "$cache" "$(free_space "$cache")"
    # Check-then-sweep runs inside ONE hold of the heavy-build lock (#1308):
    # checking first and queueing for the lock afterwards would let a build
    # that starts while we wait (up to PPASS_HEAVY_LOCK_WAIT) slip past the
    # check and have its artifacts swept from under it.
    export -f open_files_under locked_sweep
    sweep_status=0
    "$script_dir/heavy-lock" bash -c 'locked_sweep "$@"' locked_sweep \
      "$cache" "$main_root" "$cache_days" "$cache_max" ${sweep_args[@]+"${sweep_args[@]}"} || sweep_status=$?
    case $sweep_status in
      0) "$apply" && printf 'SWEPT      %s (free after: %s)\n' "$cache" "$(free_space "$cache")" ;;
      3) ;;  # in use: skipped, try again later; not a failure
      4) "$apply" && cache_failed=true ;;  # cannot tell: refusing is a failure only when deleting
      *) cache_failed=true ;;  # cargo-sweep or the lock failed: a failed dry run is a failure too
    esac
  fi
fi

if ! "$apply"; then
  printf '\nPreview only. Re-run with --apply and an explicit scope to delete.\n'
fi
if "$cache_failed"; then
  exit 1
fi
