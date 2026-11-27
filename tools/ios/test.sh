#!/usr/bin/env bash
# iOS App 测试：本机有真机时优先真机；CI 或无真机时用模拟器。
# 真机只跳过 host-only-tests.txt 中明确依赖仓库源文件的测试，CI 始终跑完整套件。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
DERIVED="$IOS/build/DerivedData"
MANIFEST="$ROOT/tools/ios/host-only-tests.txt"
# shellcheck source=tools/ios/lanes.sh
source "$ROOT/tools/ios/lanes.sh"
ios_lane_select

if ios_lane_is_device; then
  ios_lane_validate_manifest "$ROOT" "$MANIFEST"
  ios_lane_print_plan "$ROOT" "$MANIFEST"
  UDID="$(ios_lane_real_udid)"
  SKIP_ARGS=()
  while IFS= read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    SKIP_ARGS+=("-skip-testing" "PPassTests/$name")
  done < <(grep -Ev '^[[:space:]]*(#|$)' "$MANIFEST")
else
  if [ "${PPASS_IOS_TEST_PLAN_ONLY:-0}" = 1 ]; then
    UDID=SIMULATOR_UDID
  else
    UDID=$("$ROOT/tools/ios/sim.sh" udid)
  fi
  SKIP_ARGS=()
fi

# 计划与实际执行共用同一份 destination / SKIP_ARGS，防止计划说没跳过、真实命令却跳过。
if [ "${PPASS_IOS_TEST_PLAN_ONLY:-0}" = 1 ]; then
  ios_lane_print_plan "$ROOT" "$MANIFEST"
  printf 'XCODEBUILD_DESTINATION=id=%s\n' "$UDID"
  printf 'XCODEBUILD_SKIP_COUNT=%s\n' "${#SKIP_ARGS[@]}"
  for arg in ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}; do printf 'XCODEBUILD_ARG=%s\n' "$arg"; done
  exit 0
fi

command -v xcodegen >/dev/null || { echo "error: 缺 xcodegen（brew install xcodegen）" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: 缺 jq（brew install jq）" >&2; exit 1; }

# App 依赖传输 XCFramework（TransportFFITests/Generated，不入库）：交由构建脚本按输入树摘要决定是否重编。
"$ROOT/tools/build-ios-transport-xcframework.sh" "$IOS/TransportFFITests/Generated"

(cd "$IOS" && xcodegen generate --quiet)

if ios_lane_is_device; then
  "$ROOT/tools/e3/lock" ios xcodebuild test \
    -project "$IOS/PPass.xcodeproj" \
    -scheme PPass \
    -destination "id=${UDID}" \
    -derivedDataPath "$DERIVED" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-2WJUWVUJBN}" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    "${SKIP_ARGS[@]}" \
    "$@"
else
  # 同一台模拟器上的测试排队执行，避免别的会话收尾关机打断本次运行（见 sim-lock.sh）。
  # shellcheck source=tools/ios/sim-lock.sh
  . "$ROOT/tools/ios/sim-lock.sh"
  sim_lock_acquire
  STATE=$(xcrun simctl list devices -j | jq -r --arg u "$UDID" '.devices[][] | select(.udid == $u) | .state')
  if [ "$STATE" != "Booted" ] && [ "${CI:-}" != "true" ]; then
    trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; sim_lock_release' EXIT
  else
    trap 'sim_lock_release' EXIT
  fi
  echo "模拟器：${UDID}（运行前状态 ${STATE}）"

  if ! xcodebuild test \
    -project "$IOS/PPass.xcodeproj" \
    -scheme PPass \
    -destination "id=${UDID}" \
    -derivedDataPath "$DERIVED" \
    "$@"; then
    # 已踩过：Xcode 26.6 自带 iOS 26.5 SDK，而本机只装了 26.4 runtime 时，xcodebuild 把所有
    # 模拟器都判为不可用（报 "Unable to find a destination"）。解法是让该 SDK 用已装的 runtime：
    #   xcrun simctl runtime match list
    #   xcrun simctl runtime match set iphoneos<SDK版本> <已装 runtime 的 build 号>
    # （还原：xcrun simctl runtime match set iphoneos<SDK版本> --default）
    echo "error: xcodebuild test 失败。若上面是 \"Unable to find a destination\"，见 tools/ios/test.sh 里的说明。" >&2
    exit 1
  fi
fi
