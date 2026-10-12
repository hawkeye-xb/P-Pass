#!/usr/bin/env bash
# 把模拟器里某个 bundle 的相册授权设成指定档位：full / limited / denied / reset。
#
# 为什么不只用 `xcrun simctl privacy grant photos`：本机实测（Xcode 26.6，iOS 26.4 runtime），
# 它写进 TCC.db 的行是 auth_value=2、auth_version=1，tccd 对 kTCCServicePhotos 认 auth_version=2，
# 版本 1 的行被当成「未决定」——App 读到 PHAuthorizationStatus.notDetermined(0)、取不到任何照片。
# 把同一行的 auth_version 改成 2 后读到 .authorized(3)。limited 是 auth_value=3（同样 version 2）。
# 所以这里先用 simctl 写出标准行（保证 csreq 等字段由系统生成），再只改 auth_version / auth_value 两列。
#
# 只动模拟器自己的 TCC.db（~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/TCC/TCC.db），
# 不碰本机 macOS 的 TCC。改完要让宿主进程重启才生效——xcodebuild test 每次都会重新拉起宿主。
set -euo pipefail

udid="${1:?usage: sim-photos-auth.sh <udid> <bundle-id> <full|limited|denied|reset>}"
bundle="${2:?bundle id required}"
level="${3:?level required}"
db="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"

case "$level" in
  reset)
    xcrun simctl privacy "$udid" reset photos "$bundle"
    exit 0
    ;;
  full) value=2 ;;
  limited) value=3 ;;
  denied) value=0 ;;
  *) echo "unknown level: $level" >&2; exit 2 ;;
esac

xcrun simctl privacy "$udid" grant photos "$bundle"
[[ -f "$db" ]] || { echo "TCC.db not found: $db" >&2; exit 1; }
sqlite3 "$db" "UPDATE access SET auth_value=$value, auth_version=2 WHERE service='kTCCServicePhotos' AND client='$bundle';"
row="$(sqlite3 "$db" "SELECT auth_value||','||auth_version FROM access WHERE service='kTCCServicePhotos' AND client='$bundle';")"
[[ "$row" == "$value,2" ]] || { echo "TCC row not updated (got '$row')" >&2; exit 1; }
echo "photos[$bundle] = $level (auth_value=$value, auth_version=2)"
