#!/usr/bin/env bash
# #348：归档 iOS App → 云托管签名 → 上传 TestFlight（App Store Connect）。苹果标准做法：
# App Store Connect API 密钥 + 云托管签名，不导出、不保管任何 p12 / 描述文件。
#
# 签名只发生在导出这一步（云端）：归档时 CODE_SIGNING_ALLOWED=NO，不碰钥匙串、不连 Apple。
# 以前归档也带 -allowProvisioningUpdates + API 密钥做自动签名：runner 每次都是全新钥匙串，Xcode 就在
# 归档时新建一张 Apple Development 证书，一次一张，累积到账号上限后归档直接失败
# （"maximum number of certificates" / "No profiles for …"，run 40298231858）。
# 门禁：tools/ios/check-testflight-signing.sh（归档不许带签名更新参数、必须关签名）。
#
#   PPF_BUILD_VERSION=v0.9.13-test.1 ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_P8="$(cat AuthKey.p8)" \
#     tools/ios/testflight-upload.sh [--require-prerelease] [--archive-only]
#
# 输入（环境变量）：
#   PPF_BUILD_VERSION  完整版本串（可带 v），换算规则见 tools/ios/stamp-version.sh。**必填**——
#                      为空会回退 Base.xcconfig 的 0.1.0，而 App Store Connect 不接受重复的构建号，
#                      一次误传就把将来正式版要用的号占掉。
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8   API 密钥三件套（P8 是 .p8 文件的文本内容）。
#                      或设 ASC_KEY_P8_FILE=<已有的 p8 文件路径>（本机用）。
# 选项：
#   --require-prerelease  版本必须是 X.Y.Z-test.N / X.Y.Z-beta.N（手动入口用：防止手点一次就占掉正式版的号）。
#   --archive-only        只归档并校验归档里的版本号，不导出、不上传（不需要 ASC 密钥；产出的是无签名归档）。
#
# 做了什么（任何一步失败都退出非零）：
#   1. 校验版本串、换算 CFBundleShortVersionString / CFBundleVersion
#   2. 生成传输 XCFramework（缺才生成）+ xcodegen
#   3. xcodebuild archive（Release、generic/platform=iOS、CODE_SIGNING_ALLOWED=NO：无签名、无证书、不连 Apple）
#   4. 用 PlistBuddy 读归档里 .app 的 Info.plist，核对 版本 / 构建号 / PPassFullVersion / 加密声明——
#      **在占用构建号之前**拦住版本号错位
#   5. 给归档里的 .app 补一个 ad-hoc 签名（codesign -s -，不需要证书），只为把 entitlements 带进归档：
#      导出时 Xcode 从归档里已有的签名读 entitlements，无签名归档会让 App Group 等能力被悄悄丢掉
#   6. xcodebuild -exportArchive（method app-store-connect、destination upload、-allowProvisioningUpdates
#      + API 密钥）：云托管分发证书在 Apple 侧签名，导出即上传
#
# p8 只落在 umask 077 的临时文件里，脚本退出（含失败）即删；全程不 set -x、不回显密钥。
# 构建号一旦上传就被占用：同一个 PPF_BUILD_VERSION 重传会被拒（失败重试要换新的 test 序号）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
OUT="$IOS/build/testflight"
rm -rf "$OUT"; mkdir -p "$OUT"

REQUIRE_PRERELEASE=0
ARCHIVE_ONLY=0
for a in "$@"; do
  case "$a" in
    --require-prerelease) REQUIRE_PRERELEASE=1 ;;
    --archive-only) ARCHIVE_ONLY=1 ;;
    *) echo "usage: $0 [--require-prerelease] [--archive-only]" >&2; exit 2 ;;
  esac
done

# ── 1. 版本 ──────────────────────────────────────────────────────────
if [ -z "${PPF_BUILD_VERSION:-}" ]; then
  echo "testflight-upload: PPF_BUILD_VERSION 为空——拒绝回退默认版本（会占掉正式版的构建号）" >&2
  exit 1
fi
FULL="${PPF_BUILD_VERSION#v}"
read -r SHORT BUILD FULL <<<"$("$ROOT/tools/ios/stamp-version.sh" --print "$FULL")"
if [ "$REQUIRE_PRERELEASE" = 1 ] && [[ "$FULL" != *-test.* && "$FULL" != *-beta.* ]]; then
  echo "testflight-upload: --require-prerelease：「${FULL}」不是 X.Y.Z-test.N / -beta.N" >&2
  exit 1
fi
export PPF_BUILD_VERSION="$FULL"
echo "版本：${FULL} → CFBundleShortVersionString=${SHORT} CFBundleVersion=${BUILD}"

PLIST_BUDDY=/usr/libexec/PlistBuddy
TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM\[sdk=iphoneos\*\]: *\([A-Z0-9]*\).*/\1/p' "$IOS/project.yml" | head -1)
[ -n "$TEAM" ] || { echo "testflight-upload: project.yml 里找不到 DEVELOPMENT_TEAM[sdk=iphoneos*]" >&2; exit 1; }

command -v xcodegen >/dev/null || { echo "error: 缺 xcodegen" >&2; exit 1; }

# ── 密钥（仅非 archive-only）─────────────────────────────────────────
TMPD=$(mktemp -d)
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT
# 只给导出（第 6 步）用；归档（第 3 步）绝不带，见文件头。
EXPORT_SIGN_ARGS=(-allowProvisioningUpdates)
if [ "$ARCHIVE_ONLY" = 0 ]; then
  : "${ASC_KEY_ID:?ASC_KEY_ID 未设置}"
  : "${ASC_ISSUER_ID:?ASC_ISSUER_ID 未设置}"
  KEY_FILE="$TMPD/AuthKey_${ASC_KEY_ID}.p8"
  if [ -n "${ASC_KEY_P8_FILE:-}" ]; then
    [ -s "$ASC_KEY_P8_FILE" ] || { echo "error: ASC_KEY_P8_FILE 不存在或为空" >&2; exit 1; }
    (umask 077; cp "$ASC_KEY_P8_FILE" "$KEY_FILE")
  else
    : "${ASC_KEY_P8:?ASC_KEY_P8 未设置}"
    (umask 077; printf '%s\n' "$ASC_KEY_P8" > "$KEY_FILE")
  fi
  grep -q 'BEGIN PRIVATE KEY' "$KEY_FILE" || { echo "error: ASC_KEY_P8 不是 .p8 私钥文本（不回显内容）" >&2; exit 1; }
  EXPORT_SIGN_ARGS+=(-authenticationKeyPath "$KEY_FILE" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# ── 2. 工程 ──────────────────────────────────────────────────────────
if [ ! -d "$IOS/TransportFFITests/Generated/TransportFFI.xcframework" ] || [ ! -f "$IOS/TransportFFITests/Generated/swift/transport.swift" ]; then
  "$ROOT/tools/build-ios-transport-xcframework.sh" "$IOS/TransportFFITests/Generated"
fi
(cd "$IOS" && xcodegen generate --quiet)

# ── 2.5 幂等：该构建号已在 App Store Connect ⇒ 不重复归档上传（补跑 / 重跑安全）──────────
# 同时是密钥的预检：鉴权失败 / 没有该 App 记录会在这里就红，不必等到十几分钟的归档之后。
if [ "$ARCHIVE_ONLY" = 0 ]; then
  rc=0
  ASC_KEY_P8="$(cat "$KEY_FILE")" python3 "$ROOT/tools/ios/asc-builds.py" --short "$SHORT" --build "$BUILD" || rc=$?
  if [ "$rc" = 0 ]; then
    echo "构建 ${FULL}（build ${BUILD}）已在 App Store Connect ⇒ 不重复上传"
    echo "short=${SHORT}"$'\n'"build=${BUILD}"$'\n'"full=${FULL}" > "$OUT/version.env"
    exit 0
  elif [ "$rc" != 2 ]; then
    echo "testflight-upload: 查 App Store Connect 失败（asc-builds.py 退出 ${rc}）——密钥 / 角色 / App 记录有问题" >&2
    exit 1
  fi
fi

# ── 3. 归档 ──────────────────────────────────────────────────────────
rm -rf "$OUT/PPass.xcarchive" "$OUT/export"
ARCHIVE="$OUT/PPass.xcarchive"
echo "==> xcodebuild archive（Release / generic iOS，无签名；团队 ${TEAM} 的签名在导出时由云端完成）"
xcodebuild archive \
  -project "$IOS/PPass.xcodeproj" -scheme PPass -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO >"$OUT/archive.log" 2>&1 || { tail -60 "$OUT/archive.log"; echo "testflight-upload: archive 失败（完整日志 $OUT/archive.log）" >&2; exit 1; }
tail -3 "$OUT/archive.log"

# ── 4. 归档里的版本校验（占用构建号之前）─────────────────────────────
APP=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' | head -1)
[ -n "$APP" ] || { echo "testflight-upload: 归档里没有 .app" >&2; exit 1; }
pl() { "$PLIST_BUDDY" -c "Print :$1" "$APP/Info.plist"; }
check() { # <键> <期望>
  local got; got=$(pl "$1" 2>/dev/null || echo "<缺>")
  if [ "$got" != "$2" ]; then echo "testflight-upload: 归档 Info.plist 的 $1 = ${got}，期望 ${2}" >&2; exit 1; fi
}
check CFBundleShortVersionString "$SHORT"
check CFBundleVersion "$BUILD"
check PPassFullVersion "$FULL"
check PPassVersionSource PPF_BUILD_VERSION
check ITSAppUsesNonExemptEncryption false
echo "归档校验通过：${FULL}（short ${SHORT} / build ${BUILD}）"
{
  echo "short=${SHORT}"
  echo "build=${BUILD}"
  echo "full=${FULL}"
} > "$OUT/version.env"

# ── 5. 把 entitlements 带进归档（ad-hoc 签名，不需要证书）──────────────
# entitlements 来自 project.yml 生成的 PPass.entitlements（唯一来源）。application-identifier /
# team-identifier 等由导出时的分发描述文件补上，这里不写。嵌套的 framework / appex 若将来出现，
# 一并 ad-hoc 签（自内向外），导出时云签名会整体重签。
ENT="$IOS/PPass/PPass.entitlements"
[ -f "$ENT" ] || { echo "testflight-upload: 找不到 $ENT" >&2; exit 1; }
while IFS= read -r nested; do
  codesign --force --sign - --timestamp=none "$nested"
done < <(find "$APP" -mindepth 2 \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -prune -print | sort -r)
codesign --force --sign - --timestamp=none --entitlements "$ENT" "$APP"
got_ent=$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)
grep -q 'com.apple.security.application-groups' <<<"$got_ent" \
  || { echo "testflight-upload: 归档 .app 的签名里没有 App Group entitlement" >&2; exit 1; }
echo "归档 entitlements 已写入（ad-hoc）：$(codesign -dv "$APP" 2>&1 | grep -E '^Signature=' || true)"

if [ "$ARCHIVE_ONLY" = 1 ]; then
  echo "--archive-only：不导出、不上传"
  exit 0
fi

# ── 6. 导出即上传 ────────────────────────────────────────────────────
# manageAppVersionAndBuildNumber=false：构建号以我们盖的章为准（单调规则见 stamp-version.sh），
# 不让 Xcode 在导出时改写。
cat > "$TMPD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${TEAM}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
echo "==> xcodebuild -exportArchive（destination upload → TestFlight）"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$TMPD/ExportOptions.plist" \
    -exportPath "$OUT/export" "${EXPORT_SIGN_ARGS[@]}" >"$OUT/export.log" 2>&1; then
  tail -60 "$OUT/export.log"
  echo "testflight-upload: export/upload 失败（完整日志 $OUT/export.log）" >&2
  if grep -qiE 'cloud signing permission|Cloud signing|distribution certificate|No signing certificate' "$OUT/export.log"; then
    echo "提示：API 密钥没有云托管分发证书权限——需要用户在 App Store Connect 换 Admin 角色的密钥，或给该密钥开云托管证书权限。" >&2
  fi
  if grep -qiE 'no devices|has no devices' "$OUT/export.log"; then
    echo "提示：开发 profile 需要至少一台已登记设备——先在团队里登记一台设备。" >&2
  fi
  exit 1
fi
tail -15 "$OUT/export.log"
# 云签名后实际带上的 entitlements（只记录：此时已上传，判据在发版核对时看这一行）。
if [ -f "$OUT/export/DistributionSummary.plist" ]; then
  echo "导出后的 entitlements（DistributionSummary.plist）："
  plutil -p "$OUT/export/DistributionSummary.plist" | grep -A12 -i 'entitlements' || true
else
  echo "导出目录里没有 DistributionSummary.plist：$(ls "$OUT/export" 2>/dev/null | tr '\n' ' ')"
fi
grep -qiE 'Upload succeeded|Uploaded|upload.*complete' "$OUT/export.log" \
  && echo "上传成功：${FULL}（build ${BUILD}）" \
  || echo "注意：导出成功但日志里没找到明确的上传成功字样，请用 tools/ios/asc-builds.py 在 App Store Connect 侧核对。"
