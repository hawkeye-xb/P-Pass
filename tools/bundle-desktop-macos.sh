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
# H-10b (2026-08-08, xixi): dmg 打开必须"无脑拖拽"——先出可写卷，
# 挂载后放 Applications 链接 + Finder 布局（图标位置/视图选项），
# 再转 UDZO。缺布局时 dmg 里"孤零零一个程序"，用户不知道拖到
# Applications（真机实测反馈）。
hdiutil create -volname "P-Pass" -srcfolder /tmp/pp-dmg-stage \
  -ov -format UDRW /tmp/pp-dmg-rw.dmg
hdiutil attach /tmp/pp-dmg-rw.dmg -mountpoint /Volumes/P-Pass -nobrowse
ln -s /Applications /Volumes/P-Pass/Applications
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "P-Pass"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 520, 400}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set position of item "P-Pass.app" of container window to {130, 180}
    set position of item "Applications" of container window to {390, 180}
    close
  end tell
end tell
APPLESCRIPT
# 布局失败（无头 CI 的 TCC 可能拦 Apple Events）不致命：Applications
# 链接已在，拖拽路径仍然成立；布局只是窗口观感。
if [ $? -ne 0 ]; then echo "warning: Finder layout skipped (headless/TCC) — Applications link still present"; fi
hdiutil detach /Volumes/P-Pass -quiet
hdiutil convert /tmp/pp-dmg-rw.dmg -format UDZO -o "$DMG_OUT/P-Pass-macos-arm64.dmg"
rm -f /tmp/pp-dmg-rw.dmg

echo "── done: $(du -sh "$DMG_OUT/P-Pass-macos-arm64.dmg" | cut -f1) dmg"
