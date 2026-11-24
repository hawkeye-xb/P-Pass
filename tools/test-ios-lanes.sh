#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/ios/lanes.sh
source "$ROOT/tools/ios/lanes.sh"
MANIFEST="$ROOT/tools/ios/host-only-tests.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
pass() { printf 'ok %s\n' "$*"; }
expect_contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3：缺 $2" ;; esac }
expect_not_contains() { case "$1" in *"$2"*) fail "$3：不应含 $2" ;; *) pass "$3" ;; esac }
expect_rc() {
  if [ "$1" -eq "$2" ]; then pass "$3"; else fail "$3：rc=$1，期望 $2"; fi
}

ios_lane_validate_manifest "$ROOT" "$MANIFEST"
expect_rc $? 0 "现有宿主清单完整"

cp "$MANIFEST" "$TMP/duplicate.txt"
printf 'VersionStampTests\n' >> "$TMP/duplicate.txt"
ios_lane_validate_manifest "$ROOT" "$TMP/duplicate.txt" >/dev/null 2>&1
expect_rc $? 1 "重复清单项判红"

cp "$MANIFEST" "$TMP/missing-file.txt"
printf 'NoSuchTests\n' >> "$TMP/missing-file.txt"
ios_lane_validate_manifest "$ROOT" "$TMP/missing-file.txt" >/dev/null 2>&1
expect_rc $? 1 "不存在的测试类判红"

grep -v '^VersionStampTests$' "$MANIFEST" > "$TMP/missing-host.txt"
ios_lane_validate_manifest "$ROOT" "$TMP/missing-host.txt" >/dev/null 2>&1
expect_rc $? 1 "漏掉宿主依赖测试判红"

# devicectl 的 CoreDevice UUID 与 xcodebuild 需要的硬件 UDID 必须不同，防止测试把混用当正确。
xcrun() {
  if [ "$1 $2 $3" != "devicectl list devices" ]; then return 1; fi
  local json=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--json-output" ]; then json="$2"; shift 2; else shift; fi
  done
  [ -n "$json" ] || return 1
  cat >"$json" <<'JSON'
{"result":{"devices":[{"identifier":"B2805351-9CD1-55C7-81B0-DBEAD9E86BD3","deviceProperties":{"name":"iPhone test"},"hardwareProperties":{"platform":"iOS","deviceType":"iPhone","udid":"00008030-001A2B3C4D5E6F7A"},"connectionProperties":{"pairingState":"paired","tunnelState":"connected"}}]}}
JSON
  if [ "${STUB_EXTRA_DEVICE:-0}" = 1 ]; then
    local enriched="${json}.extra"
    jq '.result.devices += [(.result.devices[0] | .identifier="SECOND-CORE-UUID" | .hardwareProperties.udid="SECOND-HW-UDID")]' "$json" >"$enriched"
    mv "$enriched" "$json"
  fi
}
export -f xcrun
CORE_UUID=B2805351-9CD1-55C7-81B0-DBEAD9E86BD3
HW_UDID=00008030-001A2B3C4D5E6F7A

# 关键硬判据：USB 连着唯一物理 iPhone 时，默认不带 PPASS_IOS_LANE=device 必须 100% 跑 simulator，绝不偷抢真机！
out=$(
  unset PPASS_IOS_LANE PPASS_IOS_FORCE_SIMULATOR
  CI=false PPASS_IOS_TEST_PLAN_ONLY=1 PPASS_IOS_TEST_DEVICE="$CORE_UUID" bash "$ROOT/tools/ios/test.sh"
)
expect_contains "$out" 'EXECUTION=simulator' "默认物理隔离：插着唯一真机跑单测也 100% 走 simulator"
expect_not_contains "$out" 'EXECUTION=device' "默认物理隔离：绝不自动切真机"

# 显式指定 PPASS_IOS_LANE=device 时，才走真机并换硬件 UDID
out=$(CI=false PPASS_IOS_LANE=device PPASS_IOS_FORCE_SIMULATOR=0 PPASS_IOS_TEST_PLAN_ONLY=1 PPASS_IOS_TEST_DEVICE="$CORE_UUID" bash "$ROOT/tools/ios/test.sh")
expect_contains "$out" "EXECUTION=device UDID=$HW_UDID" "显式指定 PPASS_IOS_LANE=device 才走真机并换硬件 UDID"
expect_contains "$out" "XCODEBUILD_DESTINATION=id=$HW_UDID" "真实 xcodebuild 目的地使用硬件 UDID"
HOST_COUNT=$(grep -Ev '^[[:space:]]*(#|$)' "$ROOT/tools/ios/host-only-tests.txt" | wc -l | tr -d ' ')
expect_contains "$out" "HOST_TESTS_DEFERRED=$HOST_COUNT" "真机明确延期全部宿主测试"
expect_contains "$out" 'SKIP=PPassTests/VersionStampTests' "真机带宿主跳过参数"
expect_contains "$out" 'XCODEBUILD_ARG=-skip-testing' "真实 xcodebuild 参数带宿主跳过项"

# 即使环境里带 PPASS_IOS_LANE=device，CI=true 或 PPASS_IOS_FORCE_SIMULATOR=1 仍强制回模拟器
out=$(CI=true PPASS_IOS_LANE=device PPASS_IOS_FORCE_SIMULATOR=0 PPASS_IOS_TEST_PLAN_ONLY=1 PPASS_IOS_TEST_DEVICE="$CORE_UUID" bash "$ROOT/tools/ios/test.sh")
expect_contains "$out" 'EXECUTION=simulator' "CI 强制保持模拟器"
expect_contains "$out" 'XCODEBUILD_SKIP_COUNT=0' "CI 的真实参数没有任何跳过项"

# 反证：只改真实 simulator 参数、保持计划文本不变时，参数级断言必须能抓到。
MUT="$ROOT/tools/ios/.test-lanes-mutated.$$"
trap 'rm -rf "$TMP"; rm -f "$MUT"' EXIT
sed 's/SKIP_ARGS=()/SKIP_ARGS=("-skip-testing" "PPassTests\/VersionStampTests")/' "$ROOT/tools/ios/test.sh" >"$MUT"
out=$(CI=true PPASS_IOS_FORCE_SIMULATOR=0 PPASS_IOS_TEST_PLAN_ONLY=1 PPASS_IOS_TEST_DEVICE="$CORE_UUID" bash "$MUT")
expect_contains "$out" 'EXECUTION=simulator' "变异样例的计划文本仍伪装成 simulator"
expect_contains "$out" 'XCODEBUILD_ARG=-skip-testing' "反证：参数级判据能抓到 CI 偷带 skip-testing"
rm -f "$MUT"

out=$(CI=false PPASS_IOS_LANE=device PPASS_IOS_FORCE_SIMULATOR=1 PPASS_IOS_TEST_PLAN_ONLY=1 PPASS_IOS_TEST_DEVICE="$CORE_UUID" bash "$ROOT/tools/ios/test.sh")
expect_contains "$out" 'EXECUTION=simulator' "PPASS_IOS_FORCE_SIMULATOR=1 压过 device"

out=$(
  unset PPASS_IOS_TEST_DEVICE PPASS_IOS_HARDWARE_UDID
  CI=false PPASS_IOS_LANE=device PPASS_IOS_FORCE_SIMULATOR=0
  export CI PPASS_IOS_LANE PPASS_IOS_FORCE_SIMULATOR
  STUB_EXTRA_DEVICE=1 ios_lane_select 2>&1
)
expect_rc $? 2 "显式真机模式下多台真机不能装错目标"
expect_contains "$out" '多台' "多台真机报错要求显式指定"

if [ "$FAILS" -ne 0 ]; then
  printf '%s 项失败\n' "$FAILS" >&2
  exit 1
fi
printf 'ok: iOS 真机/宿主分轨自测通过\n'
