#!/usr/bin/env bash
# #1110：macOS 内置 daemon 的嵌套 helper App —— 组装、签名、本地开发。
#
# daemon 要读写 data protection 钥匙串，必须带 `keychain-access-groups` 权限，并由
# 嵌入的 provisioning profile 授权（Apple TN3137）；裸可执行文件没有地方放授权文件，
# 所以组装成独立的 .app，放在 P-Pass.app/Contents/Helpers/ 下：
#
#   ppf-daemon.app/Contents/
#     Info.plist                 CFBundleIdentifier = com.hawkeyexb.ppass.desktop.daemon
#     MacOS/ppf-daemon           bundle-macos.sh 产出的 daemon（rpath @executable_path/lib）
#     MacOS/lib/*.dylib          同上，与可执行文件并排
#     embedded.provisionprofile  只在 Developer ID 签名时放
#
# 用法：
#   assemble <rel_dir> <helper.app> <version>
#       <rel_dir> = bundle-macos.sh 的输出（daemon + lib/）。只摆文件、不签名；
#       不依赖 macOS 工具（release dry-run 在 Linux 上跑这一步）。
#   sign <helper.app> <identity> [profile]
#       由内向外：lib/*.dylib → helper。identity 为 `-` 时 ad-hoc 签名、不带权限声明
#       也不放授权文件（ad-hoc 签名带受限权限，进程一启动就被系统杀掉）。
#       Developer ID 签名必须给授权文件，签前核对它、签后核对结果。
#       PPF_SIGN_TIMESTAMP=none 跳过 Apple 时间戳服务（本地开发用；发布不许）。
#   dev [daemon_bin]
#       本地开发：把本地构建的 daemon（缺省 target/debug/daemon，先 cargo build）组装到
#       apps/desktop/src-tauri/target/Helpers/ppf-daemon.app（`tauri dev` 的壳按
#       ../Helpers/ppf-daemon.app 找 daemon，crates/platform/src/macos.rs
#       `bundled_daemon_path_from`），再用个人团队的 Developer ID 证书 + 授权文件签名。
#       #1115：签名 helper 只接受签名的窗口程序，未签名的开发壳连不上它；开发壳连测试沙盒
#       （`just dev-daemon` + PPF_SANDBOX_DIR，见 justfile 的 dev-desktop）。
#       授权文件路径由 PPF_DAEMON_PROVISIONPROFILE 给。不打 dmg、不公证，几秒。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WT="$ROOT/tools/release/with-timeout.sh"
ENTITLEMENTS="$ROOT/apps/desktop/src-tauri/macos/daemon-helper.entitlements"

BUNDLE_ID="com.hawkeyexb.ppass.desktop.daemon"
TEAM_ID="2WJUWVUJBN"
ACCESS_GROUP="$TEAM_ID.$BUNDLE_ID"
EXE_NAME="ppf-daemon"

die() { echo "FATAL: $*" >&2; exit 1; }

assemble() {
  local rel="$1" helper="$2" version="$3"
  [ -f "$rel/daemon" ] || die "$rel/daemon 不存在——先跑 tools/bundle-macos.sh"
  [ -d "$rel/lib" ] || die "$rel/lib 不存在——先跑 tools/bundle-macos.sh"
  [ -n "$version" ] || die "assemble 需要版本号"
  rm -rf "$helper"
  mkdir -p "$helper/Contents/MacOS"
  cp "$rel/daemon" "$helper/Contents/MacOS/$EXE_NAME"
  chmod +x "$helper/Contents/MacOS/$EXE_NAME"
  cp -R "$rel/lib" "$helper/Contents/MacOS/lib"
  # python3 标准库 plistlib：dry-run 在 Linux 上跑，那里没有 PlistBuddy / plutil。
  # #1115：最低系统版本只有一个来源——tauri.conf.json 的 bundle.macOS.minimumSystemVersion
  # （外层 App 的 LSMinimumSystemVersion 也来自它）。helper 与外层一致。
  python3 - "$helper/Contents/Info.plist" "$BUNDLE_ID" "$EXE_NAME" "$version" \
    "$ROOT/apps/desktop/src-tauri/tauri.conf.json" <<'PY'
import json, plistlib, sys
out, bundle_id, exe, version, conf = sys.argv[1:]
min_os = json.load(open(conf))["bundle"]["macOS"]["minimumSystemVersion"]
with open(out, "wb") as f:
    plistlib.dump({
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": exe,
        "CFBundleName": exe,
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        # 后台进程：不进 Dock、不出菜单栏
        "LSUIElement": True,
        "LSMinimumSystemVersion": min_os,
    }, f)
PY
  echo "   helper 组装完成：${helper}（${version}）"
}

# 解析授权文件，核对它就是给本 helper 用的那一份。失败即退出。
check_profile() {
  local profile="$1" decoded
  [ -f "$profile" ] || die "授权文件不存在：$profile"
  decoded="$(mktemp)"
  security cms -D -i "$profile" >"$decoded" 2>/dev/null || die "授权文件解不开（不是 .provisionprofile？）：$profile"
  python3 - "$decoded" "$TEAM_ID" "$BUNDLE_ID" "$ACCESS_GROUP" <<'PY' || { rm -f "$decoded"; exit 1; }
import datetime, plistlib, sys
path, team, bundle_id, group = sys.argv[1:]
d = plistlib.load(open(path, "rb"))
ent = d.get("Entitlements", {})
problems = []
if team not in d.get("TeamIdentifier", []):
    problems.append(f"TeamIdentifier = {d.get('TeamIdentifier')}，应含 {team}")
if ent.get("com.apple.application-identifier") != f"{team}.{bundle_id}":
    problems.append(f"application-identifier = {ent.get('com.apple.application-identifier')!r}，应为 {team}.{bundle_id}")
groups = ent.get("keychain-access-groups", [])
if group not in groups and f"{team}.*" not in groups:
    problems.append(f"keychain-access-groups = {groups}，不覆盖 {group}")
if "OSX" not in d.get("Platform", []):
    problems.append(f"Platform = {d.get('Platform')}，应含 OSX")
if d.get("ProvisionedDevices"):
    problems.append("这是开发授权文件（带 ProvisionedDevices），应为 Developer ID 授权文件")
exp = d.get("ExpirationDate")
# plistlib 读出的是不带时区的 UTC 时间
if exp is None or exp <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    problems.append(f"已过期：ExpirationDate = {exp}")
if problems:
    print("FATAL: 授权文件不对：\n  " + "\n  ".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"   授权文件：{d.get('Name')}，到期 {exp:%Y-%m-%d}")
PY
  rm -f "$decoded"
}

sign() {
  local helper="$1" identity="$2" profile="${3:-}"
  local exe="$helper/Contents/MacOS/$EXE_NAME" lib
  [ -x "$exe" ] || die "$exe 不存在——先 assemble"

  if [ "$identity" = "-" ]; then
    # ad-hoc：无团队 ID，钥匙串访问组无从授权；带上权限声明进程会被系统当场杀掉。
    rm -f "$helper/Contents/embedded.provisionprofile"
    for lib in "$helper"/Contents/MacOS/lib/*.dylib; do
      [ -f "$lib" ] || continue
      "$WT" "codesign dylib（ad-hoc）" 120 1 -- codesign --force --sign - "$lib"
    done
    "$WT" "codesign helper（ad-hoc）" 120 1 -- codesign --force --sign - "$helper"
    echo "warn: helper 是 ad-hoc 签名，不带钥匙串权限——这个包里的 daemon 读写不了钥匙串。" >&2
    return 0
  fi

  [ -n "$profile" ] || die "Developer ID 签名必须给授权文件（#1110）"
  check_profile "$profile"
  cp "$profile" "$helper/Contents/embedded.provisionprofile"

  local ts=(--timestamp) ts_label="Apple 时间戳服务" ts_tries=2
  if [ "${PPF_SIGN_TIMESTAMP:-}" = "none" ]; then
    ts=(--timestamp=none) ts_label="不带时间戳" ts_tries=1
  fi
  # 由内向外：先 dylib（hardened runtime 的库校验要求与可执行文件同团队），再 helper 本身。
  for lib in "$helper"/Contents/MacOS/lib/*.dylib; do
    [ -f "$lib" ] || continue
    "$WT" "codesign dylib（${ts_label}）" 300 "$ts_tries" -- \
      codesign --force --sign "$identity" --options runtime "${ts[@]}" "$lib"
  done
  "$WT" "codesign helper（${ts_label}）" 300 "$ts_tries" -- \
    codesign --force --sign "$identity" --options runtime "${ts[@]}" \
    --entitlements "$ENTITLEMENTS" "$helper"
  verify_signed "$helper"
}

# 签完核对：标识、团队、hardened runtime、访问组、嵌入的授权文件。
verify_signed() {
  local helper="$1" info ent
  "$WT" "codesign 校验 helper" 120 1 -- codesign --verify --strict "$helper"
  info="$(codesign -dvv "$helper" 2>&1)"
  grep -qx "Identifier=$BUNDLE_ID" <<<"$info" || die "helper 的 Identifier 不是 $BUNDLE_ID"
  grep -qx "TeamIdentifier=$TEAM_ID" <<<"$info" || die "helper 不是团队 $TEAM_ID 签的"
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\(runtime\)' <<<"$info" || die "helper 没开 hardened runtime"
  ent="$(codesign -d --entitlements - --xml "$helper" 2>/dev/null)"
  grep -q "<string>$ACCESS_GROUP</string>" <<<"$ent" || die "helper 的权限声明里没有访问组 $ACCESS_GROUP"
  [ -f "$helper/Contents/embedded.provisionprofile" ] || die "helper 里没有 embedded.provisionprofile"
  echo "   ✓ helper 签名：$BUNDLE_ID / 团队 $TEAM_ID / runtime / 访问组 $ACCESS_GROUP"
}

dev() {
  local daemon="${1:-}" stage helper identity version
  [ "$(uname)" = "Darwin" ] || die "dev 只在 macOS 上用"
  local profile="${PPF_DAEMON_PROVISIONPROFILE:-}"
  [ -n "$profile" ] || die "设 PPF_DAEMON_PROVISIONPROFILE=<授权文件路径>（Developer ID 授权文件，不进仓库）"
  if [ -z "$daemon" ]; then
    (cd "$ROOT" && cargo build -p daemon)
    daemon="$ROOT/target/debug/daemon"
  fi
  [ -x "$daemon" ] || die "daemon 不存在：$daemon"
  # 只认个人团队的 Developer ID Application 证书，恰好一张；别的团队一律不用。
  identity="$(security find-identity -v -p codesigning \
    | awk -v team="($TEAM_ID)\"" '/"Developer ID Application: / && index($0, team) {print $2}' | sort -u)"
  [ -n "$identity" ] || die "钥匙串里没有团队 $TEAM_ID 的 Developer ID Application 证书"
  [ "$(wc -l <<<"$identity" | tr -d ' ')" = "1" ] || die "团队 $TEAM_ID 的 Developer ID Application 证书不止一张，拿不准用哪张"
  version="$("$ROOT/tools/release-version.sh" desktop)"
  stage="$(mktemp -d)"
  "$ROOT/tools/bundle-macos.sh" "$stage" "$daemon" >/dev/null
  helper="$ROOT/apps/desktop/src-tauri/target/Helpers/ppf-daemon.app"
  assemble "$stage" "$helper" "$version"
  rm -rf "$stage"
  PPF_SIGN_TIMESTAMP=none sign "$helper" "$identity" "$profile"
  "$helper/Contents/MacOS/$EXE_NAME" --version
  echo "── done: $helper"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  assemble) [ $# -eq 3 ] || die "用法：$0 assemble <rel_dir> <helper.app> <version>"; assemble "$@" ;;
  sign) [ $# -ge 2 ] || die "用法：$0 sign <helper.app> <identity> [profile]"; sign "$@" ;;
  dev) dev "$@" ;;
  *) die "用法：$0 assemble|sign|dev …（见文件头）" ;;
esac
