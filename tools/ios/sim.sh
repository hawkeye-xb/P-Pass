#!/usr/bin/env bash
# iOS 模拟器选择（#887）。本机与 CI 共用同一套逻辑。
#
#   tools/ios/sim.sh udid     打印要用的模拟器 UDID（没有就现建一台）
#
# 选法：在**最新**的已装 iOS runtime 上找名为 $IOS_SIM_NAME（默认 iPhone 17）的
# 可用设备；没有就用同名设备类型现建一台。不写死 runtime 版本——CI runner 与
# 本机装的 runtime 不一样，写死等于在别处必挂。
# 设备类型不存在（老 Xcode）时报错退出，不偷偷换成别的机型。
set -euo pipefail

NAME="${IOS_SIM_NAME:-iPhone 17}"

latest_runtime() {
  xcrun simctl list runtimes available -j \
    | jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty'
}

cmd_udid() {
  local rt udid dt
  rt=$(latest_runtime)
  if [ -z "$rt" ]; then
    echo "error: 没有可用的 iOS 模拟器 runtime（xcrun simctl list runtimes）" >&2
    exit 1
  fi
  udid=$(xcrun simctl list devices available -j \
    | jq -r --arg rt "$rt" --arg n "$NAME" '.devices[$rt] // [] | map(select(.name == $n)) | first | .udid // empty')
  if [ -n "$udid" ]; then
    echo "$udid"
    return
  fi
  dt=$(xcrun simctl list devicetypes -j \
    | jq -r --arg n "$NAME" '.devicetypes[] | select(.name == $n) | .identifier' | head -1)
  if [ -z "$dt" ]; then
    echo "error: 没有名为「${NAME}」的模拟器设备类型；用 IOS_SIM_NAME 指定一个（xcrun simctl list devicetypes）" >&2
    exit 1
  fi
  echo "在 ${rt} 上新建模拟器「${NAME}」" >&2
  xcrun simctl create "$NAME" "$dt" "$rt"
}

case "${1:-}" in
  udid) cmd_udid ;;
  *) echo "usage: $0 udid" >&2; exit 1 ;;
esac
