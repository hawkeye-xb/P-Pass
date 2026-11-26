#!/usr/bin/env bash
# shellcheck shell=bash
# 「已采纳」方案（docs/decisions/）的解析：acceptance-gate.sh 与 repo-lib.sh 共用这一份，
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

# 跨脚本唯一真源：flow.py 与 acceptance-gate.sh 共用的多语言假测试检测规则（JSON）。
fake_src_read_spec() {
  cat <<'FAKE_SRC_SPEC'
{
  "ext": "\\.(?:rs|kt|swift|svelte)(?![A-Za-z0-9_])",
  "py_read_text": "\\.(?:rs|kt|swift|svelte)(?![A-Za-z0-9_])(?:[^\\n;=()]{0,100}\\.?|\\s*\\)\\s*(?:\\n[ \\t]*)?\\.)read_(?:text|bytes)\\b|\\.(?:rs|kt|swift|svelte)\\b[^\\n]{0,120}read_text",
  "call_head": "\\b(?:open|(?:fs\\s*\\.\\s*promises\\s*\\.\\s*)?readFile(?:Sync)?|Files\\.(?:readString|readAllLines)|(?:(?:std::)?fs::)?read_to_string|include_str!)\\s*\\(|\\b(?:NS)?(?:String|Data)(?:\\.init)?\\s*\\(\\s*contentsOf(?:File)?\\s*:|\\.contents\\s*\\(\\s*atPath\\s*:",
  "path_ctor_head": "\\b(?:(?:java\\.io\\.)?File|Path)\\s*\\(",
  "path_read_meth": "\\.(?:readText|readBytes|readLines|read_text|read_bytes)\\b",
  "cross_end_allowlist": {
    "crates/daemon/tests/flow_health.rs": ["FlowContract.kt", "FlowTypes.swift"]
  }
}
FAKE_SRC_SPEC
}
