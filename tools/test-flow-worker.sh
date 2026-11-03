#!/usr/bin/env bash
# worker 流程三条命令（tools/flow/worker-*.sh）的判据测试。
#
# 临时仓库（裸 origin + 主仓克隆）里走真实路径；gh 与 just 是 PATH 注入的桩：
#   gh   读写 $FAKE_GH 目录：<号>.state/.title/.labels/.body/.type，评论追加到 <号>.comments
#   just ci / ci-docs 看 $FAKE_GH/ci_fail；just verify 看 has_verify / verify_fail
# 每条拒绝都配一条只去掉触发条件的放行用例作反证。
#
# 用法: tools/test-flow-worker.sh
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
check() { # check <描述> <命令...>：命令成功即通过
  local d="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

export HOME="${TMP}/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
mkdir -p "$HOME"
git config --global user.name "Flow Test"
git config --global user.email "flow-test@example.invalid"
git config --global init.defaultBranch main
export PPASS_HOOK_REPO="o/r"
export PPASS_FLOW_SKIP_HOOK_INSTALL=1
export PPASS_NO_LOCK=1
unset PPASS_HOOK_BYPASS PPASS_HOOK_BYPASS_REASON PPASS_HOOK_ROOT PPASS_WT_ROOT

BIN="${TMP}/pathbin"
mkdir -p "$BIN"
for c in git bash env sh sed awk tar mktemp cat tr head tail grep rm cp chmod touch sort cmp \
  basename dirname mkdir mv cut wc ls diff; do
  p="$(command -v "$c")" && [ "${p#/}" != "$p" ] || {
    echo "找不到命令 ${c}，无法搭测试环境"
    exit 1
  }
  ln -s "$p" "${BIN}/${c}"
done

export FAKE_GH="${TMP}/gh"
mkdir -p "$FAKE_GH"
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
G="$FAKE_GH"
case "$1 $2" in
  "auth status") exit 0 ;;
  "label create") echo "label create $3" >>"$G/calls"; exit 0 ;;
  "issue view")
    n="$3"
    [ -f "$G/$n.body" ] || { echo "GraphQL: Could not resolve to an issue ($n)" >&2; exit 1; }
    printf 'state:%s\ntitle:%s\nlabels:%s\nbody:\n' "$(cat "$G/$n.state")" "$(cat "$G/$n.title")" "$(cat "$G/$n.labels")"
    cat "$G/$n.body"
    ;;
  "issue edit")
    n="$3"; shift 3
    add="" del=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label) add="$2"; shift 2 ;;
        --remove-label) del="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cur="$(cat "$G/$n.labels")"
    new=""
    for l in $(printf '%s' "$cur" | tr ',' ' '); do
      skip=0
      for d in $(printf '%s' "$del" | tr ',' ' '); do [ "$l" = "$d" ] && skip=1; done
      [ "$skip" = 1 ] || new="${new:+$new,}$l"
    done
    for a in $(printf '%s' "$add" | tr ',' ' '); do
      case ",$new," in *",$a,"*) ;; *) new="${new:+$new,}$a" ;; esac
    done
    printf '%s' "$new" >"$G/$n.labels"
    ;;
  "issue comment")
    n="$3"; shift 3
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && { { cat "$2"; echo "-----"; } >>"$G/$n.comments"; }
      shift
    done
    ;;
  "api repos/o/r/issues/"*) [ -f "$G/${2##*/}.type" ] && cat "$G/${2##*/}.type"; exit 0 ;;
  *)
    case "$1" in
      api) n="${2##*/}"; [ -f "$G/$n.type" ] && cat "$G/$n.type"; exit 0 ;;
    esac
    echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
cat >"${BIN}/just" <<'STUB'
#!/usr/bin/env bash
G="$FAKE_GH"
case "$1" in
  ci | ci-docs)
    echo "==> just $1 running"
    if [ -e "$G/ci_fail" ]; then echo "error: lint failed: FAKE-CI-RED"; exit 1; fi
    echo "==> CI pipeline: all green FAKE-CI-GREEN"
    ;;
  --show) [ "$2" = verify ] && [ -e "$G/has_verify" ] ;;
  verify)
    echo "verify scenario $2"
    if [ -e "$G/verify_fail" ]; then echo "FAKE-VERIFY-RED"; exit 1; fi
    echo "FAKE-VERIFY-GREEN"
    ;;
  *) echo "stub just: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${BIN}/gh" "${BIN}/just"
export PATH="$BIN"

# ── 仓库：裸 origin + 主仓 ─────────────────────────────────────────────
git init -q --bare "${TMP}/origin.git"
git init -q "${TMP}/main"
(
  cd "${TMP}/main" || exit 1
  git remote add origin "${TMP}/origin.git"
  mkdir -p tools .github src docs/decisions core
  cp -R "${SRC}/tools/flow" tools/flow
  cp "${SRC}/tools/ci-paths.sh" tools/ci-paths.sh
  printf '+ core/**\n' >.github/core-paths.txt
  echo a >src/a.txt
  echo d >docs/d.md
  echo c >core/c.txt
  printf '# A\n\n- 状态：已采纳\n' >docs/decisions/2026-11-01-adopted.md
  printf '# P\n\n- 状态：提议\n' >docs/decisions/2026-11-01-proposed.md
  git add -A
  git commit -q -m init
  git push -q origin HEAD:refs/heads/main
)
export PPASS_WT_ROOT="${TMP}/wt"
M="${TMP}/main"

issue() { # issue <号> <标签> <标题> <范围 glob，空格分隔，空=无范围块> [类型] [正文附加行]
  local n="$1" labels="$2" title="$3" scope="$4" type="${5:-}" extra="${6:-}"
  set -f # 范围里的 ** 不能被 shell 展开
  printf 'OPEN' >"${FAKE_GH}/${n}.state"
  printf '%s' "$labels" >"${FAKE_GH}/${n}.labels"
  printf '%s' "$title" >"${FAKE_GH}/${n}.title"
  [ -z "$type" ] || printf '%s\n' "$type" >"${FAKE_GH}/${n}.type"
  {
    printf '## 🟥 挂号段\r\n\r\n**产品诉求**：x\r\n\r\n**范围（只许动这些）**：\r\n'
    if [ -n "$scope" ]; then
      printf '```\r\n'
      for g in $scope; do printf '%s\r\n' "$g"; done
      printf '```\r\n'
    fi
    printf '\r\n**验收场景**：y\r\n'
    [ -z "$extra" ] || printf '\r\n%s\r\n' "$extra"
  } >"${FAKE_GH}/${n}.body"
  set +f
}
labels_of() { cat "${FAKE_GH}/$1.labels"; }
has_lbl() { case ",$(labels_of "$1")," in *",$2,"*) return 0 ;; esac; return 1; }
comments_of() { cat "${FAKE_GH}/$1.comments" 2>/dev/null; }
on_origin() { git --git-dir="${TMP}/origin.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
START() { (cd "$M" && bash tools/flow/worker-start.sh "$@"); }
STUCK() { (cd "$M" && bash tools/flow/worker-stuck.sh "$@"); }
DONE() { (cd "$1" && bash tools/flow/worker-done.sh); }

# ── just start ────────────────────────────────────────────────────────
echo "== just start =="
issue 10 "status:inbox" "[T-10] not ready" "src/**"
if START 10 >/dev/null 2>&1; then bad "start 放行了非 ready 的卡"; else ok "start 拒绝非 ready（status:inbox）"; fi
has_lbl 10 "status:inbox" && ok "拒绝后标签不变" || bad "拒绝后标签被改了"
[ ! -d "${PPASS_WT_ROOT}/10-not-ready" ] && ok "拒绝后没建 worktree" || bad "拒绝后建了 worktree"

issue 11 "status:ready" "[T-11] no scope" ""
if START 11 >/dev/null 2>&1; then bad "start 放行了没有范围代码块的卡"; else ok "start 拒绝无「范围」代码块"; fi
has_lbl 11 "status:ready" && ok "拒绝后仍是 ready" || bad "拒绝后标签被改了"

issue 12 "status:ready" "[T-12] closed one" "src/**"
printf 'CLOSED' >"${FAKE_GH}/12.state"
if START 12 >/dev/null 2>&1; then bad "start 放行了已关闭的卡"; else ok "start 拒绝已关闭的卡"; fi

issue 13 "status:ready" "[T-13] Fix the Thing" "src/**" "Bug"
OUT="$(START 13 2>&1)"
rc=$?
[ "$rc" = 0 ] && ok "start 放行 ready + 有范围的卡（反证：与上面三条只差触发条件）" || bad "start 拒绝了合格的卡：$OUT"
check "worktree 建在 <根>/<号>-<slug>" test -d "${PPASS_WT_ROOT}/13-fix-the-thing"
check "Bug → fix/ 分支" git -C "${PPASS_WT_ROOT}/13-fix-the-thing" symbolic-ref --short HEAD
[ "$(git -C "${PPASS_WT_ROOT}/13-fix-the-thing" symbolic-ref --short HEAD)" = "fix/13-fix-the-thing" ] && ok "分支名 fix/13-fix-the-thing" || bad "分支名不对"
has_lbl 13 "status:doing" && ! has_lbl 13 "status:ready" && ok "标签 ready → doing" || bad "标签没从 ready 换成 doing"
[ -z "$(git -C "${PPASS_WT_ROOT}/13-fix-the-thing" config --get branch.fix/13-fix-the-thing.merge)" ] && ok "上游已解除（裸 git push 不会推到 main）" || bad "上游仍指向 origin/main"
printf '%s' "$OUT" | grep -q "just done" && ok "打印了下一步" || bad "没打印下一步"
issue 14 "status:ready" "[T-14] feature" "src/**" "Feature"
START 14 >/dev/null 2>&1
git -C "${PPASS_WT_ROOT}/14-feature" symbolic-ref --short HEAD | grep -q '^feat/14-' && ok "Feature → feat/" || bad "Feature 没推成 feat/"
issue 15 "status:ready" "[T-15] doc tweak" "docs/**" ""
START 15 >/dev/null 2>&1
git -C "${PPASS_WT_ROOT}/15-doc-tweak" symbolic-ref --short HEAD | grep -q '^docs/15-' && ok "Task + 全在 docs/ → docs/（hook 不认 chore）" || bad "Task 没推成 docs/"
issue 16 "status:ready,core" "[T-16] core card" "core/**" "Bug"
OUT="$(START 16 2>&1)"
printf '%s' "$OUT" | grep -q "只写复现" && ok "核心卡提示「只写复现、根因和两个修法」" || bad "核心卡没有提示"
printf '%s' "$OUT" | grep -q "按方案实现" && bad "没引用方案的核心卡出了「按方案实现」" || ok "反证：核心卡没引用方案 → 不出「按方案实现」"
issue 18 "status:ready,core" "[T-18] core adopted" "core/**" "Bug" "**ADR**：docs/decisions/2026-11-01-adopted.md"
OUT="$(START 18 2>&1)"
printf '%s' "$OUT" | grep -q "按方案实现" && ! printf '%s' "$OUT" | grep -q "只写复现" &&
  ok "核心卡引用已采纳方案 → 提示「按方案实现」，不出「只写复现」" || bad "核心卡引用已采纳方案仍没提示按方案实现：$OUT"
printf '%s' "$OUT" | grep -q "方案：docs/decisions/2026-11-01-adopted.md" && ok "提示里列出已采纳方案路径" || bad "提示里没列方案路径"
issue 19 "status:ready,core" "[T-19] core proposed" "core/**" "Bug" "**ADR**：docs/decisions/2026-11-01-proposed.md"
OUT="$(START 19 2>&1)"
printf '%s' "$OUT" | grep -q "只写复现" && ! printf '%s' "$OUT" | grep -q "按方案实现" &&
  ok "反证：核心卡只引用「提议」方案 → 仍提示「只写复现、根因和两个修法」" || bad "引用「提议」方案的核心卡提示不对：$OUT"
issue 17 "status:ready" "[T-17] plain" "src/**" "Bug"
OUT="$(START 17 2>&1)"
printf '%s' "$OUT" | grep -q "只写复现" && bad "非核心卡也出了核心提示" || ok "反证：非核心卡不出核心提示"

# 范围解析与 hook 里那份逐字相同（防漂移）；先证明比对本身会红
awk_block() { sed -n "/awk '\$/,/^')\"/p" "$1" | sed 1d; }
HOOK_AWK="$(awk_block "${SRC}/tools/hooks/pre-commit")"
LIB_AWK="$(awk_block "${SRC}/tools/flow/worker-lib.sh")"
[ -n "$HOOK_AWK" ] && [ "$HOOK_AWK" = "$LIB_AWK" ] && ok "范围解析 awk 与 tools/hooks/pre-commit 逐字一致" || bad "范围解析 awk 与 hook 漂移"
[ "$HOOK_AWK" != "$(printf '%s' "$HOOK_AWK" | sed 's/infence = 1/infence = 2/')" ] && ok "反证：改动一处比对即红" || bad "比对对改动不敏感"

# ── just done ─────────────────────────────────────────────────────────
echo "== just done =="
card() { # card <号> <标题> <范围> → 领卡并输出 worktree 目录
  issue "$1" "status:ready" "$2" "$3" "Bug"
  START "$1" >/dev/null 2>&1 || { echo "领卡失败" >&2; return 1; }
  ls -d "${PPASS_WT_ROOT}/$1-"*
}
commit_file() { # commit_file <目录> <文件> [内容]
  mkdir -p "$(dirname "$1/$2")"
  echo "${3:-x}" >"$1/$2"
  git -C "$1" add -A && git -C "$1" commit -q -s -m "change $2"
}

# 越界 → 不推、blocked；去掉越界后放行
W="$(card 20 "[T-20] scope" "src/**")"
commit_file "$W" src/ok.txt
commit_file "$W" docs/outside.md
if DONE "$W" >"${TMP}/o20" 2>&1; then bad "done 放行了越界改动"; else ok "done 拒绝范围外文件（退出码非 0）"; fi
on_origin "fix/20-scope" && bad "越界仍被推送" || ok "越界时没有推送"
has_lbl 20 "status:blocked" && ! has_lbl 20 "status:doing" && ok "越界时打 status:blocked（去掉 doing）" || bad "越界时标签不对"
comments_of 20 | grep -q "docs/outside.md" && ok "评论点名了越界文件" || bad "评论没点名越界文件"
git -C "$W" rm -q docs/outside.md && git -C "$W" commit -q -s -m "drop outside"
if DONE "$W" >"${TMP}/o20b" 2>&1; then ok "反证：撤掉越界后放行并推送"; else bad "撤掉越界后仍失败：$(tail -5 "${TMP}/o20b")"; fi
on_origin "fix/20-scope" && ok "绿时已推送到 origin" || bad "绿时没推送"
has_lbl 20 "status:review" && ! has_lbl 20 "status:blocked" && ! has_lbl 20 "status:doing" && ok "标签 → status:review，blocked 已去掉" || bad "交卡后标签不对：$(labels_of 20)"
C="$(comments_of 20)"
for k in "fix/20-scope" "E1" "FAKE-CI-GREEN" "just ci" "change src/ok.txt" ".evidence/20"; do
  printf '%s' "$C" | grep -qF -- "$k" && ok "回执含「${k}」" || bad "回执缺「${k}」"
done
printf '%s' "$C" | grep -qF "$HOME" && bad "回执泄露了本机家目录" || ok "回执不含本机家目录"
printf '%s' "$C" | grep -q "E3" && printf '%s' "$C" | grep -q "just verify 20" && bad "无 verify 时回执声称了 E3 验证" || ok "无 just verify 时不声称 E3"

# 门禁红 → 不推、blocked、评论贴错误末尾；去掉故障后放行
W="$(card 21 "[T-21] ci red" "src/**")"
commit_file "$W" src/r.txt
touch "${FAKE_GH}/ci_fail"
if DONE "$W" >"${TMP}/o21" 2>&1; then bad "门禁红时 done 仍成功"; else ok "门禁红 → done 退出码非 0"; fi
on_origin "fix/21-ci-red" && bad "门禁红仍推送了" || ok "门禁红时没有推送"
has_lbl 21 "status:blocked" && ok "门禁红时打 status:blocked" || bad "门禁红时没打 blocked"
comments_of 21 | grep -q "FAKE-CI-RED" && ok "评论贴了错误末尾（FAKE-CI-RED）" || bad "评论没贴错误末尾"
rm -f "${FAKE_GH}/ci_fail"
DONE "$W" >/dev/null 2>&1 && on_origin "fix/21-ci-red" && ok "反证：去掉故障后推送" || bad "去掉故障后仍失败"

# verify 存在且红 → blocked；绿 → 回执写 E3
touch "${FAKE_GH}/has_verify"
W="$(card 22 "[T-22] verify" "src/**")"
commit_file "$W" src/v.txt
touch "${FAKE_GH}/verify_fail"
if DONE "$W" >/dev/null 2>&1; then bad "verify 红时 done 仍成功"; else ok "just verify 红 → done 失败"; fi
on_origin "fix/22-verify" && bad "verify 红仍推送" || ok "verify 红时没有推送"
comments_of 22 | grep -q "FAKE-VERIFY-RED" && ok "评论贴了 verify 错误末尾" || bad "评论没贴 verify 错误"
rm -f "${FAKE_GH}/verify_fail"
DONE "$W" >/dev/null 2>&1 && on_origin "fix/22-verify" && ok "反证：verify 绿后推送" || bad "verify 绿后仍失败"
comments_of 22 | grep -q "E3" && comments_of 22 | grep -q "FAKE-VERIFY-GREEN" && ok "有 verify 时回执写 E3 并贴输出" || bad "回执缺 E3 / verify 输出"
rm -f "${FAKE_GH}/has_verify"

# 纯文档走 ci-docs
W="$(card 23 "[T-23] docs only" "docs/**")"
commit_file "$W" docs/n.md
DONE "$W" >/dev/null 2>&1
comments_of 23 | grep -q "just ci-docs" && ok "纯文档改动跑 just ci-docs" || bad "纯文档没走 ci-docs"
comments_of 20 | grep -q "just ci-docs" && bad "代码改动误走 ci-docs" || ok "反证：代码改动走 just ci"

# 核心改动无 core 标签 → blocked；
W="$(card 24 "[T-24] core hit" "core/** src/**")"
commit_file "$W" core/x.txt
if DONE "$W" >/dev/null 2>&1; then bad "无 core 标签却放行了核心改动"; else ok "核心改动且无 core 标签 → 拒绝"; fi
has_lbl 24 "status:blocked" && ok "核心命中时打 status:blocked" || bad "核心命中没打 blocked"
printf 'status:blocked,core' >"${FAKE_GH}/24.labels"
DONE "$W" >/dev/null 2>&1 && ok "反证：带 core 标签放行" || bad "带 core 标签仍被拒"

# 分支落后 main → 拒绝但不打 blocked
W="$(card 25 "[T-25] behind" "src/**")"
commit_file "$W" src/b.txt
(cd "$M" && echo z >src/z.txt && git add -A && git commit -q -m "main moves" && git push -q origin HEAD:refs/heads/main)
if DONE "$W" >"${TMP}/o25" 2>&1; then bad "落后 main 仍放行"; else ok "落后 origin/main → 拒绝"; fi
has_lbl 25 "status:blocked" && bad "落后被当成红打了 blocked" || ok "落后只提示 rebase，不打 blocked"
grep -q "rebase" "${TMP}/o25" && ok "提示了 git rebase origin/main" || bad "没提示 rebase"
git -C "$W" rebase -q origin/main
DONE "$W" >/dev/null 2>&1 && on_origin "fix/25-behind" && ok "反证：rebase 后放行" || bad "rebase 后仍失败"

# 主仓工作区、未提交改动
if (cd "$M" && bash tools/flow/worker-done.sh) >/dev/null 2>&1; then bad "在主仓工作区 done 也成功"; else ok "done 拒绝在主仓工作区运行"; fi
W="$(card 26 "[T-26] dirty" "src/**")"
commit_file "$W" src/d.txt
echo dirty >>"$W/src/d.txt"
if DONE "$W" >/dev/null 2>&1; then bad "工作区不干净仍放行"; else ok "done 拒绝未提交改动"; fi
git -C "$W" checkout -q -- src/d.txt
DONE "$W" >/dev/null 2>&1 && ok "反证：干净后放行" || bad "干净后仍失败"

# ── just stuck ────────────────────────────────────────────────────────
echo "== just stuck =="
issue 30 "status:doing" "[T-30] stuck" "src/**"
if STUCK 30 "" >/dev/null 2>&1; then bad "stuck 接受了空原因"; else ok "stuck 拒绝空原因"; fi
has_lbl 30 "status:blocked" && bad "空原因也打了 blocked" || ok "空原因不改标签"
STUCK 30 "命中核心：根因在配对握手；修法 A / 修法 B" >/dev/null 2>&1 && ok "stuck 带原因成功" || bad "stuck 带原因失败"
has_lbl 30 "status:blocked" && ! has_lbl 30 "status:doing" && ok "stuck 打 status:blocked 并去掉 doing" || bad "stuck 标签不对"
comments_of 30 | grep -q "命中核心：根因在配对握手" && ok "stuck 评论含原因" || bad "stuck 评论缺原因"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
