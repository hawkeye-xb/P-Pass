#!/usr/bin/env bash
# CI-11 (#255): 判定一次改动要不要跑「重型门禁」（Rust 全量 / 桌面壳）。
#
# ## 为什么需要它
#
# `ci-rust` 与 `ci-desktop` 的 `pull_request` **刻意不设 paths**（CI-07 #189）：
# 它们的检查在 `main` 的必需列表里，而被 `paths` 跳过的 workflow **根本不汇报
# 状态**，必需检查会永久 Pending 把 PR 挡死。代价是纯文档 PR 也会整条跑。
#
# 出路是把「要不要干活」从 workflow 触发层下放到 **job 层**：被 `if:` 跳过的
# job **会汇报 `skipped`，而 `skipped` 对必需检查算通过**（PR #260 实测：
# 给必需检查 `architecture enforcement` 加 `if: false`，PR 仍然 CLEAN）。
#
# ## 口径：allowlist，不是 blocklist —— 这是本脚本的全部要害
#
# 朴素写法是「改了 crates/ 才跑」。那是 **fail-open**：漏一个路径 = 静默放行，
# 而且报绿。本仓这一轮修的缺陷（#189 的 paths 错位、#192 的 python3 假成功）
# 全是这个形状。
#
# 这里**反过来**：**只有当每一个改动文件都落在无害清单里，才判「可跳过」。**
# 漏一个路径 = 多跑一次（浪费几分钟），**错误方向是 fail-closed**。
#
# ## 用法
#   tools/ci-needs-full-lane.sh <base-sha>   # 与 base 做 diff
#   printf 'a\nb\n' | tools/ci-needs-full-lane.sh -   # 从 stdin 读（测试用）
#
# stdout 恒为一行 `true` / `false`（true = 要跑）。理由写 stderr。
# **退出码恒为 0** —— 判定本身不该让调用方失败；任何异常都走「判 true」。

set -uo pipefail

# ── 无害清单 ───────────────────────────────────────────────────────────
# 每一条都必须先证明它对 Rust / 桌面壳 lane 是惰性的，再往里加。
# 2026-09-20 的核实依据（grep 全仓 .rs 与 tools/arch-check.sh）：
#   docs/ cards/ .claude/  没有任何 Rust 代码或门禁脚本读取它们
#                          （唯一命中是 core-index/src/ingest.rs:182 的一句
#                            注释里提到 docs 路径，不是读取）
#   *.md                   任何位置的 markdown 都不参与编译
# ⚠️ 往这里加东西之前先问：有没有测试/构建脚本会读它？读了就不能加。
# ⚠️ assets/i18n/** 被 diag 的 keys 测试消费，**绝不能**加进来。
is_inert() {
  case "$1" in
    docs/* | cards/* | .claude/*) return 0 ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
}

say() { printf '%s\n' "$*" >&2; }

list_changed_files() {
  if [ "${1:-}" = "-" ]; then
    cat
    return 0
  fi
  base="${1:-}"
  if [ -z "$base" ]; then
    return 1
  fi
  git diff --name-only "$base...HEAD" 2>/dev/null
}

main() {
  if ! files="$(list_changed_files "$@")"; then
    say "取不到改动文件列表（没给 base，或 git diff 失败）→ 保守判定：要跑"
    printf 'true\n'
    return 0
  fi

  # 空列表说明我们没搞清楚发生了什么（浅 clone / force push / base 变了），
  # 不是「什么都没改」。一律判要跑。
  case "$files" in
    *[![:space:]]*) : ;;
    *)
      say "改动文件列表为空 → 说明没搞清状况，保守判定：要跑"
      printf 'true\n'
      return 0
      ;;
  esac

  # 用 here-string 而不是管道：管道会开子 shell，里面的 return 出不来
  # （tools/clean-local-builds.sh 在 DEV-04 #192 栽过同一个跟头）。
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! is_inert "$f"; then
      say "「$f」不在无害清单里 → 要跑"
      printf 'true\n'
      return 0
    fi
  done <<EOF
$files
EOF

  say "全部改动都落在无害清单里 → 可跳过"
  printf 'false\n'
  return 0
}

main "$@"
