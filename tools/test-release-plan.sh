#!/usr/bin/env bash
# #838：tools/release/plan-builds.sh（构建还是复用）与 tools/release/reuse-artifact.sh（复用时的两道校验）的判定测试。
#
# 用 stub gh 喂一个假的 Latest 正式版（资产放在临时目录），逐条验：
#   plan-builds：test tag / 没有 Latest / Latest 就是本 tag / 版本号相同 / 缺清单 / 缺安装包 / 两端都相同。
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
cp "$HERE/release/plan-builds.sh" "$HERE/release/reuse-artifact.sh" "$REPO/tools/release/"
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

# plan <tag> <android 号> <macOS 号> ⇒ 设置 RC / OUT
plan() {
  printf '{"desktop":"%s","android":"%s"}\n' "$3" "$2" > "$REPO/release/versions.json"
  OUT=$(cd "$REPO" && TAG="$1" GITHUB_OUTPUT=/dev/stdout tools/release/plan-builds.sh 2>&1); RC=$?
}
get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | tail -1; }
expect_plan() { # 说明 android macos
  if [ "$RC" = 0 ] && [ "$(get android)" = "$2" ] && [ "$(get macos)" = "$3" ]; then ok "$1"; else bad "$1（期望 android=$2 macos=$3）" "$OUT"; fi
}

echo "plan-builds"
latest v2026.1.1 1.0.0 2.0.0
plan v1.2.3-test.4 1.0.0 2.0.0;  expect_plan "test tag：两端都构建（即使版本号与 Latest 相同）" build build
plan v2026.1.1 1.0.0 2.0.0;      expect_plan "Latest 就是本 tag（补跑）：两端都构建" build build
plan v2026.1.2 1.0.1 2.0.0;      expect_plan "只涨 android：android 构建、macOS 复用" build reuse
[ "$(get reuse_from)" = v2026.1.1 ] && ok "复用来源 = Latest" || bad "复用来源 = Latest" "$OUT"
plan v2026.1.2 1.0.0 2.0.1;      expect_plan "只涨桌面：android 复用、macOS 构建" reuse build
plan v2026.1.2 1.0.0 2.0.0
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "::error::两端版本号都与 Latest"; then ok "两端都没涨号：明确报错"; else bad "两端都没涨号：明确报错" "$OUT"; fi
rm "$TMP/state/v2026.1.1/manifest-macos.json"
plan v2026.1.2 1.0.1 2.0.0;      expect_plan "Latest 缺 macOS 清单：macOS 构建（不猜）" build build
latest v2026.1.1 1.0.0 2.0.0; rm "$TMP/state/v2026.1.1/P-Pass_2.0.0_macos-arm64.dmg"
plan v2026.1.2 1.0.1 2.0.0;      expect_plan "Latest 缺 dmg：macOS 构建（不猜）" build build
rm -rf "$TMP/state"; mkdir -p "$TMP/state"
plan v2026.1.2 1.0.1 2.0.0;      expect_plan "没有 Latest：两端都构建" build build

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
