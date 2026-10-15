#!/usr/bin/env bash
# iOS 单元测试（#887）：XcodeGen 生成工程 → 模拟器上 xcodebuild test。
#
#   tools/ios/test.sh            # 本机 / CI 同一条命令（just ios-test）
#
# - 工程由 apps/ios/project.yml 生成，.xcodeproj 不入库。
# - 模拟器由 tools/ios/sim.sh 选（不写死 runtime 版本）。
# - 本脚本启动的模拟器，结束时关掉；跑之前就开着的（你自己在用的）不动。
# - 不签名到任何团队：模拟器上只做 ad-hoc 签名，不需要 Apple 账号。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
DERIVED="$IOS/build/DerivedData"

command -v xcodegen >/dev/null || { echo "error: 缺 xcodegen（brew install xcodegen）" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: 缺 jq（brew install jq）" >&2; exit 1; }

# App 依赖传输 XCFramework（TransportFFITests/Generated，不入库）：缺就先生成（增量编译，已有则跳过）。
# 要强制重编：删 apps/ios/TransportFFITests/Generated。
if [ ! -d "$IOS/TransportFFITests/Generated/TransportFFI.xcframework" ] || [ ! -f "$IOS/TransportFFITests/Generated/swift/transport.swift" ]; then
  "$ROOT/tools/build-ios-transport-xcframework.sh" "$IOS/TransportFFITests/Generated"
fi

(cd "$IOS" && xcodegen generate --quiet)

UDID=$("$ROOT/tools/ios/sim.sh" udid)
STATE=$(xcrun simctl list devices -j | jq -r --arg u "$UDID" '.devices[][] | select(.udid == $u) | .state')
if [ "$STATE" != "Booted" ]; then
  trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true' EXIT
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
