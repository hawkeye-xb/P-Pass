#!/usr/bin/env bash
# #773：正式 tag 的 Release 正文要以 CHANGELOG 本版小节开头（docs/RELEASING.md §3 第 5 步）。
#
# 用法：tools/release/changelog-section.sh <tag> <输出文件> [CHANGELOG 路径，默认 CHANGELOG.md]
#   正式 tag v<批次号>：从 CHANGELOG 取 `## [<批次号>]` 标题下、到下一个 `## [` 为止的全文，写成
#       ## 本版更新（<批次号>）
#
#       <小节全文>
#
#       ---
#
#   （后面接构建台账）。
#   test tag（含 `-test.`）：写空文件——test 版没有 CHANGELOG 小节，正文保持原样。
#   正式 tag 但 CHANGELOG 没有该节或该节为空：写空文件 + ::warning::，退出码 0（不阻断发布）。
set -euo pipefail

TAG="$1"; OUT="$2"; CHANGELOG="${3:-CHANGELOG.md}"
: > "$OUT"

case "$TAG" in
  *-test.*) exit 0 ;;
esac

BATCH="${TAG#v}"
SECTION=""
if [ -f "$CHANGELOG" ]; then
  # 标题行形如 `## [2026.10.3] - 2026-10-09`；批次号按字面匹配（点号不当正则）。
  # 去掉小节首尾的空行（纯 awk：GNU / BSD sed 的多行写法不通用）。
  SECTION="$(awk -v head="## [$BATCH]" '
    index($0, head) == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on { lines[++n] = $0 }
    END {
      s = 1; while (s <= n && lines[s] ~ /^[[:space:]]*$/) s++
      e = n; while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print lines[i]
    }
  ' "$CHANGELOG")"
fi

if [ -z "$SECTION" ]; then
  echo "::warning::CHANGELOG 里没有 [$BATCH] 小节（或为空）——Release 正文只有构建台账。发布前补上 CHANGELOG 再重跑，或手工编辑正文。"
  exit 0
fi

{
  printf '## 本版更新（%s）\n\n' "$BATCH"
  printf '%s\n\n' "$SECTION"
  printf -- '---\n\n'
} > "$OUT"
echo "Release 正文开头：CHANGELOG [$BATCH] 小节（$(printf '%s\n' "$SECTION" | wc -l | tr -d ' ') 行）"
