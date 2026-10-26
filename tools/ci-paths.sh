#!/usr/bin/env bash
# #1187：按改动路径做两种判定，给 CI 的 changes job 与核心审批用。
#
#   tools/ci-paths.sh hit  <base-sha|-> <glob>...         改动里有没有文件命中任一 glob
#   tools/ci-paths.sh core <base-sha|-> [规则文件]          改动有没有碰核心（默认 .github/core-paths.txt）
#
# base 传 `-` 时从 stdin 读改动文件列表（测试用）；否则取 `git diff --name-only <base>...HEAD`。
# stdout 恒为一行 `true` / `false`（true = 要跑 / 碰了核心）。理由写 stderr。
# **退出码恒为 0**，任何异常都判 true（fail-closed），与 tools/ci-needs-full-lane.sh 同一口径：
# 判错方向的代价是多跑一次，而不是静默放行。
#
# ## glob 语法（与 GitHub Actions 的 paths 一致）
#   `**` 跨目录，`*` 与 `?` 不跨 `/`。`dir/**` 匹配 dir 下全部文件。
#
# ## 核心规则文件（.github/core-paths.txt）
#   + <glob>   命中即核心
#   zone <glob> 必审区：区内文件默认是核心……
#   - <glob>   ……除非命中这里（只对 zone 生效，压不过 +）
#   一个文件是核心 ⇔ 命中任一 `+`，或（命中任一 zone 且不命中任一 `-`）。
#   必审区反着写的原因：新加的文件不用记得登记就自动受审；漏写 `-` 的代价只是多批一次。

set -uo pipefail

say() { printf '%s\n' "$*" >&2; }

# glob → 扩展正则（锚定全串）。
glob_re() {
  printf '%s' "$1" | sed -e 's/[.+^$(){}|\\[]/\\&/g' \
    -e 's#\*\*/#@DSS@#g' -e 's#\*\*#@DS@#g' \
    -e 's#\*#[^/]*#g' -e 's#?#[^/]#g' \
    -e 's#@DSS@#(.*/)?#g' -e 's#@DS@#.*#g' |
    sed -e 's/^/^/' -e 's/$/$/'
}

# 规则在读入时就编译成正则（glob_re 要起 sed），逐文件匹配只用 bash 内置的 =~，
# 否则全仓几千个文件 × 几十条规则要起几十万个进程。
matches() { # matches <file> <已编译的正则>
  [[ $1 =~ $2 ]]
}

list_changed_files() {
  if [ "${1:-}" = "-" ]; then
    cat
    return 0
  fi
  [ -n "${1:-}" ] || return 1
  case "$1" in
    0000000000000000000000000000000000000000) return 1 ;;
  esac
  git diff --name-only "$1...HEAD" 2>/dev/null
}

# 取改动列表；取不到或为空都判 true（空列表说明没搞清状况，不是「什么都没改」）。
load_files() {
  if ! FILES="$(list_changed_files "${1:-}")"; then
    say "取不到改动文件列表（没给 base、新分支或 git diff 失败）→ 保守判定：true"
    return 1
  fi
  case "$FILES" in
    *[![:space:]]*) return 0 ;;
  esac
  say "改动文件列表为空 → 保守判定：true"
  return 1
}

cmd_hit() {
  local base="${1:-}"
  shift || true
  if [ "$#" -eq 0 ]; then
    say "没给 glob → 保守判定：true"
    echo true
    return 0
  fi
  load_files "$base" || { echo true; return 0; }
  local f g
  RES=()
  for g in "$@"; do RES+=("$(glob_re "$g")"); done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for g in "${RES[@]}"; do
      if matches "$f" "$g"; then
        say "「${f}」命中「${g}」→ true"
        echo true
        return 0
      fi
    done
  done <<EOF
$FILES
EOF
  say "没有改动命中给定路径 → false"
  echo false
}

is_core() { # is_core <file>；规则已读进 PLUS / ZONE / MINUS
  local g
  for g in "${PLUS[@]+"${PLUS[@]}"}"; do
    matches "$1" "$g" && { WHY="+ ${g}"; return 0; }
  done
  for g in "${ZONE[@]+"${ZONE[@]}"}"; do
    if matches "$1" "$g"; then
      local m
      for m in "${MINUS[@]+"${MINUS[@]}"}"; do
        matches "$1" "$m" && return 1
      done
      WHY="zone ${g}"
      return 0
    fi
  done
  return 1
}

cmd_core() {
  local base="${1:-}"
  local rules="${2:-$(cd "$(dirname "$0")/.." && pwd)/.github/core-paths.txt}"
  PLUS=()
  ZONE=()
  MINUS=()
  if [ ! -r "$rules" ]; then
    say "读不到规则文件「${rules}」→ 保守判定：true"
    echo true
    return 0
  fi
  local line kind pat
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    read -r kind pat <<<"$line" || true
    [ -n "${kind:-}" ] || continue
    case "$kind" in
      +) PLUS+=("$(glob_re "$pat")") ;;
      zone) ZONE+=("$(glob_re "$pat")") ;;
      -) MINUS+=("$(glob_re "$pat")") ;;
      *)
        say "规则文件里有看不懂的行「${line}」→ 保守判定：true"
        echo true
        return 0
        ;;
    esac
  done <"$rules"
  if [ "${#PLUS[@]}" -eq 0 ] && [ "${#ZONE[@]}" -eq 0 ]; then
    say "规则文件里没有任何 + / zone → 保守判定：true"
    echo true
    return 0
  fi
  load_files "$base" || { echo true; return 0; }
  local f hit=false
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_core "$f"; then
      say "核心：${f}（${WHY}）"
      hit=true
    fi
  done <<EOF
$FILES
EOF
  [ "$hit" = true ] || say "没有碰核心 → false"
  echo "$hit"
}

case "${1:-}" in
  hit) shift; cmd_hit "$@" ;;
  core) shift; cmd_core "$@" ;;
  *)
    say "用法: tools/ci-paths.sh hit <base|-> <glob>... | core <base|-> [规则文件]（未知子命令 → true）"
    echo true
    ;;
esac
exit 0
