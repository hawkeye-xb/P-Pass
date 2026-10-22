#!/usr/bin/env bash
# H-10c: Build the human-facing P-Pass.app + dmg from the self-contained
# daemon bundle produced by bundle-macos.sh.
#
# Usage: tools/bundle-desktop-macos.sh <rel_dir> <dmg_out>
#   <rel_dir>  — output of bundle-macos.sh (contains daemon + lib/, rpath
#                already rewritten to @executable_path/lib)
#   <dmg_out>  — destination dir for the dmg (name from tools/artifact-names.sh:
#                P-Pass_<desktop 端版本>_macos-arm64.dmg; release.yml passes
#                rel_dir itself so the dmg lands next to the other assets)
#
# Steps:
#   1. (none) macOS 不走 Tauri externalBin（tauri.macos.conf.json 置空，#1110）
#   2. pnpm tauri build --no-bundle  (compiles the p-pass-desktop shell)
#   3. pnpm tauri bundle             (produces P-Pass.app, shell only)
#   4. #1110：daemon + lib/ 组装成嵌套 helper App
#      Contents/Helpers/ppf-daemon.app（tools/daemon-helper-macos.sh assemble）
#   5. 由内向外逐层签名：lib/*.dylib → helper（带钥匙串权限声明 + 授权文件）
#      → P-Pass.app。不用 --deep：它会用外层的参数重签内层，冲掉 helper 的权限声明。
#   6. hdiutil → P-Pass_<版本>_macos-arm64.dmg（UPD-15 #685：名字由
#      tools/artifact-names.sh 单源派生，不再硬编码）
#
# 版本号（#809）：外壳与 daemon 是同一次构建的两个产物，版本号只有一个来源——
# `tools/release-version.sh desktop`（正式 tag 取 release/versions.json，test tag
# 取 tag 名）。daemon 由 release.yml 经 PPF_BUILD_VERSION 注入同一个值；外壳在
# 第 2、3 步经 tauri 官方的 `--config` 合并注入（编进二进制的 package_info /
# getVersion()、Info.plist、updater 的当前版本都取它）。tauri.conf.json 里的
# "version" 不再是产物版本的来源。第 5c 步实读产物核对三者一致，不一致不许出门。
#
# Signing: ad-hoc by default (no-credential path, matches release.yml gating).
# Pass a third arg (codesign identity) for the signed path — caller gates it.
# 签名路径必须同时给 PPF_DAEMON_PROVISIONPROFILE=<daemon 授权文件路径>（#1110），
# 缺了直接失败：不出 daemon 读写不了钥匙串的包。
set -euo pipefail

REL="$1"; DMG_OUT="$2"
IDENTITY="${3:--}"
DESKTOP="$(cd "$(dirname "$0")/../apps/desktop" && pwd)"
# #772：codesign / hdiutil / osascript 都可能挂住（v2026.10.3 实发：codesign --timestamp
# 卡 14 分钟），一律经墙钟上限执行，超时打印是哪一步。只有依赖外部网络服务的那一步
# （Developer ID 签名要请求 Apple 时间戳服务）自动重试一次；本地命令挂住时立即失败——
# 挂载到一半的卷不适合原地重试，留给人 rerun failed jobs。上限取值：这些命令平时都在
# 数秒内结束（整个第 5-6 步以往 4.6 分钟，大头是 hdiutil convert）。
WT="$(cd "$(dirname "$0")/release" && pwd)/with-timeout.sh"
# UPD-15：dmg 名 = P-Pass_<desktop 端版本>_macos-arm64.dmg（唯一真相在 artifact-names.sh）
DMG_NAME="$("$(dirname "$0")/artifact-names.sh" macos-dmg)"
# #809：本次构建的版本号（与 dmg 名、daemon 的 PPF_BUILD_VERSION 同源）。
VERSION="$("$(dirname "$0")/release-version.sh" desktop)"
[ -n "$VERSION" ] || { echo "FATAL: tools/release-version.sh desktop 没给出版本号" >&2; exit 1; }
# 两次 tauri 调用（build / bundle）读同一份合并配置；不改动入库的 tauri.conf.json。
# tauri CLI 的 --config 接受 JSON 字符串（官方用法）。
# #852：配置由 macOS / Windows 共用的 tools/release/tauri-config.mjs 生成——version，外加 test
# 版本时把 updater 插件的 endpoint 换成 test-channel/manifest-macos.json（test 包与正式包走同一条
# 插件应用内更新，只有清单地址不同）。endpoint 在 build 那一步编进二进制，两次调用必须同一份。
VERSION_CONFIG="$(node "$(dirname "$0")/release/tauri-config.mjs" macos "$VERSION")"
echo "tauri --config: $VERSION_CONFIG"

[ -d "$REL/lib" ] || { echo "FATAL: $REL/lib missing — run bundle-macos.sh first" >&2; exit 1; }
[ -f "$REL/daemon" ] || { echo "FATAL: $REL/daemon missing" >&2; exit 1; }

HELPER_TOOL="$(cd "$(dirname "$0")" && pwd)/daemon-helper-macos.sh"
PROFILE="${PPF_DAEMON_PROVISIONPROFILE:-}"
if [ "$IDENTITY" != "-" ] && [ -z "$PROFILE" ]; then
  echo "FATAL: Developer ID 签名需要 daemon 授权文件：设 PPF_DAEMON_PROVISIONPROFILE（#1110）" >&2
  exit 1
fi

echo "── 2. pnpm install + tauri build --no-bundle（版本 ${VERSION}）"
cd "$DESKTOP"
pnpm install --frozen-lockfile
pnpm tauri build --no-bundle --config "$VERSION_CONFIG"

echo "── 3. tauri bundle (.app)"
# #1121：只出 .app（`--bundles app`），严格失败。
# - tauri 自己的 dmg 用不到（第 6 步按我们的布局自己出 dmg），本地无头时它还会失败；
# - createUpdaterArtifacts 已关：updater 包由 release.yml 的 Pack updater 从最终 .app
#   现打，签名在独立的签名步骤做，构建环境不拿更新签名私钥。以前（BUILD-05）这一步
#   因为本地没有私钥必然失败、只能容忍非零退出，现在没有这个理由了。
pnpm tauri bundle --bundles app --config "$VERSION_CONFIG"

APP="$DESKTOP/src-tauri/target/release/bundle/macos/P-Pass.app"
[ -d "$APP" ] || { echo "FATAL: $APP not produced" >&2; exit 1; }

echo "── 4. 组装 daemon helper：Contents/Helpers/ppf-daemon.app（#1110）"
HELPER="$APP/Contents/Helpers/ppf-daemon.app"
"$HELPER_TOOL" assemble "$REL" "$HELPER" "$VERSION"
# 裸 sidecar 的老布局不许再出现：壳只认 helper（platform::bundled_daemon_path）。
for stale in "$APP/Contents/MacOS/ppf-daemon" "$APP/Contents/MacOS/lib"; do
  [ ! -e "$stale" ] || { echo "FATAL: .app 里出现了老布局 ${stale}（externalBin 没关掉？）" >&2; exit 1; }
done

echo "── 5. 由内向外签名（${IDENTITY}）：helper → .app"
# Hardened runtime enforces library validation. An ad-hoc signature has no
# Team ID, so a daemon with `runtime` cannot map the bundled Homebrew dylibs.
# Use runtime + timestamp only for a real Developer ID identity; release CI
# supplies that identity before notarization. Local dogfood must stay ad-hoc
# and must not claim to be notarization-ready.
if [ "$IDENTITY" = "-" ]; then
  "$HELPER_TOOL" sign "$HELPER" -
  "$WT" "codesign 外层 .app（ad-hoc）" 300 1 -- codesign --force --sign - "$APP"
else
  "$HELPER_TOOL" sign "$HELPER" "$IDENTITY" "$PROFILE"
  "$WT" "codesign 外层 .app（Developer ID + Apple 时间戳服务）" 300 2 -- \
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
"$WT" "codesign 校验 .app" 120 1 -- codesign --verify --deep --strict "$APP"

# ── 5b. BUILD-09 产物自检：真的把 sidecar 跑一遍 ──────────────────────
# 这是这条链路上**唯一执行产物**的一步。在它之前，所有检查看的都是「文件
# 在不在、签名完不完整」，没有一处回答过「它能不能启动」——于是「.app 里
# daemon 和它的 dylib 被拆散」这个形状可以一路绿灯走到用户机器上，失败在
# 运行时以 dyld 报错出现（BUILD-09）。
#
# 同一形状已经出现过两次，成因不同：
#   BUILD-05 — 第 3 步非零退出把第 4 步「嵌 lib」和第 5 步重签一起跳过；
#   BUILD-09 — 压根没走本脚本，直接 `tauri build` 只搬了 externalBin 那一个
#              二进制，daemon 的 rpath（@executable_path/lib）落空。
# 按成因逐个堵是堵不完的，所以这里只问结果：**跑得起来吗**。
#
# 反证锚点：`rm -rf "$HELPER/Contents/MacOS/lib"` 后本步必须失败。
# #1110：Developer ID 路径下这一步同时证明 helper 的权限声明被系统接受——
# 授权文件不覆盖权限声明时，进程一启动就被杀（退出码 137）。
SIDECAR="$HELPER/Contents/MacOS/ppf-daemon"
echo "── 5b. 产物自检：$SIDECAR --version"
[ -x "$SIDECAR" ] || { echo "FATAL: sidecar 不存在或不可执行：$SIDECAR" >&2; exit 1; }
if ! SELFCHECK_OUT="$("$SIDECAR" --version 2>&1)"; then
  echo "FATAL: .app 里的 daemon 起不起来——构建产物是坏的，不许出门。" >&2
  echo "       $SIDECAR --version 退出码非 0，输出：" >&2
  echo "$SELFCHECK_OUT" | sed 's/^/       /' >&2
  echo "       最常见成因：helper 的 Contents/MacOS/lib 缺失或不完整（daemon 的 rpath" >&2
  echo "       是 @executable_path/lib，库必须与 daemon 并排）；或权限声明没被授权文件覆盖（137）。" >&2
  exit 1
fi
echo "   ✓ $SELFCHECK_OUT"

# ── 5c. #809 版本同源自检：外壳（Info.plist）== daemon == 本次构建版本 ─────
# 同一次构建的两个产物，版本号必须来自同一个源。以前外壳取 tauri.conf.json、
# daemon 取 tag：正式 tag 恰好一致，test tag 就错开（壳 0.9.5 / 服务
# 0.9.12-test.1）。这里只问结果：产物里写的是不是同一个号。
# 反证锚点：去掉第 2/3 步的 `--config` 后，test tag 构建必须在本步失败。
# 用 python3 标准库 plistlib 读：dry-run 在 Linux runner 上跑，那里没有 PlistBuddy。
plist_version() { python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get("CFBundleShortVersionString",""))' "$1" 2>/dev/null || true; }
PLIST_VERSION="$(plist_version "$APP/Contents/Info.plist")"
HELPER_VERSION="$(plist_version "$HELPER/Contents/Info.plist")"
DAEMON_VERSION="${SELFCHECK_OUT#P-Pass daemon }"
echo "── 5c. 版本同源：构建 $VERSION / 外壳 Info.plist $PLIST_VERSION / helper Info.plist $HELPER_VERSION / daemon $DAEMON_VERSION"
if [ "$PLIST_VERSION" != "$VERSION" ] || [ "$HELPER_VERSION" != "$VERSION" ] || [ "$DAEMON_VERSION" != "$VERSION" ]; then
  echo "FATAL: 外壳与 daemon 的版本号不同源（#809）——" >&2
  echo "       tools/release-version.sh desktop = $VERSION" >&2
  echo "       Info.plist CFBundleShortVersionString = ${PLIST_VERSION:-<读不到>}" >&2
  echo "       ppf-daemon --version = $SELFCHECK_OUT" >&2
  echo "       daemon 须以 PPF_BUILD_VERSION=<上面这个号> 构建；外壳由本脚本 --config 注入。" >&2
  exit 1
fi

# ── 5d. #1110 签名形状自检（只在 Developer ID 路径）──────────────────────
# helper 带访问组、外层不带；包里每个 Mach-O 都是同一团队、hardened runtime、带时间戳
# （公证要求）。只在本地手查会漂，所以每次构建都查。
if [ "$IDENTITY" != "-" ]; then
  echo "── 5d. 签名形状自检"
  if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q keychain-access-groups; then
    echo "FATAL: 外层 P-Pass.app 带了 keychain-access-groups——只有 helper 该带" >&2
    exit 1
  fi
  APP_INFO="$(codesign -dvv "$APP" 2>&1)"
  grep -qx "Identifier=com.hawkeyexb.ppass.desktop" <<<"$APP_INFO" || {
    echo "FATAL: 外层 Identifier 不是 com.hawkeyexb.ppass.desktop（#1112）" >&2; exit 1; }
  cmp -s "$PROFILE" "$HELPER/Contents/embedded.provisionprofile" || {
    echo "FATAL: helper 里的 embedded.provisionprofile 不是本次给的授权文件" >&2; exit 1; }
  HELPER_TEAM="$(codesign -dvv "$HELPER" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q '^Mach-O' || continue
    INFO="$(codesign -dvv "$f" 2>&1)" || { echo "FATAL: 没签名：$f" >&2; exit 1; }
    grep -qx "TeamIdentifier=$HELPER_TEAM" <<<"$INFO" || { echo "FATAL: 团队不一致：$f" >&2; exit 1; }
    grep -Eq '^CodeDirectory .*\(runtime\)' <<<"$INFO" || { echo "FATAL: 没开 hardened runtime：$f" >&2; exit 1; }
    grep -q '^Timestamp=' <<<"$INFO" || { echo "FATAL: 没有安全时间戳：$f" >&2; exit 1; }
  done < <(find "$APP" -type f -print0)
  echo "   ✓ 每个 Mach-O：团队 $HELPER_TEAM / runtime / 时间戳；外层不带访问组；授权文件一致"
fi

# BUILD-05（验收人 2026-09-17 定调：本地先讲究快）：dmg 那套
# hdiutil + 挂载 + AppleScript 布局对狗粮验证零价值，只拖慢每一轮。
# ad-hoc 身份（= 本地无凭据路径）默认不出 dmg；要 dmg 就 PPF_BUNDLE_DMG=1。
# 传了真 identity 的 CI 路径行为一字不变。
if [ "$IDENTITY" = "-" ] && [ "${PPF_BUNDLE_DMG:-0}" != "1" ]; then
  echo "── 6. dmg 跳过（本地 ad-hoc 路径；要 dmg 设 PPF_BUNDLE_DMG=1）"
  echo "── done: $APP"
  exit 0
fi

echo "── 6. dmg → $DMG_OUT/$DMG_NAME"
mkdir -p "$DMG_OUT"
rm -rf /tmp/pp-dmg-stage && mkdir -p /tmp/pp-dmg-stage
cp -R "$APP" /tmp/pp-dmg-stage/
# H-10b (2026-08-08, xixi): dmg 打开必须"无脑拖拽"——先出可写卷，
# 挂载后放 Applications 链接 + Finder 布局（图标位置/视图选项），
# 再转 UDZO。缺布局时 dmg 里"孤零零一个程序"，用户不知道拖到
# Applications（真机实测反馈）。
"$WT" "hdiutil create（可写 dmg）" 600 1 -- hdiutil create -volname "P-Pass" -srcfolder /tmp/pp-dmg-stage \
  -ov -format UDRW /tmp/pp-dmg-rw.dmg
"$WT" "hdiutil attach" 120 1 -- hdiutil attach /tmp/pp-dmg-rw.dmg -mountpoint /Volumes/P-Pass -nobrowse
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
# #772：Finder 布局不致命（见下方 ⚠️），挂住同样按「跳过布局」处理。
"$WT" "osascript Finder 布局" 60 1 -- osascript <<'APPLESCRIPT' || echo "warning: Finder layout skipped (headless/TCC/timeout) — Applications link still present"
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
"$WT" "hdiutil detach" 120 1 -- hdiutil detach /Volumes/P-Pass -quiet
"$WT" "hdiutil convert（压缩 dmg）" 600 1 -- hdiutil convert /tmp/pp-dmg-rw.dmg -format UDZO -o "$DMG_OUT/$DMG_NAME"
rm -f /tmp/pp-dmg-rw.dmg

echo "── done: $(du -sh "$DMG_OUT/$DMG_NAME" | cut -f1) dmg"
