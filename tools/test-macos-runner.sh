#!/usr/bin/env bash
# #1477：workflow 里不得再用已停用或会漂移的 macOS runner（macos-14、macos-15、macos-latest）。
# 依据：docs/decisions/2026-11-06-macos-runner-26.md（全仓统一 macos-26）。
# 判据：只看 runs-on 行。反证：造一份写着旧 runner 的样例，判据必须报红。
#
# 用法: tools/test-macos-runner.sh
# 退出码: 0 全过 / 1 有失败
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WF="$HERE/../.github/workflows"
BAD='^[[:space:]]*runs-on:[[:space:]]*"?macos-(14|15|latest)\b'
fail=0
ok() { echo "  ✅ $1"; }
ko() { echo "  ❌ $1"; fail=1; }

# 返回命中旧 runner 的行（有输出即红）
scan() { grep -nE "$BAD" "$@" 2>/dev/null; }

# 反证：样例写旧 runner，必须被判红；写 macos-26 必须不红
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for old in macos-14 macos-15 macos-latest; do
  printf 'jobs:\n  a:\n    runs-on: %s\n' "$old" > "$tmp/bad.yml"
  [ -n "$(scan "$tmp/bad.yml")" ] && ok "反证：$old 判红" || ko "反证失败：$old 没被判红"
done
printf 'jobs:\n  a:\n    runs-on: macos-26 # x\n' > "$tmp/good.yml"
[ -z "$(scan "$tmp/good.yml")" ] && ok "macos-26 不红" || ko "macos-26 被误判"

# 真实检查
hits="$(scan "$WF"/*.yml)"
if [ -z "$hits" ]; then ok "workflows 里没有 macos-14/15/latest"; else ko "仍有旧 runner："; echo "$hits"; fi

n="$(grep -hcE '^[[:space:]]*runs-on:[[:space:]]*"?macos-26\b' "$WF"/*.yml | paste -sd+ - | bc)"
[ "${n:-0}" -ge 5 ] && ok "macos-26 共 $n 处（≥5）" || ko "macos-26 只有 ${n:-0} 处，预期 ≥5"

[ "$fail" -eq 0 ] && echo "macos-runner: all passed" || { echo "macos-runner: FAILED"; exit 1; }
