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
# 本测试会在临时仓库里跑 git。在 git hook 里运行时（如 pre-push 触发 just ci），继承来的
# GIT_DIR 等仓库定位变量会盖过 -C / cd，把 add/commit 写进真仓库，所以先清掉。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX
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

# core_diff_is <脚本> <期望> <说明> <diff 文件，空串 = 不给 --diff> <文件>...（真实规则文件）
core_diff_is() {
  local script="$1" want="$2" label="$3" diff="$4" got
  shift 4
  if [ -n "$diff" ]; then
    got="$(printf '%s\n' "$@" | bash "$script" core - "$RULES" --diff "$diff" 2>/dev/null)"
  else
    got="$(printf '%s\n' "$@" | bash "$script" core - "$RULES" 2>/dev/null)"
  fi
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
hit_is "$PATHS" true "裸目录名命中其下文件（#1343）" "apps/android/app/src/x.kt" "apps/android/app"
hit_is "$PATHS" false "裸目录名不命中兄弟路径（#1343）" "apps/android/README.md" "apps/android/app"
hit_is "$PATHS" false "裸目录名按 / 分段，不按字符串前缀（#1343）" "apps/android/appx/y.kt" "apps/android/app"
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
core_is "$PATHS" "$RULES" false "daemon 新文件（未登记）不算核心：人控名单只列具体文件" crates/daemon/src/brand_new.rs
core_is "$PATHS" "$RULES" false "安卓 backup 新文件（未登记）不算核心" "$J/backup/BrandNew.kt"
core_is "$PATHS" "$RULES" true "安卓备份账本" "$J/backup/order/SqliteOrderStore.kt"
core_is "$PATHS" "$RULES" true "安卓 Keystore" "$J/transport/AndroidKeystoreIdentityWrapper.kt"
core_is "$PATHS" "$RULES" false "安卓脱敏（已移出人控）" "$J/log/Redact.kt"
core_is "$PATHS" "$RULES" true "安卓 res/xml" apps/android/app/src/main/res/xml/file_paths.xml
core_is "$PATHS" "$RULES" true "安卓清单" apps/android/app/src/main/AndroidManifest.xml
core_is "$PATHS" "$RULES" true "iOS 配对" apps/ios/PPass/Live/LivePairing.swift
core_is "$PATHS" "$RULES" true "iOS 权限声明" apps/ios/PPass/PPass.entitlements
core_is "$PATHS" "$RULES" true "桌面壳权限声明" apps/desktop/src-tauri/capabilities/default.json
core_is "$PATHS" "$RULES" false "CI workflow 归 owner 定的技术类，不走人控" .github/workflows/ci-rust.yml
core_is "$PATHS" "$RULES" true "发版 workflow（更新链）" .github/workflows/release.yml
core_is "$PATHS" "$RULES" true "核心名单自身" .github/core-paths.txt
core_is "$PATHS" "$RULES" true "服务启停：Windows 平台层（#1585）" crates/platform/src/windows.rs
core_is "$PATHS" "$RULES" true "服务启停：Windows 服务管理（#1585）" crates/platform/src/windows_service.rs
core_is "$PATHS" "$RULES" true "服务启停：macOS 平台层（#1585）" crates/platform/src/macos.rs
core_is "$PATHS" "$RULES" true "服务启停：壳的状态机（#1585）" apps/desktop/src-tauri/src/service_state.rs
core_is "$PATHS" "$RULES" false "门禁脚本归 owner 定的技术类" tools/ci-paths.sh
core_is "$PATHS" "$RULES" false "依赖锁不属于人控的五类" Cargo.lock
core_is "$PATHS" "$RULES" true "更新链脚本" tools/release/plan-builds.sh
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
echo "==> 4b. core：只改版本号不算核心（#1451）"
TC=apps/desktop/src-tauri/tauri.conf.json
# mkdiff <输出> <文件> <hunk 行>...：按 git diff / CI 拼的格式造一节 unified diff。
mkdiff() {
  local out="$1" f="$2"
  shift 2
  {
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n' "$f" "$f" "$f" "$f"
    printf '%s\n' "$@"
  } >"$out"
}
V_HUNK=('@@ -1,4 +1,4 @@' ' {' '   "productName": "P-Pass",' '-  "version": "0.10.1",' '+  "version": "0.11.0-beta.1",' '   "identifier": "x",')
EP_HUNK=('@@ -86,3 +86,3 @@' '       "endpoints": [' '-        "https://a.example/latest.json"' '+        "https://evil.example/latest.json"' '       ]')
PK_HUNK=('@@ -86,1 +86,1 @@' '-      "pubkey": "AAAA",' '+      "pubkey": "BBBB",')
mkdiff "$TMP/v.diff" "$TC" "${V_HUNK[@]}"
mkdiff "$TMP/v-ep.diff" "$TC" "${V_HUNK[@]}" "${EP_HUNK[@]}"
mkdiff "$TMP/v-pk.diff" "$TC" "${V_HUNK[@]}" "${PK_HUNK[@]}"
mkdiff "$TMP/bad-semver.diff" "$TC" '@@ -4 +4 @@' '-  "version": "0.10.1",' '+  "version": "0.11",'
mkdiff "$TMP/bad-semver-old.diff" "$TC" '@@ -4 +4 @@' '-  "version": "v0.10.1",' '+  "version": "0.11.0",'
mkdiff "$TMP/no-comma.diff" "$TC" '@@ -4 +4 @@' '-  "version": "0.10.1"' '+  "version": "0.11.0"'
mkdiff "$TMP/add-only.diff" "$TC" '@@ -4,0 +5 @@' '+  "version": "0.11.0",'
# 挪位置：行数与 @@ 头一致、缩进也是顶层，只有「不是原地替换」这一条不满足
mkdiff "$TMP/moved.diff" "$TC" '@@ -4 +3,0 @@' '-  "version": "0.10.1",' '@@ -86,0 +86 @@' '+  "version": "0.11.0",'
{ printf 'diff --git a/%s b/%s\nnew file mode 100644\n' "$TC" "$TC"; sed 1d "$TMP/v.diff"; } >"$TMP/newfile.diff"
mkdiff "$TMP/ep-only.diff" "$TC" "${EP_HUNK[@]}"
# 第二节只有头没有 hunk：改动计数仍是删 1 加 1，只有「恰好一节」能把它判回核心。
{ cat "$TMP/v.diff"; mkdiff "$TMP/hdr.diff" "$TC"; cat "$TMP/hdr.diff"; } >"$TMP/twice.diff"
printf '这不是 diff\n\x01\x02garbage\n' >"$TMP/garbage.diff"
# 嵌套对象里的 "version" 键（比如 plugins 里）原地换 SemVer：不是顶层版本号行，仍算核心（CodeRabbit #1456）
mkdiff "$TMP/nested.diff" "$TC" '@@ -88 +88 @@' '-      "version": "1.0.0",' '+      "version": "1.0.1",'
# @@ 头声明 10 行、实际只有 4 行（diff 被截断，后面可能还有 endpoint / pubkey 改动）：看不懂，算核心
mkdiff "$TMP/truncated.diff" "$TC" '@@ -1,10 +1,10 @@' ' {' '   "productName": "P-Pass",' '-  "version": "0.10.1",' '+  "version": "0.11.0",'
CR=crates/proto/src/lib.rs
mkdiff "$TMP/proto-version.diff" "$CR" '@@ -4 +4 @@' '-  "version": "0.10.1",' '+  "version": "0.11.0",'
cat "$TMP/v.diff" "$TMP/proto-version.diff" >"$TMP/v-proto.diff"

core_diff_is "$PATHS" false "tauri.conf.json 只改 version 行 → 不算核心" "$TMP/v.diff" "$TC"
core_diff_is "$PATHS" false "  version 行不带逗号也认" "$TMP/no-comma.diff" "$TC"
core_diff_is "$PATHS" false "  只改 version 行 + 非核心文件" "$TMP/v.diff" "$TC" docs/a.md
core_diff_is "$PATHS" true "  反证：同一 diff 再改 updater endpoint → 核心" "$TMP/v-ep.diff" "$TC"
core_diff_is "$PATHS" true "  反证：同一 diff 再改 updater pubkey → 核心" "$TMP/v-pk.diff" "$TC"
core_diff_is "$PATHS" true "  反证：只改 endpoint 一行（删一加一，但不是版本号行）→ 核心" "$TMP/ep-only.diff" "$TC"
core_diff_is "$PATHS" true "  反证：新版本号不是 SemVer → 核心" "$TMP/bad-semver.diff" "$TC"
core_diff_is "$PATHS" true "  反证：旧版本号不是 SemVer → 核心" "$TMP/bad-semver-old.diff" "$TC"
core_diff_is "$PATHS" true "  反证：只加不删 version 行 → 核心" "$TMP/add-only.diff" "$TC"
core_diff_is "$PATHS" true "  反证：version 行挪了位置（不是原地替换）→ 核心" "$TMP/moved.diff" "$TC"
core_diff_is "$PATHS" true "  反证：新增文件 → 核心" "$TMP/newfile.diff" "$TC"
core_diff_is "$PATHS" true "  反证：同一文件 diff 里出现两节 → 核心" "$TMP/twice.diff" "$TC"
core_diff_is "$PATHS" true "  反证：嵌套对象里的 version 键换值 → 核心（只认顶层那一行）" "$TMP/nested.diff" "$TC"
core_diff_is "$PATHS" true "  反证：hunk 行数与 @@ 头不符（截断的 diff）→ 核心" "$TMP/truncated.diff" "$TC"
core_diff_is "$PATHS" true "  反证：不给 diff → 核心" "" "$TC"
core_diff_is "$PATHS" true "  反证：diff 文件不存在 → 核心" "$TMP/missing.diff" "$TC"
core_diff_is "$PATHS" true "  反证：diff 是乱码 → 核心" "$TMP/garbage.diff" "$TC"
core_diff_is "$PATHS" true "  反证：diff 里没有这个文件的节 → 核心" "$TMP/proto-version.diff" "$TC"
core_diff_is "$PATHS" true "  反证：白名单外的核心文件只改了形如 version 的行 → 核心" "$TMP/proto-version.diff" "$CR"
core_diff_is "$PATHS" true "  反证：version 例外 + 另一个核心文件 → 核心" "$TMP/v-proto.diff" "$TC" "$CR"
got="$(printf '%s\n' "$TC" | bash "$PATHS" core - --diff "$TMP/v.diff" "$RULES" 2>/dev/null)"
[ "$got" = false ] && ok "--diff 写在规则文件前面也认 → $got" || bad "--diff 在规则文件前 → 期望 false，实得 $got"
got="$(printf '%s\n' "$TC" | bash "$PATHS" core - "$RULES" --diff 2>/dev/null)"
[ "$got" = true ] && ok "--diff 后面没给文件 → $got" || bad "--diff 没给文件 → 期望 true，实得 $got"

# base 是真实 sha、不给 --diff：脚本自己取 git diff <base>...HEAD。
G="$TMP/git"
mkdir -p "$G/apps/desktop/src-tauri"
printf '{\n  "productName": "P-Pass",\n  "version": "0.10.1",\n  "plugins": {\n    "updater": {\n      "pubkey": "AAAA",\n      "endpoints": ["https://a.example/latest.json"]\n    }\n  }\n}\n' >"$G/$TC"
git_core() { # git_core <期望> <说明> <sed 表达式>：在临时仓库里改 tauri.conf.json 提交，按 base sha 判
  local want="$1" label="$2" base got
  git -C "$G" checkout -q -f --detach "$G_BASE"
  sed -e "$3" "$G/$TC" >"$G/tc.tmp" && mv "$G/tc.tmp" "$G/$TC"
  git -C "$G" -c user.name=t -c user.email=t@invalid commit -q -am "$label"
  base="$G_BASE"
  got="$(cd "$G" && bash "$PATHS" core "$base" "$RULES" 2>/dev/null)"
  [ "$got" = "$want" ] && ok "$label → $got" || bad "$label → 期望 ${want}，实得 $got"
}
if git -C "$G" init -q --template= 2>/dev/null &&
  git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@invalid commit -q -m base; then
  G_BASE="$(git -C "$G" rev-parse HEAD)"
  git_core false "base sha 模式：只改 version 行 → 不算核心" 's/"0\.10\.1"/"0.11.0"/'
  git_core true "  反证：base sha 模式再改 endpoint → 核心" 's/"0\.10\.1"/"0.11.0"/; s#a\.example#evil.example#'
else
  bad "临时 git 仓库建不起来"
fi

# #1467：改名的旧路径也算改动——把安卓文件挪出 apps/android，android lane 仍要命中。
GR="$TMP/rename"
rename_hit() { # rename_hit <脚本>：临时仓库里把 apps/android/x.kt 挪到 other/x.kt，按 base 判 hit
  rm -rf "$GR" && mkdir -p "$GR/apps/android" && seq 1 50 >"$GR/apps/android/x.kt" &&
    git -C "$GR" init -q --template= &&
    git -C "$GR" add -A && git -C "$GR" -c user.name=t -c user.email=t@invalid commit -q -m base &&
    local b && b="$(git -C "$GR" rev-parse HEAD)" &&
    mkdir -p "$GR/other" && git -C "$GR" mv apps/android/x.kt other/x.kt &&
    git -C "$GR" -c user.name=t -c user.email=t@invalid commit -q -m mv &&
    (cd "$GR" && bash "$1" hit "$b" 'apps/android/**' 2>/dev/null)
}
got="$(rename_hit "$PATHS")"
[ "$got" = true ] && ok "base sha 模式：改名把文件挪出 apps/android → $got" || bad "改名挪出 apps/android → 期望 true，实得 $got"

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
if M="$(mutant "$PATHS" bare-dir-exact-only 's/^    \*) printf .*$/    *) glob_re "$g" ;;/')"; then
  expect_red "裸目录名回到整串精确匹配" hit_is "$M" true "裸目录名命中其下文件（#1343）" "apps/android/app/src/x.kt" "apps/android/app"
else bad "变异体生成失败：bare-dir-exact-only"; fi
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
# 正向也要有反证：例外逻辑整个拿掉，「只改 version 行 → false」必须变红（否则那条是恒真式）。
if M="$(mutant "$PATHS" no-version-exception 's/if \[ -n "\$DIFF_FILE" \] && version_only "\$f"; then/if false; then/')"; then
  expect_red "去掉只改版本号例外" core_diff_is "$M" false "只改 version 行 → false" "$TMP/v.diff" "$TC"
else bad "变异体生成失败：no-version-exception"; fi
if M="$(mutant "$PATHS" semver-any 's/^SEMVER_RE=.*$/SEMVER_RE=".*"/')"; then
  expect_red "SemVer 不校验" core_diff_is "$M" true "新版本号不是 SemVer → 核心" "$TMP/bad-semver.diff" "$TC"
else bad "变异体生成失败：semver-any"; fi
if M="$(mutant "$PATHS" version-any-line 's/^      printf .%s. .\^  "version".*$/      printf "%s" ".*"/')"; then
  expect_red "白名单放过任意行" core_diff_is "$M" true "只改 endpoint 一行 → 核心" "$TMP/ep-only.diff" "$TC"
else bad "变异体生成失败：version-any-line"; fi
if M="$(mutant "$PATHS" version-any-indent 's/\^  "version"/^[[:space:]]*"version"/')"; then
  expect_red "不限顶层缩进" core_diff_is "$M" true "嵌套 version 键 → 核心" "$TMP/nested.diff" "$TC"
else bad "变异体生成失败：version-any-indent"; fi
if M="$(mutant "$PATHS" no-hunk-count 's/^    \[ "\$want_old" -lt 0 \] && return 0$/    return 0/')"; then
  expect_red "不核对 hunk 行数" core_diff_is "$M" true "截断的 diff → 核心" "$TMP/truncated.diff" "$TC"
else bad "变异体生成失败：no-hunk-count"; fi
if M="$(mutant "$PATHS" no-inplace-check 's/\[ "\$prev" = minus \] ||/true ||/')"; then
  expect_red "不查原地替换" core_diff_is "$M" true "version 行挪了位置 → 核心" "$TMP/moved.diff" "$TC"
else bad "变异体生成失败：no-inplace-check"; fi
if M="$(mutant "$PATHS" multi-section-ok 's/\[ "\$n" -eq 1 \] ||/[ "$n" -ge 1 ] ||/')"; then
  expect_red "一个文件多节也认" core_diff_is "$M" true "两节 → 核心" "$TMP/twice.diff" "$TC"
else bad "变异体生成失败：multi-section-ok"; fi
if M="$(mutant "$GATE" failure-passes 's/success | skipped)/success | skipped | failure)/')"; then
  expect_red "gate 放过 failure" gate_is "$M" 1 "有 failure" '{"a":{"result":"failure"}}'
else bad "变异体生成失败：failure-passes"; fi
# 空 NEEDS 有三层兜底（显式 error、jq -e 无输出即非零、空行落进失败分支），
# 变异要三层一起拆掉才算真改坏。
if M="$(mutant "$GATE" empty-passes 's/jq -er /jq -r /; s/if length == 0 then error("empty") else \.\[\]/.[]/; s/ end'"'"'/'"'"'/; s/^while read -r job result; do$/&\
  [ -n "$job" ] || continue/')"; then
  expect_red "gate 放过空 NEEDS" gate_is "$M" 1 "NEEDS 为空对象" '{}'
else bad "变异体生成失败：empty-passes"; fi

if M="$(mutant "$PATHS" renames-hidden 's/git diff --no-renames --name-only/git diff --name-only/')"; then
  got="$(rename_hit "$M")"
  [ "$got" = false ] && ok "变异被抓到：去掉 --no-renames 后改名判 $got" || bad "变异没被抓到：去掉 --no-renames 后改名仍判 $got"
else bad "变异体生成失败：renames-hidden"; fi

echo
echo "通过 ${PASS}，失败 $FAIL"
[ "$FAIL" -eq 0 ]
