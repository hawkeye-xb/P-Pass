#!/usr/bin/env bash
# owner 流程脚本（tools/flow/owner-*.sh）的判据测试。
#
# 每个场景在全新的临时仓库里跑（裸仓库当 origin + 一个克隆），gh / just / cargo 用 PATH 注入的桩：
# 假 gh 把 issue、标签、PR、检查结果存在 $FAKE 目录的文件里，并把每次调用记到 $FAKE/calls.log，
# 断言看「有没有出现 pr create / pr merge / 推 tag」这类副作用。
# 每条拒绝都配一条只去掉触发条件的放行用例作反证。
#
# 用法: tools/test-flow-owner.sh
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { # check <描述> <命令...>
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# 与本机配置隔离：本机全局 git 配置可能带私有 hook、身份白名单、模板目录。
export HOME="${TMP}/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
mkdir -p "$HOME" "${TMP}/tpl"
export GIT_TEMPLATE_DIR="${TMP}/tpl"
git config --global user.name "Flow Test"
git config --global user.email "flow-test@example.invalid"
git config --global init.defaultBranch main
git config --global advice.detachedHead false
export PPASS_OWNER_REPO="t/r"
export PPASS_OWNER_TODAY="2026-11-02"
export PPASS_HEAVY_LOCK="${TMP}/heavy.lock"
export PPASS_OWNER_CHECK_GRACE=0
export PPASS_OWNER_CHECK_TIMEOUT=60
export PPASS_OWNER_ENV="${TMP}/no-owner.env"
export PPASS_OWNER_RUN_WAIT=0
export PPASS_OWNER_MAIN_CI_WAIT=0
export PPASS_OWNER_MAIN_CI_EMPTY_WAIT=0
unset PPASS_OWNER_STATE_DIR PPASS_OWNER_JUST PPASS_HOOK_BYPASS

# ── 桩 ──────────────────────────────────────────────────────────────
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# 假 gh：只认 owner 脚本用到的调用形状，输出按脚本里 --jq 的结果格式直接给。
printf '%s\n' "$*" >>"$FAKE/calls.log"
I="$FAKE/issues"
arg() { # arg <选项名>：取该选项后面的值
  local want="$1" prev=""
  for a in "${ARGS[@]}"; do [ "$prev" = "$want" ] && { printf '%s' "$a"; return; }; prev="$a"; done
}
ARGS=("$@")
json="$(arg --json)"
case "$1 $2" in
  "label list") cat "$FAKE/labels" ;;
  "issue list")
    case "$(arg --label)" in
      status:review) for f in "$I"/*.labels; do grep -q 'status:review' "$f" && basename "$f" .labels; done ;;
      *) : ;;
    esac
    ;;
  "issue view")
    n="$3"
    [ -f "$I/$n.body" ] || { echo "no issue $n" >&2; exit 1; }
    case "$json" in
      state) cat "$I/$n.state" 2>/dev/null || echo OPEN ;;
      *)
        printf 'title:%s\nstate:%s\nlabels:%s\n' "$(cat "$I/$n.title")" "$(cat "$I/$n.state" 2>/dev/null || echo OPEN)" "$(cat "$I/$n.labels")"
        cat "$I/$n.body"
        ;;
    esac
    ;;
  "issue edit")
    n="$3"
    bf="$(arg --body-file)"
    [ -z "$bf" ] || cp "$bf" "$I/$n.body"
    add="$(arg --add-label)"
    rm="$(arg --remove-label)"
    cur="$(cat "$I/$n.labels")"
    new=""
    for l in $(printf '%s' "$cur" | tr ',' ' '); do
      case ",$rm," in *",$l,"*) continue ;; esac
      new="${new:+$new,}$l"
    done
    for l in $(printf '%s' "$add" | tr ',' ' '); do
      case ",$new," in *",$l,"*) ;; *) new="${new:+$new,}$l" ;; esac
    done
    printf '%s' "$new" >"$I/$n.labels"
    ;;
  "issue comment") cat "$(arg --body-file)" >>"$I/$3.comments" ;;
  "issue create")
    cp "$(arg --body-file)" "$FAKE/created-issue.md"
    printf '%s\n' "$(arg --title)" >>"$FAKE/created-titles"
    echo "https://github.com/t/r/issues/999"
    ;;
  "pr list") : ;;
  "pr create")
    cp "$(arg --body-file)" "$FAKE/pr-body.md"
    arg --head >"$FAKE/pr-head-branch"
    echo "https://github.com/t/r/pull/77"
    ;;
  "pr checks")
    case " $* " in *" --watch "*) exit 0 ;; esac
    cat "$FAKE/checks.json"
    ;;
  "pr view")
    case "$json" in
      state) [ -e "$FAKE/merged" ] && echo MERGED || echo OPEN ;;
      *) printf '%s CLEAN\n' "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$(cat "$FAKE/pr-head-branch")")" ;;
    esac
    ;;
  "pr merge") touch "$FAKE/merged" ;;
  "pr comment") cat "$(arg --body-file)" >>"$FAKE/pr.comments" ;;
  "pr edit") : ;;
  "run list") cat "$FAKE/run-id" 2>/dev/null ;;
  "run watch") exit 0 ;;
  "run view")
    case "$json" in
      conclusion) cat "$FAKE/run-conclusion" ;;
      *) echo "build-android: boom" ;;
    esac
    ;;
  "api graphql")
    case "$*" in
      *createDiscussion*) echo 5 ;;
      *addDiscussionComment*) echo '{}' ;;
      *updateIssue*) echo '{}' ;;
      *issueTypes*) echo "I_999 IT_feature" ;;
      *discussionCategories*) echo "R_1 DC_ideas" ;;
      *discussions\(*) : ;;
      *) echo "stub gh graphql: unsupported $*" >&2; exit 2 ;;
    esac
    ;;
  "api "*)
    case "$2" in
      */commits/*/check-runs*) cat "$FAKE/main-ci" 2>/dev/null || echo "completed success CI Rust gate" ;;
      */commits/*/status) echo "success 0" ;;
      */workflows/ci-core-review.yml/runs*) echo "123 waiting" ;;
      */actions/runs/123/pending_deployments) echo 9 ;;
      -X) echo '{}' ;;
      *) echo "stub gh api: unsupported $*" >&2; exit 2 ;;
    esac
    ;;
  "release download") printf '{"version":"%s"}\n' "$(cat "$FAKE/channel-version")" ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
cat >"${TMP}/bin/just" <<'STUB'
#!/usr/bin/env bash
printf 'just %s\n' "$*" >>"$FAKE/calls.log"
case "$1" in
  --summary) echo "ci batch-plan" ;;
  ci) [ -e "$FAKE/ci-fail" ] && { echo "clippy: error"; exit 101; }; echo "==> CI pipeline: all green" ;;
  *) echo "stub just: unsupported $*" >&2; exit 2 ;;
esac
STUB
cat >"${TMP}/bin/cargo" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "${TMP}/bin/"*
export PATH="${TMP}/bin:${PATH}"

# ── 每个场景一套全新的仓库 ────────────────────────────────────────────
N_SCEN=0
fresh() {
  N_SCEN=$((N_SCEN + 1))
  S="${TMP}/s${N_SCEN}"
  export FAKE="${S}/fake" ORIGIN="${S}/origin.git"
  export PPASS_OWNER_WT_ROOT="${S}/wt"
  mkdir -p "$FAKE/issues"
  # CI 对照表换成夹具：一步本机检查（$FAKE/map-fail 存在就红）+ 一条只能 CI，没有 Windows 步骤。
  export PPASS_CI_LOCAL_MAP="${FAKE}/ci-local-map.tsv"
  printf 'ci-x.yml\tchk\tmac\talways\tfake-check\t[ ! -e "$FAKE/map-fail" ]\nci-x.yml\tlinux\tci-only\t-\tlinux\t只有 Linux runner\n' >"$PPASS_CI_LOCAL_MAP"
  printf '%s\n' status:inbox status:ready status:doing status:review status:batched status:blocked needs:product core >"$FAKE/labels"
  : >"$FAKE/calls.log"
  git init -q --bare "$ORIGIN"
  R="${S}/repo"
  git init -q "$R"
  cd "$R" || exit 1
  git remote add origin "$ORIGIN"
  mkdir -p tools/flow tools/release .github docs/decisions src crates/storage release
  cp "${SRC}/tools/flow/"* tools/flow/
  cp "${SRC}/tools/ci-paths.sh" "${SRC}/tools/check-dco.sh" "${SRC}/tools/heavy-lock" tools/
  cp "${SRC}/tools/release/with-timeout.sh" tools/release/
  cp "${SRC}/.github/core-paths.txt" .github/
  cat >tools/release/plan-builds.sh <<'PB'
#!/usr/bin/env bash
cat "$FAKE/plan"
PB
  printf '#!/usr/bin/env bash\n[ -e "$FAKE/dummy-fail" ] && { echo dummy red; exit 1; }\necho dummy ok\n' >tools/test-dummy.sh
  printf '# A\n\n- 状态：已采纳\n' >docs/decisions/2026-11-01-adopted.md
  printf '# P\n\n- 状态：提议\n' >docs/decisions/2026-11-01-proposed.md
  printf '{"desktop": "0.10.1", "android": "0.10.2", "ios": "0.10.2"}\n' >release/versions.json
  printf 'line1\nline2\nline3\n' >src/x.txt
  printf 'b\n' >docs/b.md
  printf 'c\n' >docs/c.md
  printf 's\n' >crates/storage/s.rs
  git add -A
  git commit -q -s -m init
  git push -q origin HEAD:refs/heads/main
  git fetch -q origin
}

# card <号> <标签> <范围 glob> <正文附加> <文件> <内容>：造 issue + 推一条卡分支（基于 origin/main）
card() {
  local n="$1" labels="$2" scope="$3" extra="$4" file="$5" content="$6"
  printf '卡 %s' "$n" >"$FAKE/issues/$n.title"
  printf '%s' "$labels" >"$FAKE/issues/$n.labels"
  printf '**范围（只许动这些）**：\n```\n%s\n```\n\n%s\n' "$scope" "$extra" >"$FAKE/issues/$n.body"
  git checkout -q -b "fix/${n}-c" origin/main
  mkdir -p "$(dirname "$file")"
  printf '%s' "$content" >"$file"
  git add -A
  git commit -q -s -m "card ${n}"
  git push -q origin "HEAD:refs/heads/fix/${n}-c"
  git checkout -q --detach origin/main
  git branch -q -D "fix/${n}-c"
  git fetch -q origin
}
labels_of() { cat "$FAKE/issues/$1.labels"; }
has_call() { grep -q -- "$1" "$FAKE/calls.log"; }
plan_line_has() { # plan_line_has <输出> <号> <号>：两张卡在同一 PLAN BATCH 行
  printf '%s\n' "$1" | grep '^PLAN BATCH ' | grep -E "( |^)$2( |$)" | grep -qE "( |^)$3( |$)"
}

# ═════════════════════════════════════════════════════════════════════
echo "── 1. batch-plan：同文件 / 冲突的卡不进同一批"
fresh
card 11 status:review "src/**" "" src/x.txt $'line1\nCHANGED-A\nline3\n'
card 12 status:review "src/**" "" src/x.txt $'line1\nCHANGED-B\nline3\n'
card 13 status:review "docs/b.md" "" docs/b.md $'b2\n'
out="$(bash tools/flow/owner-batch-plan.sh --dry-run 2>/dev/null)"
check "#11 与 #12 改同一行 → 不同批" bash -c '! printf "%s\n" "$1" | grep "^PLAN BATCH " | grep -E "(^| )11( |$)" | grep -qE "(^| )12( |$)"' _ "$out"
check "反证：#11 与 #13 不相干 → 同一批" plan_line_has "$out" 11 13
check "--dry-run 不改任何 issue" bash -c '! grep -q "issue edit" "$FAKE/calls.log"'
grep -v '^status:review$' "$FAKE/labels" >"$FAKE/labels.new" && mv "$FAKE/labels.new" "$FAKE/labels"
bash tools/flow/owner-batch-plan.sh --dry-run >/dev/null 2>&1
rc=$?
check "没有 status:review 标签 → 停下（退出码 1）" test "$rc" -eq 1
check "--dry-run 停下时也不写 GitHub" bash -c '! grep -q "^issue create" "$FAKE/calls.log"'
bash tools/flow/owner-batch-plan.sh >/dev/null 2>&1
check "反证：非预演停下时开 issue" grep -q "^issue create" "$FAKE/calls.log"

echo "── 2. batch-plan：核心卡没有「已采纳」ADR → 排除并打回 status:blocked"
fresh
card 14 "status:review,core" "crates/storage/**" "无定案" crates/storage/s.rs $'s2\n'
card 15 "status:review,core" "crates/storage/**" "定案见 docs/decisions/2026-11-01-proposed.md" crates/storage/s.rs $'s3\n'
card 16 "status:review,core" "crates/storage/**" "定案见 docs/decisions/2026-11-01-adopted.md" crates/storage/s.rs $'s4\n'
card 17 status:review "crates/storage/**" "定案见 docs/decisions/2026-11-01-adopted.md" crates/storage/s.rs $'s5\n'
card 18 status:review "docs/b.md" "" docs/c.md $'c2\n'
out="$(bash tools/flow/owner-batch-plan.sh 2>/dev/null)"
check "#14 核心无 ADR → EXCLUDE" bash -c 'printf "%s\n" "$1" | grep -q "^PLAN EXCLUDE 14 "' _ "$out"
check "#14 被打回 status:blocked（不再是 status:review）" bash -c '[ "$(cat "$FAKE/issues/14.labels")" = "core,status:blocked" ]'
check "#14 有说明原因的评论" grep -q "已采纳" "$FAKE/issues/14.comments"
check "#15 引用的 ADR 只是「提议」→ EXCLUDE" bash -c 'printf "%s\n" "$1" | grep -q "^PLAN EXCLUDE 15 "' _ "$out"
check "#17 命中核心但没有 core 标签 → EXCLUDE" bash -c 'printf "%s\n" "$1" | grep -q "^PLAN EXCLUDE 17 .*core 标签"' _ "$out"
check "#18 改了范围外的文件 → EXCLUDE" bash -c 'printf "%s\n" "$1" | grep -q "^PLAN EXCLUDE 18 .*范围"' _ "$out"
check "反证：#16 引用已采纳 ADR → 进批次" bash -c 'printf "%s\n" "$1" | grep -q "^PLAN BATCH 1 16$"' _ "$out"
check "反证：#16 标签不动" bash -c '[ "$(cat "$FAKE/issues/16.labels")" = "status:review,core" ]'

echo "── 3. batch-open：不能同批的卡拒绝合批；能同批的逐张合入"
fresh
card 21 status:review "src/**" "" src/x.txt $'line1\nA\nline3\n'
card 22 status:review "src/**" "" src/x.txt $'line1\nB\nline3\n'
card 23 status:review "assets/**" "" assets/a.txt $'a\n'
bash tools/flow/owner-batch-open.sh conflict 21 22 >/dev/null 2>&1
rc=$?
check "冲突的 #21 #22 → 拒绝（退出码 2）" test "$rc" -eq 2
check "拒绝时不建批次分支、不建 worktree" bash -c '! git show-ref --quiet refs/heads/batch/2026-11-02-conflict && [ ! -e "$PPASS_OWNER_WT_ROOT/batch-2026-11-02-conflict" ]'
check "拒绝时卡标签不动" bash -c '[ "$(cat "$FAKE/issues/21.labels")" = status:review ]'
out="$(bash tools/flow/owner-batch-open.sh ok 21 23 2>/dev/null)"
check "反证：#21 #23 → BATCH-OPEN OK" bash -c 'printf "%s\n" "$1" | grep -q "^BATCH-OPEN OK batch/2026-11-02-ok 21 23$"' _ "$out"
W="${PPASS_OWNER_WT_ROOT}/batch-2026-11-02-ok"
check "两张卡都合进来了，合并提交带 Signed-off-by" bash -c '[ "$(git -C "$1" log --merges --format=%B origin/main..HEAD | grep -c "^Signed-off-by: Flow Test")" -eq 2 ]' _ "$W"
check "卡状态 → status:batched" bash -c '[ "$(cat "$FAKE/issues/21.labels")" = status:batched ] && [ "$(cat "$FAKE/issues/23.labels")" = status:batched ]'
bash tools/flow/owner-batch-open.sh ok 22 >/dev/null 2>&1
check "同名批次分支不复用（退出码 2）" test "$?" -eq 2

echo "── 4. batch-verify 红 → 停下写 issue，batch-pr 不开 PR"
cd "$W" || exit 1
touch "$FAKE/ci-fail"
bash tools/flow/owner-batch-verify.sh >/dev/null 2>&1
check "just ci 红 → batch-verify 非 0" test "$?" -ne 0
check "停下时开了 status:blocked issue" bash -c 'grep -q "^issue create .*status:blocked" "$FAKE/calls.log" && grep -q "just ci" "$FAKE/created-titles"'
bash tools/flow/owner-batch-pr.sh >/dev/null 2>&1
check "batch-pr 拒绝（退出码 2）" test "$?" -eq 2
check "没有开 PR、没有推批次分支" bash -c '! grep -q "^pr create" "$FAKE/calls.log" && ! git --git-dir="$ORIGIN" show-ref --quiet refs/heads/batch/2026-11-02-ok'
rm -f "$FAKE/ci-fail"
touch "$FAKE/dummy-fail"
bash tools/flow/owner-batch-verify.sh >/dev/null 2>&1
check "tools/test-*.sh 红 → batch-verify 非 0" test "$?" -ne 0
rm -f "$FAKE/dummy-fail"
touch "$FAKE/map-fail"
bash tools/flow/owner-batch-verify.sh >/dev/null 2>&1
check "CI 对照表本机步骤红 → batch-verify 非 0" test "$?" -ne 0
check "停下的 issue 点名对照表里红的那步" grep -q "CI 对照表 ci-x.yml:chk/fake-check" "$FAKE/created-issue.md"
rm -f "$FAKE/map-fail"
out="$(bash tools/flow/owner-batch-verify.sh 2>/dev/null)"
check "反证：全绿 → BATCH-VERIFY PASS <HEAD>" bash -c 'printf "%s\n" "$1" | grep -q "^BATCH-VERIFY PASS $(git rev-parse HEAD)$"' _ "$out"
RPT="$(git rev-parse --git-common-dir)/ppass-batch/batch_2026-11-02-ok/verify-$(git rev-parse --short=12 HEAD)/report.md"
check "报告逐步列出对照表步骤结果" grep -q "^| ci-x.yml:chk/fake-check | PASS |" "$RPT"
check "报告列出「只能 CI」项" bash -c 'grep -q "^## 只能 CI" "$1" && grep -q "^- ci-x.yml:linux/linux：只有 Linux runner" "$1"' _ "$RPT"
check "对照表没有 Windows 步骤 → Windows 不算未覆盖" bash -c '! grep -q "^- windows" "$1"' _ "$RPT"
check "报告记下未覆盖的端（无场景库）" bash -c 'grep -q "^- mac：场景库" "$(git rev-parse --git-common-dir)/ppass-batch/batch_2026-11-02-ok/verify-$(git rev-parse --short=12 HEAD)/report.md"'

echo "── 5. batch-pr：验证后加提交拒绝；CI 红写评论不合入；CI 绿合入"
printf 'x\n' >extra.txt
git add extra.txt
git commit -q -s -m extra
bash "$W/tools/flow/owner-batch-pr.sh" >/dev/null 2>&1
check "验证后又加了提交 → batch-pr 拒绝（退出码 2）" test "$?" -eq 2
git reset -q --hard HEAD~1
printf '[{"name":"clippy","bucket":"fail","link":"https://github.com/t/r/actions/runs/5/job/6","workflow":"CI Rust"},{"name":"fmt","bucket":"pass","link":"","workflow":"CI Rust"}]' >"$FAKE/checks.json"
bash tools/flow/owner-batch-pr.sh >/dev/null 2>&1
check "CI 红 → batch-pr 非 0" test "$?" -ne 0
check "开了 PR，正文逐卡 closes 并带验证证据与未覆盖项" bash -c 'grep -q "^- closes #21 " "$FAKE/pr-body.md" && grep -q "^- closes #23 " "$FAKE/pr-body.md" && grep -q "^BATCH-VERIFY PASS " "$FAKE/pr-body.md" && grep -q "^## 未覆盖项" "$FAKE/pr-body.md"'
check "PR 正文带上「只能 CI」项" grep -q "ci-x.yml:linux/linux" "$FAKE/pr-body.md"
check "失败 job 与日志切片写进 PR 评论" bash -c 'grep -q "clippy" "$FAKE/pr.comments" && grep -q "boom" "$FAKE/pr.comments"'
check "CI 红时没有合入" bash -c '! grep -q "^pr merge" "$FAKE/calls.log"'
printf '[{"name":"clippy","bucket":"pass","link":"","workflow":"CI Rust"},{"name":"ios","bucket":"skipping","link":"","workflow":"CI iOS"}]' >"$FAKE/checks.json"
out="$(bash tools/flow/owner-batch-pr.sh 2>/dev/null)"
check "反证：CI 绿 → 合入" bash -c 'printf "%s\n" "$1" | grep -q "^BATCH-PR MERGED #77 "' _ "$out"
check "合入用 squash 并钉住已验证的提交" grep -q "^pr merge 77 -R t/r --squash --match-head-commit $(git rev-parse HEAD)$" "$FAKE/calls.log"
check "第二次跑没有重复开 PR" test "$(grep -c '^pr create' "$FAKE/calls.log")" -eq 1

echo "── 5b. batch-pr 代批 core review：核心卡有已采纳 ADR 才批；卡外提交碰核心就停"
fresh
card 31 "status:review,core" "crates/storage/**" "定案见 docs/decisions/2026-11-01-adopted.md" crates/storage/s.rs $'s9\n'
card 32 "status:review,needs:product" "docs/b.md" "" docs/b.md $'b9\n'
out="$(bash tools/flow/owner-batch-plan.sh --dry-run 2>/dev/null)"
check "带 needs:product 的卡不进批次" bash -c 'printf "%s\n" "$1" | grep -q "^PLAN EXCLUDE 32 .*needs:product"' _ "$out"
bash tools/flow/owner-batch-open.sh core 31 >/dev/null 2>&1
W="${PPASS_OWNER_WT_ROOT}/batch-2026-11-02-core"
cd "$W" || exit 1
printf 's10\n' >crates/storage/s.rs
git commit -q -s -am "owner 手修核心"
bash tools/flow/owner-batch-verify.sh >/dev/null 2>&1
printf '[{"name":"core review (owner approval)","bucket":"pass","link":"","workflow":"CI Core review"}]' >"$FAKE/checks.json"
bash tools/flow/owner-batch-pr.sh >/dev/null 2>&1
rc=$?
check "卡外提交改了核心文件 → batch-pr 停下" test "$rc" -eq 1
check "停下时没有推送、没有批 core review" bash -c '! grep -q "^api -X POST" "$FAKE/calls.log" && ! grep -q "^pr create" "$FAKE/calls.log"'
git reset -q --hard HEAD~1
bash tools/flow/owner-batch-verify.sh >/dev/null 2>&1
out="$(bash tools/flow/owner-batch-pr.sh 2>/dev/null)"
check "反证：只有核心卡自己的改动 → 批准 core review 并合入" bash -c 'grep -q "^api -X POST repos/t/r/actions/runs/123/pending_deployments -F environment_ids\[\]=9 -f state=approved -f comment=.*2026-11-01-adopted.md" "$FAKE/calls.log" && printf "%s\n" "$1" | grep -q "^BATCH-PR MERGED "' _ "$out"
check "PR 正文写明核心定案，不带 agent 归属行" bash -c 'grep -q "^- docs/decisions/2026-11-01-adopted.md" "$FAKE/pr-body.md" && ! grep -qi "generated with" "$FAKE/pr-body.md"'

echo "── 6. release-test：正式版一律拒绝；端与判定不符拒绝；test tag 正常打"
fresh
git push -q origin "$(git rev-parse HEAD):refs/tags/v0.10.3-test.2"
printf 'android=build\nmacos=skip\nwindows=skip\nios=skip\n' >"$FAKE/plan"
out="$(bash tools/flow/owner-release-test.sh --dry-run android 2>/dev/null)"
check "--dry-run → 算出 v0.10.3-test.3，不推 tag" bash -c 'printf "%s\n" "$1" | grep -q "^RELEASE-TEST DRY-RUN v0.10.3-test.3 android$" && [ "$(git ls-remote --tags origin | wc -l | tr -d " ")" -eq 1 ]' _ "$out"
for a in v1.0.0 0.11.0 --formal stable publish; do
  bash tools/flow/owner-release-test.sh "$a" android >/dev/null 2>&1
  rc=$?
  check "「${a}」→ 拒绝（退出码 2）" test "$rc" -eq 2
done
bash tools/flow/owner-release-test.sh macos >/dev/null 2>&1
check "端与 plan-builds 判定不符 → 拒绝" test "$?" -eq 2
check "以上都没有推任何新 tag" test "$(git ls-remote --tags origin | wc -l | tr -d ' ')" -eq 1
printf 'completed success CI Rust gate\ncompleted failure CI Android\n' >"$FAKE/main-ci"
bash tools/flow/owner-release-test.sh android >/dev/null 2>&1
rc=$?
check "origin/main 的 CI 有红 → 停下，不打 tag" bash -c '[ "$1" -eq 1 ] && [ "$(git ls-remote --tags origin | wc -l | tr -d " ")" -eq 1 ]' _ "$rc"
printf 'completed success CI Rust gate\nin_progress - CI Android\n' >"$FAKE/main-ci"
bash tools/flow/owner-release-test.sh android >/dev/null 2>&1
rc=$?
check "origin/main 的 CI 还在跑且超过等待上限 → 停下，不打 tag" bash -c '[ "$1" -eq 1 ] && [ "$(git ls-remote --tags origin | wc -l | tr -d " ")" -eq 1 ]' _ "$rc"
printf 'completed success CI Rust gate\ncompleted skipped CI Android\n' >"$FAKE/main-ci"
echo 4242 >"$FAKE/run-id"
echo failure >"$FAKE/run-conclusion"
bash tools/flow/owner-release-test.sh android >/dev/null 2>&1
rc=$?
check "Release 红 → 非 0 并开 issue" bash -c '[ "$1" -ne 0 ] && grep -q "Release v0.10.3-test.3" "$FAKE/created-titles"' _ "$rc"
echo success >"$FAKE/run-conclusion"
echo "0.10.3-test.4" >"$FAKE/channel-version"
out="$(bash tools/flow/owner-release-test.sh android 2>/dev/null)"
check "反证：test tag → v0.10.3-test.4 已推送（失败的 test.3 保留不动）" bash -c 'printf "%s\n" "$1" | grep -q "^RELEASE-TEST OK v0.10.3-test.4 android$" && git ls-remote --tags origin | grep -q "refs/tags/v0.10.3-test.3$"' _ "$out"
printf '{"desktop": "0.10.1", "android": "0.10.3", "ios": "0.10.2"}\n' >release/versions.json
git commit -q -s -am bump
git push -q origin HEAD:refs/heads/main
bash tools/flow/owner-release-test.sh android >/dev/null 2>&1
check "test 版本不高于正式版本线 → 拒绝" test "$?" -eq 2

echo "── 7. owner-stuck：产品取向必须给两个选项"
fresh
bash tools/flow/owner-stuck.sh "要不要保留旧照片" --product "保留" >/dev/null 2>&1
check "只给一个选项 → 拒绝（退出码 2）" test "$?" -eq 2
check "拒绝时没写 GitHub" bash -c '! grep -q "^issue create" "$FAKE/calls.log"'
bash tools/flow/owner-stuck.sh "要不要保留旧照片" --product "保留，占盘翻倍" "删除，省空间" >/dev/null 2>&1
check "反证：两个选项 → 开 issue，打 status:blocked 与 needs:product" bash -c 'grep -q "^issue create .*--label status:blocked,needs:product" "$FAKE/calls.log" && grep -q "^2. 删除，省空间" "$FAKE/created-issue.md"'

echo "── 8. idea：默认记进 Discussions；--discuss 建 status:inbox 的 Feature issue"
fresh
out="$(bash tools/flow/owner-idea.sh "手机上能看到电脑的剩余空间" --from "产品负责人在 test 回归时说" 2>/dev/null)"
check "默认 → 建 Ideas 讨论，不进看板" bash -c 'printf "%s\n" "$1" | grep -q "^IDEA DISCUSSION #5$" && grep -q "createDiscussion.*DC_ideas" "$FAKE/calls.log" && ! grep -q "^issue create" "$FAKE/calls.log"' _ "$out"
check "讨论正文带原话与来源" bash -c 'grep "createDiscussion" "$FAKE/calls.log" | grep -q "> 手机上能看到电脑的剩余空间.*产品负责人在 test 回归时说"'
out="$(bash tools/flow/owner-idea.sh "手机上能看到电脑的剩余空间" --discuss 2>/dev/null)"
check "反证：--discuss → status:inbox issue，类型设为 Feature" bash -c 'printf "%s\n" "$1" | grep -q "^IDEA ISSUE #999 status:inbox Feature$" && grep -q "^issue create .*--label status:inbox" "$FAKE/calls.log" && grep -q "updateIssue.*I_999.*IT_feature" "$FAKE/calls.log"' _ "$out"
bash tools/flow/owner-idea.sh "   " >/dev/null 2>&1
check "空想法 → 拒绝（退出码 2）" test "$?" -eq 2

echo "── 9. triage：分流由脚本按范围路径与字段判定"
tcard() { # tcard <号> <标签>：按任务卡模板造一张 inbox 卡
  printf '卡 %s' "$1" >"$FAKE/issues/$1.title"
  printf '%s' "$2" >"$FAKE/issues/$1.labels"
  printf '## 🟥 挂号段\n\n**产品诉求**：一句话\n\n## ⬜ 可接段\n\n**是否核心**：<!-- 是 / 否 -->\n\n**级别**：L1\n\n**范围（只许动这些）**：\n<!-- 一行一个 -->\n```\n```\n\n**验收场景**：\n<!-- 场景名 -->\n\n**前置依赖**：\n' >"$FAKE/issues/$1.body"
}
plan() { # plan <文件> <范围 glob> <用户可见行为> [额外行]
  printf '**做法**：改脚本\n**涉及端**：无\n**数据**：无\n**用户可见行为**：%s\n**隐私**：无\n**风险**：低\n**范围**：\n```\n%s\n```\n**验收场景**：tools/test-x.sh 全过（E2），反证：去掉判断变红\n%s\n' "$3" "$2" "${4:-}" >"$1"
}
P="${S}/plan.md"
tcard 41 status:inbox
plan "$P" "tools/new-thing.sh" "无"
out="$(bash tools/flow/owner-triage.sh 41 "$P" 2>/dev/null)"
check "纯技术、非核心 → status:ready" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 41 ready$" && [ "$(cat "$FAKE/issues/41.labels")" = status:ready ]' _ "$out"
check "写回后 hook 读得出范围，且只有一个范围代码块" bash -c 'grep -A2 "^\*\*范围" "$FAKE/issues/41.body" | grep -qx "tools/new-thing.sh" && [ "$(grep -c "^\*\*范围" "$FAKE/issues/41.body")" -eq 1 ]'
check "验收场景填进任务卡字段，实施方案段在末尾" bash -c 'grep -A1 "^\*\*验收场景" "$FAKE/issues/41.body" | grep -q "test-x.sh" && grep -q "^## 实施方案（just triage）" "$FAKE/issues/41.body"'
tcard 42 status:inbox
plan "$P" "tools/new-thing.sh" "设置页多一个开关"
bash tools/flow/owner-triage.sh 42 "$P" >/dev/null 2>&1
check "反证：有用户可见行为但没给两个选项 → 拒绝，不写 issue" bash -c '[ "$(cat "$FAKE/issues/42.labels")" = status:inbox ] && ! grep -q "实施方案" "$FAKE/issues/42.body"'
plan "$P" "tools/new-thing.sh" "设置页多一个开关" $'**选项一**：默认开，影响：老用户升级后多耗电\n**选项二**：默认关，影响：新功能没人发现'
out="$(bash tools/flow/owner-triage.sh 42 "$P" 2>/dev/null)"
check "有用户可见行为 + 两个选项 → needs:product，选项写进 issue" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 42 needs:product$" && grep -q "needs:product" "$FAKE/issues/42.labels" && grep -q "^2. 默认关" "$FAKE/issues/42.body"' _ "$out"
tcard 43 status:inbox
plan "$P" "assets/i18n/zh.json" "无"
bash tools/flow/owner-triage.sh 43 "$P" >/dev/null 2>&1
check "范围碰文案路径、方案却写「无」→ 仍按产品问题处理（无选项则拒绝）" bash -c '[ "$(cat "$FAKE/issues/43.labels")" = status:inbox ]'
tcard 44 status:inbox
plan "$P" "crates/storage/**" "无"
out="$(bash tools/flow/owner-triage.sh 44 "$P" 2>/dev/null)"
check "核心、没有已采纳 ADR → status:blocked" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 44 blocked$" && [ "$(cat "$FAKE/issues/44.labels")" = status:blocked ] && grep -q "ADR" "$FAKE/issues/44.comments"' _ "$out"
tcard 45 status:inbox
plan "$P" "crates/storage/new.rs" "无" "**ADR**：docs/decisions/2026-11-01-proposed.md"
out="$(bash tools/flow/owner-triage.sh 45 "$P" 2>/dev/null)"
check "核心新文件、ADR 只是「提议」→ status:blocked" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 45 blocked$"' _ "$out"
tcard 46 status:inbox
plan "$P" "crates/storage/new.rs" "无" "**ADR**：docs/decisions/2026-11-01-adopted.md"
out="$(bash tools/flow/owner-triage.sh 46 "$P" 2>/dev/null)"
check "反证：核心 + 已采纳 ADR → status:ready 并打 core" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 46 ready$" && grep -q "core" "$FAKE/issues/46.labels" && grep -q "^\*\*是否核心\*\*：是" "$FAKE/issues/46.body"' _ "$out"
tcard 47 status:inbox
printf '**做法**：改\n**范围**：\n```\ntools/a.sh\n```\n' >"$P"
bash tools/flow/owner-triage.sh 47 "$P" >/dev/null 2>&1
rc=$?
check "方案缺字段 → 拒绝（退出码 2），不写 issue" bash -c '[ "$1" -eq 2 ] && ! grep -q "^issue edit 47" "$FAKE/calls.log"' _ "$rc"
plan "$P" "tools/new-thing.sh" "无"
bash tools/flow/owner-triage.sh 41 "$P" >/dev/null 2>&1
check "已不是 status:inbox 的卡 → 拒绝" test "$?" -eq 2

echo
echo "flow-owner: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
