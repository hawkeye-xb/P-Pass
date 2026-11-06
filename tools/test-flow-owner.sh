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
# doctor 在每条 owner 命令开头跑：磁盘下限在测试里放开（CI runner 空间不固定），设备只列不判。
export PPASS_DOCTOR_MIN_FREE_GB=0
export PPASS_DOCTOR_SKIP_DEVICES=1
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
      status:review) for f in "$I"/*.labels; do [ -e "$f" ] || continue; grep -q 'status:review' "$f" && basename "$f" .labels; done ;;
      *) : ;;
    esac
    ;;
  "issue view")
    n="$3"
    [ -f "$I/$n.body" ] || { echo "no issue $n" >&2; exit 1; }
    case "$json" in
      state) cat "$I/$n.state" 2>/dev/null || echo OPEN ;;
      milestone) cat "$I/$n.due" 2>/dev/null || true ;;
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
  "workflow run") exit 0 ;;
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
      */issues/comments/*) cat "$FAKE/comments/${2##*/}" 2>/dev/null || exit 1 ;;
      */issues/[0-9]*) cat "$I/${2##*/}.type" 2>/dev/null || echo "" ;;
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
  --summary) echo "ci" ;;
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
  printf '%s\n' status:inbox status:ready status:doing status:review status:batched status:blocked needs:product core P0 P1 P2 P3 >"$FAKE/labels"
  : >"$FAKE/calls.log"
  git init -q --bare "$ORIGIN"
  R="${S}/repo"
  git init -q "$R"
  cd "$R" || exit 1
  git remote add origin "$ORIGIN"
  mkdir -p tools/flow tools/release .github docs/decisions src crates/storage release
  cp "${SRC}/tools/flow/"* tools/flow/
  cp -R "${SRC}/tools/hooks" tools/hooks
  # 测试只看 doctor 有没有接通 install.sh --check；真 hook 的判据在 tools/test-local-hooks.sh。
  # 空转发器让卡分支的夹具提交不被真 hook 的范围检查提前拦掉。
  printf '#!/usr/bin/env bash\nexit 0\n' >tools/hooks/dispatch.sh
  printf 'Flow Test <flow-test@example.invalid>\n' >.github/allowed-identities.txt
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
  # doctor 要求提交拦截已装；1b 用例会先解开、再装回来。
  bash tools/hooks/install.sh >/dev/null 2>&1
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
echo "── 1b. owner 命令开头先跑 doctor：环境不满足就停在自己的判定之前"
fresh
git config --unset core.hooksPath || true
bash tools/flow/owner-idea.sh "一个想法" >"${S}/out-1b" 2>&1
rc=$?
check "拦截未装 → idea 非 0（doctor 挡在开头）" test "$rc" -eq 1
check "停在 idea 自己的判定之前：没建讨论、没写 issue" bash -c '! grep -q "createDiscussion" "$FAKE/calls.log" && ! grep -q "^issue create" "$FAKE/calls.log"'
bash tools/hooks/install.sh >/dev/null 2>&1
out="$(bash tools/flow/owner-idea.sh "一个想法" 2>/dev/null)"
check "反证：装上拦截 → idea 正常建讨论" bash -c 'printf "%s\n" "$1" | grep -q "^IDEA DISCUSSION #"' _ "$out"

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
check "#1349：发版走手动触发（release=true、tag=v0.10.3-test.3），脚本自己不推 tag" bash -c 'grep -q "^workflow run release.yml .*tag=v0.10.3-test.3.* release=true" "$FAKE/calls.log" && [ "$(git ls-remote --tags origin | wc -l | tr -d " ")" -eq 1 ]'
check "临时触发分支跑完即删，远端不留" bash -c '! git ls-remote --heads origin | grep -q release-run/'
echo success >"$FAKE/run-conclusion"
echo "0.10.3-test.3" >"$FAKE/channel-version"
out="$(bash tools/flow/owner-release-test.sh android 2>/dev/null)"
check "反证：绿了 → RELEASE-TEST OK v0.10.3-test.3（上一次验证红没有建 tag，号码直接重用）" bash -c 'printf "%s\n" "$1" | grep -q "^RELEASE-TEST OK v0.10.3-test.3 android$"' _ "$out"
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
  printf '**做法**：改脚本\n**涉及端**：无\n**数据**：无\n**用户可见行为**：%s\n**隐私**：无\n**风险**：低\n**影响**：%s\n**时间性**：%s\n**范围**：\n```\n%s\n```\n**验收场景**：tools/test-x.sh 全过（E2），反证：去掉判断变红\n%s\n' "$3" "${IMPACT_T:-局部}" "${TIMING_T:-无}" "$2" "${4:-}" >"$1"
}
P="${S}/plan.md"
tcard 41 status:inbox
plan "$P" "tools/new-thing.sh" "无"
out="$(bash tools/flow/owner-triage.sh 41 "$P" 2>/dev/null)"
check "纯技术、非核心 → status:ready" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 41 ready$" && [ "$(cat "$FAKE/issues/41.labels")" = P3,status:ready ]' _ "$out"
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
check "核心、没有已采纳 ADR → status:blocked" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 44 blocked$" && [ "$(cat "$FAKE/issues/44.labels")" = P3,status:blocked ] && grep -q "ADR" "$FAKE/issues/44.comments"' _ "$out"
tcard 45 status:inbox
plan "$P" "crates/storage/new.rs" "无" "**ADR**：docs/decisions/2026-11-01-proposed.md"
out="$(bash tools/flow/owner-triage.sh 45 "$P" 2>/dev/null)"
check "核心新文件、ADR 只是「提议」→ status:blocked" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 45 blocked$"' _ "$out"
tcard 46 status:inbox
plan "$P" "crates/storage/new.rs" "无" "**ADR**：docs/decisions/2026-11-01-adopted.md"
out="$(bash tools/flow/owner-triage.sh 46 "$P" 2>/dev/null)"
check "反证：核心 + 已采纳 ADR → status:ready 并打 core" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 46 ready$" && grep -q "core" "$FAKE/issues/46.labels" && grep -q "^\*\*是否核心\*\*：是" "$FAKE/issues/46.body"' _ "$out"
DEC_OK="**产品定案**：docs/decisions/2026-11-01-adopted.md，产品负责人 2026-11-03 已确认"
tcard 48 status:inbox
plan "$P" "assets/i18n/zh.json" "首页多一张引导" "$DEC_OK"
out="$(bash tools/flow/owner-triage.sh 48 "$P" 2>/dev/null)"
check "界面路径 + 用户可见行为 + 产品定案（已采纳、产品负责人已确认）→ status:ready，不打 needs:product" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 48 ready$" && [ "$(cat "$FAKE/issues/48.labels")" = P3,status:ready ] && grep -q "^\*\*产品定案\*\*：docs/decisions/2026-11-01-adopted.md" "$FAKE/issues/48.body"' _ "$out"
tcard 49 status:inbox
plan "$P" "assets/i18n/zh.json" "首页多一张引导"
bash tools/flow/owner-triage.sh 49 "$P" >/dev/null 2>&1
rc=$?
check "反证：同一张卡去掉产品定案 → 仍按产品问题处理（无选项则拒绝，不写 issue）" bash -c '[ "$1" -eq 2 ] && [ "$(cat "$FAKE/issues/49.labels")" = status:inbox ] && ! grep -q "实施方案" "$FAKE/issues/49.body"' _ "$rc"
tcard 50 status:inbox
plan "$P" "assets/i18n/zh.json" "首页多一张引导" "**产品定案**：docs/decisions/2026-11-01-proposed.md，产品负责人 2026-11-03 已确认"
err="$(bash tools/flow/owner-triage.sh 50 "$P" 2>&1 >/dev/null)"
rc=$?
check "产品定案只引用「提议」方案 → 拒绝（退出码 2），不写 issue" bash -c '[ "$1" -eq 2 ] && printf "%s\n" "$2" | grep -q "已采纳" && ! grep -q "^issue edit 50" "$FAKE/calls.log"' _ "$rc" "$err"
plan "$P" "assets/i18n/zh.json" "首页多一张引导" "**产品定案**：docs/decisions/2026-11-01-adopted.md docs/decisions/2026-11-01-proposed.md，产品负责人 2026-11-03 已确认"
bash tools/flow/owner-triage.sh 50 "$P" >/dev/null 2>&1
check "产品定案里混了一份「提议」方案 → 拒绝" test "$?" -eq 2
plan "$P" "assets/i18n/zh.json" "首页多一张引导" "$DEC_OK"
out="$(bash tools/flow/owner-triage.sh 50 "$P" 2>/dev/null)"
check "反证：同一张卡改为引用「已采纳」方案 → status:ready" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 50 ready$"' _ "$out"
tcard 51 status:inbox
plan "$P" "assets/i18n/zh.json" "首页多一张引导" "**产品定案**：docs/decisions/2026-11-01-adopted.md"
err="$(bash tools/flow/owner-triage.sh 51 "$P" 2>&1 >/dev/null)"
rc=$?
check "产品定案没写明产品负责人确认 → 拒绝（退出码 2），不写 issue" bash -c '[ "$1" -eq 2 ] && printf "%s\n" "$2" | grep -q "产品负责人已确认" && ! grep -q "^issue edit 51" "$FAKE/calls.log"' _ "$rc" "$err"
plan "$P" "assets/i18n/zh.json" "首页多一张引导" "$DEC_OK"
out="$(bash tools/flow/owner-triage.sh 51 "$P" 2>/dev/null)"
check "反证：同一张卡补上产品负责人确认 → status:ready" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 51 ready$"' _ "$out"
tcard 52 status:inbox
plan "$P" "assets/i18n/zh.json" "首页多一张引导" "**产品定案**：无"
bash tools/flow/owner-triage.sh 52 "$P" >/dev/null 2>&1
check "产品定案写「无」等于没写 → 仍按产品问题处理（无选项则拒绝）" bash -c '[ "$(cat "$FAKE/issues/52.labels")" = status:inbox ]'
tcard 47 status:inbox
printf '**做法**：改\n**范围**：\n```\ntools/a.sh\n```\n' >"$P"
bash tools/flow/owner-triage.sh 47 "$P" >/dev/null 2>&1
rc=$?
check "方案缺字段 → 拒绝（退出码 2），不写 issue" bash -c '[ "$1" -eq 2 ] && ! grep -q "^issue edit 47" "$FAKE/calls.log"' _ "$rc"
plan "$P" "tools/new-thing.sh" "无"
bash tools/flow/owner-triage.sh 41 "$P" >/dev/null 2>&1
check "已不是 status:inbox 的卡 → 拒绝" test "$?" -eq 2

echo "── 9b. triage：owner 定案（依据只认 AGENTS.md 原文与仓库 owner 的评论）"
printf '\n## 角色\n\niOS 先对齐 Android，要加就两端一起加。\n' >>AGENTS.md
git add -A && git commit -q -s -m "agents" && git push -q origin HEAD:refs/heads/main && git fetch -q origin
mkdir -p "$FAKE/comments"
printf 't\n' >"$FAKE/comments/101"
printf 'someone-else\n' >"$FAKE/comments/102"
OD_OK="**owner 定案**：AGENTS.md「iOS 先对齐 Android，要加就两端一起加」"
UIP="assets/i18n/zh.json"
tcard 61 status:inbox
plan "$P" "$UIP" "首页多一张引导" "$OD_OK"
out="$(bash tools/flow/owner-triage.sh 61 "$P" 2>/dev/null)"
check "AGENTS.md 原文依据 → ready + decided:owner，不打 needs:product，依据写进实施方案" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 61 ready$" && grep -q "decided:owner" "$FAKE/issues/61.labels" && grep -q "status:ready" "$FAKE/issues/61.labels" && ! grep -q "needs:product" "$FAKE/issues/61.labels" && grep -q "^\*\*owner 定案\*\*：AGENTS.md「iOS 先对齐" "$FAKE/issues/61.body"' _ "$out"
tcard 62 status:inbox
plan "$P" "$UIP" "首页多一张引导" "**owner 定案**：AGENTS.md「iOS 先对齐 Android，两端随便加」"
err="$(bash tools/flow/owner-triage.sh 62 "$P" 2>&1 >/dev/null)"
rc=$?
check "反证：原文不在 AGENTS.md 里 → 拒绝（退出码 2），不写 issue、不打标签" bash -c '[ "$1" -eq 2 ] && printf "%s\n" "$2" | grep -q "找不到" && [ "$(cat "$FAKE/issues/62.labels")" = status:inbox ] && ! grep -q "^issue edit 62" "$FAKE/calls.log"' _ "$rc" "$err"
tcard 63 status:inbox
plan "$P" "$UIP" "首页多一张引导" "**owner 定案**：AGENTS.md「先对齐」"
bash tools/flow/owner-triage.sh 63 "$P" >/dev/null 2>&1
check "原文太短（凑巧能匹配）→ 拒绝" test "$?" -eq 2
tcard 64 status:inbox
plan "$P" "$UIP" "首页多一张引导" "**owner 定案**：https://github.com/t/r/issues/9#issuecomment-101"
out="$(bash tools/flow/owner-triage.sh 64 "$P" 2>/dev/null)"
check "仓库 owner 的评论链接 → ready + decided:owner" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 64 ready$" && grep -q "decided:owner" "$FAKE/issues/64.labels"' _ "$out"
tcard 65 status:inbox
plan "$P" "$UIP" "首页多一张引导" "**owner 定案**：https://github.com/t/r/issues/9#issuecomment-102"
err="$(bash tools/flow/owner-triage.sh 65 "$P" 2>&1 >/dev/null)"
rc=$?
check "反证：评论作者不是仓库 owner → 拒绝（退出码 2），不写 issue" bash -c '[ "$1" -eq 2 ] && printf "%s\n" "$2" | grep -q "不是仓库 owner" && [ "$(cat "$FAKE/issues/65.labels")" = status:inbox ] && ! grep -q "^issue edit 65" "$FAKE/calls.log"' _ "$rc" "$err"
tcard 66 status:inbox
plan "$P" "$UIP" "首页多一张引导" "**owner 定案**：https://github.com/t/r/issues/9#issuecomment-999"
bash tools/flow/owner-triage.sh 66 "$P" >/dev/null 2>&1
check "评论不存在 → 拒绝" test "$?" -eq 2
tcard 67 status:inbox
plan "$P" "$UIP" "首页多一张引导" "**owner 定案**：https://github.com/other/repo/issues/9#issuecomment-101"
bash tools/flow/owner-triage.sh 67 "$P" >/dev/null 2>&1
check "别的仓库的评论链接 → 拒绝（依据数为 0）" test "$?" -eq 2
tcard 68 status:inbox
printf '**做法**：改\n**涉及端**：无\n**数据**：无\n**用户可见行为**：首页多一张引导\n**隐私**：会读通讯录\n**风险**：低\n**影响**：局部\n**时间性**：无\n**范围**：\n```\n%s\n```\n**验收场景**：x（E2）\n%s\n' "$UIP" "$OD_OK" >"$P"
bash tools/flow/owner-triage.sh 68 "$P" >/dev/null 2>&1
check "隐私不为「无」，带 owner 定案仍 needs:product（无选项则拒绝，不打 decided:owner）" bash -c '[ "$(cat "$FAKE/issues/68.labels")" = status:inbox ]'
printf '**选项一**：读\n**选项二**：不读\n' >>"$P"
out="$(bash tools/flow/owner-triage.sh 68 "$P" 2>/dev/null)"
check "反证：同一张卡补上两个选项 → needs:product，没有 decided:owner" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 68 needs:product$" && grep -q "needs:product" "$FAKE/issues/68.labels" && ! grep -q "decided:owner" "$FAKE/issues/68.labels"' _ "$out"
tcard 69 status:inbox
printf '**做法**：改\n**涉及端**：无\n**数据**：新增本地缓存\n**用户可见行为**：首页多一张引导\n**隐私**：无\n**风险**：低\n**影响**：局部\n**时间性**：无\n**范围**：\n```\n%s\n```\n**验收场景**：x（E2）\n%s\n**选项一**：留\n**选项二**：删\n' "$UIP" "$OD_OK" >"$P"
out="$(bash tools/flow/owner-triage.sh 69 "$P" 2>/dev/null)"
check "数据不为「无」，带 owner 定案仍 needs:product" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 69 needs:product$" && ! grep -q "decided:owner" "$FAKE/issues/69.labels"' _ "$out"
tcard 70 status:inbox
printf 'Feature' >"$FAKE/issues/70.type"
plan "$P" "$UIP" "首页多一张引导" $'**owner 定案**：AGENTS.md「iOS 先对齐 Android，要加就两端一起加」\n**选项一**：做\n**选项二**：不做'
out="$(bash tools/flow/owner-triage.sh 70 "$P" 2>/dev/null)"
check "Feature 卡带 owner 定案 → 仍 needs:product" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 70 needs:product$" && ! grep -q "decided:owner" "$FAKE/issues/70.labels"' _ "$out"
rm -f "$FAKE/issues/70.type"
tcard 73 status:inbox
plan "$P" "$UIP" "首页多一张引导" "$OD_OK"
out="$(bash tools/flow/owner-triage.sh 73 "$P" 2>/dev/null)"
check "反证：同样的方案、卡类型不是 Feature → ready + decided:owner" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 73 ready$" && grep -q "decided:owner" "$FAKE/issues/73.labels"' _ "$out"
tcard 71 status:inbox
plan "$P" "$UIP" "首页多一张引导" $'**选项一**：做\n**选项二**：不做'
out="$(bash tools/flow/owner-triage.sh 71 "$P" 2>/dev/null)"
check "不带 owner 定案：行为不变（needs:product、无 decided:owner、不调 gh api 查卡类型）" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 71 needs:product$" && ! grep -q "decided:owner" "$FAKE/issues/71.labels" && ! grep -q "^api repos/t/r/issues/71" "$FAKE/calls.log"' _ "$out"
tcard 72 status:inbox
plan "$P" "$UIP" "首页多一张引导" "**owner 定案**：无"
bash tools/flow/owner-triage.sh 72 "$P" >/dev/null 2>&1
check "owner 定案写「无」等于没写 → 仍按产品问题处理" bash -c '[ "$(cat "$FAKE/issues/72.labels")" = status:inbox ]'
tcard 74 status:inbox
printf '**做法**：改\n**涉及端**：无\n**数据**：无\n**用户可见行为**：首页多一张引导\n**隐私**：无\n读取联系人\n**风险**：低\n**影响**：局部\n**时间性**：无\n**范围**：\n```\n%s\n```\n**验收场景**：x（E2）\n%s\n' "$UIP" "$OD_OK" >"$P"
bash tools/flow/owner-triage.sh 74 "$P" >/dev/null 2>&1
check "隐私「无」后面换行还有内容 → 不算无，owner 定案不顶用（无选项则拒绝）" bash -c '[ "$(cat "$FAKE/issues/74.labels")" = status:inbox ] && ! grep -q "decided:owner" "$FAKE/issues/74.labels"'
tcard 75 status:inbox
printf '**做法**：改\n**涉及端**：无\n**数据**：无\n分类别缓存\n**用户可见行为**：首页多一张引导\n**隐私**：无\n**风险**：低\n**影响**：局部\n**时间性**：无\n**范围**：\n```\n%s\n```\n**验收场景**：x（E2）\n%s\n' "$UIP" "$OD_OK" >"$P"
bash tools/flow/owner-triage.sh 75 "$P" >/dev/null 2>&1
check "数据「无」后面换行还有内容 → 不算无" bash -c '[ "$(cat "$FAKE/issues/75.labels")" = status:inbox ]'
tcard 76 status:inbox
printf '**做法**：改\n**涉及端**：无\n**数据**：无\n**用户可见行为**：首页多一张引导\n**隐私**：无\n**风险**：低\n**影响**：局部\n**时间性**：无\n**范围**：\n```\n%s\n```\n**验收场景**：x（E2）\n%s\n' "$UIP" "$OD_OK" >"$P"
out="$(bash tools/flow/owner-triage.sh 76 "$P" 2>/dev/null)"
check "反证：隐私、数据整个字段就是「无」→ ready + decided:owner" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 76 ready$" && grep -q "decided:owner" "$FAKE/issues/76.labels"' _ "$out"
tcard 77 status:inbox
plan "$P" "$UIP" "首页多一张引导" $'**owner 定案**：AGENTS.md「iOS 先对齐 Android，\n要加就两端一起加」'
bash tools/flow/owner-triage.sh 77 "$P" >/dev/null 2>&1
check "多行引用 → 拒绝（退出码 2），不拆成几段各自匹配" bash -c '[ "$(cat "$FAKE/issues/77.labels")" = status:inbox ] && ! grep -q "^issue edit 77" "$FAKE/calls.log"'
tcard 78 status:inbox
plan "$P" "$UIP" "首页多一张引导" $'**owner 定案**：AGENTS.md「iOS 先对齐 Android，要加就两端一起加」'
out="$(bash tools/flow/owner-triage.sh 78 "$P" 2>/dev/null)"
check "反证：同一句写在一行里 → ready" bash -c 'printf "%s\n" "$1" | grep -q "^TRIAGE 78 ready$"' _ "$out"

echo "── 9c. triage：优先级由「影响」×「时间性」算，替换旧 P 标签"
prio_of() { # prio_of <影响> <时间性> <号> [初始标签]：跑一次 triage，输出该卡最终的 P 标签（逗号分隔）
  tcard "$3" "${4:-status:inbox}"
  IMPACT_T="$1" TIMING_T="$2" plan "$P" "tools/new-thing.sh" "无"
  bash tools/flow/owner-triage.sh "$3" "$P" >/dev/null 2>&1
  tr ',' '\n' <"$FAKE/issues/$3.labels" | grep -E '^P[0-3]$' | paste -sd, -
}
tcard 80 status:inbox
printf '**做法**：改\n**涉及端**：无\n**数据**：无\n**用户可见行为**：无\n**隐私**：无\n**风险**：低\n**时间性**：无\n**范围**：\n```\ntools/new-thing.sh\n```\n**验收场景**：x（E2）\n' >"$P"
bash tools/flow/owner-triage.sh 80 "$P" >/dev/null 2>&1
check "缺「影响」→ 拒绝，不写 issue、不打 P 标签" bash -c '[ "$(cat "$FAKE/issues/80.labels")" = status:inbox ] && ! grep -q "^issue edit 80" "$FAKE/calls.log"'
tcard 81 status:inbox
printf '**做法**：改\n**涉及端**：无\n**数据**：无\n**用户可见行为**：无\n**隐私**：无\n**风险**：低\n**影响**：局部\n**范围**：\n```\ntools/new-thing.sh\n```\n**验收场景**：x（E2）\n' >"$P"
bash tools/flow/owner-triage.sh 81 "$P" >/dev/null 2>&1
check "缺「时间性」→ 拒绝，不写 issue、不打 P 标签" bash -c '[ "$(cat "$FAKE/issues/81.labels")" = status:inbox ] && ! grep -q "^issue edit 81" "$FAKE/calls.log"'
tcard 82 status:inbox
IMPACT_T="很严重" TIMING_T="无" plan "$P" "tools/new-thing.sh" "无"
bash tools/flow/owner-triage.sh 82 "$P" >/dev/null 2>&1
check "「影响」写成不认识的值 → 拒绝" bash -c '[ "$(cat "$FAKE/issues/82.labels")" = status:inbox ]'
check "停线 → P0（影响再小也是）" test "$(prio_of 局部 停线 83)" = P0
check "不可挽回 + 无时间压力 → P1" test "$(prio_of 不可挽回 无 84)" = P1
check "面广 + 截止日 → P1" test "$(prio_of 面广 截止日 85)" = P1
check "局部 + 截止日 → P2" test "$(prio_of 局部 截止日 86)" = P2
check "局部 + 无 → P3" test "$(prio_of 局部 无 87)" = P3
check "反证：同样「局部」，只把时间性换成截止日 → 不再是 P3" test "$(prio_of 局部 截止日 88)" != P3
check "重跑 triage 替换旧 P 标签，不叠加（旧 P3 → P2，只剩一个）" test "$(prio_of 局部 截止日 89 status:inbox,P3)" = P2
check "旧 P 标签与新结果相同 → 仍只有一个" test "$(prio_of 局部 无 90 status:inbox,P3)" = P3
tcard 91 status:inbox
printf '[MAIN-RED] main 红了' >"$FAKE/issues/91.title"
IMPACT_T=局部 TIMING_T=无 plan "$P" "tools/new-thing.sh" "无"
bash tools/flow/owner-triage.sh 91 "$P" >/dev/null 2>&1
check "标题 [MAIN-RED] → 自动 P0" bash -c 'tr "," "\n" <"$FAKE/issues/91.labels" | grep -qx P0'
tcard 92 status:inbox
printf '2026-11-04T00:00:00Z' >"$FAKE/issues/92.due"
IMPACT_T=局部 TIMING_T=无 plan "$P" "tools/new-thing.sh" "无"
bash tools/flow/owner-triage.sh 92 "$P" >/dev/null 2>&1
check "milestone 到期前 3 天内 → 升一级（P3 → P2）" bash -c 'tr "," "\n" <"$FAKE/issues/92.labels" | grep -qx P2'
tcard 93 status:inbox
printf '2026-12-30T00:00:00Z' >"$FAKE/issues/93.due"
IMPACT_T=局部 TIMING_T=无 plan "$P" "tools/new-thing.sh" "无"
bash tools/flow/owner-triage.sh 93 "$P" >/dev/null 2>&1
check "反证：milestone 还很远 → 不升级，仍 P3" bash -c 'tr "," "\n" <"$FAKE/issues/93.labels" | grep -qx P3'

echo
echo "flow-owner: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
