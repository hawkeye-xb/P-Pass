#!/usr/bin/env bash
# owner 流程脚本（tools/flow/owner-*.sh）的公共函数。只被 source，不单独执行。
# 说明见 docs/runbook/owner.md。
#
# 设计口径：每一步都有自动判定；红了或判定不了，一律经 die_stuck 走统一出口
# （tools/flow/owner-stuck.sh 写 issue / 评论），然后非 0 退出。脚本里没有「先跳过」「先忽略」。
#
# 可注入的环境变量（测试用，平时不设）：
#   PPASS_OWNER_REPO        owner/repo，默认从 origin 的 URL 解析
#   PPASS_OWNER_STATE_DIR   批次状态与报告目录，默认 <git 公共目录>/ppass-batch
#   PPASS_OWNER_TODAY       批次日期（YYYY-MM-DD），默认今天
#   PPASS_OWNER_WT_ROOT     批次 worktree 的父目录，默认主仓旁边的 P-Pass-wt/
#   PPASS_OWNER_JUST        just 命令，默认 just
#   PPASS_HEAVY_LOCK        重编译互斥锁文件，默认 /tmp/ppass-heavy-build.lock

set -uo pipefail

FLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "✗ 不在 git 仓库里" >&2
  exit 1
}
COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
STATE_DIR="${PPASS_OWNER_STATE_DIR:-${COMMON_DIR}/ppass-batch}"
JUST="${PPASS_OWNER_JUST:-just}"
HEAVY_LOCK="${PPASS_HEAVY_LOCK:-/tmp/ppass-heavy-build.lock}"

say() { printf '%s\n' "$*" >&2; }
step() { printf '\n==> %s\n' "$*" >&2; }
okmsg() { printf 'ok: %s\n' "$*" >&2; }

# 停下的唯一出口：记录到 GitHub（owner-stuck.sh），然后退出 1。
#   die_stuck "<原因>" [--issue N | --pr N] [--log <文件>]
die_stuck() {
  local reason="$1"
  shift
  printf '\n✗ 停下：%s\n' "$reason" >&2
  bash "${FLOW_DIR}/owner-stuck.sh" "$reason" "$@" >&2 ||
    say "✗ 写 issue 也失败了：把上面的原因原样转告产品负责人，不要继续"
  exit 1
}

# 不需要写 issue 的拒绝（用法错、前置条件没满足、下一步命令已经明确）：打印原因与下一步，退出 2。
refuse() {
  printf '\n✗ 拒绝：%s\n' "$1" >&2
  shift
  local l
  for l in "$@"; do printf '    %s\n' "$l" >&2; done
  exit 2
}

repo_slug() {
  local r="${PPASS_OWNER_REPO:-}"
  if [ -z "$r" ]; then
    r="$(git config --get remote.origin.url 2>/dev/null |
      sed -E -e 's#/+$##' -e 's#\.git$##' -e 's#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
  fi
  [[ "$r" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 1
  printf '%s\n' "$r"
}
REPO="$(repo_slug)" || {
  echo "✗ 解析不出 GitHub 仓库（origin URL 不认识），设 PPASS_OWNER_REPO=<owner>/<repo>" >&2
  exit 1
}

need_gh() {
  command -v gh >/dev/null 2>&1 || refuse "找不到 gh" "装好并登录 gh（gh auth login）后重跑。"
}

today() { printf '%s\n' "${PPASS_OWNER_TODAY:-$(date +%Y-%m-%d)}"; }

fetch_origin() {
  git fetch -q --prune origin 2>/dev/null || die_stuck "git fetch origin 失败（离线或凭据问题），判断不了 main 的最新状态"
}

# ── 批次状态（每个批次分支一个目录，报告也放这里；不进 git）────────────
current_batch_branch() {
  local b
  b="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  case "$b" in batch/*) printf '%s\n' "$b" ;; *) return 1 ;; esac
}
batch_dir() { printf '%s/%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr '/' '_')"; }
state_get() { # state_get <批次分支> <键>
  local f
  f="$(batch_dir "$1")/state"
  [ -f "$f" ] || return 1
  sed -n "s/^$2=//p" "$f" | tail -1
}
state_set() { # state_set <批次分支> <键> <值>（同键覆盖）
  local d f
  d="$(batch_dir "$1")"
  f="${d}/state"
  mkdir -p "$d"
  touch "$f"
  grep -v "^$2=" "$f" >"${f}.tmp" || true
  printf '%s=%s\n' "$2" "$3" >>"${f}.tmp"
  mv "${f}.tmp" "$f"
}
require_batch() { # 必须在批次分支上、工作区干净、有状态文件
  BATCH="$(current_batch_branch)" ||
    refuse "当前分支不是 batch/*" "先 just batch-open <主题> <issue...>，再到它打印的 worktree 里跑。"
  [ -f "$(batch_dir "$BATCH")/state" ] ||
    refuse "「${BATCH}」没有批次状态文件（不是 just batch-open 开的？）" "用 just batch-open 重新开批次。"
  [ -z "$(git status --porcelain --untracked-files=no)" ] ||
    refuse "工作区有未提交改动" "批次分支上不许手改代码。改动属于哪张卡就退回那张卡，git stash 后重跑。"
}

# ── 卡与分支 ────────────────────────────────────────────────────────
# 卡号 → 远端卡分支（origin/<type>/<号>-<slug>）。恰好一条才算数。
card_branch() {
  local n="$1" list cnt
  list="$(git for-each-ref --format='%(refname:short)' "refs/remotes/origin/" |
    grep -E "^origin/(feat|fix|docs|test|ci)/${n}-." || true)"
  cnt="$(printf '%s' "$list" | grep -c . || true)"
  if [ "$cnt" -ne 1 ]; then
    CARD_ERR="远端卡分支应恰好 1 条 <type>/${n}-<slug>，实际 ${cnt} 条${list:+：$(printf '%s' "$list" | tr '\n' ' ')}"
    return 1
  fi
  printf '%s\n' "${list#origin/}"
}

card_files() { # card_files <分支>：卡分支相对 main 的改动（改名算新旧两个路径）
  git -c core.quotepath=false diff --name-only --no-renames "origin/main...origin/$1"
}

# issue 正文里「范围」段的第一个代码块（与 tools/hooks/pre-commit 同一解析）。
scope_globs() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    !insec && /^\*\*范围/ { insec = 1; next }
    insec && !infence && /^[[:space:]]*```/ { infence = 1; next }
    infence && /^[[:space:]]*```/ { exit }
    infence { print; next }
    insec && (/^\*\*[^*]+\*\*/ || /^#/) { exit }
  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^\./##' |
    grep -v -e '^$' -e '^#' | sed -e 's#/$#/**#'
}

# 「已采纳」方案解析（adopted_adrs / decision_refs）与 worker 共用一份。
# shellcheck source=tools/flow/decision-lib.sh
source "${FLOW_DIR}/decision-lib.sh"

# 读 issue：设置 ISSUE_TITLE / ISSUE_LABELS（逗号分隔）/ ISSUE_BODY / ISSUE_STATE。
load_issue() {
  local out
  out="$(gh issue view "$1" -R "$REPO" --json title,labels,body,state \
    --jq '"title:" + .title, "state:" + .state, "labels:" + ([.labels[].name] | join(",")), .body' 2>&1)" || {
    CARD_ERR="读不到 #$1：$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    return 1
  }
  ISSUE_TITLE="$(printf '%s\n' "$out" | sed -n '1s/^title://p')"
  ISSUE_STATE="$(printf '%s\n' "$out" | sed -n '2s/^state://p')"
  ISSUE_LABELS="$(printf '%s\n' "$out" | sed -n '3s/^labels://p')"
  ISSUE_BODY="$(printf '%s\n' "$out" | sed '1,3d')"
}
has_label() { case ",${ISSUE_LABELS}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# 一张卡能不能进批次。成功时设置 CARD_BRANCH / CARD_SHA / CARD_CORE(true|false) / CARD_ADRS；
# 失败时 CARD_ERR 是一句可以直接写进 issue 的原因，CARD_BLOCK=1 表示该把卡打回 status:blocked。
check_card() {
  local n="$1" files outside f hit core globs bad_dco
  CARD_ERR=""
  CARD_BLOCK=0
  CARD_ADRS=""
  load_issue "$n" || return 1
  [ "$ISSUE_STATE" = "OPEN" ] || { CARD_ERR="#${n} 不是打开状态（${ISSUE_STATE}）"; return 1; }
  has_label "status:review" || { CARD_ERR="#${n} 没有 status:review 标签（worker 还没交卡）"; return 1; }
  has_label "needs:product" && { CARD_ERR="#${n} 带 needs:product，还在等产品负责人拍板"; return 1; }
  CARD_BRANCH="$(card_branch "$n")" || { CARD_BLOCK=1; return 1; }
  CARD_SHA="$(git rev-parse "origin/${CARD_BRANCH}")"
  if ! git merge-base --is-ancestor origin/main "origin/${CARD_BRANCH}"; then
    CARD_BLOCK=1
    CARD_ERR="卡分支 ${CARD_BRANCH} 不包含最新 origin/main：worker 先 git rebase origin/main、重跑验证、再推"
    return 1
  fi
  files="$(card_files "$CARD_BRANCH")"
  [ -n "$files" ] || { CARD_BLOCK=1; CARD_ERR="卡分支 ${CARD_BRANCH} 相对 main 没有改动"; return 1; }

  # 本地 hook 的逃生口留下的尾行：绕过了核心与范围检查，owner 不能自己放行。
  if git log --format=%B "origin/main..origin/${CARD_BRANCH}" | grep -q '^Hook-Bypass:'; then
    CARD_BLOCK=1
    CARD_ERR="卡分支 ${CARD_BRANCH} 有带 Hook-Bypass 尾行的提交（绕过了本地核心/范围检查），要产品负责人或 owner 人工核对后再进批次"
    return 1
  fi
  bad_dco="$(bash "${REPO_ROOT}/tools/check-dco.sh" "origin/main..origin/${CARD_BRANCH}" 2>&1 >/dev/null)" || {
    CARD_BLOCK=1
    CARD_ERR="卡分支 ${CARD_BRANCH} 的 DCO 签名不全：$(printf '%s' "$bad_dco" | head -3 | tr '\n' ' ')"
    return 1
  }

  globs="$(scope_globs "$ISSUE_BODY")"
  [ -n "$globs" ] || { CARD_BLOCK=1; CARD_ERR="#${n} 没有可读的「范围」代码块"; return 1; }
  local garr=() g
  while IFS= read -r g; do garr+=("$g"); done <<EOF
$globs
EOF
  outside=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit="$(printf '%s\n' "$f" | bash "${REPO_ROOT}/tools/ci-paths.sh" hit - "${garr[@]}" 2>/dev/null)"
    [ "$hit" = "true" ] || outside="${outside} ${f}"
  done <<EOF
$files
EOF
  [ -z "$outside" ] || { CARD_BLOCK=1; CARD_ERR="卡分支改了「范围」外的文件：${outside# }"; return 1; }

  core="$(printf '%s\n' "$files" | bash "${REPO_ROOT}/tools/ci-paths.sh" core - "${REPO_ROOT}/.github/core-paths.txt" 2>/dev/null)"
  CARD_CORE=false
  if [ "$core" != "false" ]; then
    CARD_CORE=true
    has_label core || {
      CARD_BLOCK=1
      CARD_ERR="改动命中核心（.github/core-paths.txt），但 #${n} 没有 core 标签"
      return 1
    }
    CARD_ADRS="$(adopted_adrs "$ISSUE_BODY")"
    [ -n "$CARD_ADRS" ] || {
      CARD_BLOCK=1
      CARD_ERR="核心卡必须在正文引用 docs/decisions/ 下状态为「已采纳」的 ADR（origin/main 上），#${n} 没有；先按 AGENTS.md 红线 6 定案"
      return 1
    }
  fi
  return 0
}

# 两条卡分支能否同批：没有共同文件，且试合并（git merge-tree）无冲突。
branches_compatible() { # branches_compatible <分支A> <分支B>；不兼容时 COMPAT_ERR 写原因
  local common
  common="$(comm -12 <(card_files "$1" | sort -u) <(card_files "$2" | sort -u) | head -3 | tr '\n' ' ')"
  if [ -n "$common" ]; then
    COMPAT_ERR="${1} 与 ${2} 改了同一文件：${common% }"
    return 1
  fi
  if ! git merge-tree --write-tree "origin/$1" "origin/$2" >/dev/null 2>&1; then
    COMPAT_ERR="${1} 与 ${2} 试合并有冲突"
    return 1
  fi
  return 0
}

# 把卡打回 status:blocked，并写明原因（评论）。
block_card() { # block_card <号> <原因>
  bash "${FLOW_DIR}/owner-stuck.sh" "$2" --issue "$1" >&2
}

# 换标签：去掉所有 status:*，加上目标状态。
set_status() { # set_status <号> <status:xxx>
  local n="$1" to="$2" rm="" l
  load_issue "$n" || return 1
  for l in $(printf '%s' "$ISSUE_LABELS" | tr ',' ' '); do
    case "$l" in status:*) [ "$l" = "$to" ] || rm="${rm:+${rm},}${l}" ;; esac
  done
  if [ -n "$rm" ]; then
    gh issue edit "$n" -R "$REPO" --add-label "$to" --remove-label "$rm" >/dev/null
  else
    gh issue edit "$n" -R "$REPO" --add-label "$to" >/dev/null
  fi
}

# 重编译互斥：同机只跑一个大编译。没有 lockf（非 macOS）时直接跑。
heavy() { # 经 tools/heavy-lock 排队（可重入，#1308）
  PPASS_HEAVY_LOCK="$HEAVY_LOCK" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/heavy-lock" "$@"
}
