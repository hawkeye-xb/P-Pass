#!/usr/bin/env bash
# #838：把 Latest 正式版里某一端的产物原样取回，作为本次发布该端的 workflow artifact
# （与构建 job 上传的 artifact 同名、同布局，下游的上传 / 清单 / 正文 job 不用区分来源）。
#
# 复用必须证明两件事，任一不成立就红（绝不发一份说不清来历的产物）：
#   1. 字节就是 Latest 记录的那份：android 对 manifest-android.json 的 sha256；
#      macOS 对 SHA256SUMS-macos-arm64（dmg 与 .app.tar.gz）。
#   2. 产物自己报的版本号 = 本次该端的版本号（#809 的教训：清单写的号不等于包里的号）：
#      android 读 APK 的 versionName（aapt2 dump badging）；macOS 读 .app.tar.gz 里
#      Info.plist 的 CFBundleShortVersionString。
#
# 用法：tools/release/reuse-artifact.sh <android|macos> <from-tag> <版本号> <输出目录>
#   android ⇒ <输出目录>/P-Pass_<号>_android.apk
#   macos   ⇒ <输出目录>/{P-Pass_<号>_macos-arm64.dmg, P-Pass_<号>_macos-arm64.app.tar.gz, SHA256SUMS-macos-arm64}
# #1151：复用**不重新签名**——把 Latest 清单里这份字节的原更新签名取回来，用本通道公钥验过后放在
#   产物旁（<产物>.sig），下游签名步骤见到现成的 .sig 只验不签（tools/release/carry-signature.sh）。
#   需要环境变量 RELEASE_TAG（决定用哪个通道的公钥）。
# aapt2：环境变量 AAPT2 > PATH 里的 aapt2 > $ANDROID_HOME 下最新 build-tools 的 aapt2。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
END="${1:?端}"; FROM="${2:?from-tag}"; VER="${3:?版本号}"; OUTDIR="${4:?输出目录}"
mkdir -p "$OUTDIR"
cd "$OUTDIR"
: "${RELEASE_TAG:?RELEASE_TAG 未设置（复用要沿用旧签名，需要它选通道公钥）}"
CLEAN="$(mktemp -d)"
trap 'rm -rf "$CLEAN"' EXIT

sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

case "$END" in
  android)
    APK="P-Pass_${VER}_android.apk"
    gh release download "$FROM" -p "$APK" -O "$APK"
    WANT_SHA=$(gh release download "$FROM" -p manifest-android.json -O - | jq -r '.platforms["android-arm64"].sha256 // empty')
    [ -n "$WANT_SHA" ] || { echo "::error::${FROM} 的 manifest-android.json 没有 android-arm64 的 sha256"; exit 1; }
    GOT_SHA=$(sha_of "$APK")
    [ "$GOT_SHA" = "$WANT_SHA" ] || { echo "::error::${APK} 的 sha256 与 ${FROM} 的清单不符（清单 ${WANT_SHA}，实际 ${GOT_SHA}）"; exit 1; }
    AAPT2="${AAPT2:-$(command -v aapt2 || true)}"
    if [ -z "$AAPT2" ]; then
      AAPT2="$(ls -d "${ANDROID_HOME:?ANDROID_HOME 未设置}"/build-tools/*/ | sort -V | tail -1)aapt2"
    fi
    NAME=$("$AAPT2" dump badging "$APK" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -1)
    [ "$NAME" = "$VER" ] || { echo "::error::${APK} 包内 versionName=${NAME:-读不到}，本次 android 版本号是 ${VER}"; exit 1; }
    gh release download "$FROM" -p manifest-android.json -O "$CLEAN/manifest-android.json"
    "$HERE/carry-signature.sh" "$RELEASE_TAG" "$APK" "$APK.sig" "$CLEAN/manifest-android.json"
    echo "android：复用 ${FROM} 的 ${APK}（sha256 ${GOT_SHA}，versionName ${NAME}）"
    ;;
  macos)
    DMG="P-Pass_${VER}_macos-arm64.dmg"; UPD="P-Pass_${VER}_macos-arm64.app.tar.gz"; SUMS="SHA256SUMS-macos-arm64"
    for f in "$DMG" "$UPD" "$SUMS"; do gh release download "$FROM" -p "$f" -O "$f"; done
    for f in "$DMG" "$UPD"; do
      WANT_SHA=$(awk -v n="$f" '$2 == n || $2 == "*"n {print $1}' "$SUMS" | head -1)
      [ -n "$WANT_SHA" ] || { echo "::error::${FROM} 的 ${SUMS} 里没有 ${f}"; exit 1; }
      GOT_SHA=$(sha_of "$f")
      [ "$GOT_SHA" = "$WANT_SHA" ] || { echo "::error::${f} 的 sha256 与 ${FROM} 的 ${SUMS} 不符（记录 ${WANT_SHA}，实际 ${GOT_SHA}）"; exit 1; }
    done
    NAME=$(python3 - "$UPD" <<'PY'
import plistlib, sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    m = next((m for m in t.getmembers() if m.name.rstrip("/").endswith(".app/Contents/Info.plist")), None)
    print(plistlib.load(t.extractfile(m)).get("CFBundleShortVersionString", "") if m else "")
PY
)
    [ "$NAME" = "$VER" ] || { echo "::error::${UPD} 里 Info.plist 的 CFBundleShortVersionString=${NAME:-读不到}，本次 macOS 版本号是 ${VER}"; exit 1; }
    gh release download "$FROM" -p manifest-macos.json -O "$CLEAN/manifest-macos.json"
    "$HERE/carry-signature.sh" "$RELEASE_TAG" "$UPD" "$UPD.sig" "$CLEAN/manifest-macos.json"
    echo "macOS：复用 ${FROM} 的 ${DMG} / ${UPD}（sha256 与 ${SUMS} 一致，Info.plist ${NAME}）"
    ;;
  *) echo "未知端 ${END}" >&2; exit 2 ;;
esac
