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
}
export -f xcrun
CORE_UUID=B2805351-9CD1-55C7-81B0-DBEAD9E86BD3
HW_UDID=00008030-001A2B3C4D5E6F7A

out=$(CI=false PPASS_IOS_FORCE_SIMULATOR=0 PPASS_IOS_TEST_PLAN_ONLY=1 PPASS_IOS_TEST_DEVICE="$CORE_UUID" bash "$ROOT/tools/ios/test.sh")
expect_contains "$out" "EXECUTION=device UDID=$HW_UDID" "本地真机用例显式清除继承的 CI 环境，并换硬件 UDID"
expect_contains "$out" 'HOST_TESTS_DEFERRED=11' "真机明确延期全部宿主测试"
expect_contains "$out" 'SKIP=PPassTests/VersionStampTests' "真机带宿主跳过参数"
expect_contains "$out" 'SKIP=PPassTests/OnboardingNavigationTests' "真机覆盖直接读源文件的测试"

out=$(CI=true PPASS_IOS_FORCE_SIMULATOR=0 PPASS_IOS_TEST_PLAN_ONLY=1 PPASS_IOS_TEST_DEVICE="$CORE_UUID" bash "$ROOT/tools/ios/test.sh")
expect_contains "$out" 'EXECUTION=simulator' "CI 保持模拟器"
expect_contains "$out" 'HOST_TESTS_DEFERRED=0 SKIP=none' "CI 不继承真机跳过项"
expect_not_contains "$out" 'SKIP=PPassTests/' "CI 不跳过任何测试"

out=$(CI=false PPASS_IOS_FORCE_SIMULATOR=1 PPASS_IOS_TEST_PLAN_ONLY=1 PPASS_IOS_TEST_DEVICE="$CORE_UUID" bash "$ROOT/tools/ios/test.sh")
expect_contains "$out" 'EXECUTION=simulator' "允许显式选择宿主模拟器"

app_script=$(<"$ROOT/tools/ios/test.sh")
expect_contains "$app_script" "\$ROOT/tools/e3/lock" "App 真机锁使用仓库绝对路径"
expect_contains "$app_script" 'DEVELOPMENT_TEAM=' "App 真机测试显式签名团队"
just_script=$(<"$ROOT/justfile")
expect_contains "$just_script" 'ios_lane_select' "justfile 在 App 测试前保存一次分轨"
expect_contains "$just_script" 'if ios_lane_is_device; then' "justfile 在真机分支显式处理 FFI"
expect_contains "$just_script" 'FFI_DEFERRED=tool-hosted testing requires the host simulator; run in CI' "FFI 明确延期到 CI"
expect_contains "$just_script" 'PPASS_DAEMON_PROFILE=dev bash tools/ios/test-transport-ffi.sh' "CI 与宿主仍执行完整 FFI"
ffi_script=$(<"$ROOT/tools/ios/test-transport-ffi.sh")
expect_not_contains "$ffi_script" 'ios_lane_is_device' "tool-hosted FFI 不伪装成真机可运行"

out=$(
  unset PPASS_IOS_TEST_DEVICE PPASS_IOS_LANE
  ios_lane_real_udid
)
expect_contains "$out" "$HW_UDID" "设备名含空格也能发现真机并返回硬件 UDID"

(
  unset PPASS_IOS_LANE
  ios_lane_real_udid() { :; }
  ios_lane_is_device
)
expect_rc $? 1 "没有真机时才回退模拟器"

(
  CI=false PPASS_IOS_FORCE_SIMULATOR=0 PPASS_IOS_TEST_DEVICE="$CORE_UUID"
  export CI PPASS_IOS_FORCE_SIMULATOR PPASS_IOS_TEST_DEVICE
  unset PPASS_IOS_LANE
  ios_lane_select
  [ "$PPASS_IOS_LANE" = device ] || exit 1
  # App 测试结束后不得再次探测并改写分轨；FFI 读取同一份结果。
  ios_lane_real_udid() { return 1; }
  ios_lane_select
  ios_lane_is_device
)
expect_rc $? 0 "App 与 FFI 共用任务开始时保存的分轨结果"

if [ "$FAILS" -ne 0 ]; then
  printf '%s 项失败\n' "$FAILS" >&2
  exit 1
fi
printf 'ok: iOS 真机/宿主分轨自测通过\n'
