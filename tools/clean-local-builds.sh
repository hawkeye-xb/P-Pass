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
  if ! git -C "$worktree" merge-base --is-ancestor HEAD origin/main; then
    printf 'HEAD is not merged into origin/main'
    return 1
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
    target="$worktree/target"
    [[ -d "$worktree" ]] || continue  # A selected worktree may have just gone away.
    if [[ ! -e "$target" ]]; then
      printf 'ABSENT     %s\n' "$target"
      continue
    fi
    if [[ -L "$target" ]]; then
      printf 'SKIP       %s — target/ is a symlink\n' "$target"
      continue
    fi
    active=$(has_active_build "$worktree" || true)
    if [[ -n "$active" ]]; then
      printf 'SKIP       %s — active build: %s\n' "$target" "$active"
      continue
    fi
    printf 'CANDIDATE  %s (%s)\n' "$target" "$(target_size "$worktree")"
    if "$apply"; then
      rm -rf "$target"
      printf 'REMOVED    %s\n' "$target"
    fi
  done
fi

if ! "$apply"; then
  printf '\nPreview only. Re-run with --apply and an explicit scope to delete.\n'
fi
