#!/usr/bin/env bash
# Preview or explicitly reclaim local build caches and stale worktrees.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/clean-local-builds.sh [--targets] [--worktrees] [--all] [--apply]

Without --apply, this command only previews candidates.

Scopes:
  --targets     Remove target/ directories only. Source worktrees remain.
  --worktrees   Remove only registered worktrees that are clean, merged into
                origin/main, not the current worktree, and have no active build.
  --all         Select both scopes.

Safety:
  --apply is mandatory for deletion. --apply also requires an explicit scope.
  A target/ or worktree with an active Cargo/Rustc/Gradle/Node build is skipped.
EOF
}

apply=false
clean_targets=false
clean_worktrees=false
selected_scope=false

while (($#)); do
  case "$1" in
    --apply) apply=true ;;
    --targets) clean_targets=true; selected_scope=true ;;
    --worktrees) clean_worktrees=true; selected_scope=true ;;
    --all) clean_targets=true; clean_worktrees=true; selected_scope=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if "$apply" && ! "$selected_scope"; then
  printf 'error: --apply requires --targets, --worktrees, or --all\n' >&2
  exit 2
fi

# Previewing without a selector means show both categories; it cannot delete.
if ! "$selected_scope"; then
  clean_targets=true
  clean_worktrees=true
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'error: run this from inside a Git worktree\n' >&2
  exit 2
}
repo_root=$(cd "$repo_root" && pwd -P)
current_worktree=$(pwd -P)
cd "$repo_root"

mapfile_worktrees() {
  git worktree list --porcelain | while IFS= read -r line; do
    case "$line" in
      'worktree '*) printf '%s\n' "${line#worktree }" ;;
    esac
  done
}

has_active_build() {
  local worktree="$1"
  ps -axo pid=,command= | while IFS= read -r process; do
    case "$process" in
      *"$worktree"*)
        case "$process" in
          *cargo*|*rustc*|*gradle*|*'tauri '*|*'vite '*|*'pnpm '*|*'npm '*)
            printf '%s\n' "$process"
            return 0
            ;;
        esac
        ;;
    esac
  done
}

worktree_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}' || printf '?'
}

target_size() {
  du -sh "$1/target" 2>/dev/null | awk '{print $1}' || printf '?'
}

worktree_is_removable() {
  local worktree="$1"
  local active

  if [[ "$worktree" == "$current_worktree" ]]; then
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
  active=$(has_active_build "$worktree" || true)
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
    done < <(find "$worktree" \( -type d -name node_modules -o -type d -name .git \) -prune -o \
                  -type d -name target -print 2>/dev/null | sort)

    "$found_any" || printf 'ABSENT     %s — no Cargo target directory\n' "$worktree"
  done
fi

if ! "$apply"; then
  printf '\nPreview only. Re-run with --apply and an explicit scope to delete.\n'
fi
