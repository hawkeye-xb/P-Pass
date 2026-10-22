#!/usr/bin/env bash
# REL-11（#708）回归测试：发布链补跑 / 门禁路径的版本号口径。
#
#   ① repair-manifests.yml 的分端版本号取自**被修复的 tag**，不是 main；
#      tag 里没有 release/versions.json（UPD-13 之前）⇒ 明确报错。
#   ② tools/release-version.sh：RELEASE_TAG 优先于 GITHUB_REF_NAME
#      （dispatch 补跑时 GITHUB_REF_NAME=main）；不设 RELEASE_TAG 时行为不变。
#   ③ tools/check-version-bump.sh：head-ref 不存在 / diff 失败 ⇒ 非零退出，不静默放行。
#
# ① 直接从 workflow YAML 里按 step 名抽出 run 块来跑——测的是真实 YAML，不是复制品。
# 全部在临时 git 仓库里造数据（bare origin + 浅克隆），不碰本仓库的 tag / 工作区。
#
# 用法：bash tools/test-release-version-source.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/p-pass-rel11.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

g() { git -c core.hooksPath=/dev/null -c user.name=rel11-test -c user.email=rel11@test.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

# ── 造一个合成仓库 ─────────────────────────────────────────────────
#   v0.1.0：UPD-13 之前，没有 release/versions.json
#   v1.0.0：versions.json = 1.0.0 / 1.1.0
#   main  ：已 bump 到 2.0.0 / 2.1.0（模拟「main 已 bump 之后再修旧 tag」）
#   #740：v1.0.0 与 main 各有一份不同的 android 1.1.0 说明，main 另有 2.1.0 的说明——
#   repair 必须用 tag 那份 release/（说明、冻结件随 tag），并经 main 的 release-version.sh 读号。
SRC="$SANDBOX/src"
g init -q -b main "$SRC"
mkdir -p "$SRC/apps/android" "$SRC/docs" "$SRC/release/notes/android" "$SRC/tools"
echo a > "$SRC/apps/android/a.txt"
g -C "$SRC" add -A && g -C "$SRC" commit -qm c1 && g -C "$SRC" tag v0.1.0
printf '{"desktop":"1.0.0","android":"1.1.0"}\n' > "$SRC/release/versions.json"
echo 'tag 上的说明' > "$SRC/release/notes/android/1.1.0.zh.txt"
g -C "$SRC" add -A && g -C "$SRC" commit -qm c2 && g -C "$SRC" tag v1.0.0
printf '{"desktop":"2.0.0","android":"2.1.0"}\n' > "$SRC/release/versions.json"
echo 'main 上改过的说明' > "$SRC/release/notes/android/1.1.0.zh.txt"
echo 'main 才有的说明' > "$SRC/release/notes/android/2.1.0.zh.txt"
cp "$ROOT/tools/release-version.sh" "$SRC/tools/release-version.sh"
echo b > "$SRC/apps/android/a.txt"
g -C "$SRC" add -A && g -C "$SRC" commit -qm c3
BARE="$SANDBOX/origin.git"
g clone -q --bare "$SRC" "$BARE"

# ── ① repair-manifests.yml ────────────────────────────────────────
WF="$ROOT/.github/workflows/repair-manifests.yml"
STEP_NAME="Resolve per-platform versions from tag"
STEP_SH="$SANDBOX/resolve-step.sh"
if ! python3 - "$WF" "$STEP_NAME" "$STEP_SH" <<'PY'
import sys, yaml
wf, name, out = sys.argv[1:4]
steps = yaml.safe_load(open(wf))["jobs"]["repair"]["steps"]
hit = [s for s in steps if s.get("name") == name]
if not hit:
    sys.exit(f"repair-manifests.yml 里没有 step「{name}」")
open(out, "w").write(hit[0]["run"])
PY
then
  fail "① repair-manifests.yml 缺少从 tag 读版本号的 step"
else
  run_step() { # <tag> → 在一个 depth=1 的 main 浅克隆里跑该 step（与 CI 的 checkout 同形）
    local tag="$1" work="$SANDBOX/work-$1"
    rm -rf "$work"
    g clone -q --depth=1 --no-tags "file://$BARE" "$work"
    : > "$SANDBOX/env-$tag"
    (cd "$work" && TAG="$tag" GITHUB_ENV="$SANDBOX/env-$tag" bash -e "$STEP_SH")
  }

  if out=$(run_step v1.0.0 2>&1) \
     && grep -qx 'DESKTOP_VERSION=1.0.0' "$SANDBOX/env-v1.0.0" \
     && grep -qx 'ANDROID_VERSION=1.1.0' "$SANDBOX/env-v1.0.0"; then
    pass "① 旧 tag v1.0.0 取到 tag 里的版本号（1.0.0/1.1.0），不是 main 的 2.0.0/2.1.0"
  else
    fail "① 旧 tag 版本号取错：$out / env=$(cat "$SANDBOX/env-v1.0.0" 2>/dev/null)"
  fi

  # #740：说明文件随 tag——工作区 release/ 整目录换成 v1.0.0 的版本
  W="$SANDBOX/work-v1.0.0"
  if [ "$(cat "$W/release/notes/android/1.1.0.zh.txt" 2>/dev/null)" = 'tag 上的说明' ] \
     && [ ! -e "$W/release/notes/android/2.1.0.zh.txt" ] \
     && g -C "$W" diff --quiet v1.0.0 -- release; then
    pass "① 工作区 release/ 换成被修复 tag 的版本（说明取 tag 那份，main 才有的文件不残留）"
  else
    fail "① 工作区 release/ 不是被修复 tag 的版本：$(g -C "$W" status --short -- release 2>&1)"
  fi

  if out=$(run_step v1.0.0-test.1 2>&1); then
    fail "① test tag 应在 Resolve 步就报错退出，却成功了：$out"
  elif grep -q '只服务正式 tag' <<<"$out"; then
    pass "① test tag 在 Resolve 步（下载 / 签名之前）明确报错退出"
  else
    fail "① test tag 报错信息不对：$out"
  fi

  if out=$(run_step v0.1.0 2>&1); then
    fail "① 没有 versions.json 的 tag 应报错退出，却成功了：$out"
  elif grep -q '没有 release/versions.json' <<<"$out"; then
    pass "① 没有 versions.json 的 tag（UPD-13 之前）明确报错退出"
  else
    fail "① 没有 versions.json 的 tag 报错信息不对：$out"
  fi
fi

# Compose 步不得再读工作区（= main）的 versions.json
if python3 - "$WF" <<'PY'
import re, sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["repair"]["steps"]
run = next(s["run"] for s in steps if s.get("name") == "Compose + sign manifests")
# 命中「jq ... release/versions.json」（工作区相对路径，前面不是 / 或 . 或 :）即判红
sys.exit(1 if re.search(r"jq\b[^\n]*(?<![./:])release/versions\.json", run) else 0)
PY
then
  pass "① Compose 步不再读 checkout（main）里的 release/versions.json"
else
  fail "① Compose 步仍在读 checkout（main）里的 release/versions.json"
fi

# ── ② release-version.sh ──────────────────────────────────────────
RV="$ROOT/tools/release-version.sh"
main_android=$(jq -r .android "$ROOT/release/versions.json")
main_desktop=$(jq -r .desktop "$ROOT/release/versions.json")
expect_rv() { # <desc> <want> <platform> [env...]
  local desc="$1" want="$2" plat="$3"; shift 3
  local got
  got=$(env -u RELEASE_TAG -u GITHUB_REF_NAME "$@" "$RV" "$plat" 2>&1) || got="exit=$? $got"
  if [ "$got" = "$want" ]; then pass "② $desc → $got"; else fail "② ${desc}：期望 ${want}，实际 $got"; fi
}
expect_rv "RELEASE_TAG=v0.9.3-test.1 GITHUB_REF_NAME=main android" "0.9.3-test.1" android \
  RELEASE_TAG=v0.9.3-test.1 GITHUB_REF_NAME=main
expect_rv "不设 RELEASE_TAG，GITHUB_REF_NAME=v0.9.3-test.2 android（行为不变）" "0.9.3-test.2" android \
  GITHUB_REF_NAME=v0.9.3-test.2
expect_rv "不设 RELEASE_TAG，GITHUB_REF_NAME=main android（行为不变：读 versions.json）" "$main_android" android \
  GITHUB_REF_NAME=main
expect_rv "RELEASE_TAG 为空串时回落 GITHUB_REF_NAME=v0.9.3-test.2" "0.9.3-test.2" desktop \
  RELEASE_TAG= GITHUB_REF_NAME=v0.9.3-test.2
expect_rv "RELEASE_TAG=正式 tag 压过 test 形态的 GITHUB_REF_NAME" "$main_desktop" desktop \
  RELEASE_TAG=v2026.10.1 GITHUB_REF_NAME=v0.9.3-test.3

# ── ③ check-version-bump.sh ───────────────────────────────────────
# 把被测脚本放进合成仓库（它按自身路径定位 ROOT 并在那里跑 git）。
CV="$SRC/tools/check-version-bump.sh"
cp "$ROOT/tools/check-version-bump.sh" "$CV"
chmod +x "$CV"
expect_cv() { # <desc> <want-exit: 0|nonzero> <grep-pattern> args...
  local desc="$1" want="$2" pat="$3"; shift 3
  local out rc=0
  out=$("$CV" "$@" 2>&1) || rc=$?
  if { [ "$want" = 0 ] && [ "$rc" -eq 0 ]; } || { [ "$want" = nonzero ] && [ "$rc" -ne 0 ]; }; then
    if grep -q -- "$pat" <<<"$out"; then
      pass "③ ${desc}（exit=${rc}）"
      return
    fi
  fi
  fail "③ ${desc}：期望 exit $want 且含「${pat}」，实际 exit=${rc}：$out"
}
expect_cv "head-ref 不存在 ⇒ 非零" nonzero "head-ref" v1.0.0 refs/tags/does-not-exist
expect_cv "head-ref 恰好是目录名（tools）⇒ 非零，不被当成路径" nonzero "head-ref" v1.0.0 tools
expect_cv "正常路径不受影响：v1.0.0→HEAD 改了 android 且涨了号 ⇒ 0" 0 "^ok:" v1.0.0 HEAD
# 门禁本身仍然有效：改 android 不涨号 ⇒ 红
echo c > "$SRC/apps/android/a.txt"
g -C "$SRC" add apps/android/a.txt && g -C "$SRC" commit -qm c4
expect_cv "改 android 不涨号 ⇒ 非零（门禁本身没被改坏）" nonzero "android 版本没涨" HEAD~1 HEAD
# #887：apps/ios/ 不属于桌面线也不属于 android 线——只改它不要求任何一端涨号。
# （iOS 线见下方 #348 一节：上一个 tag 没有 ios 号时跳过 iOS 门禁。）
mkdir -p "$SRC/apps/ios"
echo i > "$SRC/apps/ios/project.yml"
g -C "$SRC" add apps/ios/project.yml && g -C "$SRC" commit -qm c5
expect_cv "只改 apps/ios/ ⇒ 0，不要求 desktop/android 涨号" 0 "命中 0 个文件；android .* 命中 0 个文件" HEAD~1 HEAD

# #894：安卓 APK 里的 libtransport.so 由 crates/transport（+ Cargo.toml/lock 等）构建，
# 只改它们不涨 android 号 ⇒ 正式 tag 会复用旧 apk。门禁必须把它们算进安卓线。
commit_only() { # <msg> <path>... 改这些文件并提交（不动 versions.json）
  local msg="$1" f; shift
  for f in "$@"; do mkdir -p "$SRC/$(dirname "$f")"; echo "$msg" >> "$SRC/$f"; done
  g -C "$SRC" add -A && g -C "$SRC" commit -qm "$msg"
}
expect_android() { # <desc> <want: red|clean> args...
  local desc="$1" want="$2" out; shift 2
  out=$("$CV" "$@" 2>&1) || true
  if [ "$want" = red ] && grep -q "android 版本没涨" <<<"$out"; then pass "③ ${desc}"; return; fi
  if [ "$want" = clean ] && ! grep -q "android 版本没涨" <<<"$out"; then pass "③ ${desc}"; return; fi
  fail "③ ${desc}：期望安卓线 ${want}，实际：$out"
}
commit_only t1 crates/transport/src/lib.rs
expect_android "只改 crates/transport/src ⇒ 安卓线红（#894）" red HEAD~1 HEAD
commit_only t2 Cargo.lock
expect_android "只改 Cargo.lock ⇒ 安卓线红（gradle inputs 含它）" red HEAD~1 HEAD
commit_only t3 tools/build-android-iroh-blobs-bridge.sh
expect_android "只改安卓原生库构建脚本 ⇒ 安卓线红" red HEAD~1 HEAD
commit_only t4 rust-toolchain.toml
expect_android "只改 rust-toolchain.toml ⇒ 安卓线红" red HEAD~1 HEAD
commit_only t4b crates/proto/src/lib.rs
expect_android "只改 crates/proto ⇒ 安卓线红（#1124：libtransport.so 开 mobile-ffi，依赖 proto）" red HEAD~1 HEAD
commit_only t5 crates/daemon/src/main.rs
expect_android "只改 crates/daemon ⇒ 安卓线不受影响" clean HEAD~1 HEAD
expect_cv "只改 crates/daemon ⇒ 桌面线照常红" nonzero "desktop 版本没涨" HEAD~1 HEAD
commit_only t6 crates/transport/tests/loopback.rs
expect_android "只改 crates/transport/tests ⇒ 不算产品改动" clean HEAD~1 HEAD
commit_only t7 crates/transport/src/provider.rs
printf '{"desktop":"2.0.1","android":"2.1.1"}\n' > "$SRC/release/versions.json"
g -C "$SRC" add -A && g -C "$SRC" commit -qm t7-bump
expect_cv "改 crates/transport 且两端都涨号 ⇒ 0" 0 "^ok:" HEAD~2 HEAD

# #348：iOS 线。上一个 tag 里没有 ios 号时跳过门禁（上面所有用例都在这种情形下，照常通过）；
# 有了 ios 号之后：改 iOS 输入不涨 ios 号 ⇒ 红；只改测试/e2e 脚本不算；涨了号 ⇒ 过。
expect_ios() { # <desc> <want: red|clean> args...
  local desc="$1" want="$2" out; shift 2
  out=$("$CV" "$@" 2>&1) || true
  if [ "$want" = red ] && grep -q "ios 版本没涨" <<<"$out"; then pass "③ ${desc}"; return; fi
  if [ "$want" = clean ] && ! grep -q "ios 版本没涨" <<<"$out"; then pass "③ ${desc}"; return; fi
  fail "③ ${desc}：期望 iOS 线 ${want}，实际：$out"
}
printf '{"desktop":"2.0.1","android":"2.1.1","ios":"0.1.0"}\n' > "$SRC/release/versions.json"
g -C "$SRC" add -A && g -C "$SRC" commit -qm i0-versions
commit_only i1 apps/ios/PPass/x.swift
expect_ios "上一版有 ios 号：只改 apps/ios/ 不涨号 ⇒ iOS 线红" red HEAD~1 HEAD
commit_only i2 tools/ios/e2e-sim.sh
expect_ios "只改 tools/ios/e2e-sim.sh（测试脚本）⇒ iOS 线不受影响" clean HEAD~1 HEAD
commit_only i3 apps/android/app/src/main/res/values/strings.xml
expect_ios "只改 Android strings.xml（iOS 文案由它生成）⇒ iOS 线红" red HEAD~1 HEAD
commit_only i4 crates/transport/src/lib.rs
expect_ios "改 crates/transport ⇒ iOS 线红（XCFramework 的 Rust 源）" red HEAD~1 HEAD
printf '{"desktop":"2.0.1","android":"2.1.1","ios":"0.1.1"}\n' > "$SRC/release/versions.json"
g -C "$SRC" add -A && g -C "$SRC" commit -qm i5-bump
expect_ios "改了 iOS 输入且涨了 ios 号 ⇒ iOS 线过" clean HEAD~2 HEAD

# 口径一致性：gradle `buildIrohBlobsProviderBridge` 的每个 inputs include 都必须被
# check-version-bump.sh 的 ANDROID_INPUTS 覆盖——gradle 加了输入、门禁没跟上 ⇒ 红。
# GRADLE_KTS 可指向另一份文件做反证。
GRADLE_KTS="${GRADLE_KTS:-$ROOT/apps/android/app/build.gradle.kts}"
re=$(sed -n "s/^ANDROID_INPUTS='\(.*\)'$/\1/p" "$ROOT/tools/check-version-bump.sh")
incs=$(sed -n 's/.*include(\(.*\)).*/\1/p' "$GRADLE_KTS" | tr ',' '\n' | tr -d ' "')
if [ -z "$re" ] || [ -z "$incs" ]; then
  fail "③ 口径一致性：没抽到 ANDROID_INPUTS（${re:-空}）或 gradle include（${incs:-空}）"
else
  miss=0
  while IFS= read -r inc; do
    sample=${inc//\*\*/src/x.rs}
    sample=${sample//\*/x}
    grep -Eq "$re" <<<"$sample" || { miss=1; printf '  gradle input %s 不在 ANDROID_INPUTS 里\n' "$inc" >&2; }
  done <<<"$incs"
  if [ "$miss" -eq 0 ]; then
    pass "③ gradle inputs（$(tr '\n' ' ' <<<"$incs")）全部在安卓门禁口径内"
  else
    fail "③ gradle inputs 与 check-version-bump.sh 的安卓口径不一致"
  fi
fi

# ── ④ release.yml：dispatch 补跑必须检出被补跑的 tag（REL-13 #716）──────
# dispatch 时 actions/checkout 默认检出 main ⇒ 构建出的代码与 versions.json 都不是那个
# tag。判据：每个 checkout 的 with 块里都有 `ref: ${{ inputs.tag || github.ref }}`；
# 全文不再出现 GITHUB_SHA / github.sha（dispatch 时它们指向 main）。
# RELEASE_YML 可指向另一份文件做反证（例如 origin/main 上修复前的版本）。
REL_YML="${RELEASE_YML:-$ROOT/.github/workflows/release.yml}"
# shellcheck disable=SC2016  # 字面量：要匹配 YAML 里的 ${{ }} 原文，不是展开
want_ref='ref: ${{ inputs.tag || github.ref }}'
total=0; missing=0
while IFS= read -r ln; do
  total=$((total + 1))
  # 取该 checkout 行之后、缩进更深的连续行（它的 with 块）
  ind=$(sed -n "${ln}p" "$REL_YML" | sed -E 's/^( *).*/\1/' | wc -c)
  block=$(awk -v s="$ln" -v ind="$ind" 'NR>s { match($0,/^ */); if (RLENGTH < ind || $0 ~ /^ *- /) exit; print }' "$REL_YML")
  grep -qF "$want_ref" <<<"$block" || { missing=$((missing + 1)); printf '  checkout @%s 行缺 ref\n' "$ln" >&2; }
done < <(grep -n 'uses: actions/checkout@' "$REL_YML" | cut -d: -f1)
if [ "$total" -gt 0 ] && [ "$missing" -eq 0 ]; then
  pass "④ release.yml 全部 $total 个 checkout 都检出被补跑的 tag"
else
  fail "④ release.yml checkout 共 $total 个，缺 ref 的 $missing 个"
fi
# 只看代码行：注释里提到 GITHUB_SHA（解释为什么不用它）不算。
if grep -n -E 'GITHUB_SHA|github\.sha' "$REL_YML" | grep -v -E '^[0-9]+: *#' >&2; then
  fail "④ release.yml 仍引用 GITHUB_SHA / github.sha（dispatch 时是 main 的提交）"
else
  pass "④ release.yml 不再引用 GITHUB_SHA / github.sha"
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d 项失败\n' "$fails" >&2
  exit 1
fi
printf '\nall green\n'
