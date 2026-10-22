#!/usr/bin/env bash
# #838：tools/release/plan-builds.sh（构建还是复用）与 tools/release/reuse-artifact.sh（复用时的两道校验）的判定测试。
#
# 用 stub gh 喂一个假的 Latest 正式版（资产放在临时目录），逐条验：
#   plan-builds：test tag / 没有 Latest / Latest 就是本 tag / 版本号相同 / 缺清单 / 缺安装包 / 两端都相同。
#   plan-builds（#852 test tag 按端发布）：基线 = test-channel 里该端清单的版本；只改 Android / 只改桌面 /
#   改共享代码 / 只改文档 / 基线拿不到（无清单、坏清单、tag 不存在、不是祖先、就是本 tag）。
#   plan-builds（#1062）：Rust 改动按 Cargo 依赖图归属到端；入口包与真实构建命令、真实依赖图一致。
#   reuse-artifact：字节与 Latest 记录不符 ⇒ 红；包内版本号与本次不符 ⇒ 红；都对 ⇒ 取回。
# 核心断言一句话：**拿不准一律构建；复用必须字节与版本号都对得上**。
#
# 用法: tools/test-release-plan.sh
# 退出码: 0 全过 / 1 有失败
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# ── stub gh：release view（不带 tag = Latest）/ release download，数据在 $STUB_STATE ──
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, fnmatch
S = os.environ["STUB_STATE"]; a = sys.argv[1:]
def opt(n):
    return a[a.index(n) + 1] if n in a else None
pos = [x for i, x in enumerate(a[2:], 2) if not x.startswith("-") and a[i - 1] not in ("-q", "--json", "-p", "-O", "--jq")]
if a[:2] == ["release", "view"]:
    latest = open(os.path.join(S, "LATEST")).read().strip() if os.path.exists(os.path.join(S, "LATEST")) else ""
    tag = pos[0] if pos else latest
    d = os.path.join(S, tag)
    if not tag or not os.path.isdir(d): sys.stderr.write("release not found\n"); sys.exit(1)
    q = opt("-q")
    if q == ".tagName": print(tag)
    elif q == ".assets[].name": print("\n".join(sorted(os.listdir(d))))
    else: sys.exit(2)
elif a[:2] == ["release", "download"]:
    d = os.path.join(S, pos[0]); p = opt("-p"); out = opt("-O")
    hits = [n for n in sorted(os.listdir(d)) if fnmatch.fnmatch(n, p)] if os.path.isdir(d) else []
    if not hits: sys.stderr.write("no assets match the file pattern\n"); sys.exit(1)
    data = open(os.path.join(d, hits[0]), "rb").read()
    if out == "-": sys.stdout.buffer.write(data)
    else: open(out or hits[0], "wb").write(data)
else:
    sys.exit(2)
STUB
cat > "$TMP/bin/aapt2" <<'STUB'
#!/usr/bin/env python3
import sys, zipfile
print("package: name='com.hawkeyexb.ppass' versionName='%s'" % zipfile.ZipFile(sys.argv[-1]).read("VERSION").decode())
STUB
chmod +x "$TMP/bin/gh" "$TMP/bin/aapt2"
export PATH="$TMP/bin:$PATH"

# ── 夹具：一个假仓库（plan-builds 从仓库根读 release/versions.json）+ Latest 的资产 ──
REPO="$TMP/repo"
mkdir -p "$REPO/tools/release" "$REPO/release"
cp "$HERE/release/plan-builds.sh" "$HERE/release/rust-impact.py" "$HERE/release/reuse-artifact.sh" "$REPO/tools/release/"
git -C "$REPO" init -q && git -C "$REPO" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
mk_apk() { python3 - "$1" "$2" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z: z.writestr("VERSION", sys.argv[2]); z.writestr("classes.dex", b"x" * 64)
PY
}
mk_tar() { python3 - "$1" "$2" <<'PY'
import io, plistlib, sys, tarfile
p = plistlib.dumps({"CFBundleShortVersionString": sys.argv[2]})
with tarfile.open(sys.argv[1], "w:gz") as t:
    i = tarfile.TarInfo("P-Pass.app/Contents/Info.plist"); i.size = len(p); t.addfile(i, io.BytesIO(p))
PY
}
# latest <tag> <android 版本> <macOS 版本>：造一个完整的 Latest
latest() {
  local tag="$1" av="$2" mv="$3" d="$TMP/state/$1"
  rm -rf "$TMP/state"; mkdir -p "$d"; echo "$tag" > "$TMP/state/LATEST"
  mk_apk "$d/P-Pass_${av}_android.apk" "$av"
  printf '{"version":"%s","platforms":{"android-arm64":{"sha256":"%s"}}}\n' "$av" "$(sha "$d/P-Pass_${av}_android.apk")" > "$d/manifest-android.json"
  printf 'dmg-bytes' > "$d/P-Pass_${mv}_macos-arm64.dmg"
  mk_tar "$d/P-Pass_${mv}_macos-arm64.app.tar.gz" "$mv"
  (cd "$d" && for f in "P-Pass_${mv}_macos-arm64.dmg" "P-Pass_${mv}_macos-arm64.app.tar.gz"; do echo "$(sha "$f")  $f"; done > SHA256SUMS-macos-arm64)
  printf '{"version":"%s","platforms":{"darwin-aarch64":{}}}\n' "$mv" > "$d/manifest-macos.json"
}
export STUB_STATE="$TMP/state"

# plan <tag> <android 号> <macOS 号> [ios 号] ⇒ 设置 RC / OUT（不给 ios 号 = versions.json 里没有 ios 线）
plan() {
  if [ -n "${4:-}" ]; then
    printf '{"desktop":"%s","android":"%s","ios":"%s"}\n' "$3" "$2" "$4" > "$REPO/release/versions.json"
  else
    printf '{"desktop":"%s","android":"%s"}\n' "$3" "$2" > "$REPO/release/versions.json"
  fi
  OUT=$(cd "$REPO" && TAG="$1" GITHUB_OUTPUT=/dev/stdout tools/release/plan-builds.sh 2>&1); RC=$?
}
get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | tail -1; }
expect_plan() { # 说明 android macos
  if [ "$RC" = 0 ] && [ "$(get android)" = "$2" ] && [ "$(get macos)" = "$3" ]; then ok "$1"; else bad "$1（期望 android=$2 macos=$3）" "$OUT"; fi
}

echo "plan-builds"
latest v2026.1.1 1.0.0 2.0.0
# #852：原断言「test tag 恒两端构建」的意图是 test tag 绝不走 reuse。现在 test tag 按改动路径判定；
# test-channel 里还没有分端清单时拿不准 ⇒ 两端都构建（细则见下方 #852 一节）。
plan v1.2.3-test.4 1.0.0 2.0.0;  expect_plan "test tag：test-channel 无清单 ⇒ 两端都构建（即使版本号与 Latest 相同，也绝不 reuse）" build build
plan v2026.1.1 1.0.0 2.0.0;      expect_plan "Latest 就是本 tag（补跑）：两端都构建" build build
plan v2026.1.2 1.0.1 2.0.0;      expect_plan "只涨 android：android 构建、macOS 复用" build reuse
[ "$(get windows)" = skip ] && ok "正式 tag 不构建 Windows（windows=skip，#788 未定）" || bad "正式 tag 不构建 Windows" "$OUT"
[ "$(get reuse_from)" = v2026.1.1 ] && ok "复用来源 = Latest" || bad "复用来源 = Latest" "$OUT"
plan v2026.1.2 1.0.0 2.0.1;      expect_plan "只涨桌面：android 复用、macOS 构建" reuse build
plan v2026.1.2 1.0.0 2.0.0
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "::error::各端版本号都与 Latest"; then ok "各端都没涨号：明确报错"; else bad "各端都没涨号：明确报错" "$OUT"; fi
rm "$TMP/state/v2026.1.1/manifest-macos.json"
plan v2026.1.2 1.0.1 2.0.0;      expect_plan "Latest 缺 macOS 清单：macOS 构建（不猜）" build build
latest v2026.1.1 1.0.0 2.0.0; rm "$TMP/state/v2026.1.1/P-Pass_2.0.0_macos-arm64.dmg"
plan v2026.1.2 1.0.1 2.0.0;      expect_plan "Latest 缺 dmg：macOS 构建（不猜）" build build
rm -rf "$TMP/state"; mkdir -p "$TMP/state"
plan v2026.1.2 1.0.1 2.0.0;      expect_plan "没有 Latest：两端都构建" build build

echo "plan-builds（#348 正式 tag 的 iOS：只有 build / skip）"
expect_ios() { # <说明> <ios 判定>
  if [ "$RC" = 0 ] && [ "$(get ios)" = "$2" ]; then ok "$1"; else bad "$1（期望 ios=$2）" "$OUT"; fi
}
REPO_MAIN="$REPO"
REPO="$TMP/repo-ios"
mkdir -p "$REPO/tools/release" "$REPO/release"
cp "$HERE/release/plan-builds.sh" "$HERE/release/rust-impact.py" "$REPO/tools/release/"
git -C "$REPO" init -q
GI=(git -C "$REPO" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false)
printf '{"desktop":"2.0.0","android":"1.0.0","ios":"0.1.0"}\n' > "$REPO/release/versions.json"
"${GI[@]}" add -A && "${GI[@]}" commit -q -m latest && "${GI[@]}" tag v2026.1.1
latest v2026.1.1 1.0.0 2.0.0
plan v2026.1.2 1.0.0 2.0.0 0.1.0
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "::error::各端版本号都与 Latest"; then ok "iOS 号与 Latest 里的相同且另两端也复用 ⇒ 没东西可发 ⇒ 报错"; else bad "iOS 号相同且另两端也复用 ⇒ 报错" "$OUT"; fi
plan v2026.1.2 1.0.1 2.0.0 0.1.0;  expect_ios "iOS 号未涨 ⇒ skip（TestFlight 不能重复上传同一构建号）" skip
plan v2026.1.2 1.0.0 2.0.0 0.2.0;  expect_ios "iOS 号涨了 ⇒ build（另两端复用也不报错：只发 iOS）" build
if [ "$(get android)" = reuse ] && [ "$(get macos)" = reuse ] && [ "$(get ios_version)" = 0.2.0 ]; then ok "只涨 iOS：android / macos 复用、ios_version 输出本次号"; else bad "只涨 iOS：android / macos 复用" "$OUT"; fi
printf '{"desktop":"2.0.0","android":"1.0.0"}\n' > "$REPO/release/versions.json"
"${GI[@]}" add -A && "${GI[@]}" commit -q -m latest2 && "${GI[@]}" tag -f v2026.1.1 >/dev/null
plan v2026.1.2 1.0.1 2.0.0 0.1.0;  expect_ios "Latest 那一版没有 ios 线 ⇒ 拿不准 ⇒ build" build
plan v2026.1.1 1.0.1 2.0.0 0.1.0;  expect_ios "Latest 就是本 tag（补跑）⇒ build（重复上传由 testflight-upload.sh 查重）" build
rm -rf "$TMP/state"; mkdir -p "$TMP/state"
plan v2026.1.2 1.0.1 2.0.0 0.1.0;  expect_ios "没有 Latest ⇒ build" build
REPO="$REPO_MAIN"

echo "plan-builds（#852 test tag 按端发布）"
# 假仓库里按顺序提交、打 test tag；test-channel 的清单放在 $STUB_STATE/test-channel/。
G=(git -C "$REPO" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false)
commit_tag() { # <tag> <路径...>：改这些路径并打 tag
  local tag="$1" f; shift
  for f in "$@"; do mkdir -p "$REPO/$(dirname "$f")"; echo "$tag" >> "$REPO/$f"; done
  "${G[@]}" add -A && "${G[@]}" commit -q -m "$tag" && "${G[@]}" tag "$tag"
}
channel() { # <android 版本|-> <macOS 版本|-> [Windows 版本|-] [iOS 版本|-]：设置 test-channel 里的分端清单（- = 没有；Windows、iOS 缺省同 macOS）
  rm -rf "$TMP/state/test-channel"; mkdir -p "$TMP/state/test-channel"
  [ "$1" = - ] || printf '{"version":"%s","platforms":{"android-arm64":{}}}\n' "$1" > "$TMP/state/test-channel/manifest-android.json"
  [ "$2" = - ] || printf '{"version":"%s","platforms":{"darwin-aarch64":{}}}\n' "$2" > "$TMP/state/test-channel/manifest-macos.json"
  local w="${3:-$2}"
  [ "$w" = - ] || printf '{"version":"%s","platforms":{"windows-x86_64":{}}}\n' "$w" > "$TMP/state/test-channel/manifest-windows.json"
  local i="${4:-$2}"
  [ "$i" = - ] || printf '{"version":"%s","platforms":{}}\n' "$i" > "$TMP/state/test-channel/manifest-ios.json"
}
expect_win() { # <说明> <windows 判定>
  if [ "$RC" = 0 ] && [ "$(get windows)" = "$2" ]; then ok "$1"; else bad "$1（期望 windows=$2）" "$OUT"; fi
}
tplan() { # <tag>：在该 tag 的提交上跑 plan-builds（release/versions.json 各 tag 相同）
  "${G[@]}" checkout -q "$1"
  OUT=$(cd "$REPO" && TAG="$1" GITHUB_OUTPUT=/dev/stdout tools/release/plan-builds.sh 2>&1); RC=$?
}
rm -rf "$TMP/state"; mkdir -p "$TMP/state"
printf '{"desktop":"2.0.0","android":"1.0.0"}\n' > "$REPO/release/versions.json"
commit_tag v0.1.0-test.1 apps/android/a.kt apps/desktop/d.js crates/core/c.rs
commit_tag v0.1.0-test.2 apps/android/a.kt
commit_tag v0.1.0-test.3 apps/desktop/src/d.js
commit_tag v0.1.0-test.4 crates/core/c.rs
commit_tag v0.1.0-test.5 docs/x.md cards/y.md apps/desktop/README.md
commit_tag v0.1.0-test.6 tools/build-android-iroh-blobs-bridge.sh
commit_tag v0.1.0-test.7 tools/bundle-desktop-macos.sh
commit_tag v0.1.0-test.8 release/notes/x.txt
commit_tag v0.1.0-test.9 apps/desktop/src-tauri/tauri.windows.conf.json
# #887：iOS 工程与它专用的脚本。必须在第一次 tplan（会 checkout 到 tag、HEAD 分离）之前提交。
commit_tag v0.1.0-test.10 apps/ios/project.yml tools/ios/test.sh tools/build-ios-transport-xcframework.sh
commit_tag v0.1.0-test.11 apps/ios/PPass/x.swift apps/android/a.kt
# #348：iOS 界面文案由 Android strings.xml 生成 ⇒ 改它要同时发 Android 与 iOS。
commit_tag v0.1.0-test.12 apps/android/app/src/main/res/values-zh/strings.xml
# #1121：正式更新公钥在 tauri.conf.json，Android 构建期也从这里读 ⇒ 改它两端都要重建。
commit_tag v0.1.0-test.13 apps/desktop/src-tauri/tauri.conf.json

channel 0.1.0-test.1 0.1.0-test.1; tplan v0.1.0-test.2; expect_plan "只改 apps/android/ ⇒ Android 构建、桌面 skip" build skip
expect_win "只改 apps/android/ ⇒ Windows 也不陪跑" skip
[ "$(get reuse_from)" = "" ] && ok "test tag 不带复用来源" || bad "test tag 不带复用来源" "$OUT"
channel 0.1.0-test.2 0.1.0-test.2; tplan v0.1.0-test.3; expect_plan "只改 apps/desktop/ ⇒ 桌面构建、Android skip" skip build
expect_win "只改 apps/desktop/ ⇒ Windows 也构建（两个桌面端共用）" build
channel 0.1.0-test.3 0.1.0-test.3; tplan v0.1.0-test.4; expect_plan "改 crates/（共享代码）⇒ 两端构建" build build
expect_win "改 crates/（共享代码）⇒ Windows 也构建" build
channel 0.1.0-test.4 0.1.0-test.4; tplan v0.1.0-test.5
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "::error::test tag v0.1.0-test.5"; then ok "只改 docs/ cards/ *.md ⇒ 两端都没变 ⇒ 明确报错"; else bad "只改 docs/ cards/ *.md ⇒ 两端都没变 ⇒ 明确报错" "$OUT"; fi
channel 0.1.0-test.5 0.1.0-test.5; tplan v0.1.0-test.6; expect_plan "改 Android 构建脚本 ⇒ 只算 Android" build skip
channel 0.1.0-test.6 0.1.0-test.6; tplan v0.1.0-test.7; expect_plan "改 macOS 打包脚本 ⇒ 只算桌面" skip build
expect_win "改 macOS 打包脚本 ⇒ 不算 Windows" skip
channel 0.1.0-test.7 0.1.0-test.7; tplan v0.1.0-test.8; expect_plan "改没列出的路径（release/）⇒ 拿不准 ⇒ 两端" build build
expect_win "改没列出的路径（release/）⇒ Windows 也构建" build
channel 0.1.0-test.8 0.1.0-test.8; tplan v0.1.0-test.9; expect_plan "只改 tauri.windows.conf.json ⇒ Android、macOS 都 skip" skip skip
expect_win "只改 tauri.windows.conf.json ⇒ 只构建 Windows（不报「没东西可发」）" build
channel 0.1.0-test.9 0.1.0-test.9; tplan v0.1.0-test.10
expect_plan "只改 apps/ios/ tools/ios/ tools/build-ios-*（#887/#348）⇒ 另三端都 skip、只发 iOS（不报错）" skip skip
expect_ios "只改 apps/ios/ tools/ios/ tools/build-ios-* ⇒ iOS 构建" build
expect_win "只改 apps/ios/ ⇒ Windows 不陪跑" skip
channel 0.1.0-test.10 0.1.0-test.10; tplan v0.1.0-test.11; expect_plan "apps/ios/ 与 apps/android/ 混改 ⇒ Android 构建、macOS skip" build skip
expect_ios "apps/ios/ 与 apps/android/ 混改 ⇒ iOS 也构建" build
expect_win "apps/ios/ 与 apps/android/ 混改（#887）⇒ Windows 不陪跑" skip
channel 0.1.0-test.11 0.1.0-test.11; tplan v0.1.0-test.12; expect_plan "只改 Android strings.xml（#348）⇒ Android 构建、macOS skip" build skip
expect_ios "只改 Android strings.xml（iOS 文案由它生成）⇒ iOS 也构建" build
channel 0.1.0-test.12 0.1.0-test.12; tplan v0.1.0-test.13; expect_plan "只改 tauri.conf.json（#1121：Android 也从这里读更新公钥）⇒ Android、macOS 都构建" build build
expect_win "只改 tauri.conf.json ⇒ Windows 也构建" build
channel 0.1.0-test.11 0.1.0-test.11 0.1.0-test.11 -; tplan v0.1.0-test.12; expect_ios "test-channel 没有 iOS 清单 ⇒ 拿不准 ⇒ iOS 构建" build
channel 0.1.0-test.8 0.1.0-test.8 -; tplan v0.1.0-test.9; expect_win "test-channel 没有 Windows 清单 ⇒ 拿不准 ⇒ Windows 构建" build
channel 0.1.0-test.2 0.1.0-test.1; tplan v0.1.0-test.2
if [ "$RC" = 0 ] && [ "$(get android)" = build ]; then ok "基线就是本 tag（补跑）⇒ 构建"; else bad "基线就是本 tag（补跑）⇒ 构建" "$OUT"; fi
# 基线按端取：上次桌面没构建（test-channel 的 macOS 仍是 test.1）⇒ 那之后的桌面改动不会被漏掉
channel 0.1.0-test.2 0.1.0-test.1; tplan v0.1.0-test.3; expect_plan "按端基线：Android 自 test.2 无改动 skip；macOS 自 test.1 起有桌面改动 ⇒ 构建" skip build
channel 0.1.0-test.3 -; tplan v0.1.0-test.4; expect_plan "test-channel 没有 macOS 清单 ⇒ 拿不准 ⇒ 构建" build build
channel - 0.1.0-test.4; printf '{"version":"0.1.0-test.4","platforms":{}}\n' > "$TMP/state/test-channel/manifest.json"; tplan v0.1.0-test.5
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "各端自上一次"; then ok "过渡期：没有 manifest-android.json 时用老格式 manifest.json 当 Android 基线"; else bad "过渡期：没有 manifest-android.json 时用老格式 manifest.json 当 Android 基线" "$OUT"; fi
channel 0.0.9-test.1 0.1.0-test.4; tplan v0.1.0-test.5; expect_plan "基线 tag 在仓库里不存在 ⇒ 构建" build skip
printf 'not json' > "$TMP/state/test-channel/manifest-android.json"; tplan v0.1.0-test.5; expect_plan "清单读不出（坏 JSON）⇒ 构建" build skip
"${G[@]}" checkout -q v0.1.0-test.1 && "${G[@]}" checkout -q -b side && commit_tag v0.1.0-test.90 apps/desktop/side.js
channel 0.1.0-test.90 0.1.0-test.90; tplan v0.1.0-test.5; expect_plan "基线不是本次提交的祖先 ⇒ 构建" build build
"${G[@]}" checkout -q v0.1.0-test.12

echo "plan-builds（#1062 test tag：Rust 改动按 Cargo 依赖图归属到端）"
# 最小 Cargo workspace：transport 的 proto 依赖只在 mobile-ffi 下生效（另有一条 dev 依赖）——同真实仓库。
# 入口（rust-impact.py ENTRIES）：Android transport[android-jni, mobile-ffi]、iOS transport[mobile-ffi]、
# macOS daemon、Windows daemon + testclient（夹具里没有桌面壳）。
expect4() { # <说明> <android> <macos> <windows> <ios>
  if [ "$RC" = 0 ] && [ "$(get android)" = "$2" ] && [ "$(get macos)" = "$3" ] && [ "$(get windows)" = "$4" ] && [ "$(get ios)" = "$5" ]; then ok "$1"
  else bad "$1（期望 android=$2 macos=$3 windows=$4 ios=$5）" "$OUT"; fi
}
REPO_MAIN="$REPO"
REPO="$TMP/repo-rust"
mkdir -p "$REPO/tools/release" "$REPO/release"
cp "$HERE/release/plan-builds.sh" "$HERE/release/rust-impact.py" "$REPO/tools/release/"
printf '{"desktop":"2.0.0","android":"1.0.0","ios":"0.1.0"}\n' > "$REPO/release/versions.json"
crate() { # <目录> <包名> <Cargo.toml 余下内容>
  mkdir -p "$REPO/$1/src"; echo "// $2" > "$REPO/$1/src/lib.rs"
  printf '[package]\nname = "%s"\nversion.workspace = true\nedition = "2021"\n\n%s\n' "$2" "$3" > "$REPO/$1/Cargo.toml"
}
ws_toml() { # <workspace 版本> [额外内容]
  printf '[workspace]\nmembers = ["crates/proto", "crates/transport", "crates/daemon", "crates/platform", "tools/testclient"]\nresolver = "2"\n\n[workspace.package]\nversion = "%s"\n%s' "$1" "${2:-}" > "$REPO/Cargo.toml"
}
lock() { # <成员版本> <iroh-x 版本> <iroh-x checksum> <sqlite-x 版本>：transport 用 iroh-x，daemon 用 sqlite-x
  python3 - "$REPO/Cargo.lock" "$@" <<'PY'
import sys
out, v, iv, ic, sv = sys.argv[1:]
src = 'source = "registry+https://github.com/rust-lang/crates.io-index"'
def ws(n, deps): return '[[package]]\nname = "%s"\nversion = "%s"\ndependencies = [\n%s]\n' % (n, v, "".join(' "%s",\n' % d for d in deps))
def ext(n, ver, ck): return '[[package]]\nname = "%s"\nversion = "%s"\n%s\nchecksum = "%s"\n' % (n, ver, src, ck)
parts = [ws("daemon", ["platform", "proto", "sqlite-x", "transport"]), ext("iroh-x", iv, ic), ws("platform", []), ws("proto", []),
         ext("sqlite-x", sv, "s" + sv), ws("testclient", ["proto", "transport"]), ws("transport", ["iroh-x", "proto"])]
open(out, "w").write("version = 4\n\n" + "\n".join(parts))
PY
}
crate crates/proto proto ''
echo '// extra' > "$REPO/crates/proto/src/extra.rs"
crate crates/platform platform ''
crate crates/transport transport '[features]
android-jni = []
mobile-ffi = ["dep:proto"]

[dependencies]
proto = { path = "../proto", optional = true }

[dev-dependencies]
proto = { path = "../proto" }'
crate crates/daemon daemon '[dependencies]
proto = { path = "../proto" }
transport = { path = "../transport" }
platform = { path = "../platform" }'
crate tools/testclient testclient '[dependencies]
proto = { path = "../../crates/proto" }
transport = { path = "../../crates/transport" }'
ws_toml 0.9.0; lock 0.9.0 1.0.0 aaa 1.0.0
git -C "$REPO" init -q
G=(git -C "$REPO" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false)
rtag() { "${G[@]}" add -A && "${G[@]}" commit -q -m "$1" && "${G[@]}" tag "$1"; }
touch_() { local f; for f in "$@"; do mkdir -p "$REPO/$(dirname "$f")"; echo "// $1" >> "$REPO/$f"; done; }
rtag v0.2.0-test.1
touch_ crates/daemon/src/lib.rs;            rtag v0.2.0-test.2
touch_ crates/transport/src/lib.rs;         rtag v0.2.0-test.3
touch_ crates/proto/src/lib.rs;             rtag v0.2.0-test.4
touch_ tools/testclient/src/lib.rs;         rtag v0.2.0-test.5
touch_ crates/daemon/tests/flow.rs;         rtag v0.2.0-test.6
ws_toml 0.9.1; lock 0.9.1 1.0.0 aaa 1.0.0;  rtag v0.2.0-test.7
lock 0.9.1 1.0.0 aaa 1.1.0;                 rtag v0.2.0-test.8
lock 0.9.1 1.0.0 bbb 1.1.0;                 rtag v0.2.0-test.9
ws_toml 0.9.1 $'\n[profile.release]\nlto = true\n'; rtag v0.2.0-test.10
touch_ crates/newcrate/src/lib.rs;          rtag v0.2.0-test.11
"${G[@]}" rm -rq crates/newcrate; printf 'not toml [[[\n' > "$REPO/Cargo.lock"; rtag v0.2.0-test.12
rchk() { # <tag> <说明> <android> <macos> <windows> <ios>：test-channel 四端都指向上一个 tag
  local prev="v0.2.0-test.$(( ${1##*.} - 1 ))"
  channel "${prev#v}" "${prev#v}" "${prev#v}" "${prev#v}"; tplan "$1"; expect4 "$2" "$3" "$4" "$5" "$6"
}
rchk v0.2.0-test.2  "只改 crates/daemon ⇒ 只构建桌面两端，Android / iOS 不陪跑" skip build build skip
rchk v0.2.0-test.3  "改 crates/transport ⇒ 依赖它的四端都构建" build build build build
rchk v0.2.0-test.4  "改 crates/proto ⇒ 四端都构建（#1124：Android 也开 mobile-ffi，transport 在它下依赖 proto）" build build build build
rchk v0.2.0-test.5  "改 tools/testclient ⇒ 只有 Windows（只有它打包 testclient）" skip skip build skip
rchk v0.2.0-test.6  "改 crates/daemon/tests/ ⇒ 按 daemon 算桌面两端（保守：测试目录不另行排除）" skip build build skip
rchk v0.2.0-test.7  "桌面涨号的 Cargo 那一半（根 Cargo.toml 只变 workspace 版本、Cargo.lock 只变成员版本）⇒ 只构建桌面两端（同一提交里的 release/ 仍算所有端）" skip build build skip
rchk v0.2.0-test.8  "Cargo.lock 只变 daemon 专用的外部依赖 ⇒ 只构建桌面两端" skip build build skip
rchk v0.2.0-test.9  "Cargo.lock 变了 transport 的外部依赖（checksum）⇒ 四端都构建" build build build build
rchk v0.2.0-test.10 "根 Cargo.toml 有版本号以外的变化 ⇒ 拿不准 ⇒ 四端都构建" build build build build
rchk v0.2.0-test.11 "crates/ 下不属于任何 workspace 成员的路径 ⇒ 拿不准 ⇒ 四端都构建" build build build build
rchk v0.2.0-test.12 "Cargo.lock 解析不了 ⇒ 拿不准 ⇒ 四端都构建" build build build build
# 改名按原路径也算一次（--no-renames）：把 proto 的源文件挪出 crates/，proto 的改动不能因为只剩新路径而漏掉。
"${G[@]}" checkout -q v0.2.0-test.4 && mkdir -p "$REPO/docs" && "${G[@]}" mv crates/proto/src/extra.rs docs/moved.md \
  && "${G[@]}" commit -q -m mv && "${G[@]}" tag v0.2.0-test.20
channel 0.2.0-test.4 0.2.0-test.4 0.2.0-test.4 0.2.0-test.4; tplan v0.2.0-test.20
expect4 "proto 的文件被挪进 docs/（rename）⇒ 仍按 proto 归属：四端都构建" build build build build
# cargo 不可用 / metadata 失败 ⇒ 拿不准 ⇒ 所有端（假 cargo 恒失败；不靠删 PATH）。
mkdir -p "$TMP/badcargo"; printf '#!/bin/sh\necho "boom" >&2\nexit 1\n' > "$TMP/badcargo/cargo"; chmod +x "$TMP/badcargo/cargo"
channel 0.2.0-test.1 0.2.0-test.1 0.2.0-test.1 0.2.0-test.1; "${G[@]}" checkout -q v0.2.0-test.2
OUT=$(cd "$REPO" && PATH="$TMP/badcargo:$PATH" TAG=v0.2.0-test.2 GITHUB_OUTPUT=/dev/stdout tools/release/plan-builds.sh 2>&1); RC=$?
expect4 "cargo metadata 失败 ⇒ 只改 crates/daemon 也四端都构建" build build build build
printf '%s' "$OUT" | grep -q "::warning::cargo metadata 失败" && ok "cargo metadata 失败时打 ::warning::（不静默降级）" || bad "cargo metadata 失败时打 ::warning::" "$OUT"
REPO="$REPO_MAIN"

echo "plan-builds（#1062 入口包与真实构建命令、真实依赖图一致）"
ROOT="$(cd "$HERE/.." && pwd)"
has() { grep -qF -- "$2" "$ROOT/$1" && ok "$1 含「$2」" || bad "$1 应含「$2」（入口包 / feature 变了要同步 rust-impact.py 的 ENTRIES）"; }
has tools/build-android-iroh-blobs-bridge.sh "cargo build -p transport --features android-jni,mobile-ffi"
has tools/build-android-iroh-blobs-bridge.sh "-p transport --features mobile-bindgen"
has tools/build-ios-transport-xcframework.sh "-p transport --lib --features mobile-ffi"
has tools/build-ios-transport-xcframework.sh "-p transport --features mobile-bindgen"
grep -qE '^ +run: cargo build --release -p daemon$' "$ROOT/.github/workflows/release.yml" && ok "release.yml macOS 只编 daemon" || bad "release.yml macOS 应为 cargo build --release -p daemon（同步 ENTRIES.macos）"
has .github/workflows/release.yml "run: cargo build --release -p daemon -p testclient"
SHELL_PKG=$(sed -n 's/^name = "\(.*\)"/\1/p' "$ROOT/apps/desktop/src-tauri/Cargo.toml" | head -1)
grep -qF "DESKTOP_SHELL = \"$SHELL_PKG\"" "$ROOT/tools/release/rust-impact.py" && ok "桌面壳包名（${SHELL_PKG}）与 ENTRIES 一致" || bad "桌面壳包名 ${SHELL_PKG} 与 rust-impact.py 的 DESKTOP_SHELL 不一致"
# 真实仓库的依赖图：钉住「哪个 crate 归哪些端」的现状——有人给 transport 加了 path 依赖，这里先变。
RM="$TMP/real-meta"; mkdir -p "$RM"
if (cd "$ROOT" && RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}" cargo metadata --no-deps --format-version 1 --offline >"$RM/ws.json" \
  && RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}" cargo metadata --no-deps --format-version 1 --offline \
    --manifest-path apps/desktop/src-tauri/Cargo.toml >"$RM/shell.json"); then
  REAL=$(cd "$ROOT" && printf '%s\n' crates/daemon/src/x.rs crates/transport/src/x.rs crates/proto/src/x.rs crates/platform/src/x.rs tools/testclient/src/x.rs \
    | python3 -I tools/release/rust-impact.py --base HEAD --meta "$RM/ws.json" --meta "$RM/shell.json" 2>&1)
  WANT=$(printf 'macos windows\tcrates/daemon/src/x.rs\nandroid ios macos windows\tcrates/transport/src/x.rs\nandroid ios macos windows\tcrates/proto/src/x.rs\nmacos windows\tcrates/platform/src/x.rs\nwindows\ttools/testclient/src/x.rs')
  [ "$REAL" = "$WANT" ] && ok "真实依赖图：daemon/platform ⇒ 桌面两端，transport / proto ⇒ 四端，testclient ⇒ Windows" \
    || bad "真实依赖图的归属变了（确认是有意的再改这里）" "$REAL"
else
  bad "真实仓库 cargo metadata 失败（本测试需要 cargo）"
fi

echo "reuse-artifact"
reuse() { OUT=$(cd "$REPO" && tools/release/reuse-artifact.sh "$1" v2026.1.1 "$2" "$TMP/out-$3" 2>&1); RC=$?; }
latest v2026.1.1 1.0.0 2.0.0
reuse android 1.0.0 a1
[ "$RC" = 0 ] && [ -f "$TMP/out-a1/P-Pass_1.0.0_android.apk" ] && ok "android：字节与版本号都对 ⇒ 取回" || bad "android：字节与版本号都对 ⇒ 取回" "$OUT"
reuse macos 2.0.0 m1
[ "$RC" = 0 ] && [ "$(ls "$TMP/out-m1" | wc -l | tr -d ' ')" = 3 ] && ok "macOS：字节与版本号都对 ⇒ 取回三件" || bad "macOS：字节与版本号都对 ⇒ 取回三件" "$OUT"
printf 'tampered' >> "$TMP/state/v2026.1.1/P-Pass_1.0.0_android.apk"
reuse android 1.0.0 a2
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "sha256 与 v2026.1.1 的清单不符" && ok "android：字节与清单不符 ⇒ 红" || bad "android：字节与清单不符 ⇒ 红" "$OUT"
latest v2026.1.1 1.0.0 2.0.0
mk_apk "$TMP/state/v2026.1.1/P-Pass_1.0.0_android.apk" 0.9.9
printf '{"version":"1.0.0","platforms":{"android-arm64":{"sha256":"%s"}}}\n' "$(sha "$TMP/state/v2026.1.1/P-Pass_1.0.0_android.apk")" > "$TMP/state/v2026.1.1/manifest-android.json"
reuse android 1.0.0 a3
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "包内 versionName=0.9.9" && ok "android：包内 versionName 与本次不符 ⇒ 红（#809 教训）" || bad "android：包内 versionName 与本次不符 ⇒ 红" "$OUT"
latest v2026.1.1 1.0.0 2.0.0
printf 'other' > "$TMP/state/v2026.1.1/P-Pass_2.0.0_macos-arm64.dmg"
reuse macos 2.0.0 m2
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "P-Pass_2.0.0_macos-arm64.dmg 的 sha256 与" && ok "macOS：dmg 与 SHA256SUMS 不符 ⇒ 红" || bad "macOS：dmg 与 SHA256SUMS 不符 ⇒ 红" "$OUT"
latest v2026.1.1 1.0.0 2.0.0
D="$TMP/state/v2026.1.1"; mk_tar "$D/P-Pass_2.0.0_macos-arm64.app.tar.gz" 1.9.9
(cd "$D" && for f in P-Pass_2.0.0_macos-arm64.dmg P-Pass_2.0.0_macos-arm64.app.tar.gz; do echo "$(sha "$f")  $f"; done > SHA256SUMS-macos-arm64)
reuse macos 2.0.0 m3
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "CFBundleShortVersionString=1.9.9" && ok "macOS：Info.plist 版本与本次不符 ⇒ 红（#809 教训）" || bad "macOS：Info.plist 版本与本次不符 ⇒ 红" "$OUT"

echo
echo "通过 ${PASS} / 失败 ${FAIL}"
[ "$FAIL" = 0 ]
