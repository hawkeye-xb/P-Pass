#!/usr/bin/env bash
# #1187：tools/ci-paths.sh 与 tools/ci-gate.sh 的判据测试 + 变异反证。
#
# 这两个脚本判错方向的后果都是**静默放行且报绿**：hit 判成 false ⇒ 该跑的 lane 被跳过；
# core 判成 false ⇒ 核心改动不用审批；gate 把 failure 当通过 ⇒ 红的 PR 能合入。
# 所以除了正向断言，每个命门都有一条变异：把脚本故意改坏，断言必须变红，
# 不红说明断言是恒真式。
#
# 用法: tools/test-ci-paths.sh
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATHS="$HERE/ci-paths.sh"
GATE="$HERE/ci-gate.sh"
RULES="$HERE/../.github/core-paths.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok() {
  printf '  ✅ %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '  ❌ %s\n' "$1"
  FAIL=$((FAIL + 1))
}

# hit_is <脚本> <期望> <说明> <文件列表（换行分隔）> <glob>...
hit_is() {
  local script="$1" want="$2" label="$3" files="$4" got
  shift 4
  got="$(printf '%s' "$files" | bash "$script" hit - "$@" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "$label → $got" || bad "$label → 期望 ${want}，实得 $got"
}

# core_is <脚本> <规则文件> <期望> <说明> <文件>...
core_is() {
  local script="$1" rules="$2" want="$3" label="$4" got
  shift 4
  got="$(printf '%s\n' "$@" | bash "$script" core - "$rules" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "$label → $got" || bad "$label → 期望 ${want}，实得 $got"
}

# gate_is <脚本> <期望退出码> <说明> <NEEDS json>
gate_is() {
  local script="$1" want="$2" label="$3" got
  NEEDS="$4" bash "$script" >/dev/null 2>&1
  got=$?
  [ "$got" = "$want" ] && ok "$label → exit $got" || bad "$label → 期望 exit ${want}，实得 $got"
}

echo "==> 1. hit：glob 语义与 GitHub paths 一致"
hit_is "$PATHS" true "dir/** 命中深层文件" "apps/android/app/src/x.kt" "apps/android/**"
hit_is "$PATHS" false "dir/** 不命中兄弟目录" "apps/ios/x.swift" "apps/android/**"
hit_is "$PATHS" true "**.sh 命中任意深度的 .sh" "tools/ios/e3-judge.sh" "**.sh"
hit_is "$PATHS" false "* 不跨 /" "tools/ios/e3-judge.sh" "tools/*.sh"
hit_is "$PATHS" true "* 在本层命中" "tools/arch-check.sh" "tools/*.sh"
hit_is "$PATHS" true "tools/build-ios-* 前缀" "tools/build-ios-transport-xcframework.sh" "tools/build-ios-*"
hit_is "$PATHS" false ". 按字面匹配，不当通配" "Cargo-lock" "Cargo.lock"
hit_is "$PATHS" true "多文件里有一个命中即 true" "docs/a.md
crates/proto/src/lib.rs" "crates/proto/**"
hit_is "$PATHS" false "全部不命中" "docs/a.md
README.md" "crates/**" "apps/**"

echo
echo "==> 2. hit：fail-closed"
hit_is "$PATHS" true "空列表 → true" "" "crates/**"
hit_is "$PATHS" true "没给 glob → true" "docs/a.md"
got="$(bash "$PATHS" hit 2>/dev/null)"
[ "$got" = true ] && ok "没给 base → true" || bad "没给 base → 期望 true，实得 $got"
got="$(bash "$PATHS" hit 0000000000000000000000000000000000000000 "docs/**" 2>/dev/null)"
[ "$got" = true ] && ok "base 全零（新分支 push）→ true" || bad "base 全零 → 期望 true，实得 $got"
got="$(bash "$PATHS" bogus 2>/dev/null)"
[ "$got" = true ] && ok "未知子命令 → true" || bad "未知子命令 → 期望 true，实得 $got"

echo
echo "==> 3. core：真实规则文件上的抽样（数据与安全最高优先级）"
J=apps/android/app/src/main/java/com/hawkeyexb/ppass
core_is "$PATHS" "$RULES" true "配对验证码 crate" crates/pair-pake/src/lib.rs
core_is "$PATHS" "$RULES" true "数据库迁移" crates/storage/migrations/0001_init.sql
core_is "$PATHS" "$RULES" true "钥匙串" crates/platform/src/keychain.rs
core_is "$PATHS" "$RULES" true "daemon 鉴权" crates/daemon/src/authz.rs
core_is "$PATHS" "$RULES" true "**daemon 新文件（未登记）默认是核心**" crates/daemon/src/brand_new.rs
core_is "$PATHS" "$RULES" true "**安卓 backup 新文件默认是核心**" "$J/backup/BrandNew.kt"
core_is "$PATHS" "$RULES" true "安卓 Keystore" "$J/transport/AndroidKeystoreIdentityWrapper.kt"
core_is "$PATHS" "$RULES" true "安卓脱敏（log/ 下唯一受审）" "$J/log/Redact.kt"
core_is "$PATHS" "$RULES" true "安卓 res/xml（+ 压过 -）" apps/android/app/src/main/res/xml/file_paths.xml
core_is "$PATHS" "$RULES" true "安卓清单" apps/android/app/src/main/AndroidManifest.xml
core_is "$PATHS" "$RULES" true "iOS 配对" apps/ios/PPass/Live/LivePairing.swift
core_is "$PATHS" "$RULES" true "iOS 权限声明" apps/ios/PPass/PPass.entitlements
core_is "$PATHS" "$RULES" true "桌面壳权限声明" apps/desktop/src-tauri/capabilities/default.json
core_is "$PATHS" "$RULES" true "workflow" .github/workflows/ci-rust.yml
core_is "$PATHS" "$RULES" true "核心名单自身" .github/core-paths.txt
core_is "$PATHS" "$RULES" true "判定脚本自身" tools/ci-paths.sh
core_is "$PATHS" "$RULES" true "依赖锁" Cargo.lock
core_is "$PATHS" "$RULES" true "混合：界面 + 核心" "$J/ui/HomeScreen.kt" crates/proto/src/lib.rs
core_is "$PATHS" "$RULES" false "安卓界面" "$J/ui/HomeScreen.kt"
core_is "$PATHS" "$RULES" false "安卓文案资源" apps/android/app/src/main/res/values/strings.xml
core_is "$PATHS" "$RULES" false "安卓备份开关偏好" "$J/backup/AutoBackupPrefs.kt"
core_is "$PATHS" "$RULES" false "iOS 首页" apps/ios/PPass/Home/HeroCard.swift
core_is "$PATHS" "$RULES" false "daemon 缩略图预生成" crates/daemon/src/thumb_pregen.rs
core_is "$PATHS" "$RULES" false "桌面前端" apps/desktop/src/App.svelte
core_is "$PATHS" "$RULES" false "媒体解码" crates/media-codec/src/lib.rs
core_is "$PATHS" "$RULES" false "文档" docs/runbook/full-regression-sop.md
core_is "$PATHS" "$RULES" false "issue 模板" .github/ISSUE_TEMPLATE/task-card.md

echo
echo "==> 4. core：规则语义与 fail-closed（用最小规则文件）"
R="$TMP/rules.txt"
printf '%s\n' '+ a/**' 'zone z/**' '- z/ui/**' '+ z/ui/secret.kt' >"$R"
core_is "$PATHS" "$R" true "+ 命中" a/x
core_is "$PATHS" "$R" true "zone 内未放行" z/x
core_is "$PATHS" "$R" false "zone 内被 - 放行" z/ui/x
core_is "$PATHS" "$R" true "+ 压过 -" z/ui/secret.kt
core_is "$PATHS" "$R" false "zone 外" b/x
core_is "$PATHS" "$R" true "空列表 → true" ""
core_is "$PATHS" "$TMP/missing.txt" true "规则文件不存在 → true" docs/a.md
printf '%s\n' '# 只有注释' '- z/**' >"$TMP/empty.txt"
core_is "$PATHS" "$TMP/empty.txt" true "规则里没有 + / zone → true" docs/a.md
printf '%s\n' '+ a/**' 'zoen z/**' >"$TMP/typo.txt"
core_is "$PATHS" "$TMP/typo.txt" true "规则拼错（zoen）→ true，不许静默忽略" docs/a.md

echo
echo "==> 5. gate：只有 success / skipped 能过"
gate_is "$GATE" 0 "全 success" '{"changes":{"result":"success"},"android":{"result":"success"}}'
gate_is "$GATE" 0 "按需跳过" '{"changes":{"result":"success"},"android":{"result":"skipped"}}'
gate_is "$GATE" 1 "有 failure" '{"changes":{"result":"success"},"android":{"result":"failure"}}'
gate_is "$GATE" 1 "有 cancelled" '{"changes":{"result":"success"},"android":{"result":"cancelled"}}'
gate_is "$GATE" 1 "changes 自己挂了（下游因此 skipped）" '{"changes":{"result":"failure"},"android":{"result":"skipped"}}'
gate_is "$GATE" 1 "NEEDS 为空对象" '{}'
gate_is "$GATE" 1 "NEEDS 不是 JSON" 'not json'
gate_is "$GATE" 1 "NEEDS 未设置" ''

echo
echo "==> 6. 变异反证：把脚本改坏，上面的断言必须变红"
mutant() { # mutant <源> <名> <sed 表达式> → 打印变异体路径
  local out="$TMP/$2.sh"
  sed -e "$3" "$1" >"$out"
  if cmp -s "$1" "$out"; then
    echo "变异「$2」没改到任何东西（sed 表达式失配）" >&2
    return 1
  fi
  printf '%s' "$out"
}
expect_red() { # expect_red <说明> <命令…>：命令输出 ❌ 才算变异被抓到
  local label="$1"
  shift
  if "$@" 2>/dev/null | grep -q '❌'; then ok "变异被抓到：$label"; else bad "变异没被抓到：$label"; fi
}

if M="$(mutant "$PATHS" star-crosses-slash 's@\[^/\]\*#g@.*#g@')"; then
  expect_red "* 跨 /" hit_is "$M" false "* 不跨 /" "tools/ios/e3-judge.sh" "tools/*.sh"
else bad "变异体生成失败：star-crosses-slash"; fi
if M="$(mutant "$PATHS" empty-means-false 's/保守判定：true"$/&; echo false; exit 0/')"; then
  expect_red "空列表判 false" hit_is "$M" true "空列表 → true" "" "crates/**"
else bad "变异体生成失败：empty-means-false"; fi
if M="$(mutant "$PATHS" zone-ignores-minus-order 's/matches "\$1" "\$m" \&\& return 1/:/')"; then
  expect_red "zone 不认 -" core_is "$M" "$R" false "zone 内被 - 放行" z/ui/x
else bad "变异体生成失败：zone-ignores-minus-order"; fi
if M="$(mutant "$PATHS" minus-beats-plus 's/^  for g in "\${PLUS\[@\]+"\${PLUS\[@\]}"}"; do$/  for g in; do/')"; then
  expect_red "+ 失效" core_is "$M" "$R" true "+ 压过 -" z/ui/secret.kt
else bad "变异体生成失败：minus-beats-plus"; fi
if M="$(mutant "$PATHS" typo-ignored 's/^        say "规则文件里有看不懂的行.*$/        continue/')"; then
  expect_red "拼错的规则被静默忽略" core_is "$M" "$TMP/typo.txt" true "规则拼错 → true" docs/a.md
else bad "变异体生成失败：typo-ignored"; fi
if M="$(mutant "$GATE" failure-passes 's/success | skipped)/success | skipped | failure)/')"; then
  expect_red "gate 放过 failure" gate_is "$M" 1 "有 failure" '{"a":{"result":"failure"}}'
else bad "变异体生成失败：failure-passes"; fi
# 空 NEEDS 有三层兜底（显式 error、jq -e 无输出即非零、空行落进失败分支），
# 变异要三层一起拆掉才算真改坏。
if M="$(mutant "$GATE" empty-passes 's/jq -er /jq -r /; s/if length == 0 then error("empty") else \.\[\]/.[]/; s/ end'"'"'/'"'"'/; s/^while read -r job result; do$/&\
  [ -n "$job" ] || continue/')"; then
  expect_red "gate 放过空 NEEDS" gate_is "$M" 1 "NEEDS 为空对象" '{}'
else bad "变异体生成失败：empty-passes"; fi

echo
echo "通过 ${PASS}，失败 $FAIL"
[ "$FAIL" -eq 0 ]
