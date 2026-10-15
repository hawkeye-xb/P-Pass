#!/usr/bin/env bash
# 从真机拉回 App 的落盘日志（#955）并打印尾部。前台、后台（BGTask / 静默唤醒）拉起的进程都写这个文件。
#
#   tools/ios/pull-logs.sh [设备标识] [尾部行数]     # 输出在 apps/ios/build/device-logs/<时间戳>/
#   PPASS_DEVICE=<id> PPASS_LOG_TAIL=80 tools/ios/pull-logs.sh
#
# - 设备标识 = `xcrun devicectl list devices` 里的 Identifier；不给就取第一台 connected 的 iPhone。
# - 拉两份：ppass.log（当前）与 ppass.log.1（上一份滚动），后者可能不存在。
# - 日志不含照片文件名 / 相册名 / 配对凭据（见 docs/runbook/ios-device-forensics.md「后台日志」）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
DEV="${1:-${PPASS_DEVICE:-}}"
TAIL_LINES="${2:-${PPASS_LOG_TAIL:-60}}"
OUT="$IOS/build/device-logs/$(date +%Y%m%d-%H%M%S)"

command -v jq >/dev/null || { echo "error: 缺 jq（brew install jq）" >&2; exit 1; }
[ -n "$BUNDLE_ID" ] || { echo "error: 读不到 PPASS_BUNDLE_ID（apps/ios/Config/Base.xcconfig）" >&2; exit 1; }

if [ -z "$DEV" ]; then
  LIST=$(mktemp "${TMPDIR:-/tmp}/ppass-devices.XXXXXX")
  trap 'rm -f "$LIST"' EXIT
  xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1 || true
  DEV=$(jq -r '[.result.devices[]? | select(.hardwareProperties.deviceType == "iPhone" and .connectionProperties.tunnelState == "connected")][0].identifier // empty' "$LIST")
  [ -n "$DEV" ] || { echo "error: 没有 connected 的 iPhone（xcrun devicectl list devices）；可传设备标识或设 PPASS_DEVICE" >&2; exit 1; }
  echo "设备：${DEV}（自动选择）"
fi

mkdir -p "$OUT"
pull() {
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Library/Logs/$1" --destination "$OUT/$1" >"$OUT/$1.pull.out" 2>&1
}
if ! pull ppass.log; then
  cat "$OUT/ppass.log.pull.out" >&2
  echo "error: 拉不到 Library/Logs/ppass.log（App 还没写过日志？先启动一次 App）" >&2
  exit 1
fi
pull ppass.log.1 || rm -f "$OUT/ppass.log.1"
rm -f "$OUT"/*.pull.out

echo "已拉回：${OUT}"
ls -l "$OUT"
echo "--- ppass.log 尾部 ${TAIL_LINES} 行 ---"
tail -n "$TAIL_LINES" "$OUT/ppass.log"
