#!/usr/bin/env bash
# #1991 / #1997：四端零引用死词条秒级静态门禁反证自测。
#
#   tools/test-check-dead-i18n.sh
#
# 验证：
#   1. check-dead-i18n.py --self-test 自身自带的全套反证通过；
#   2. 注入各端死词条时必须报红，还原后恢复绿。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# 1. 执行内置反证自测
out=$(python3 "$ROOT/tools/check-dead-i18n.py" --self-test 2>&1) || {
    fail "check-dead-i18n.py --self-test 失败：$out"
    exit 1
}
pass "check-dead-i18n.py --self-test 通过"

# 2. 扫描真实仓库（全仓死词条清零）
out=$(python3 "$ROOT/tools/check-dead-i18n.py" 2>&1) || {
    fail "check-dead-i18n.py 扫描失败：$out"
    exit 1
}
pass "当前仓库扫描全绿通过"

if [ "$fails" -eq 0 ]; then
    echo "ok: 四端死词条扫描门禁自测通过"
    exit 0
else
    echo "✗ $fails 项测试失败" >&2
    exit 1
fi
