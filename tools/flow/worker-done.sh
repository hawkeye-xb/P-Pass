#!/usr/bin/env bash
# just done：在卡 worktree 里交卡。
#   门禁（just ci / 纯文档 just ci-docs）→ just verify <号>（命令存在才跑）→ 核对改动只含范围内文件
#   → 全绿才 git push → 在 issue 贴回执 → status:doing→status:review。
# 任何一步红：不推送，在 issue 写明停在哪并贴错误末尾，打 status:blocked，退出码非 0。
# 前置不满足（不在卡 worktree、没提交、工作区不干净、落后 main）只报错退出，不打 blocked。
# 环境: PPASS_NO_LOCK=1 不套 lockf；PPASS_HOOK_REPO 覆盖仓库。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

command -v gh >/dev/null 2>&1 || die "找不到 gh"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "不在 git 仓库里"
cd "$TOP" || exit 1
FLOW_PATHS="${TOP}/tools/ci-paths.sh"
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ "$BRANCH" =~ ^(feat|fix|docs|test|ci)/([0-9]+)-. ]]; then N="${BASH_REMATCH[2]}"; else
  die "当前分支「${BRANCH:-detached HEAD}」不是卡分支" "cd 到 just start 给你的那个目录再跑 just done。"
fi
GIT_DIR_ABS="$(cd "$(git rev-parse --absolute-git-dir)" && pwd -P)"
COMMON_ABS="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
[ "$GIT_DIR_ABS" != "$COMMON_ABS" ] || die "你在主仓工作区里，不是卡 worktree" "cd 到 just start 给你的那个目录再跑 just done。"
REPO="$(flow_repo)"

[ -z "$(git status --porcelain)" ] || die "工作区有未提交的改动" "$(git status --short | head -5)" \
  "先 git add + git commit -s；不该提交的改动撤掉。"
git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" || die "取不到 origin/main（离线？）"
[ "$(git rev-list --count origin/main..HEAD)" -gt 0 ] || die "本分支相对 origin/main 没有任何提交" "先提交改动，或没有改动就 just stuck。"
if ! git merge-base --is-ancestor origin/main HEAD; then
  die "分支落后 origin/main $(git rev-list --count HEAD..origin/main) 个提交" \
    "先跟上：git rebase origin/main，解冲突后重跑 just done。"
fi

EVID_DIR="$(dirname "$TOP")/.evidence/${N}"
mkdir -p "$EVID_DIR"
EVID_SHOW="$(basename "$(dirname "$TOP")")/.evidence/${N}"
FAILS_FILE="${EVID_DIR}/fail-count"

# 红：不推送、写评论、打 blocked、非 0 退出。
fail_blocked() { # fail_blocked <停在哪> <日志文件|空> [补充行]
  local step="$1" log="$2" extra="${3:-}" cnt tmp
  cnt=$(($(cat "$FAILS_FILE" 2>/dev/null || echo 0) + 1))
  printf '%s' "$cnt" >"$FAILS_FILE"
  tmp="$(mktemp)"
  {
    echo "**交卡失败：停在「${step}」，未推送**"
    echo
    echo "分支：\`${BRANCH}\`（累计第 ${cnt} 次交卡失败）"
    [ -z "$extra" ] || { echo; printf '%s\n' "$extra" | scrub; }
    if [ -n "$log" ] && [ -s "$log" ]; then
      echo
      echo '```'
      tail -n 30 "$log" | scrub
      echo '```'
    fi
  } >"$tmp"
  flow_comment "$N" "$tmp"
  rm -f "$tmp"
  flow_labels "$N" "status:blocked" "status:doing,status:review,status:ready"
  printf '\n✗ 交卡失败，停在：%s。未推送，#%s 已打 status:blocked。\n' "$step" "$N" >&2
  [ -z "$extra" ] || printf '  %s\n' "$extra" >&2
  [ -z "$log" ] || { printf '  日志：%s/%s\n' "$EVID_SHOW" "$(basename "$log")" >&2; tail -n 15 "$log" >&2; }
  if [ "$cnt" -ge 3 ]; then
    printf '  已连红 %s 次：别再重试，换思路；确实卡住就 just stuck %s "连红 3 次：<停在哪>"。\n' "$cnt" "$N" >&2
  else
    printf '  修好后重跑 just done（成功时会自动去掉 blocked）。\n' >&2
  fi
  exit 1
}

flow_load_issue "$N"
flow_parse_scope "$I_BODY"
[ "${#GLOBS[@]}" -gt 0 ] || fail_blocked "读范围" "" "#${N} 没有可读的「范围」代码块"

# ── 1. 改动清单只含范围内文件；核心判定 ───────────────────────────────
FILES="$(git -c core.quotepath=false diff --name-only --no-renames origin/main...HEAD)"
OUTSIDE=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  flow_in_scope "$f" || OUTSIDE+=("$f")
done <<EOF2
$FILES
EOF2
if [ "${#OUTSIDE[@]}" -gt 0 ]; then
  fail_blocked "核对范围" "" "$(printf '越界文件：%s\n' "${OUTSIDE[@]}")
范围：${GLOBS[*]}
撤掉越界改动重新交卡；确需改这些文件，just stuck ${N} \"需改范围外文件：…\"。"
fi
CORE="$(printf '%s\n' "$FILES" | bash "$FLOW_PATHS" core - "${TOP}/.github/core-paths.txt" 2>/dev/null)"
if [ "$CORE" != "false" ] && ! has_label core; then
  fail_blocked "核心判定" "" "改动命中核心路径（.github/core-paths.txt）而 #${N} 没有 core 标签：只写复现、根因和两个修法，撤回代码改动，just stuck ${N} \"命中核心：…\"。"
fi

# ── 2. 门禁 ───────────────────────────────────────────────────────────
docs_only=1
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in docs/* | *.md | release/notes/*) ;; *) docs_only=0 ;; esac
done <<EOF2
$FILES
EOF2
if [ "$docs_only" = 1 ]; then GATE="just ci-docs"; else GATE="just ci"; fi

run_logged() { # run_logged <日志> <命令...>：重编译套 lockf（有就用）
  local log="$1"
  shift
  if [ -z "${PPASS_NO_LOCK:-}" ] && command -v lockf >/dev/null 2>&1; then
    lockf -k /tmp/ppass-heavy-build.lock "$@" >"$log" 2>&1
  else
    "$@" >"$log" 2>&1
  fi
}

echo "==> ${GATE}（日志：${EVID_SHOW}/gate.log）"
run_logged "${EVID_DIR}/gate.log" $GATE || fail_blocked "${GATE}" "${EVID_DIR}/gate.log"
GATE_TAIL="$(tail -n 5 "${EVID_DIR}/gate.log" | scrub)"

# ── 3. 验收场景（just verify 存在才跑）──────────────────────────────────
VERIFY_STATE="skipped"
VERIFY_TAIL=""
if just --show verify >/dev/null 2>&1; then
  echo "==> just verify ${N}（日志：${EVID_SHOW}/verify.log）"
  run_logged "${EVID_DIR}/verify.log" just verify "$N" || fail_blocked "just verify ${N}" "${EVID_DIR}/verify.log"
  VERIFY_STATE="passed"
  VERIFY_TAIL="$(tail -n 8 "${EVID_DIR}/verify.log" | scrub)"
else
  echo "⚠ 本仓还没有 just verify：只跑了 ${GATE}。验收场景需按 issue 上写的步骤手工做真机验证并回帖。"
fi

# 门禁期间 main 可能又动了：推之前再确认一次（pre-push hook 也会拦，这里提前给出明白话）。
git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" || die "取不到 origin/main（离线？），没推"
git merge-base --is-ancestor origin/main HEAD ||
  die "门禁期间 origin/main 前进了，分支落后" "git rebase origin/main，重跑 just done。"

# ── 4. 推送（显式 refspec，不依赖上游设置）──────────────────────────────
PUSH_LOG="${EVID_DIR}/push.log"
git push -u origin "HEAD:refs/heads/${BRANCH}" >"$PUSH_LOG" 2>&1 || fail_blocked "git push" "$PUSH_LOG"

# ── 5. 回执 ───────────────────────────────────────────────────────────
if [ "$VERIFY_STATE" = "passed" ]; then
  LEVEL="E1（${GATE}）+ E3（just verify ${N}）"
else
  LEVEL="E1（${GATE}）；验收场景未经 just verify 自动验证，E3 需手工补"
fi
flow_ensure_review_label
tmp="$(mktemp)"
{
  echo "**worker 已交卡**"
  echo
  echo "- 分支：\`${BRANCH}\`（已推送，未开 PR）"
  echo "- 提交："
  git log --format='  - `%h` %s' origin/main..HEAD
  echo "- 改动清单（只含范围内文件）："
  echo '```'
  git diff --stat origin/main...HEAD
  echo '```'
  echo "- 门禁：\`${GATE}\` 通过。输出末尾："
  echo '```'
  printf '%s\n' "$GATE_TAIL"
  echo '```'
  if [ "$VERIFY_STATE" = "passed" ]; then
    echo "- 验收：\`just verify ${N}\` 通过。输出末尾："
    echo '```'
    printf '%s\n' "$VERIFY_TAIL"
    echo '```'
  else
    echo "- 验收：本仓暂无 \`just verify\`，未自动验证。"
  fi
  echo "- 证据等级：${LEVEL}"
  echo "- 证据目录（本机，不进 git）：\`${EVID_SHOW}\`"
} >"$tmp"
flow_comment "$N" "$tmp"
rm -f "$tmp"
flow_labels "$N" "status:review" "status:doing,status:blocked"
rm -f "$FAILS_FILE"

echo
echo "✅ #${N} 已交卡：${BRANCH} 已推送，标签 → status:review，回执已贴。"
echo "   证据等级：${LEVEL}"
echo "   下一步：just start <下一张卡的 issue号>；owner 会攒批合入。不要自己开 PR。"
