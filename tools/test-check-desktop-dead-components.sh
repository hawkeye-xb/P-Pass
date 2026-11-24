#!/usr/bin/env bash
# #1991 / #1997：桌面前端未挂载死组件门禁反证自测。
#
#   tools/test-check-desktop-dead-components.sh
#
# 验证：
#   1. check-desktop-dead-components.py --self-test 自身自带的全套反证通过（包括仅被测试 import 的死组件与完全孤立的死组件）；
#   2. 正常无死组件时通过。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

out=$(python3 "$ROOT/tools/check-desktop-dead-components.py" --self-test 2>&1) || {
    fail "check-desktop-dead-components.py --self-test 失败：$out"
    exit 1
}
pass "check-desktop-dead-components.py --self-test 通过"

out=$(python3 "$ROOT/tools/check-desktop-dead-components.py" 2>&1) || {
    fail "check-desktop-dead-components.py 扫描失败：$out"
    exit 1
}
pass "当前仓库扫描全绿通过"

if [ "$fails" -eq 0 ]; then
    echo "ok: 桌面前端未挂载死组件门禁自测通过"
    exit 0
else
    echo "✗ $fails 项测试失败" >&2
    exit 1
fi
