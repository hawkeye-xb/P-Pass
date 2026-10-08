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
SRC="$SANDBOX/src"
g init -q -b main "$SRC"
mkdir -p "$SRC/apps/android" "$SRC/docs" "$SRC/release" "$SRC/tools"
echo a > "$SRC/apps/android/a.txt"
g -C "$SRC" add -A && g -C "$SRC" commit -qm c1 && g -C "$SRC" tag v0.1.0
printf '{"desktop":"1.0.0","android":"1.1.0"}\n' > "$SRC/release/versions.json"
g -C "$SRC" add -A && g -C "$SRC" commit -qm c2 && g -C "$SRC" tag v1.0.0
printf '{"desktop":"2.0.0","android":"2.1.0"}\n' > "$SRC/release/versions.json"
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
  if [ "$got" = "$want" ]; then pass "② $desc → $got"; else fail "② $desc：期望 $want，实际 $got"; fi
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
      pass "③ $desc（exit=$rc）"
      return
    fi
  fi
  fail "③ $desc：期望 exit $want 且含「$pat」，实际 exit=$rc：$out"
}
expect_cv "head-ref 不存在 ⇒ 非零" nonzero "head-ref" v1.0.0 refs/tags/does-not-exist
expect_cv "head-ref 恰好是目录名（tools）⇒ 非零，不被当成路径" nonzero "head-ref" v1.0.0 tools
expect_cv "正常路径不受影响：v1.0.0→HEAD 改了 android 且涨了号 ⇒ 0" 0 "^ok:" v1.0.0 HEAD
# 门禁本身仍然有效：改 android 不涨号 ⇒ 红
echo c > "$SRC/apps/android/a.txt"
g -C "$SRC" add apps/android/a.txt && g -C "$SRC" commit -qm c4
expect_cv "改 android 不涨号 ⇒ 非零（门禁本身没被改坏）" nonzero "android 版本没涨" HEAD~1 HEAD

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
