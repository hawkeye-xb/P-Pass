#!/usr/bin/env bash
# #1990-2：跨端业务规则抽象——双端共用 JSON 真值表静态门禁
# 确保：
# 1. assets/contracts/ui-state-truth-table.json 存在且是合法 JSON；
# 2. Android 存在对账单测且引用了该 JSON；
# 3. iOS 存在对账单测且引用了该 JSON；
# 4. iOS 宿主测试清单 tools/ios/host-only-tests.txt 已登记对账单测。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

check() {
  local target_root="$1"
  local json_file="$target_root/assets/contracts/ui-state-truth-table.json"
  local android_test="$target_root/apps/android/app/src/test/java/com/hawkeyexb/ppass/ui/CrossPlatformUiStateTruthTableTest.kt"
  local ios_test="$target_root/apps/ios/PPassTests/CrossPlatformUiStateTruthTableTests.swift"
  local host_list="$target_root/tools/ios/host-only-tests.txt"

  if [ ! -f "$json_file" ]; then
    echo "✗ 缺少共用真值表：$json_file" >&2
    return 1
  fi

  python3 -c "
import json, sys
try:
    with open('$json_file', 'r', encoding='utf-8') as f:
        data = json.load(f)
    required_keys = [
        'connection_states',
        'photos_guides',
        'scope_access_policies',
        'initial_scope_times',
        'hero_idle_line_colors',
        'hero_from_today_empties'
    ]
    for k in required_keys:
        if k not in data or not isinstance(data[k], list) or len(data[k]) == 0:
            sys.exit(f'ui-state-truth-table.json 缺少非空数组段落: {k}')
except Exception as e:
    sys.exit(f'ui-state-truth-table.json 格式非法: {e}')
" || return 1

  if [ ! -f "$android_test" ]; then
    echo "✗ 缺少 Android 对账单测：$android_test" >&2
    return 1
  fi
  if ! grep -q 'assets/contracts/ui-state-truth-table.json' "$android_test"; then
    echo "✗ Android 对账单测未引用 ui-state-truth-table.json" >&2
    return 1
  fi

  if [ ! -f "$ios_test" ]; then
    echo "✗ 缺少 iOS 对账单测：$ios_test" >&2
    return 1
  fi
  if ! grep -q 'assets/contracts/ui-state-truth-table.json' "$ios_test"; then
    echo "✗ iOS 对账单测未引用 ui-state-truth-table.json" >&2
    return 1
  fi

  if [ ! -f "$host_list" ]; then
    echo "✗ 缺少 iOS 宿主测试清单：$host_list" >&2
    return 1
  fi
  if ! grep -q '^CrossPlatformUiStateTruthTableTests$' "$host_list"; then
    echo "✗ tools/ios/host-only-tests.txt 未登记 CrossPlatformUiStateTruthTableTests" >&2
    return 1
  fi

  echo "ok: 双端共用 UI 状态真值表与对账单测存在且一致"
}

if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  mkdir -p "$TMP/assets/contracts" "$TMP/apps/android/app/src/test/java/com/hawkeyexb/ppass/ui" "$TMP/apps/ios/PPassTests" "$TMP/tools/ios"
  cat <<'EOF' > "$TMP/assets/contracts/ui-state-truth-table.json"
{
  "connection_states": [{}],
  "photos_guides": [{}],
  "scope_access_policies": [{}],
  "initial_scope_times": [{}],
  "hero_idle_line_colors": [{}],
  "hero_from_today_empties": [{}]
}
EOF
  echo 'val s = "assets/contracts/ui-state-truth-table.json"' > "$TMP/apps/android/app/src/test/java/com/hawkeyexb/ppass/ui/CrossPlatformUiStateTruthTableTest.kt"
  echo 'let s = "assets/contracts/ui-state-truth-table.json"' > "$TMP/apps/ios/PPassTests/CrossPlatformUiStateTruthTableTests.swift"
  echo 'CrossPlatformUiStateTruthTableTests' > "$TMP/tools/ios/host-only-tests.txt"

  # 正常情况：通过
  check "$TMP" >/dev/null || { echo "自测失败：基准样桩未通过" >&2; exit 1; }

  # 反证 1：缺真值表
  rm "$TMP/assets/contracts/ui-state-truth-table.json"
  if check "$TMP" >/dev/null 2>&1; then
    echo "自测失败：缺失 JSON 文件未被拦截" >&2
    exit 1
  fi
  echo '{"connection_states": [{}]}' > "$TMP/assets/contracts/ui-state-truth-table.json"

  # 反证 2：缺少段落
  if check "$TMP" >/dev/null 2>&1; then
    echo "自测失败：缺失必需段落未被拦截" >&2
    exit 1
  fi
  cat <<'EOF' > "$TMP/assets/contracts/ui-state-truth-table.json"
{
  "connection_states": [{}],
  "photos_guides": [{}],
  "scope_access_policies": [{}],
  "initial_scope_times": [{}],
  "hero_idle_line_colors": [{}],
  "hero_from_today_empties": [{}]
}
EOF

  # 反证 3：Android 没引用
  echo 'val s = "other.json"' > "$TMP/apps/android/app/src/test/java/com/hawkeyexb/ppass/ui/CrossPlatformUiStateTruthTableTest.kt"
  if check "$TMP" >/dev/null 2>&1; then
    echo "自测失败：Android 没引用未被拦截" >&2
    exit 1
  fi
  echo 'val s = "assets/contracts/ui-state-truth-table.json"' > "$TMP/apps/android/app/src/test/java/com/hawkeyexb/ppass/ui/CrossPlatformUiStateTruthTableTest.kt"

  # 反证 4：iOS 没引用
  echo 'let s = "other.json"' > "$TMP/apps/ios/PPassTests/CrossPlatformUiStateTruthTableTests.swift"
  if check "$TMP" >/dev/null 2>&1; then
    echo "自测失败：iOS 没引用未被拦截" >&2
    exit 1
  fi
  echo 'let s = "assets/contracts/ui-state-truth-table.json"' > "$TMP/apps/ios/PPassTests/CrossPlatformUiStateTruthTableTests.swift"

  # 反证 5：host-only-tests 未登记
  echo 'OtherTest' > "$TMP/tools/ios/host-only-tests.txt"
  if check "$TMP" >/dev/null 2>&1; then
    echo "自测失败：host-only-tests 未登记未被拦截" >&2
    exit 1
  fi

  echo "ok: check-ui-truth-table.sh 自测通过（全反证通过）"
  exit 0
fi

check "$ROOT"
