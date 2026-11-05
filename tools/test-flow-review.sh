#!/usr/bin/env bash
# just review（tools/flow/review.sh）的判据测试。
#
# 临时仓库（裸 origin 里有 refs/pull/7/head）里走真实路径；gh 与评审 agent 都是桩：
#   gh     读写 $FAKE 目录：pr 头提交、正文，issue 正文；评论与提交状态记在文件里
#   agent  记下收到的参数、工作目录、stdin，按 $FAKE/mode 决定怎么回答
# 每条拒绝都配一条只去掉触发条件的放行用例作反证。
#
# 用法: tools/test-flow-review.sh
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
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

export HOME="${TMP}/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
mkdir -p "$HOME"
git config --global user.name "Review Test"
git config --global user.email "review-test@example.invalid"
git config --global init.defaultBranch main
export PPASS_HOOK_REPO="o/r"

FAKE="${TMP}/fake"
mkdir -p "$FAKE" "${TMP}/bin"
export FAKE
export PATH="${TMP}/bin:${PATH}"

# ── 假 gh ─────────────────────────────────────────────────────────────
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
case "$1 $2" in
  "pr view")
    case " $* " in *" --json author "*) cat "$F/pr.author" 2>/dev/null; exit 0 ;; esac
    printf 'state:%s\nsha:%s\ntitle:%s\nbody:\n' "$(cat "$F/pr.state")" "$(cat "$F/pr.sha")" "T-7 title"
    cat "$F/pr.body"
    ;;
  "pr diff")
    case " $* " in *" --name-only "*) cat "$F/pr.files" ;; *) cat "$F/pr.diff" ;; esac
    ;;
  "pr merge")
    case " $* " in *" --disable-auto "*)
      echo "$*" >>"$F/disables"
      [ ! -e "$F/disable_fail" ] || { echo "${DISABLE_ERR:-HTTP 500}" >&2; exit 1; }
      exit 0 ;;
    esac
    echo "$*" >>"$F/merges"; [ ! -e "$F/merge_fail" ] || { echo "auto-merge not allowed" >&2; exit 1; } ;;
  "pr comment")
    n="$3"; shift 3
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && { cat "$2" >>"$F/comments"; echo "-----" >>"$F/comments"; }
      shift
    done
    ;;
  "issue view")
    printf 'state:OPEN\ntitle:%s\nlabels:status:doing\nbody:\n' "card $3"
    cat "$F/issue.$3"
    ;;
  "api -X")
    shift 2
    echo "$*" >>"$F/statuses"
    ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

# ── 假评审 agent ──────────────────────────────────────────────────────
cat >"${TMP}/bin/fake-agent" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
printf '%s\n' "$@" >"$F/agent.args"
pwd -P >"$F/agent.cwd"
cat >"$F/agent.stdin"
case "$(cat "$F/mode")" in
  pass) echo "未发现正确性问题。"; echo "VERDICT: PASS" ;;
  fail) echo "tools/x.sh:3 —— MAC_GLOBS 没加引号，会被 shell 展开。"; echo "VERDICT: FAIL" ;;
  noverdict) echo "看起来还行。" ;;
  empty) printf '\n   \n\n' ;;
  crash) echo "boom" >&2; exit 3 ;;
  tamper) echo "x" >>tools/x.sh; echo "VERDICT: PASS" ;;
esac
STUB
chmod +x "${TMP}/bin/fake-agent"
export PPASS_REVIEW_AGENT="${TMP}/bin/fake-agent"

# ── 仓库：裸 origin + 主仓，PR #7 的头提交在 refs/pull/7/head ─────────
git init -q --bare "${TMP}/origin.git"
git init -q "${TMP}/main"
(
  cd "${TMP}/main" || exit 1
  git remote add origin "${TMP}/origin.git"
  mkdir -p tools/flow .github
  cp -R "${SRC}/tools/flow/." tools/flow/
  cp "${SRC}/tools/ci-paths.sh" tools/ci-paths.sh
  # core/** 是用户看不见的核心（如发布链脚本），apps/core/** 是用户看得见的核心。
  printf '+ core/**\n+ apps/core/**\n' >.github/core-paths.txt
  mkdir -p docs/decisions
  printf '# 方案\n\n- 状态：已采纳\n' >docs/decisions/2026-11-01-adopted.md
  printf 'echo base\n' >tools/x.sh
  git add -A && git commit -q -m init
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b pr7
  printf 'echo changed\n' >tools/x.sh
  git commit -q -am "change x"
  git push -q origin HEAD:refs/pull/7/head
  git rev-parse HEAD >"${FAKE}/pr.sha"
  git checkout -q main
)
printf 'OPEN' >"$FAKE/pr.state"
printf 'tools/x.sh\n' >"$FAKE/pr.files"
printf -- '--- a/tools/x.sh\n+++ b/tools/x.sh\n@@\n-echo base\n+echo changed-DIFFLINE\n' >"$FAKE/pr.diff"
printf '**范围（只许动这些）**：\n```\ntools/x.sh\n```\n\n**验收场景**：MARK-ACCEPT 引号必须加。\n' >"$FAKE/issue.77"
printf 'closes #77\n\n改了 x。\n' >"$FAKE/pr.body"
SHA="$(cat "$FAKE/pr.sha")"

REVIEW() { (cd "${TMP}/main" && bash tools/flow/review.sh "$@"); }
reset() {
  : >"$FAKE/comments"
  : >"$FAKE/statuses"
  : >"$FAKE/merges"
  : >"$FAKE/disables"
  rm -f "$FAKE/disable_fail"
  rm -f "$FAKE/merge_fail"
  rm -f "$FAKE/agent.args" "$FAKE/agent.cwd" "$FAKE/agent.stdin"
  printf '%s' "$1" >"$FAKE/mode"
}
has() { grep -qF -- "$1" "$2"; }

echo "==> 通过"
reset pass
REVIEW 7 >"${TMP}/o1" 2>&1 && ok "VERDICT: PASS → 退出 0" || bad "PASS 却失败：$(tail -3 "${TMP}/o1")"
has "独立评审：通过" "$FAKE/comments" && ok "评论写「通过」" || bad "评论不对：$(cat "$FAKE/comments")"
has "state=success" "$FAKE/statuses" && has "context=review/agent" "$FAKE/statuses" && ok "提交状态 review/agent=success" || bad "状态不对：$(cat "$FAKE/statuses")"
grep -q "${SHA}" "$FAKE/statuses" && ok "状态写在 PR 头提交上" || bad "状态没写在头提交上"
has "VERDICT" "$FAKE/comments" && bad "评论里留了 VERDICT 行" || ok "评论里不带 VERDICT 行"

has "pr merge --auto --squash 7 --repo o/r" "$FAKE/merges" && ok "评审通过 → gh pr merge --auto --squash" || bad "通过后没开自动合入：$(cat "$FAKE/merges")"

echo "==> 只读权限与输入"
ARGS="$FAKE/agent.args"
has "Read Grep Glob" "$ARGS" && ok "allowedTools 只有 Read Grep Glob" || bad "allowedTools 不对：$(cat "$ARGS")"
python3 - "$ARGS" <<'PY' && ok "allowedTools 里没有 Bash / Edit / Write" || bad "allowedTools 里混进了写权限或 Bash"
import sys
a = open(sys.argv[1]).read().split("\n")
i = a.index("--allowedTools")
allowed = a[i + 1].split()
sys.exit(1 if set(allowed) & {"Bash", "Edit", "Write", "NotebookEdit"} else 0)
PY
has "--disallowedTools" "$ARGS" && has "Bash Edit Write" "$ARGS" && ok "disallowedTools 兜底禁写与 Bash" || bad "没有 disallowedTools"
[ "$(cat "$FAKE/agent.cwd")" != "$(cd "${TMP}/main" && pwd -P)" ] && ok "agent 的工作目录不是主仓" || bad "agent 在主仓里跑"
has "MARK-ACCEPT" "$FAKE/agent.stdin" && ok "prompt 带卡上的验收场景" || bad "prompt 缺验收场景"
has "tools/x.sh" "$FAKE/agent.stdin" && has "DIFFLINE" "$FAKE/agent.stdin" && ok "prompt 带范围与 diff" || bad "prompt 缺范围或 diff"
has "VERDICT: PASS" "$FAKE/agent.stdin" && ok "prompt 说明了 VERDICT 约定" || bad "prompt 没写 VERDICT 约定"
has "--model" "$ARGS" && bad "没指定模型却带了 --model" || ok "没指定模型 → 不带 --model"
reset pass
REVIEW 7 --model deepseek-x >/dev/null 2>&1
has "deepseek-x" "$FAKE/agent.args" && ok "--model 传给 agent" || bad "--model 没传到 agent"

echo "==> 未通过"
reset fail
REVIEW 7 >"${TMP}/o2" 2>&1 && bad "VERDICT: FAIL 却退出 0" || ok "VERDICT: FAIL → 退出非 0"
has "独立评审：未通过" "$FAKE/comments" && has "MAC_GLOBS" "$FAKE/comments" && ok "评论写「未通过」并带问题清单" || bad "评论不对：$(cat "$FAKE/comments")"
has "state=failure" "$FAKE/statuses" && ok "提交状态 review/agent=failure" || bad "状态不对：$(cat "$FAKE/statuses")"
[ ! -s "$FAKE/merges" ] && ok "未通过 → 不开自动合入" || bad "未通过却开了自动合入"
reset noverdict
# #1435 起「agent 没给出结论」与「评审不通过」分开：前者写 error +「评审没跑成」（不算通过，也不当作代码有问题）。
REVIEW 7 >/dev/null 2>&1 && bad "没有 VERDICT 却通过" || ok "没有 VERDICT → 不通过（反证：有 VERDICT: PASS 才通过）"
has "state=error" "$FAKE/statuses" && ! has "state=success" "$FAKE/statuses" && has "评审没跑成" "$FAKE/comments" &&
  ok "没有 VERDICT → 状态 error、评论写「评审没跑成」" || bad "没有 VERDICT 状态不是 error"
reset crash
REVIEW 7 >/dev/null 2>&1 && bad "agent 崩了却通过" || ok "agent 退出非 0 → 不通过"
has "state=error" "$FAKE/statuses" && has "退出码 3" "$FAKE/comments" && has "评审没跑成" "$FAKE/comments" &&
  ok "agent 崩溃 → 状态 error，评论写「评审没跑成」与原因" || bad "agent 崩溃的记录不对"
reset tamper
REVIEW 7 >/dev/null 2>&1 && bad "agent 改了检出却通过" || ok "agent 改动检出 → 评审作废（即使它说 PASS）"
has "state=failure" "$FAKE/statuses" && has "改动了只读检出" "$FAKE/comments" && ok "改动检出 → failure 并写明" || bad "改动检出的记录不对"
git -C "${TMP}/main" worktree list | grep -q checkout && bad "临时检出没清掉" || ok "临时检出评审后清掉"

echo "==> 盯梢、人控级要有真机验收记录"
ACC='产品负责人 2026-11-04 16:30 真机验收通过'
for case_ in "界面文案路径:assets/i18n/en.json" "核心路径（看得见）:apps/core/c.kt"; do
  name="${case_%%:*}"; file="${case_#*:}"
  reset pass
  printf '%s\n' "$file" >"$FAKE/pr.files"
  printf 'closes #77\n' >"$FAKE/pr.body"
  REVIEW 7 >/dev/null 2>&1 && bad "${name}：没有验收记录却通过" || ok "${name}：正文没有验收记录 → 未通过"
  has "缺验收记录" "$FAKE/comments" && has "真机验收通过" "$FAKE/comments" && ok "${name}：评论写明缺这一行" || bad "${name}：评论没写缺验收行：$(cat "$FAKE/comments")"
  has "state=failure" "$FAKE/statuses" && [ ! -s "$FAKE/merges" ] && ok "${name}：状态 failure 且不开自动合入" || bad "${name}：状态或自动合入不对"
  reset pass
  printf 'closes #77\n\n%s\n' "$ACC" >"$FAKE/pr.body"
  REVIEW 7 >/dev/null 2>&1 && ok "${name}：反证：补上验收行 → 通过" || bad "${name}：补上验收行仍失败"
  has "--auto --squash" "$FAKE/merges" && ok "${name}：补上验收行 → 开自动合入" || bad "${name}：补上验收行没开自动合入"
done
reset pass
printf 'tools/x.sh\n' >"$FAKE/pr.files"
printf 'closes #77\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1 && has "--auto --squash" "$FAKE/merges" && ok "反证：用户看不到的改动（tools）不要验收行也通过并开自动合入" || bad "用户看不到的改动被要求验收行"
# 只改测试文件（apps 下）：与 worker-done / CI gate 同一口径，不要验收行也通过；改正式文件则要
reset pass
printf 'apps/desktop/src/foo.test.js\n' >"$FAKE/pr.files"
printf 'closes #77\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1 && has "--auto --squash" "$FAKE/merges" && ok "反证：apps 下只改测试文件，不要验收行也通过" || bad "只改测试文件被要求验收行"
reset pass
printf 'apps/desktop/src/foo.test.js\napps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt\n' >"$FAKE/pr.files"
REVIEW 7 >/dev/null 2>&1 && bad "改了 backup/BackupWorker.kt 没有验收行却通过" || ok "改 apps 下的正式文件（备份行为）→ 要验收行"
printf 'tools/x.sh\n' >"$FAKE/pr.files"
reset pass
touch "$FAKE/merge_fail"
REVIEW 7 >/dev/null 2>&1 && bad "开自动合入失败却退出 0" || ok "开自动合入失败 → 退出非 0"
has "state=success" "$FAKE/statuses" && ok "开自动合入失败时评审状态仍已写（评审本身通过）" || bad "评审状态没写"

echo "==> 拒绝评审"
reset pass
printf 'no card here\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1 && bad "PR 正文没有 closes #N 却评审了" || ok "正文没有 closes #N → 拒绝"
[ ! -s "$FAKE/comments" ] && [ ! -s "$FAKE/statuses" ] && ok "拒绝时不贴评论、不写状态" || bad "拒绝时仍写了评论或状态"
printf 'closes #77\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1 && ok "反证：补上 closes #77 → 评审通过" || bad "补上 closes 仍失败"
printf 'MERGED' >"$FAKE/pr.state"
reset pass
REVIEW 7 >/dev/null 2>&1 && bad "已合并的 PR 也评审了" || ok "PR 不是 open → 拒绝"
printf 'OPEN' >"$FAKE/pr.state"
REVIEW abc >/dev/null 2>&1 && bad "非数字 PR 号被接受" || ok "PR 号不是数字 → 拒绝"
REVIEW >/dev/null 2>&1 && bad "没给 PR 号被接受" || ok "没给 PR 号 → 拒绝"

echo "==> 验收行判定收紧 + 判未通过时撤销自动合入"
printf 'apps/core/c.kt\n' >"$FAKE/pr.files"
accept_case() { # 名称 正文行 期望(pass|fail)
  reset pass
  printf 'apps/core/c.kt\n' >"$FAKE/pr.files"
  printf 'closes #77\n\n%s\n' "$2" >"$FAKE/pr.body"
  if REVIEW 7 >/dev/null 2>&1; then got=pass; else got=fail; fi
  [[ "$got" == "$3" ]] && ok "验收行 ${1} → ${3}" || bad "验收行 ${1}：期望 ${3}，实际 ${got}"
}
accept_case "占位句" '产品负责人 <时间> 真机验收通过' fail
accept_case "否定句" '没有 产品负责人 2026-11-04 真机验收通过' fail
accept_case "规则句嵌在句中" '合入条件：PR 正文写「产品负责人 2026-11-04 真机验收通过」' fail
accept_case "日期后插入否定「未」" '产品负责人 11-04 未真机验收通过' fail
accept_case "日期后接未完成、后面才提验收" '产品负责人 11-04 尚未完成，待真机验收通过后补' fail
accept_case "加粗后接括号说明（#1373 真实整行）" '**产品负责人 11-04 本地真机验收通过**（三星 SM-S9210 + iPhone 16，按合在一起的包）。步骤摘要：' pass
accept_case "正常写法（具体日期）" '产品负责人 2026-11-04 真机验收通过' pass
accept_case "正常写法（加粗、短日期、本地，同 #1373）" '**产品负责人 11-04 本地真机验收通过**' pass

reset fail
printf 'tools/x.sh\n' >"$FAKE/pr.files"
REVIEW 7 >/dev/null 2>&1 && bad "FAIL 用例没失败" || ok "评审判 FAIL → 退出非 0"
has "pr merge 7" "$FAKE/disables" && has "--disable-auto" "$FAKE/disables" && ok "判 FAIL → 调用 gh pr merge --disable-auto" || bad "判 FAIL 没撤销自动合入：$(cat "$FAKE/disables")"
reset pass
printf 'tools/x.sh\n' >"$FAKE/pr.files"
REVIEW 7 >/dev/null 2>&1
[ ! -s "$FAKE/disables" ] && ok "反证：判 PASS 不调用 --disable-auto" || bad "判 PASS 却撤销了自动合入"
reset fail
printf 'tools/x.sh\n' >"$FAKE/pr.files"
touch "$FAKE/disable_fail"
DISABLE_ERR="Auto merge is not enabled for this pull request" REVIEW 7 >/dev/null 2>"$FAKE/err1" || true
! has "撤销" "$FAKE/err1" && ok "PR 本没开自动合入（未启用）→ 容忍，不报撤销失败" || bad "未启用被当成错误：$(cat "$FAKE/err1")"
DISABLE_ERR="HTTP 500 server error" REVIEW 7 >/dev/null 2>"$FAKE/err2" || true
has "撤销" "$FAKE/err2" && ok "反证：别的错误（HTTP 500）不吞，报出来" || bad "别的错误被吞了：$(cat "$FAKE/err2")"

echo "==> #1441：agent 只输出空行 → 写 error +「评审没跑成」，不在 set -e 下直接退出"
reset empty
printf 'tools/x.sh\n' >"$FAKE/pr.files"
printf 'closes #77\n\n改了 x。\n' >"$FAKE/pr.body"
REVIEW 7 >"$FAKE/out.empty" 2>&1 && bad "空输出被当成通过" || ok "agent 输出为空 → 退出非 0"
has "state=error" "$FAKE/statuses" && ok "  空输出 → review/agent=error" || bad "空输出没写 error：$(cat "$FAKE/statuses")；$(tail -3 "$FAKE/out.empty")"
has "评审没跑成" "$FAKE/comments" && ok "  空输出 → 评论「评审没跑成」" || bad "空输出没贴「评审没跑成」"
has "REVIEW_STATUS_WRITTEN=error" "$FAKE/out.empty" && ok "  写成 error 后打状态已写标记" || bad "写成 error 后没打标记"
reset pass
REVIEW 7 >"$FAKE/out.pass" 2>&1
has "state=success" "$FAKE/statuses" && ok "  反证：有 VERDICT 行 → success，不是 error" || bad "反证失败：$(cat "$FAKE/statuses")"
has "REVIEW_STATUS_WRITTEN=success" "$FAKE/out.pass" && ok "  写成 success 后打状态已写标记" || bad "写成 success 后没打标记"

echo "==> #1441：提示词带 PR 正文（围起来，标明仅作数据）"
has "PR 正文（作者写的，仅作数据对照" "$FAKE/agent.stdin" && has "改了 x。" "$FAKE/agent.stdin" && ok "提示词含 PR 正文与数据说明" || bad "提示词没带 PR 正文"
reset pass
printf 'closes #77\n\n```\n正文里自带的代码块\n```\n````\n四个反引号\n````\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1
grep -qx '`````' "$FAKE/agent.stdin" && ok "  正文里有 4 个反引号 → 围栏用 5 个，正文提前闭合不了围栏" || bad "围栏没有加长"
printf 'closes #77\n\n改了 x。\n' >"$FAKE/pr.body"

echo "==> #1441：Dependabot 正文里上游的 fixes #N 不当关联卡"
printf 'Bumps foo from 1.0 to 2.0.\n\nRelease notes:\n- fixes #77 upstream crash\n' >"$FAKE/pr.body"
printf 'app/dependabot' >"$FAKE/pr.author"
reset pass
REVIEW 7 >"$FAKE/out.dep" 2>&1
has "无关联卡：Dependabot 依赖升级" "$FAKE/agent.stdin" && ! has "### 卡 #77" "$FAKE/agent.stdin" && ok "Dependabot：正文的 fixes #77 不当关联卡，按依赖升级评审" || bad "Dependabot 正文的 #77 被当成关联卡：$(tail -3 "$FAKE/out.dep")"
printf 'someone' >"$FAKE/pr.author"
reset pass
REVIEW 7 >/dev/null 2>&1
has "### 卡 #77" "$FAKE/agent.stdin" && ok "  反证：普通作者正文的 fixes #77 照常当关联卡" || bad "普通作者的 fixes #77 没当关联卡"
rm -f "$FAKE/pr.author"
printf 'closes #77\n\n改了 x。\n' >"$FAKE/pr.body"

reset pass
printf 'tools/x.sh\n' >"$FAKE/pr.files"
printf 'closes #77\n\n改了 x。\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1
grep -q '关联卡 #77 ；' "$FAKE/comments" && ok "评论脚注只列一次关联卡号" || bad "评论脚注卡号不对：$(grep '关联卡' "$FAKE/comments")"

echo "==> #1448：核心但用户看不见 → 不要验收行，要已采纳方案 + 测试"
hidden_case() { # 名称 改动文件（空格分隔） 正文附加行 期望(pass|fail)
  reset pass
  printf '%s\n' $2 >"$FAKE/pr.files"
  printf 'closes #77\n\n%s\n' "$3" >"$FAKE/pr.body"
  if REVIEW 7 >/dev/null 2>&1; then got=pass; else got=fail; fi
  [[ "$got" == "$4" ]] && ok "看不见的核心 ${1} → ${4}" || bad "看不见的核心 ${1}：期望 ${4}，实际 ${got}：$(head -4 "$FAKE/comments")"
}
hidden_case "只有验收行" "core/c.txt" '产品负责人 2026-11-04 真机验收通过' fail
has "已采纳" "$FAKE/comments" && ok "  未通过理由点名要已采纳方案" || bad "理由没点名已采纳方案"
hidden_case "引用已采纳方案但没测试" "core/c.txt" '方案：docs/decisions/2026-11-01-adopted.md' fail
hidden_case "反证：已采纳方案 + 测试文件" "core/c.txt tools/test-c.sh" '方案：docs/decisions/2026-11-01-adopted.md' pass
hidden_case "方案不在 origin/main 上" "core/c.txt tools/test-c.sh" '方案：docs/decisions/2026-11-09-nope.md' fail

echo "==> #1452：SOP 格式验收行与整体模式"
reset pass
printf 'assets/i18n/en.json\n' >"$FAKE/pr.files"
printf 'closes #77\n\n产品负责人 2026-11-05 15:30 按 SOP https://x/1 操作，owner 判日志通过\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1 && ok "SOP 格式验收行 → 通过" || bad "SOP 格式验收行不认：$(head -4 "$FAKE/comments")"
reset pass
printf 'closes #77\n\n随模块验收 #9\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1 && ok "界面改动整体模式「随模块验收 #9」→ 通过" || bad "随模块验收不认"
reset pass
printf 'apps/core/c.kt\n' >"$FAKE/pr.files"
REVIEW 7 >/dev/null 2>&1 && bad "看得见的核心只靠随模块验收也通过了" || ok "反证：看得见的核心只有随模块验收 → 未通过"
printf 'tools/x.sh\n' >"$FAKE/pr.files"
printf 'closes #77\n\n改了 x。\n' >"$FAKE/pr.body"

echo "==> #1448：只改更新说明要「文案确认通过」行"
notes_case() { # 名称 正文行 期望(pass|fail)
  reset pass
  printf 'release/notes/android/0.11.0.zh.txt\n' >"$FAKE/pr.files"
  printf 'closes #77\n\n%s\n' "$2" >"$FAKE/pr.body"
  if REVIEW 7 >/dev/null 2>&1; then got=pass; else got=fail; fi
  [[ "$got" == "$3" ]] && ok "更新说明 ${1} → ${3}" || bad "更新说明 ${1}：期望 ${3}，实际 ${got}"
}
notes_case "没有确认行" '- 文案确认：待产品负责人文案确认' fail
has "文案确认通过" "$FAKE/comments" && ok "  未通过理由点名「文案确认通过」行" || bad "理由没点名文案确认行：$(head -5 "$FAKE/comments")"
notes_case "反证：有确认行" '产品负责人 2026-11-05 15:30 文案确认通过' pass
printf 'tools/x.sh\n' >"$FAKE/pr.files"
printf 'closes #77\n\n改了 x。\n' >"$FAKE/pr.body"

echo
echo "flow-review: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
