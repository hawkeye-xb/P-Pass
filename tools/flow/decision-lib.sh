#!/usr/bin/env bash
# shellcheck shell=bash
# 「已采纳」方案（docs/decisions/）的解析：owner（owner-lib.sh）与 worker（worker-lib.sh）共用这一份，
# 两边判据不许各写一套。只被 source，不单独执行。只用 git / grep / sort（worker 测试的 PATH 白名单）。

# 文本里引用的方案文件路径（docs/decisions/YYYY-MM-DD-*.md，一行一个，去重）。
decision_refs() {
  printf '%s\n' "$1" | grep -oE 'docs/decisions/[0-9]{4}-[0-9]{2}-[0-9]{2}-[A-Za-z0-9._-]+\.md' | sort -u
}

# 文本引用的、在 origin/main 上状态为「已采纳」的方案（一行一个路径）。
adopted_adrs() {
  local p
  for p in $(decision_refs "$1"); do
    # Git Bash 会把 origin/main:<path> 的冒号当路径分隔符改写；禁止 MSYS 做路径转换。
    MSYS_NO_PATHCONV=1 git show "origin/main:${p}" 2>/dev/null | grep -qE '^[-*][[:space:]]*状态(：|:)[[:space:]]*已采纳' &&
      printf '%s\n' "$p"
  done
}
