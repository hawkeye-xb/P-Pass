#!/usr/bin/env bash
# H-10c: Build the human-facing P-Pass.app + dmg from the self-contained
# daemon bundle produced by bundle-macos.sh.
#
# Usage: tools/bundle-desktop-macos.sh <rel_dir> <dmg_out>
#   <rel_dir>  — output of bundle-macos.sh (contains daemon + lib/, rpath
#                already rewritten to @executable_path/lib)
#   <dmg_out>  — destination dir for P-Pass-macos-arm64.dmg (kept OUTSIDE
#                rel_dir so the self-contained zip never picks it up)
#
# Steps:
#   1. sidecar = bundled daemon (Tauri externalBin wants the -<triple> name)
#   2. pnpm tauri build --no-bundle  (compiles the p-pass-desktop shell)
#   3. pnpm tauri bundle             (produces P-Pass.app)
#   4. copy lib/ INTO the .app at Contents/MacOS/lib — the daemon's rpath is
#      @executable_path/lib, so it must sit next to the sidecar binary
#   5. re-sign the .app (mandatory after changing bundle contents on arm64)
#   6. hdiutil → P-Pass-macos-arm64.dmg
#
# Signing: ad-hoc by default (no-credential path, matches release.yml gating).
# Pass a second arg (codesign identity) for the signed path — caller gates it.
set -euo pipefail

REL="$1"; DMG_OUT="$2"
IDENTITY="${3:--}"
DESKTOP="$(cd "$(dirname "$0")/../apps/desktop" && pwd)"

[ -d "$REL/lib" ] || { echo "FATAL: $REL/lib missing — run bundle-macos.sh first" >&2; exit 1; }
[ -f "$REL/daemon" ] || { echo "FATAL: $REL/daemon missing" >&2; exit 1; }

echo "── 1. sidecar = bundled daemon"
mkdir -p "$DESKTOP/src-tauri/binaries"
cp "$REL/daemon" "$DESKTOP/src-tauri/binaries/ppf-daemon-aarch64-apple-darwin"

echo "── 2. pnpm install + tauri build --no-bundle"
cd "$DESKTOP"
pnpm install --frozen-lockfile
pnpm tauri build --no-bundle

echo "── 3. tauri bundle (.app)"
pnpm tauri bundle

APP="$DESKTOP/src-tauri/target/release/bundle/macos/P-Pass.app"
[ -d "$APP" ] || { echo "FATAL: $APP not produced" >&2; exit 1; }

echo "── 4. embed lib/ next to sidecar (rpath @executable_path/lib)"
rm -rf "$APP/Contents/MacOS/lib"
cp -R "$REL/lib" "$APP/Contents/MacOS/lib"

echo "── 5. re-sign .app ($IDENTITY)"
# H-02: 公证要求 hardened runtime + timestamp——ad-hoc 路径同样带上
#（无害且与凭据路径行为一致），否则 .app 内可执行无 runtime 选项，
# notarytool 提交 dmg 时可能被 Apple 拒。
codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP"

echo "── 6. dmg → $DMG_OUT/P-Pass-macos-arm64.dmg"
mkdir -p "$DMG_OUT"
rm -rf /tmp/pp-dmg-stage && mkdir -p /tmp/pp-dmg-stage
cp -R "$APP" /tmp/pp-dmg-stage/
hdiutil create -volname "P-Pass" -srcfolder /tmp/pp-dmg-stage \
  -ov -format UDZO "$DMG_OUT/P-Pass-macos-arm64.dmg"

echo "── done: $(du -sh "$DMG_OUT/P-Pass-macos-arm64.dmg" | cut -f1) dmg"
