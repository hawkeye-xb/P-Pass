#!/usr/bin/env bash
# #1302：文案按端归属后，tools/check-version-bump.sh 只让文案所在的那一端要求涨号。
#
#   tools/test-version-bump-i18n.sh
#   CV_SCRIPT=<另一份 check-version-bump.sh> tools/test-version-bump-i18n.sh   # 反证：拿旧口径跑必须红
#
# 每个用例：临时仓库里上一个 tag 三端都有号（ios 线不跳过），只改一个文案文件、不涨任何号，
# 看门禁点名哪几端「版本没涨」。点名的端集合必须恰好等于期望——多点一端 = 改一句文案牵动别的端
# （#1302 要消灭的），少点一端 = 漏判（UPD-13 要防的）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CV_SRC="${CV_SCRIPT:-$ROOT/tools/check-version-bump.sh}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
g() { git -c core.hooksPath=/dev/null -c user.name=i18n-test -c user.email=i18n@test.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

REPO="$WORK/repo"
mkdir -p "$REPO/tools" "$REPO/release"
cp "$CV_SRC" "$REPO/tools/check-version-bump.sh"
g -C "$REPO" init --template= -q
printf '{"desktop":"1.0.0","android":"1.0.0","androidVersionCode":1,"ios":"1.0.0"}\n' > "$REPO/release/versions.json"
g -C "$REPO" add -A && g -C "$REPO" commit -qm base && g -C "$REPO" tag v1.0.0

# expect <描述> <期望点名的端，空格分隔，按 desktop android ios 顺序> <改动文件...>
expect() {
  local desc="$1" want="$2" out got="" f; shift 2
  g -C "$REPO" checkout -q -B "case-$RANDOM" v1.0.0
  for f in "$@"; do mkdir -p "$REPO/$(dirname "$f")"; echo "$desc" >> "$REPO/$f"; done
  g -C "$REPO" add -A && g -C "$REPO" commit -qm "$desc"
  out=$(cd "$REPO" && bash tools/check-version-bump.sh v1.0.0 HEAD 2>&1) || true
  grep -q "desktop 版本没涨" <<<"$out" && got="$got desktop"
  grep -q "android 版本没涨" <<<"$out" && got="$got android"
  grep -q "ios 版本没涨" <<<"$out" && got="$got ios"
  got="${got# }"
  if [ "$got" = "$want" ]; then pass "$desc ⇒ 要求涨号：${got:-无}"; else fail "$desc ⇒ 期望 [${want:-无}]，实际 [${got:-无}]：$out"; fi
}

expect "只改 Android 独有文案（strings_android_only.xml）" "android" \
  apps/android/app/src/main/res/values/strings_android_only.xml \
  apps/android/app/src/main/res/values-zh/strings_android_only.xml
expect "只改桌面文案（apps/desktop/src/i18n）" "desktop" \
  apps/desktop/src/i18n/en.json apps/desktop/src/i18n/zh.json
expect "只改两部手机共用的文案（strings.xml + iOS 生成物）" "android ios" \
  apps/android/app/src/main/res/values/strings.xml \
  apps/ios/PPass/Resources/en.lproj/Localizable.strings
expect "只改 iOS 独有文案（IOS.strings）" "ios" \
  apps/ios/PPass/Resources/en.lproj/IOS.strings
# 反证：跨端集合（线上 msg_key，手机逐字节捆绑）改了，三端都必须要求涨号——
# 只改源不改副本也一样（副本漂移另由 mobile-static-check 拦）。
expect "反证：改跨端集合 assets/i18n" "desktop android ios" \
  assets/i18n/en.json assets/i18n/zh.json

if [ "$fails" -gt 0 ]; then
  echo "✗ ${fails} 个用例失败" >&2
  exit 1
fi
echo "ok: 文案按端归属的发版判定全部符合预期"
