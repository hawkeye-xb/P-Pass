#!/usr/bin/env bash
# iOS 逐屏截图（#315）：构建一次，按「场景 × 路由」逐个冷启动 App 截图。演示数据，不点坐标。
#
#   tools/ios/screenshots.sh [输出目录]      # 默认 apps/ios/build/screenshots（不入库）
#   IOS_SHOT_LANG=en tools/ios/screenshots.sh # 界面语言（默认 zh-Hans）
#
# 场景（PPASS_SCENARIO）与路由（PPASS_ROUTE）的取值见 FakeBackend.swift / RootView.swift。
# #943：外观与字号可选——IOS_SHOT_APPEARANCE=light|dark（默认 light）、
#   IOS_SHOT_SIZE=默认 large，可取 extra-extra-extra-large / accessibility-extra-extra-extra-large 等
#   （xcrun simctl ui <udid> content_size 的取值）。要全矩阵：tools/ios/screenshots.sh 跑四次，输出分目录。
# 本脚本启动的模拟器结束时关掉。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
OUT="${1:-$IOS/build/screenshots}"
LANG_CODE="${IOS_SHOT_LANG:-zh-Hans}"
DERIVED="$IOS/build/DerivedData"
BUNDLE_ID=com.hawkeyexb.ppass

(cd "$IOS" && xcodegen generate --quiet)
UDID=$("$ROOT/tools/ios/sim.sh" udid)
STATE=$(xcrun simctl list devices -j | jq -r --arg u "$UDID" '.devices[][] | select(.udid == $u) | .state')
if [ "$STATE" != "Booted" ]; then
  trap 'xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true' EXIT
  xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

xcodebuild build -project "$IOS/PPass.xcodeproj" -scheme PPass -destination "id=${UDID}" \
  -derivedDataPath "$DERIVED" -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/PPass.app"
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 || true
xcrun simctl ui "$UDID" appearance "${IOS_SHOT_APPEARANCE:-light}"
xcrun simctl ui "$UDID" content_size "${IOS_SHOT_SIZE:-large}"
mkdir -p "$OUT"

shot() { # <文件名> <场景> <路由> [等待秒数]
  local name="$1" scenario="$2" route="$3" wait="${4:-3}"
  SIMCTL_CHILD_PPASS_SCENARIO="$scenario" SIMCTL_CHILD_PPASS_ROUTE="$route" \
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
    -AppleLanguages "($LANG_CODE)" -AppleLocale "${LANG_CODE/-/_}" >/dev/null
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/${name}.png" >/dev/null 2>&1
  echo "  ${name}.png  (scenario=${scenario} route=${route})"
}

echo "截图 → ${OUT}（语言 ${LANG_CODE}）"
# 两个 tab 与时间线
shot 01-photos-grid normal photos
shot 02-photos-loading timelineLoading photos 2
shot 03-photos-empty timelineEmpty photos
shot 04-photos-error timelineError photos
shot 05-photos-lost lost photos
shot 06-viewer-photo normal viewer 4
shot 07-viewer-video normal video 6
# 设置 tab（首页）的各个状态
shot 10-home-idle-pending normal settings
shot 11-home-sending sending settings
shot 12-home-paused paused settings
shot 13-home-waiting waiting settings
shot 14-home-all-safe allSafe settings
shot 15-home-trouble trouble settings
shot 16-home-partial-access partialAccess settings
shot 17-home-no-access noAccess settings
shot 18-home-no-albums noAlbums settings
shot 19-home-pairing-lost lost settings
# 子页
shot 20-albums normal bucket
shot 21-storage normal storage
shot 22-diagnostics normal diagnostics
# 配对
shot 30-welcome notPaired welcome
shot 31-scan-no-camera notPaired scan
shot 32-manual notPaired manual
shot 33-pair-waiting notPaired pairWaiting
shot 34-pair-refused notPaired pairRefused
shot 35-pair-lapsed notPaired pairLapsed
shot 36-pair-failed notPaired pairFailed
shot 37-backup-started normal backupStarted
xcrun simctl ui "$UDID" appearance light
xcrun simctl ui "$UDID" content_size large
xcrun simctl status_bar "$UDID" clear || true
echo "完成：$(ls "$OUT" | wc -l | tr -d ' ') 张"
