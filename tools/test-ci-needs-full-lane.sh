#!/usr/bin/env bash
# CI-11 (#255): tools/ci-needs-full-lane.sh 的判据测试 + 变异反证。
#
# 为什么这份测试是必需品：那个脚本一旦判错方向，后果是**静默放行且报绿**
# ——本仓这一轮修的缺陷全是这个形状。所以除了正向断言，**必须有变异反证**：
# 把判据故意改坏，断言必须立刻变红；不红就说明断言是恒真式，等于没写。
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

# 用给定脚本跑一组文件，回显判定
decide() {
  local script="$1"
  shift
  printf '%s\n' "$@" | bash "$script" - 2>/dev/null
}

expect() {
  local script="$1" want="$2" label="$3"
  shift 3
  local got
  got="$(decide "$script" "$@")"
  if [ "$got" = "$want" ]; then
    printf '  ✅ %-52s → %s\n' "$label" "$got"
    PASS=$((PASS + 1))
  else
    printf '  ❌ %-52s → 期望 %s，实得 %s\n' "$label" "$want" "$got"
    FAIL=$((FAIL + 1))
  fi
}

echo "==> 1. 正向判据（未变异的脚本）"
expect "$SUT" false "只改 docs/"                      docs/product/a.md
expect "$SUT" false "只改 cards/ 与根 .md"            cards/x.md README.md
expect "$SUT" false "只改 .claude/"                   .claude/settings.json
expect "$SUT" true  "改了 crates/"                    crates/daemon/src/main.rs
expect "$SUT" true  "改了桌面壳"                       apps/desktop/src-tauri/src/lib.rs
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
echo "==> 3. 变异反证：把判据改坏，上面的断言必须变红"
MUT="$TMP/mutated.sh"
# 变异：把兜底的 `return 1`（= 不在清单里）改成 `return 0`（= 当成无害），
# 也就是把 allowlist 悄悄变成「什么都放行」。
sed 's/^    \*) return 1 ;;$/    *) return 0 ;;/' "$SUT" >"$MUT"
if ! grep -q '^    \*) return 0 ;;$' "$MUT"; then
  echo "  ❌ 变异没生效（锚点没匹配上）—— 这一节等于没跑，判失败"
  FAIL=$((FAIL + 1))
else
  echo "  变异已注入：is_inert 的兜底分支 return 1 → return 0（allowlist 变成全放行）"
  before=$FAIL
  # 这三条在变异后**必须**失败；若仍然通过，说明原断言是恒真式
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
echo "==> 4. 异常路径：不给参数时必须判「要跑」"
got="$(bash "$SUT" 2>/dev/null)"
if [ "$got" = "true" ]; then
  echo "  ✅ 无参数 → true"
  PASS=$((PASS + 1))
else
  echo "  ❌ 无参数 → 期望 true，实得 $got"
  FAIL=$((FAIL + 1))
fi

echo
echo "────────────────────────────────"
printf '通过 %d，失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ ci-needs-full-lane 判据全部符合期望，且经变异证明有判别力"
