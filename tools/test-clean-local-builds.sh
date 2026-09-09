#!/usr/bin/env bash
# Integration test for tools/clean-local-builds.sh; operates only in a temp repo.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cleanup_script="$script_dir/clean-local-builds.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ppass-clean-local.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

remote="$tmp/remote.git"
repo="$tmp/repo"

git init --bare "$remote" >/dev/null
git clone "$remote" "$repo" >/dev/null
git -C "$repo" config user.name 'P-Pass test'
git -C "$repo" config user.email 'test@example.invalid'
printf 'fixture\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m 'fixture' >/dev/null
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
git -C "$repo/.worktrees/pending" commit -m 'pending' >/dev/null

# Default mode is a non-destructive preview.
preview=$(cd "$repo" && bash "$cleanup_script")
[[ "$preview" == *'Mode: PREVIEW'* ]]
[[ -d "$repo/target" ]]
[[ -d "$repo/.worktrees/merged/target" ]]

# Explicit cache cleanup does not remove any worktree source directory.
(cd "$repo" && bash "$cleanup_script" --apply --targets >/dev/null)
[[ ! -e "$repo/target" ]]
[[ ! -e "$repo/.worktrees/merged/target" ]]
[[ -d "$repo/.worktrees/merged" ]]
[[ -d "$repo/.worktrees/dirty" ]]
[[ -d "$repo/.worktrees/pending" ]]

# A process whose command line represents a build in this worktree blocks removal.
mkdir -p "$repo/.worktrees/active/target"
python3 -c 'import time; time.sleep(30)' "$repo/.worktrees/active" 'cargo build' &
active_pid=$!
trap 'kill "$active_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
sleep 1

worktree_apply=$(cd "$repo" && bash "$cleanup_script" --apply --worktrees)
[[ "$worktree_apply" == *"REMOVED    $repo/.worktrees/merged"* ]]
[[ ! -d "$repo/.worktrees/merged" ]]
[[ -d "$repo/.worktrees/dirty" ]]
[[ -f "$repo/.worktrees/dirty/DIRTY" ]]
[[ -d "$repo/.worktrees/pending" ]]
[[ -f "$repo/.worktrees/pending/PENDING" ]]
[[ -d "$repo/.worktrees/active" ]]
[[ -d "$repo/.worktrees/active/target" ]]
[[ "$worktree_apply" == *"SKIP       $repo/.worktrees/pending — HEAD is not merged into origin/main"* ]]
[[ "$worktree_apply" == *"SKIP       $repo/.worktrees/active — active build:"* ]]

kill "$active_pid"
wait "$active_pid" 2>/dev/null || true
trap 'rm -rf "$tmp"' EXIT

printf 'ok: clean-local-builds safety integration test\n'
