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
expect "$SUT" false "只改 cards/ 与根 .md"            cards/x.md README.md
expect "$SUT" false "只改 .claude/"                   .claude/settings.json
expect "$SUT" true  "改了 crates/"                    crates/daemon/src/main.rs
expect "$SUT" true  "改了桌面壳（默认 lane 必须照跑）"  apps/desktop/src-tauri/src/lib.rs
expect "$SUT" true  "改了 Cargo.lock"                 Cargo.lock
expect "$SUT" true  "文档 + 代码混合（一个不无害就要跑）" docs/a.md crates/proto/src/lib.rs

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
for spec in "docs/a.md" "cards/x.md" ".claude/s.json" "README.md" \
            "apps/x.kt" "apps/desktop/src-tauri/src/lib.rs" \
            "crates/a.rs" "Cargo.lock" "assets/i18n/en.json" \
            "tools/arch-check.sh" ".github/workflows/ci-rust.yml" "newthing/x.rs" \
            "" ; do
  a="$(decide "$SUT" default $spec)"
  h="$(decide "$SUT" rust-workspace $spec)"
  if [ "$h" = "true" ] && [ "$a" != "true" ]; then
    printf '  ❌ 包含关系被破坏：「%s」→ run_arch=%s 而 run_heavy=%s\n' "$spec" "$a" "$h"
    INCL_OK=0
  fi
done
if [ "$INCL_OK" -eq 1 ]; then
  echo "  ✅ 13 组输入全部满足 run_heavy=true ⇒ run_arch=true"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

echo
echo "==> 6. 变异反证甲：把 allowlist 兜底改成全放行，断言必须变红"
MUT="$TMP/mutated.sh"
# 变异：把兜底的 `return 1`（= 不在清单里）改成 `return 0`（= 当成无害），
# 也就是把 allowlist 悄悄变成「什么都放行」。
sed 's/^  return 1$/  return 0/' "$SUT" >"$MUT"
if ! grep -q '^  return 0$' "$MUT"; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  echo "  变异已注入：is_inert 的兜底 return 1 → return 0（allowlist 变成全放行）"
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
# 这一节专治「第 3 节那些 false 是不是恒假式」。把 apps/* 改成一个永不匹配的
# 模式，那些「可跳」断言必须全部变成「要跑」。
MUT2="$TMP/mutated2.sh"
sed 's|^      apps/\*) return 0 ;;$|      zzz-never-matches/*) return 0 ;;|' "$SUT" >"$MUT2"
if ! grep -q 'zzz-never-matches' "$MUT2"; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
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
echo "────────────────────────────────"
printf '通过 %d，失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ ci-needs-full-lane 判据全部符合期望，两个 lane 均经变异证明有判别力"
