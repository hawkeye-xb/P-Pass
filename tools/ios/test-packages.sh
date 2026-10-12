#!/usr/bin/env bash
# iOS 本地 SwiftPM 包的测试（#345）：apps/ios/Packages/*/Package.swift 逐个在 iOS 模拟器上跑。
#
#   tools/ios/test-packages.sh [包目录根，默认 apps/ios/Packages]
#
# 为什么一律走 `xcodebuild test` + iOS 模拟器，而不是按包分 `swift test`：
#   包最终跑在 iPhone 上。纯 Swift 的包在模拟器上测与在 macOS 上 `swift test` 结论一样，
#   而依赖 PhotoKit/UIKit 的包只能在模拟器上测——用同一条路两类都覆盖，不需要去猜
#   「这个包依不依赖 iOS 框架」（猜错 = 静默跳过）。
# 没有任何包时打印一句并退出 0（扩展点：包合入后自动被发现，不用改本脚本或 workflow）。
# 发现了 Package.swift 却列不出可测的 scheme ⇒ 红，不许静默跳过。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKGS="${1:-$ROOT/apps/ios/Packages}"

shopt -s nullglob
manifests=("$PKGS"/*/Package.swift)
if [ "${#manifests[@]}" -eq 0 ]; then
  echo "没有本地 SwiftPM 包（${PKGS}/*/Package.swift），跳过"
  exit 0
fi

UDID=$("$ROOT/tools/ios/sim.sh" udid)
STATE=$(xcrun simctl list devices -j | jq -r --arg u "$UDID" '.devices[][] | select(.udid == $u) | .state')
if [ "$STATE" != "Booted" ]; then
  trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true' EXIT
fi

fail=0
for m in "${manifests[@]}"; do
  dir=$(dirname "$m")
  name=$(basename "$dir")
  # SwiftPM 包的自动 scheme：多 product 时叫 <名>-Package（含全部测试），否则就是包名。
  schemes=$(cd "$dir" && xcodebuild -list -json 2>/dev/null | jq -r '(.workspace // .project).schemes[]?')
  scheme=""
  if grep -qx "${name}-Package" <<<"$schemes"; then
    scheme="${name}-Package"
  elif grep -qx "$name" <<<"$schemes"; then
    scheme="$name"
  fi
  if [ -z "$scheme" ]; then
    echo "error: ${name}：xcodebuild -list 里找不到 ${name}-Package 或 ${name} scheme（实际：$(tr '\n' ' ' <<<"$schemes")）" >&2
    fail=1
    continue
  fi
  echo "==> ${name}（scheme ${scheme}）"
  if ! (cd "$dir" && xcodebuild test -scheme "$scheme" -destination "id=${UDID}" \
      -derivedDataPath "$ROOT/apps/ios/build/Packages/${name}"); then
    echo "error: ${name} 测试失败" >&2
    fail=1
  fi
done
exit "$fail"
