#!/usr/bin/env bash
# CI-11 (#255) / CI-17 (#373): tools/ci-needs-full-lane.sh 的判据测试 + 变异反证。
#
# 为什么这份测试是必需品：那个脚本一旦判错方向，后果是**静默放行且报绿**
# ——本仓这一轮修的缺陷全是这个形状。所以除了正向断言，**必须有变异反证**：
# 把判据故意改坏，断言必须立刻变红；不红就说明断言是恒真式，等于没写。
#
# CI-17 之后判据有**两个 lane**，本文件对两个 lane 各验一遍，另外钉三件事：
#   - 包含关系：不存在任何输入使 run_arch=false 而 run_heavy=true；
#   - 不带 lane 参数的调用语义与默认 lane 完全一致（ci-desktop.yml 就是这么调的，
#     这条是**向后兼容契约**，破了会静默改变桌面壳门禁的行为）；
#   - 未知 lane 一律判要跑（打错一个字母不许静默套用更宽的清单）。
#
# 用法: tools/test-ci-needs-full-lane.sh
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/ci-needs-full-lane.sh"
# 本测试会在临时仓库里跑 git。在 git hook 里运行时（如 pre-push 触发 just ci），继承来的
# GIT_DIR 等仓库定位变量会盖过 -C / cd，把 add/commit 写进真仓库，所以先清掉。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX
# #1504：tools/ 的判定要在仓库里 git grep 引用方，判据按当前目录找仓库根，所以在仓库根跑。
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO" || exit 1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# 用给定脚本跑一组文件，回显判定。lane 传 "-" 表示**不带 lane 参数**调用
# （向后兼容那条路径），其余按字面传给脚本。
decide() {
  local script="$1" lane="$2"
  shift 2
  if [ "$lane" = "-" ]; then
    printf '%s\n' "$@" | bash "$script" - 2>/dev/null
  else
    printf '%s\n' "$@" | bash "$script" - "$lane" 2>/dev/null
  fi
}

expect_lane() {
  local script="$1" lane="$2" want="$3" label="$4"
  shift 4
  local got
  got="$(decide "$script" "$lane" "$@")"
  if [ "$got" = "$want" ]; then
    printf '  ✅ %-56s → %s\n' "$label" "$got"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-56s → 期望 %s，实得 %s\n' "$label" "$want" "$got"
    FAIL=$((FAIL + 1))
  fi
}

# 不带 lane 参数（= ci-desktop.yml 的调法）
expect() {
  local script="$1" want="$2" label="$3"
  shift 3
  expect_lane "$script" - "$want" "$label" "$@"
}

echo "==> 1. 正向判据 · 不带 lane 参数（ci-desktop.yml 的调法，语义须与 CI-17 之前一致）"
expect "$SUT" false "只改 docs/"                      docs/product/a.md
expect "$SUT" false "只改子目录 .md 与根 .md"         infra/x.md README.md
expect "$SUT" false "只改 .claude/"                   .claude/settings.json
expect "$SUT" true  "改了 crates/"                    crates/daemon/src/main.rs
expect "$SUT" true  "改了桌面壳（默认 lane 必须照跑）"  apps/desktop/src-tauri/src/lib.rs
expect "$SUT" true  "改了 Cargo.lock"                 Cargo.lock
expect "$SUT" true  "文档 + 代码混合（一个不无害就要跑）" docs/a.md crates/proto/src/lib.rs
expect "$SUT" true  "#1049：桌面业务规则文档有常量表测试读它" docs/desktop/business-rules.zh-CN.md
expect_lane "$SUT" rust-workspace true "#1049：桌面业务规则文档（宽 lane 也要跑）" docs/desktop/business-rules.zh-CN.md

# #1066：flow_health.rs 读这两个手机端源码对账低空间线，宽 lane 也必须跑。
ANDROID_LOW="apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/FlowContract.kt"
IOS_LOW="apps/ios/Packages/PPassCore/Sources/PPassCore/Flow/FlowTypes.swift"
expect_lane "$SUT" rust-workspace true "#1066：Android 低空间常量文件（宽 lane 也要跑）" "$ANDROID_LOW"
expect_lane "$SUT" rust-workspace true "#1066：iOS 低空间常量文件（宽 lane 也要跑）" "$IOS_LOW"
expect "$SUT" true "#1066：Android 低空间常量文件（默认 lane）" "$ANDROID_LOW"
expect_lane "$SUT" rust-workspace false "#1066：同目录其他手机文件仍可跳" apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/Other.kt

# #1467：按依赖面补进的无害路径（两个 lane 都可跳）
INERT_1467=(
  tools/flow/flow.py
  tools/flow/review-prompt.md
  tools/e3/verify
  tools/hooks/pre-commit
  tools/test-flow.py
  tools/test-acceptance-gate.sh
  tools/test-ci-review.sh
  tools/test-e3.sh
  tools/test-local-hooks.sh
  tools/test-release-acceptance.sh
  tools/ci-paths.sh
  tools/test-ci-paths.sh
  release/notes/android/0.11.0.zh.txt
  .github/ISSUE_TEMPLATE/task.yml
)
for f in "${INERT_1467[@]}"; do
  expect "$SUT" false "#1467：只改 ${f}"                      "$f"
  expect_lane "$SUT" rust-workspace false "#1467：只改 ${f}（宽 lane）" "$f"
done
expect "$SUT" false "#1467：流程脚本 + 更新说明 + 文档混合"  tools/flow/a.sh release/notes/macos/1.0.0.en.txt docs/a.md
expect "$SUT" true  "#1467：流程脚本 + crates 混合 → 要跑"    tools/flow/a.sh crates/daemon/src/lib.rs
expect "$SUT" true  "#1467：release/ 下 notes 之外 → 要跑"   release/other.txt
expect "$SUT" true  "#1467：判据脚本自身 → 要跑"             tools/ci-needs-full-lane.sh
expect "$SUT" true  "#1467：fitness 登记表 → 要跑"           tools/egress-allowlist.txt
expect "$SUT" true  "#1467：tools/ 下其他自测 → 要跑"        tools/test-check-egress.sh
expect "$SUT" true  "#1467：.github/ 其它文件 → 要跑"        .github/actions/desktop-checks/action.yml
# #1467：crates/diag 用 include_str! 读桌面 i18n 字典，宽 lane 不能当 apps/** 跳过
DIAG_EN="apps/desktop/src/i18n/en.json"
DIAG_ZH="apps/desktop/src/i18n/zh.json"
expect_lane "$SUT" rust-workspace true "#1467：桌面 i18n en（diag 读，宽 lane 要跑）" "$DIAG_EN"
expect_lane "$SUT" rust-workspace true "#1467：桌面 i18n zh（diag 读，宽 lane 要跑）" "$DIAG_ZH"
expect_lane "$SUT" rust-workspace false "#1467：桌面其他前端文件仍可跳" apps/desktop/src/lib/x.ts

echo
echo "==> 1b. #1504：tools/ 下没登记的文件按引用闭包判（真仓库）"
for lane in default rust-workspace; do
  expect_lane "$SUT" "$lane" false "只改本地清理脚本（lane=${lane}）"        tools/clean-local-builds.sh
  expect_lane "$SUT" "$lane" false "只改本地清理脚本的自测（lane=${lane}）"  tools/test-clean-local-builds.sh
  expect_lane "$SUT" "$lane" true  "arch-check（ci-rust 直接调用，lane=${lane}）" tools/arch-check.sh
  expect_lane "$SUT" "$lane" true  "fitness_lib（被 import，lane=${lane}）"  tools/fitness_lib.py
done
expect "$SUT" true "清理脚本 + crates 混合 → 要跑" tools/clean-local-builds.sh crates/daemon/src/lib.rs

echo
echo "==> 1c. #1467：从源码派生的反向用例（被 gated job 读到的文件两个 lane 都必须判要跑）"
DERIVED="$TMP/derived.txt"
: >"$DERIVED"
# ① crates/ 里 include_str!/include_bytes! 指向 crates/ 之外的目标（按所在文件解析相对路径）
(cd "$REPO" && git grep -nE 'include_(str|bytes)!\("[^"]+"\)' -- 'crates/*.rs') |
  python3 -c '
import posixpath, re, sys
for line in sys.stdin:
    path = line.split(":", 1)[0]
    for t in re.findall(r"include_(?:str|bytes)!\(\"([^\"]+)\"\)", line):
        # git 输出的路径恒为 / 分隔；os.path 在 Windows 上会拼出反斜杠，与后面的 / 比较对不上（#1518）。
        p = posixpath.normpath(posixpath.join(posixpath.dirname(path), t))
        if not p.startswith("crates/") and not p.startswith(".."):
            print(p)
' >>"$DERIVED"
# ② ci-rust.yml、ci-desktop.yml 及其 composite action 里引用的 tools/ 文件
WF_FILES=("$REPO/.github/workflows/ci-rust.yml" "$REPO/.github/workflows/ci-desktop.yml")
ACTIONS="$(grep -hoE 'uses: \./\.github/actions/[A-Za-z0-9_-]+' "${WF_FILES[@]}" | sed 's#uses: \./##' | sort -u)"
while IFS= read -r a; do
  [ -n "$a" ] || continue
  WF_FILES+=("$REPO/$a/action.yml")
  echo "$a/action.yml" >>"$DERIVED"
done <<EOF2
$ACTIONS
EOF2
grep -hv '^[[:space:]]*#' "${WF_FILES[@]}" | grep -hoE 'tools/[A-Za-z0-9_./-]*[A-Za-z0-9_-]' >>"$DERIVED"
sort -u "$DERIVED" -o "$DERIVED"
n="$(grep -c . "$DERIVED")"
bad=0
if [ "$n" -lt 10 ]; then
  echo "  ❌ 派生出的文件只有 $n 个，提取逻辑可能失效（期望至少 10 个）"
  bad=1
fi
grep -qx 'apps/desktop/src/i18n/en.json' "$DERIVED" || { echo "  ❌ 派生清单里没有 diag 读的桌面 i18n（提取逻辑失效）"; bad=1; }
grep -qx 'tools/setup-rust-toolchain.sh' "$DERIVED" || { echo "  ❌ 派生清单里没有 setup-rust-toolchain.sh（提取逻辑失效）"; bad=1; }
while IFS= read -r f; do
  [ -n "$f" ] || continue
  for lane in default rust-workspace; do
    got="$(decide "$SUT" "$lane" "$f")"
    if [ "$got" != "true" ]; then
      printf '  ❌ 「%s」被 gated job 读到，lane=%s 却判 %s\n' "$f" "$lane" "$got"
      bad=1
    fi
  done
done <"$DERIVED"
if [ "$bad" -eq 0 ]; then
  echo "  ✅ 派生出 $n 个被读文件，两个 lane 全部判要跑"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

echo
echo "==> 2. fail-closed 的命门：不认识的东西一律要跑"
expect "$SUT" true  "**未知新目录**（清单里没有）"      newthing/x.rs
expect "$SUT" true  "assets/i18n（被 diag 测试消费）"  assets/i18n/en.json
expect "$SUT" true  "tools/ 下的脚本"                  tools/arch-check.sh
expect "$SUT" true  "workflow 自己"                    .github/workflows/ci-rust.yml
expect "$SUT" true  "空列表（说明没搞清状况）"          ""
echo "  （空列表那条：没搞清发生了什么 ≠ 什么都没改，必须判要跑）"

echo
echo "==> 3. CI-17：两个 lane 各自的判定"
echo "  -- default lane（显式传，须与不传参数完全一致）--"
expect_lane "$SUT" default true  "改了桌面壳"           apps/desktop/src-tauri/src/lib.rs
expect_lane "$SUT" default true  "改了 Android"         apps/android/app/src/main/x.kt
expect_lane "$SUT" default false "只改 docs/"           docs/a.md
echo "  -- rust-workspace lane（apps/** 额外算惰性）--"
expect_lane "$SUT" rust-workspace false "只改桌面壳 → 主 workspace 门禁可跳" apps/desktop/src-tauri/src/lib.rs
expect_lane "$SUT" rust-workspace false "只改 Android → 可跳"               apps/android/app/src/main/x.kt
expect_lane "$SUT" rust-workspace false "apps/ + docs/ 混合 → 仍可跳"        apps/x.kt docs/a.md
expect_lane "$SUT" rust-workspace true  "apps/ + crates/ 混合 → 必须跑"      apps/x.kt crates/y.rs
expect_lane "$SUT" rust-workspace true  "改了 crates/ → 必须跑"              crates/daemon/src/main.rs
expect_lane "$SUT" rust-workspace true  "改了 Cargo.lock → 必须跑"           Cargo.lock
expect_lane "$SUT" rust-workspace true  "未知新目录 → 必须跑"                newthing/x.rs
expect_lane "$SUT" rust-workspace true  "workflow 自己 → 必须跑"             .github/workflows/ci-rust.yml
expect_lane "$SUT" rust-workspace true  "tools/ 下的脚本 → 必须跑"           tools/arch-check.sh
expect_lane "$SUT" rust-workspace true  "空列表 → 必须跑"                    ""

echo
echo "==> 4. CI-17：未知 lane 一律判要跑（打错一个字母不许套用更宽的清单）"
expect_lane "$SUT" rust-worksapce true "lane 拼错（rust-worksapce）"  apps/x.kt
expect_lane "$SUT" heavy          true "lane 用了旧叫法（heavy）"      apps/x.kt
expect_lane "$SUT" ""             true "lane 传空串"                  apps/x.kt

echo
echo "==> 5. CI-17：包含关系 —— 不存在 run_arch=false 而 run_heavy=true 的输入"
# 宽 lane 的无害清单是窄 lane 的**超集** ⇒ 宽 lane 判「要跑」时，窄 lane 不可能判「可跳」。
# 这条若破，说明有人把某条路径只加进了窄清单，是真的 fail-open。
INCL_OK=1
for spec in "docs/a.md" "infra/x.md" ".claude/s.json" "README.md" \
            "apps/x.kt" "apps/desktop/src-tauri/src/lib.rs" \
            "crates/a.rs" "Cargo.lock" "assets/i18n/en.json" \
            "tools/arch-check.sh" ".github/workflows/ci-rust.yml" "newthing/x.rs" \
            "tools/flow/a.sh" "release/notes/x.txt" ".github/ISSUE_TEMPLATE/t.yml" \
            "apps/desktop/src/i18n/en.json" "tools/clean-local-builds.sh" \
            "" ; do
  a="$(decide "$SUT" default $spec)"
  h="$(decide "$SUT" rust-workspace $spec)"
  if [ "$h" = "true" ] && [ "$a" != "true" ]; then
    printf '  ❌ 包含关系被破坏：「%s」→ run_arch=%s 而 run_heavy=%s\n' "$spec" "$a" "$h"
    INCL_OK=0
  fi
done
if [ "$INCL_OK" -eq 1 ]; then
  echo "  ✅ 18 组输入全部满足 run_heavy=true ⇒ run_arch=true"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

echo
echo "==> 6. 变异反证甲：把 allowlist 兜底改成全放行，断言必须变红"
# prepare_mutant <out_dir> <python transform>: 复制 wrapper + impact.py 并对 impact.py 注入变异
prepare_mutant() {
  local mdir="$1" py_code="$2"
  rm -rf "$mdir"
  mkdir -p "$mdir/tools/ci"
  cp "$SUT" "$mdir/tools/ci-needs-full-lane.sh"
  cp "$REPO/tools/ci/impact.py" "$mdir/tools/ci/impact.py"
  chmod +x "$mdir/tools/ci-needs-full-lane.sh"
  python3 -B -I -c "$py_code" "$mdir/tools/ci/impact.py"
}

MUT_DIR="$TMP/mut1"
if ! prepare_mutant "$MUT_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "return True, f\"「{f}」不在无害清单里（lane={lane}）→ 要跑\""
new = "return False, \"mutated allow all\""
assert old in s, "anchor missing"
p.write_text(s.replace(old, new, 1), encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT="$MUT_DIR/tools/ci-needs-full-lane.sh"
  echo "  变异已注入：decide_ci 的兜底 return True → return False（allowlist 变成全放行）"
  before=$FAIL
  expect "$MUT" true "【变异后应失败】改了 crates/"      crates/daemon/src/main.rs
  expect "$MUT" true "【变异后应失败】未知新目录"        newthing/x.rs
  expect "$MUT" true "【变异后应失败】改了 Cargo.lock"   Cargo.lock
  gained=$((FAIL - before))
  if [ "$gained" -eq 3 ]; then
    echo "  ✅ 三条断言在变异后全部变红 ⇒ 判据有判别力，不是恒真式"
    FAIL=$((FAIL - 3))
    PASS=$((PASS + 1))
  else
    echo "  ❌ 变异后只有 $gained/3 条变红 ⇒ 断言判别力不足，必须修"
    FAIL=$((before + 1))
  fi
fi

echo
echo "==> 7. 变异反证乙（CI-17）：把宽 lane 的 apps/* 改坏，rust-workspace 的断言必须变红"
MUT2_DIR="$TMP/mut2"
if ! prepare_mutant "$MUT2_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "if lane == \"rust-workspace\" and rel_path.startswith(\"apps/\"):"
new = "if lane == \"rust-workspace\" and rel_path.startswith(\"zzz-never-matches/\"):"
assert old in s, "anchor missing"
p.write_text(s.replace(old, new, 1), encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT2="$MUT2_DIR/tools/ci-needs-full-lane.sh"
  echo "  变异已注入：宽 lane 的 apps/* → zzz-never-matches/*"
  before=$FAIL
  expect_lane "$MUT2" rust-workspace false "【变异后应失败】只改桌面壳" apps/desktop/src-tauri/src/lib.rs
  expect_lane "$MUT2" rust-workspace false "【变异后应失败】只改 Android" apps/android/app/src/main/x.kt
  expect_lane "$MUT2" rust-workspace false "【变异后应失败】apps/ + docs/" apps/x.kt docs/a.md
  gained=$((FAIL - before))
  if [ "$gained" -eq 3 ]; then
    echo "  ✅ 三条断言在变异后全部变红 ⇒ 宽清单真的在起作用，不是恒假式"
    FAIL=$((FAIL - 3))
    PASS=$((PASS + 1))
  else
    echo "  ❌ 变异后只有 $gained/3 条变红 ⇒ 断言判别力不足，必须修"
    FAIL=$((before + 1))
  fi
fi

echo
echo "==> 7b. 变异反证丙（#1066）：去掉两个手机端常量文件的跨目录识别，宽 lane 的断言必须变红"
MUT3_DIR="$TMP/mut3"
if ! prepare_mutant "$MUT3_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old_r = "if readers and (lane != \"rust-workspace\" or any(pkg != graph.tauri_pkg for pkg in readers)):"
new_r = "if False:"
old_f = "\"apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/FlowContract.kt\","
old_i = "\"apps/ios/Packages/PPassCore/Sources/PPassCore/Flow/FlowTypes.swift\","
assert old_r in s and old_f in s and old_i in s, "anchor missing"
s = s.replace(old_r, new_r, 1).replace(old_f, "", 1).replace(old_i, "", 1)
p.write_text(s, encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT3="$MUT3_DIR/tools/ci-needs-full-lane.sh"
  before=$FAIL
  expect_lane "$MUT3" rust-workspace true "【变异后应失败】Android 低空间常量文件" "$ANDROID_LOW"
  expect_lane "$MUT3" rust-workspace true "【变异后应失败】iOS 低空间常量文件" "$IOS_LOW"
  gained=$((FAIL - before))
  if [ "$gained" -eq 2 ]; then
    echo "  ✅ 两条断言在变异后全部变红 ⇒ 登记与动态扫描都在起作用"
    FAIL=$((FAIL - 2))
    PASS=$((PASS + 1))
  else
    echo "  ❌ 变异后只有 $gained/2 条变红 ⇒ 断言判别力不足，必须修"
    FAIL=$((before + 1))
  fi
fi

echo
echo "==> 7c. 变异反证丁（#1467）：去掉新补的无害条目，「可跳」断言必须变红"
MUT4_DIR="$TMP/mut4"
if ! prepare_mutant "$MUT4_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
s2 = s.replace("\"release/notes/\", ", "").replace("\"tools/flow/\", ", "").replace("\".github/ISSUE_TEMPLATE/\"", "\"zzz-no-match/\"")
assert s2 != s, "anchor missing"
p.write_text(s2, encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT4="$MUT4_DIR/tools/ci-needs-full-lane.sh"
  before=$FAIL
  expect "$MUT4" false "【变异后应失败】只改 tools/flow"               tools/flow/a.sh
  expect "$MUT4" false "【变异后应失败】只改 release/notes"            release/notes/android/0.11.0.zh.txt
  expect "$MUT4" false "【变异后应失败】只改 .github/ISSUE_TEMPLATE/" .github/ISSUE_TEMPLATE/task.yml
  gained=$((FAIL - before))
  if [ "$gained" -eq 3 ]; then
    echo "  ✅ 三条断言在变异后全部变红 ⇒ 新清单真的在起作用，不是恒假式"
    FAIL=$((FAIL - 3))
    PASS=$((PASS + 1))
  else
    echo "  ❌ 变异后只有 $gained/3 条变红 ⇒ 断言判别力不足，必须修"
    FAIL=$((before + 1))
  fi
fi

echo
echo "==> 7d. 变异反证戊（#1467）：去掉桌面 i18n 的识别，宽 lane 断言与派生断言都必须变红"
MUT5_DIR="$TMP/mut5"
if ! prepare_mutant "$MUT5_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old_r = "if readers and (lane != \"rust-workspace\" or any(pkg != graph.tauri_pkg for pkg in readers)):"
old_en = "\"apps/desktop/src/i18n/en.json\","
old_zh = "\"apps/desktop/src/i18n/zh.json\","
assert old_r in s and old_en in s and old_zh in s, "anchor missing"
s = s.replace(old_r, "if False:", 1).replace(old_en, "", 1).replace(old_zh, "", 1)
p.write_text(s, encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT5="$MUT5_DIR/tools/ci-needs-full-lane.sh"
  before=$FAIL
  expect_lane "$MUT5" rust-workspace true "【变异后应失败】桌面 i18n en" "$DIAG_EN"
  expect_lane "$MUT5" rust-workspace true "【变异后应失败】桌面 i18n zh" "$DIAG_ZH"
  dgot="$(decide "$MUT5" rust-workspace "$DIAG_EN")"
  if [ "$dgot" = "false" ] && grep -qx "$DIAG_EN" "$DERIVED"; then
    derived_red=1
  else
    derived_red=0
  fi
  gained=$((FAIL - before))
  if [ "$gained" -eq 2 ] && [ "$derived_red" -eq 1 ]; then
    echo "  ✅ 两条断言变红，派生清单同样会抓到 ⇒ 登记与派生都在起作用"
    FAIL=$((FAIL - 2))
    PASS=$((PASS + 1))
  else
    echo "  ❌ 变异后 $gained/2 条变红、派生是否抓到=$derived_red ⇒ 判别力不足，必须修"
    FAIL=$((before + 1))
  fi
fi

echo
echo "==> 7e. #1467：base sha 模式下改名的旧路径也参与判定（把 gated 脚本挪进惰性目录必须要跑）"
GR="$TMP/rename-repo"
rename_decide() { # rename_decide <脚本>：临时仓库里把 tools/setup-rust-toolchain.sh 挪到 tools/flow/，按 base 判
  rm -rf "$GR" && mkdir -p "$GR/tools" "$GR/.github/workflows" &&
    seq 1 50 >"$GR/tools/setup-rust-toolchain.sh" &&
    printf 'jobs:\n  t:\n    steps:\n      - run: tools/setup-rust-toolchain.sh\n' >"$GR/.github/workflows/ci-rust.yml" &&
    printf 'jobs:\n  d:\n    steps:\n      - run: echo d\n' >"$GR/.github/workflows/ci-desktop.yml" &&
    git -C "$GR" init -q --template= &&
    git -C "$GR" add -A && git -C "$GR" -c user.name=t -c user.email=t@invalid commit -q -m base &&
    local b && b="$(git -C "$GR" rev-parse HEAD)" &&
    mkdir -p "$GR/tools/flow" && git -C "$GR" mv tools/setup-rust-toolchain.sh tools/flow/setup-rust-toolchain.sh &&
    git -C "$GR" -c user.name=t -c user.email=t@invalid commit -q -m mv &&
    (cd "$GR" && bash "$1" "$b" rust-workspace 2>/dev/null)
}
got="$(rename_decide "$SUT")"
if [ "$got" = "true" ]; then
  echo "  ✅ 改名 tools/setup-rust-toolchain.sh → tools/flow/ → true"
  PASS=$((PASS + 1))
else
  echo "  ❌ 改名 tools/setup-rust-toolchain.sh → tools/flow/ → 期望 true，实得 ${got}"
  FAIL=$((FAIL + 1))
fi
MUT6_DIR="$TMP/mut6"
if ! prepare_mutant "$MUT6_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "\"--no-renames\", "
assert old in s, "anchor missing"
p.write_text(s.replace(old, "", 1), encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT6="$MUT6_DIR/tools/ci-needs-full-lane.sh"
  got="$(rename_decide "$MUT6")"
  if [ "$got" = "false" ]; then
    echo "  ✅ 反证：去掉 --no-renames 后同一改名判 false ⇒ 用例有判别力"
    PASS=$((PASS + 1))
  else
    echo "  ❌ 反证：去掉 --no-renames 后仍判 ${got} ⇒ 用例没有判别力"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "==> 7f. #1504：引用闭包（临时仓库：ci-rust 调 gated.sh，gated.sh source helper.sh，lonely.sh 只被 justfile 提到）"
CR="$TMP/closure-repo"
mkdir -p "$CR/.github/workflows" "$CR/tools"
printf 'jobs:\n  t:\n    steps:\n      - run: tools/gated.sh\n' >"$CR/.github/workflows/ci-rust.yml"
printf 'jobs:\n  d:\n    steps:\n      - run: echo desktop\n' >"$CR/.github/workflows/ci-desktop.yml"
# shellcheck disable=SC2016 # 字面量写进夹具，不展开
printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/helper.sh"\n' >"$CR/tools/gated.sh"
printf 'h() { :; }\n' >"$CR/tools/helper.sh"
printf 'echo lonely\n' >"$CR/tools/lonely.sh"
printf 'lonely:\n  bash tools/lonely.sh\n' >"$CR/justfile"
git -C "$CR" init -q --template= && git -C "$CR" add -A &&
  git -C "$CR" -c user.name=t -c user.email=t@invalid commit -q -m base
# cdecide <脚本> <lane> <文件...>：在临时仓库里按 stdin 判
cdecide() {
  local script="$1" lane="$2"
  shift 2
  (cd "$CR" && printf '%s\n' "$@" | bash "$script" - "$lane" 2>/dev/null)
}
cexpect() { # cexpect <脚本> <lane> <期望> <说明> <文件...>
  local script="$1" lane="$2" want="$3" label="$4" got
  shift 4
  got="$(cdecide "$script" "$lane" "$@")"
  if [ "$got" = "$want" ]; then
    printf '  ✅ %-56s → %s\n' "$label" "$got"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-56s → 期望 %s，实得 %s\n' "$label" "$want" "$got"
    FAIL=$((FAIL + 1))
  fi
}
for lane in default rust-workspace; do
  cexpect "$SUT" "$lane" true  "ci-rust 直接调用的脚本（lane=${lane}）"   tools/gated.sh
  cexpect "$SUT" "$lane" true  "被它 source 的辅助脚本（lane=${lane}）"   tools/helper.sh
  cexpect "$SUT" "$lane" false "只被 justfile 提到的脚本（lane=${lane}）" tools/lonely.sh
  cexpect "$SUT" "$lane" true  "HEAD 里已不存在的 tools 文件（lane=${lane}）" tools/gone.sh
done

# git grep 出错：PATH 里垫一个 git，只让 grep 子命令以 2 退出（其余照常转给真 git）。
REAL_GIT="$(command -v git)"
SHIM="$TMP/git-shim"
mkdir -p "$SHIM"
# shellcheck disable=SC2016 # 字面量写进夹具，不展开
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = grep ] && exit 2; done\nexec "%s" "$@"\n' "$REAL_GIT" >"$SHIM/git"
chmod +x "$SHIM/git"
shim_decide() { (cd "$CR" && echo tools/lonely.sh | PATH="$SHIM:$PATH" bash "$1" - 2>/dev/null); }
got="$(shim_decide "$SUT")"
if [ "$got" = "true" ]; then
  echo "  ✅ git grep 出错（退出码 2）时 lonely.sh → true"
  PASS=$((PASS + 1))
else
  echo "  ❌ git grep 出错（退出码 2）时 lonely.sh → 期望 true，实得 ${got}"
  FAIL=$((FAIL + 1))
fi

# 门禁 workflow 用通配符拼 tools/ 路径：引用不写名字，追不到，一律要跑。
DYN="$TMP/closure-dyn"
rm -rf "$DYN" && cp -R "$CR" "$DYN"
# shellcheck disable=SC2016 # 字面量写进夹具，不展开
printf '      - run: for s in tools/gen/*.sh; do "$s"; done\n' >>"$DYN/.github/workflows/ci-rust.yml"
got="$( (cd "$DYN" && echo tools/lonely.sh | bash "$SUT" - 2>/dev/null) )"
if [ "$got" = "true" ]; then
  echo "  ✅ 门禁 workflow 里有 tools/*.sh 通配时 lonely.sh → true"
  PASS=$((PASS + 1))
else
  echo "  ❌ 门禁 workflow 里有 tools/*.sh 通配时 lonely.sh → 期望 true，实得 ${got}"
  FAIL=$((FAIL + 1))
fi

echo "  -- 反证：去掉闭包追溯（只看直接引用），辅助脚本必须判 false --"
MUT7_DIR="$TMP/mut7"
if ! prepare_mutant "$MUT7_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "seen.add(r)\n                queue.append(r)"
new = "continue"
assert old in s, "anchor missing"
p.write_text(s.replace(old, new, 1), encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT7="$MUT7_DIR/tools/ci-needs-full-lane.sh"
  before=$FAIL
  cexpect "$MUT7" default true "【变异后应失败】被 source 的辅助脚本" tools/helper.sh
  cexpect "$MUT7" default true "直接调用的脚本（变异不影响）"       tools/gated.sh
  gained=$((FAIL - before))
  if [ "$gained" -eq 1 ]; then
    echo "  ✅ 只有辅助脚本那条变红 ⇒ 闭包追溯真的在起作用"
    FAIL=$((FAIL - 1))
    PASS=$((PASS + 1))
  else
    echo "  ❌ 变异后 ${gained}/1 条变红（期望恰好 1）⇒ 判别力不足，必须修"
    FAIL=$((before + 1))
  fi
fi

echo "  -- 反证：忽略 git grep 的退出码，垫片下 lonely.sh 必须判 false --"
MUT8_DIR="$TMP/mut8"
if ! prepare_mutant "$MUT8_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "if grep_err:"
new = "if False:"
assert old in s, "anchor missing"
p.write_text(s.replace(old, new, 1), encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT8="$MUT8_DIR/tools/ci-needs-full-lane.sh"
  got="$(shim_decide "$MUT8")"
  if [ "$got" = "false" ]; then
    echo "  ✅ 忽略退出码后同一垫片判 false ⇒ git grep 出错的用例有判别力"
    PASS=$((PASS + 1))
  else
    echo "  ❌ 忽略退出码后仍判 ${got} ⇒ 用例没有判别力"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "==> 8. 异常路径：不给参数时必须判「要跑」"
for args in "" "rust-workspace"; do
  # shellcheck disable=SC2086
  got="$(bash "$SUT" $args 2>/dev/null)"
  label="无 base（lane=${args:-未给}）"
  if [ "$got" = "true" ]; then
    printf '  ✅ %-56s → true\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-56s → 期望 true，实得 %s\n' "$label" "$got"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "==> 7g. 变异反证（#1545）：去掉 .coderabbit.yaml 登记，可跳断言必须变红"
expect "$SUT" false "#1545：只改 .coderabbit.yaml" .coderabbit.yaml
expect_lane "$SUT" rust-workspace false "#1545：只改 .coderabbit.yaml（宽 lane）" .coderabbit.yaml
MUT9_DIR="$TMP/mut9"
if ! prepare_mutant "$MUT9_DIR" '
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "if rel_path == \".coderabbit.yaml\":\n        return True"
new = "if False:\n        return True"
assert old in s, "anchor missing"
p.write_text(s.replace(old, new, 1), encoding="utf-8")
'; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  MUT9="$MUT9_DIR/tools/ci-needs-full-lane.sh"
  before=$FAIL
  expect "$MUT9" false "【变异后应失败】只改 .coderabbit.yaml" .coderabbit.yaml
  gained=$((FAIL - before))
  if [ "$gained" -eq 1 ]; then
    echo "  ✅ 断言在变异后变红 ⇒ .coderabbit.yaml 登记真的在起作用"
    FAIL=$((FAIL - 1))
    PASS=$((PASS + 1))
  else
    echo "  ❌ 变异后 $gained/1 条变红 ⇒ 断言判别力不足，必须修"
    FAIL=$((before + 1))
  fi
fi

echo
echo "────────────────────────────────"
printf '通过 %d，失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ ci-needs-full-lane 判据全部符合期望，两个 lane 均经变异证明有判别力"
