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
# Hardened runtime enforces library validation. An ad-hoc signature has no
# Team ID, so a daemon with `runtime` cannot map the bundled Homebrew dylibs.
# Use runtime + timestamp only for a real Developer ID identity; release CI
# supplies that identity before notarization. Local dogfood must stay ad-hoc
# and must not claim to be notarization-ready.
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
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
# 几何（2026-08-25 修）：窗口必须装得下两个图标 + 文字标签。
# 旧值 bounds {100,100,520,400} = 420 宽，而 Applications 图标位置
# x=390、图标 96px → 横跨 342..438，**溢出内容区 18px**，还没算比图标
# 更宽的文字标签——真机观感就是"窗口太小，两个图标放不下"（验收人反馈）。
# 现在 560×360：图标中心 x=150 / x=410，各占 102..198 / 362..458，
# 两侧都留出余量；y=180 在 332 高的内容区里居中偏上，标签不贴底边。
#   bounds = {left, top, right, bottom}（屏幕坐标，含标题栏 ~28px）
#   position = 图标中心，内容区坐标系
# 下面这四个数与 AppleScript 里的必须一致——单改一处就是这次的 bug 复发，
# 所以先在 shell 里算一遍装不装得下，装不下直接失败，不许出一个观感坏掉
# 的 dmg。半宽取文字标签宽度（比 96px 图标更宽，标签才是真正的溢出源）。
DMG_W=560; ICON_X_APP=150; ICON_X_APPS=410; LABEL_HALF=70
if [ $((ICON_X_APP - LABEL_HALF)) -lt 0 ] || [ $((ICON_X_APPS + LABEL_HALF)) -gt "$DMG_W" ]; then
  echo "error: dmg 图标放不进 ${DMG_W}px 宽的窗口——" \
       "app 横跨 $((ICON_X_APP - LABEL_HALF))..$((ICON_X_APP + LABEL_HALF))，" \
       "Applications 横跨 $((ICON_X_APPS - LABEL_HALF))..$((ICON_X_APPS + LABEL_HALF))" >&2
  exit 1
fi
osascript <<'APPLESCRIPT' || echo "warning: Finder layout skipped (headless/TCC) — Applications link still present"
tell application "Finder"
  tell disk "P-Pass"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 660, 460}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set position of item "P-Pass.app" of container window to {150, 180}
    set position of item "Applications" of container window to {410, 180}
    close
  end tell
end tell
APPLESCRIPT
# ⚠️ 上面用 `|| echo` 而不是事后判 `$?`。本脚本开头是 `set -euo pipefail`，
# osascript 一旦非零退出脚本当场就死，事后那句 `if [ $? -ne 0 ]` 永远
# 执行不到——注释里写的「布局失败不致命」在旧写法下是假的，无头 CI 的
# TCC 拦 Apple Events 就会连带炸掉整个打包步骤（2026-08-25 发现）。
# 布局确实不致命：Applications 链接已在，拖拽路径仍然成立。
hdiutil detach /Volumes/P-Pass -quiet
hdiutil convert /tmp/pp-dmg-rw.dmg -format UDZO -o "$DMG_OUT/P-Pass-macos-arm64.dmg"
rm -f /tmp/pp-dmg-rw.dmg

echo "── done: $(du -sh "$DMG_OUT/P-Pass-macos-arm64.dmg" | cut -f1) dmg"
