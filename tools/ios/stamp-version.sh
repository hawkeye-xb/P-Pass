#!/usr/bin/env bash
# #346：iOS 版本号可判定——构建期把版本写进构建产物的 Info.plist。
#
#   tools/ios/stamp-version.sh <Info.plist>      # Xcode「Stamp version」构建阶段调用（见 apps/ios/project.yml）
#   tools/ios/stamp-version.sh --print [完整串]  # 只打印换算结果「short build full」（测试/排查用）
#
# 输入（与 Android 同源）：PPF_BUILD_VERSION（发布流水线注入的完整串，可带前导 v，
# 如 v0.5.7-test.1）。为空 = 本地/非 tag 构建，回退 PPASS_FALLBACK_VERSION（apps/ios/Config/Base.xcconfig，
# 对位 Android build.gradle.kts 里 `?: "x.y.z"` 那个回退值）。
#
# 写进 Info.plist（CFBundleShortVersionString 只接受最多三段数字，装不下 -test.1）：
#   CFBundleShortVersionString = X.Y.Z                 （去掉预发布后缀）
#   CFBundleVersion            = 单调整数（规则见下）  （对位 Android versionCode）
#   PPassFullVersion           = 完整串 X.Y.Z[-test.N|-beta.N]（诊断页显示它）
#   PPassVersionSource         = PPF_BUILD_VERSION | fallback（这一版号从哪来，排查用）
#
# CFBundleVersion 规则：((X*1000 + Y)*1000 + Z)*1000 + S，S 按发布先后排：
#   -test.N → N（1..499）   -beta.N → 500+N（N 1..498）   正式版 → 999
# 于是 0.5.7-test.1 < 0.5.7-test.2 < 0.5.7-beta.1 < 0.5.7 < 0.5.8-test.1，与发布先后一致；
# 同一个完整串永远得到同一个号（可复现，也能从号反推版本）。Y、Z ≤ 999。
# 不认识的写法（别的预发布类型、超出范围）一律报错退出——不猜。
set -euo pipefail

VERSION_RE='^([0-9]+)\.([0-9]+)\.([0-9]+)(-(test|beta)\.([0-9]+))?$'

# ── 取完整串 ─────────────────────────────────────────────────────────
MODE=stamp
if [ "${1:-}" = "--print" ]; then
  MODE=print
  FULL="${2:-}"
  SOURCE_LABEL=argument
fi
if [ -z "${FULL:-}" ]; then
  if [ -n "${PPF_BUILD_VERSION:-}" ]; then
    FULL="$PPF_BUILD_VERSION"
    SOURCE_LABEL=PPF_BUILD_VERSION
  elif [ -n "${PPASS_FALLBACK_VERSION:-}" ]; then
    FULL="$PPASS_FALLBACK_VERSION"
    SOURCE_LABEL=fallback
  else
    echo "stamp-version: PPF_BUILD_VERSION 与 PPASS_FALLBACK_VERSION 都为空——不知道该写哪个版本" >&2
    exit 1
  fi
fi
FULL="${FULL#v}"

# ── 换算 ─────────────────────────────────────────────────────────────
if [[ ! "$FULL" =~ $VERSION_RE ]]; then
  echo "stamp-version: 不认识的版本串「${FULL}」（只接受 X.Y.Z、X.Y.Z-test.N、X.Y.Z-beta.N）" >&2
  exit 1
fi
X=$((10#${BASH_REMATCH[1]}))
Y=$((10#${BASH_REMATCH[2]}))
Z=$((10#${BASH_REMATCH[3]}))
KIND="${BASH_REMATCH[5]}"
N="${BASH_REMATCH[6]}"
if [ "$Y" -gt 999 ] || [ "$Z" -gt 999 ]; then
  echo "stamp-version: 「${FULL}」的次版本或修订号超过 999，CFBundleVersion 规则装不下" >&2
  exit 1
fi
if [ "$KIND" = test ]; then
  N=$((10#$N))
  if [ "$N" -lt 1 ] || [ "$N" -gt 499 ]; then echo "stamp-version: test 序号须在 1..499（${FULL}）" >&2; exit 1; fi
  S=$N
elif [ "$KIND" = beta ]; then
  N=$((10#$N))
  if [ "$N" -lt 1 ] || [ "$N" -gt 498 ]; then echo "stamp-version: beta 序号须在 1..498（${FULL}）" >&2; exit 1; fi
  S=$((500 + N))
else
  S=999
fi
SHORT="${X}.${Y}.${Z}"
BUILD=$((X * 1000 + Y))
BUILD=$((BUILD * 1000 + Z))
BUILD=$((BUILD * 1000 + S))

if [ "$MODE" = print ]; then
  echo "${SHORT} ${BUILD} ${FULL}"
  exit 0
fi

# ── 写进构建产物的 Info.plist ────────────────────────────────────────
PLIST="${1:-}"
if [ -z "$PLIST" ] || [ ! -f "$PLIST" ]; then
  echo "stamp-version: 找不到 Info.plist「${PLIST}」（用法：$0 <Info.plist> | --print [版本串]）" >&2
  exit 1
fi
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleShortVersionString $SHORT" "$PLIST"
"$PB" -c "Set :CFBundleVersion $BUILD" "$PLIST"
"$PB" -c "Delete :PPassFullVersion" "$PLIST" 2>/dev/null || true
"$PB" -c "Add :PPassFullVersion string $FULL" "$PLIST"
"$PB" -c "Delete :PPassVersionSource" "$PLIST" 2>/dev/null || true
"$PB" -c "Add :PPassVersionSource string $SOURCE_LABEL" "$PLIST"
echo "stamp-version: ${FULL}（来源 ${SOURCE_LABEL}）→ CFBundleShortVersionString=${SHORT} CFBundleVersion=${BUILD}"
