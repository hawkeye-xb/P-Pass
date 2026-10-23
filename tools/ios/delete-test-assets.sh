#!/usr/bin/env bash
# 删掉手机里所有「PPass BGTest *」相册的照片 / 视频（要人在手机上点系统确认框）。
#
#   tools/ios/delete-test-assets.sh [设备标识]
#
# 原先是 restore-desktop-pairing.sh 的 --delete-test-assets 分支。#1115 删掉了那个脚本的另一半
# （用正式桌面的 IPC 令牌自己发起并批准配对——正是 #1115 要堵的攻击形状），这一半与配对无关，
# 单独留下。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
DEV="${1:-${PPASS_DEVICE:-B2805351-9CD1-55C7-81B0-DBEAD9E86BD3}}"
OUT="$IOS/build/delete-test-assets/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

launch() { # $1 = 环境变量 JSON
  xcrun devicectl device process launch --device "$DEV" --terminate-existing --environment-variables "$1" \
    --json-output "$OUT/launch.json" "$BUNDLE_ID" >"$OUT/launch.log" 2>&1 || { cat "$OUT/launch.log"; exit 1; }
}
status_of() { # $1 = run；拉到本次 run、已 done 的 status.json 返回 0
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/e2e/status.json --destination "$OUT/status.json" >/dev/null 2>&1 \
    && [ "$(jq -r '.run // ""' "$OUT/status.json")" = "$1" ] && [ "$(jq -r '.done // false' "$OUT/status.json")" = true ]
}

RUN="delete-$(date +%s)"
launch "$(jq -cn --arg r "$RUN" '{PPASS_E2E_DIR:"container", PPASS_E2E_RUN:$r, PPASS_BGTEST_DELETE_TEST:"1"}')"
echo ">>> 手机上会弹「删除 N 项」的系统确认框，请在手机上点「删除」（3 分钟内）。"
for _ in $(seq 1 90); do status_of "$RUN" && break; sleep 2; done
jq -c . "$OUT/status.json" 2>/dev/null || true
if [ "$(jq -r .step "$OUT/status.json" 2>/dev/null)" = deleted ] && [ "$(jq -r .remaining "$OUT/status.json")" = 0 ]; then
  echo "PASS: 测试相册与其中的照片 / 视频已删除（iOS 在「最近删除」里留 30 天，不属于任何可选相册）"
  exit 0
fi
echo "FAIL: 测试资源没删干净（没点确认？）"; exit 1
