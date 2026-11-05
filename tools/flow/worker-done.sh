#!/usr/bin/env bash
# just done [--accepted "<时间>"]：在卡 worktree 里交卡。
#   核对改动只含范围内文件 → 推送前自查（证据目录里的 self-review.md，#1447）→ 门禁（按改动路径挑）
#   → just verify <号>（命令存在才跑）→ 全绿才 git push → 在每张卡贴回执 → status:doing→status:review
#   → 写好 PR 正文、单独一行打印开 PR 的命令（gh pr create …，由执行者自己运行；脚本不开 PR，见第 6 步）。
# 代码没变就复用验证（#1423）：门禁与 verify 都通过时记下 HEAD 的树哈希与门禁清单；下次树与清单都没变，
#   不重跑，回执写「复用 <时间> 的验证」。改任何一个字节（树变了）都重跑。
# 多卡分支（just start <号> <号>…）：卡号读 git config branch.<分支>.ppasscards，范围取并集。
# 用户看得到的改动（界面与文案路径、核心路径，口径同 owner-triage.sh）：开草稿 PR，
# 正文写「待产品负责人真机验收」，CI 与评审并行跑；验收后补验收行再 gh pr ready。
# 只改更新说明（release/notes/**，可带 CHANGELOG.md，#1448）：验收方式是文案确认，行写「产品负责人 <时间> 文案确认通过」。
# 交卡时已验收过可给 --accepted "<时间>"：正文直接写对应的验收行，开正式 PR。
# 合入前由 CI 的 acceptance gate 检查验收行（tools/flow/acceptance-gate.sh）。
# 任何一步红：不推送，在 issue 写明停在哪并贴错误末尾，打 status:blocked，退出码非 0。
# 前置不满足（不在卡 worktree、没提交、工作区不干净、与 main 冲突、没写自查）只报错退出，不打 blocked。
# 分支落后 main 但没有冲突：只提示，照推（PR 上的 CI 测合并后的结果，main 保护不要求跟上最新，#1423）。
# 环境: PPASS_NO_LOCK=1 不套 lockf；PPASS_HOOK_REPO 覆盖仓库。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

ACCEPTED=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --accepted) ACCEPTED="${2:-}"; shift 2 || shift ;;
    *) die "用法: just done [--accepted \"<产品负责人验收通过的时间>\"]" ;;
  esac
done

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
# 这条分支关联的卡：主卡 + 分支配置里记的其余卡（与 tools/hooks/pre-commit 同口径）。
CARDS="$(git config --get "branch.${BRANCH}.ppasscards" 2>/dev/null)" || CARDS=""
case " ${CARDS} " in *" ${N} "*) ;; *) CARDS="${N}${CARDS:+ ${CARDS}}" ;; esac
for c in $CARDS; do [[ "$c" =~ ^[0-9]+$ ]] || die "分支记录的卡号「${c}」不对" "git config --get branch.${BRANCH}.ppasscards"; done
CARDS_SHOW="#$(printf '%s' "$CARDS" | sed 's/  */、#/g')"

[ -z "$(git status --porcelain)" ] || die "工作区有未提交的改动" "$(git status --short | head -5)" \
  "先 git add + git commit -s；不该提交的改动撤掉。"
git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" || die "取不到 origin/main（离线？）"
[ "$(git rev-list --count origin/main..HEAD)" -gt 0 ] || die "本分支相对 origin/main 没有任何提交" "先提交改动，或没有改动就 just stuck。"
# 落后 main：没有冲突只提示（照推）；有冲突才停（git merge-tree 判，git ≥ 2.38；判不了只提示）。
check_main() { # check_main <时机说明>
  local behind rc=0
  git merge-base --is-ancestor origin/main HEAD && return 0
  behind="$(git rev-list --count HEAD..origin/main)"
  git merge-tree --write-tree --no-messages origin/main HEAD >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo "⚠ ${1}分支落后 origin/main ${behind} 个提交，没有冲突：照推（PR 上的 CI 测合并后的结果）。" ;;
    1) die "${1}分支与 origin/main 有冲突（落后 ${behind} 个提交）" "先跟上：git rebase origin/main，解冲突后重跑 just done。" ;;
    *) echo "⚠ ${1}分支落后 origin/main ${behind} 个提交；本机 git 判不了冲突（merge-tree 退出码 ${rc}），照推，冲突看 PR 页面。" ;;
  esac
}
check_main ""

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
  for c in $CARDS; do
    flow_comment "$c" "$tmp"
    flow_labels "$c" "status:blocked" "status:doing,status:review,status:ready"
  done
  rm -f "$tmp"
  printf '\n✗ 交卡失败，停在：%s。未推送，%s 已打 status:blocked。\n' "$step" "$CARDS_SHOW" >&2
  [ -z "$extra" ] || printf '  %s\n' "$extra" >&2
  [ -z "$log" ] || { printf '  日志：%s/%s\n' "$EVID_SHOW" "$(basename "$log")" >&2; tail -n 15 "$log" >&2; }
  if [ "$cnt" -ge 3 ]; then
    printf '  已连红 %s 次：别再重试，换思路；确实卡住就 just stuck %s "连红 3 次：<停在哪>"。\n' "$cnt" "$N" >&2
  else
    printf '  修好后重跑 just done（成功时会自动去掉 blocked）。\n' >&2
  fi
  exit 1
}

ALL_GLOBS=()
IS_CORE=0
TITLES=()
for c in $CARDS; do
  flow_load_issue "$c"
  flow_parse_scope "$I_BODY"
  [ "${#GLOBS[@]}" -gt 0 ] || fail_blocked "读范围" "" "#${c} 没有可读的「范围」代码块"
  ALL_GLOBS+=("${GLOBS[@]}")
  has_label core && IS_CORE=1
  TITLES+=("$I_TITLE")
done
GLOBS=("${ALL_GLOBS[@]}")

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
if [ "$CORE" != "false" ] && [ "$IS_CORE" = 0 ]; then
  fail_blocked "核心判定" "" "改动命中核心路径（.github/core-paths.txt）而 ${CARDS_SHOW} 都没有 core 标签：只写复现、根因和两个修法，撤回代码改动，just stuck ${N} \"命中核心：…\"。"
fi

# ── 1b. 推送前自查（#1447）─────────────────────────────────────────────
# CI 评审的同一份清单前移到推送前：执行者用自己的模型对照清单自查，结论写进证据目录的 self-review.md，
# 首行「自查对象：<HEAD 的树哈希>」（代码改了就要重新自查）。结论进回执与 PR 正文，CI 评审可对照。
TREE="$(git rev-parse 'HEAD^{tree}')"
SELF_REVIEW="${EVID_DIR}/self-review.md"
SELF_REVIEW_SHOW="${EVID_SHOW}/self-review.md"
# 可能漏改的同类旧写法：diff 里删掉的行，全仓仍出现的位置（只是提示，删掉的行是通用写法时会有噪音）。
stale_hints() {
  local line hit
  git -c core.quotepath=false diff -U0 --no-color origin/main...HEAD |
    sed -n 's/^-\([^-].*\)$/\1/p' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    awk 'length($0) >= 16' | sort -u | head -n 60 |
    while IFS= read -r line; do
      git grep -n -I -F -e "$line" -- . 2>/dev/null | head -n 3 | while IFS= read -r hit; do
        printf '  %s\n      删掉的：%s\n' "$(printf '%s' "$hit" | cut -c1-160)" "$(printf '%s' "$line" | cut -c1-120)"
      done
    done | head -n 60
}
self_review_ok() {
  [ -s "$SELF_REVIEW" ] || return 1
  [ "$(grep -v '^[[:space:]]*$' "$SELF_REVIEW" | head -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//')" = "自查对象：${TREE}" ] || return 1
  grep -q '^## 范围与验收' "$SELF_REVIEW" && grep -q '^## 同类写法' "$SELF_REVIEW"
}
if ! self_review_ok; then
  {
    echo
    if [ -s "$SELF_REVIEW" ]; then
      echo "✗ 推送前自查结论不是当前代码的（或缺段落）：${SELF_REVIEW_SHOW}"
    else
      echo "✗ 推送前还没自查：没有 ${SELF_REVIEW_SHOW}"
    fi
    echo
    echo "按 CI 评审的同一份清单（tools/flow/review-prompt.md）对 git diff origin/main...HEAD 自查："
    sed -n '/^## 你要做的/,/^## 你能用什么/p' "${TOP}/tools/flow/review-prompt.md" | sed '1d;$d' | sed 's/^/  /'
    echo
    echo "重点：每个改动的规则、判定、写法、文案，用 git grep 搜全仓同类写法（AGENTS.md、模板、justfile、runbook、"
    echo "另一端、另一个脚本里的同一份判定），逐条写处理结果。"
    hints="$(stale_hints)"
    if [ -n "$hints" ]; then
      echo
      echo "机械提示：本分支删掉的行，全仓还有这些地方仍是旧写法（可能漏改；是通用写法就写明不用改）："
      printf '%s\n' "$hints"
    fi
    echo
    echo "把结论写进 ${SELF_REVIEW}，格式："
    echo "  自查对象：${TREE}"
    echo "  ## 范围与验收"
    echo "  <卡上范围、验收场景逐条：做到没有、证据（测试名）、反证>"
    echo "  ## 同类写法"
    echo "  <git grep 了什么、找到哪些、各怎么处理>"
    echo "写好后重跑 just done。代码再改，树哈希变了，要重新自查。"
  } >&2
  exit 1
fi
SELF_REVIEW_BODY="$(grep -v '^[[:space:]]*$' "$SELF_REVIEW" | sed '1d' | scrub)"

# ── 2. 门禁：按改动路径挑，挑不出来才退回全量 just ci ──────────────────
# 本地只跑改动涉及的检查；全量 just ci 是 PR 上 CI 的事（合入门槛），不在本地重复跑。
#   纯文档                     → just ci-docs
#   apps/android/**            → just android-test
#   apps/ios/**、tools/ios/**  → just ios-test
#   assets/i18n/**、strings*.xml → just mobile-static-check
#   iOS 文案（apps/ios/**/*.strings、*.xcstrings、assets/i18n/**）→ 另加 just ios-test --lang en 与 --lang zh
#     （本机模拟器多是中文、CI 是英文：写死某一种语言的断言只在另一种语言下红，#1342）
#   crates/<名>/**             → cargo nextest run -p <包名>
#   tools/<文件>               → 改动里的 tools/test-*.sh 本身 + 引用到它的 tools/test-*.sh（git grep 找）
#   其余（桌面、.github、justfile、没有任何测试引用的 tools 文件…）任何一个挑不出来 → just ci
GATES=()
add_gate() { # 去重追加
  local g
  for g in ${GATES[@]+"${GATES[@]}"}; do [ "$g" = "$1" ] && return 0; done
  GATES+=("$1")
}
tool_tests() { # tool_tests <tools/下的文件>：打印要跑的测试，一行一个；没有就什么也不打印
  local f="$1" base dir
  case "$f" in
    tools/test-*.sh)
      [ -f "$f" ] && printf '%s\n' "$f"
      return 0
      ;;
  esac
  base="${f##*/}"
  dir="${f%/*}"
  if [ "$dir" = tools ]; then
    git grep -l -F -e "$f" -e "$base" -- 'tools/test-*.sh' 2>/dev/null || true
  else
    git grep -l -F -e "$f" -e "$base" -e "${dir}/" -- 'tools/test-*.sh' 2>/dev/null || true
  fi
}
FULL=0
HAS_CODE=0
LANG_TEST=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    docs/* | *.md | release/notes/*) continue ;;
  esac
  HAS_CODE=1
  case "$f" in
    apps/ios/*.strings | apps/ios/*.xcstrings | assets/i18n/*) LANG_TEST=1 ;;
  esac
  case "$f" in
    apps/android/*)
      add_gate "just android-test"
      case "$f" in */strings*.xml) add_gate "just mobile-static-check" ;; esac
      ;;
    tools/ios/test-*.sh)
      # tools/ios 下的测试脚本是构建辅助脚本的测试（由 mobile-static-check / ci-ios 调），
      # 不是 App 代码：直接跑它，别拉模拟器。删除的脚本不跑（diff 也会列出已删除路径）；
      # 需要模拟器的脚本在非 macOS 上自己跳过。
      [ -f "$f" ] && add_gate "bash $f" ;;
    apps/ios/* | tools/ios/*) add_gate "just ios-test" ;;
    assets/i18n/*) add_gate "just mobile-static-check" ;;
    crates/*/*)
      crate_dir="${f#crates/}"
      crate_dir="${crate_dir%%/*}"
      pkg="$(sed -n 's/^name *= *"\(.*\)"/\1/p' "crates/${crate_dir}/Cargo.toml" 2>/dev/null | head -1)"
      if [ -n "$pkg" ]; then add_gate "cargo nextest run -p ${pkg}"; else FULL=1; fi
      ;;
    tools/*)
      tests="$(tool_tests "$f")"
      if [ -n "$tests" ]; then
        while IFS= read -r t; do add_gate "bash ${t}"; done <<EOF3
$tests
EOF3
      else
        FULL=1
      fi
      ;;
    *) FULL=1 ;;
  esac
done <<EOF2
$FILES
EOF2
if [ "$HAS_CODE" = 0 ]; then
  GATES=("just ci-docs")
elif [ "$FULL" = 1 ] || [ "${#GATES[@]}" -eq 0 ]; then
  GATES=("just ci")
fi
if [ "$LANG_TEST" = 1 ]; then
  add_gate "just ios-test --lang en"
  add_gate "just ios-test --lang zh"
fi
GATE=""
for g in "${GATES[@]}"; do GATE="${GATE:+${GATE} + }${g}"; done

run_logged() { # run_logged <日志> <命令...>：重编译经 tools/heavy-lock 排队（可重入，#1308）
  local log="$1"
  shift
  if [ -z "${PPASS_NO_LOCK:-}" ]; then
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/heavy-lock" "$@" >>"$log" 2>&1
  else
    "$@" >>"$log" 2>&1
  fi
}

# 复用验证：树哈希 + 门禁清单 + 有没有 just verify 都相同，就不重跑。
HAS_VERIFY=0
just --show verify >/dev/null 2>&1 && HAS_VERIFY=1
VERIFIED="${EVID_DIR}/verified"
VKEY="tree=${TREE} gates=${GATE} verify=${HAS_VERIFY}"
REUSED=""
if [ -s "$VERIFIED" ] && [ "$(head -n 1 "$VERIFIED")" = "$VKEY" ] && [ -f "${EVID_DIR}/gate.tail" ]; then
  REUSED="$(sed -n 2p "$VERIFIED")"
fi
VERIFY_STATE="skipped"
VERIFY_TAIL=""
if [ -n "$REUSED" ]; then
  echo "==> 代码没变（树 ${TREE:0:10}）：复用 ${REUSED} 的验证（${GATE}$([ "$HAS_VERIFY" = 0 ] || echo " + just verify ${N}")），不重跑"
  GATE_TAIL="$(cat "${EVID_DIR}/gate.tail")"
  if [ "$HAS_VERIFY" = 1 ]; then
    VERIFY_STATE="passed"
    VERIFY_TAIL="$(cat "${EVID_DIR}/verify.tail" 2>/dev/null)"
  fi
else
  rm -f "$VERIFIED"
  echo "==> ${GATE}（日志：${EVID_SHOW}/gate.log）"
  : >"${EVID_DIR}/gate.log"
  for g in "${GATES[@]}"; do
    printf '\n==> %s\n' "$g" >>"${EVID_DIR}/gate.log"
    # shellcheck disable=SC2086 # 刻意按空格拆成命令与参数
    run_logged "${EVID_DIR}/gate.log" $g || fail_blocked "${g}" "${EVID_DIR}/gate.log"
  done
  GATE_TAIL="$(tail -n 5 "${EVID_DIR}/gate.log" | scrub)"

  # ── 3. 验收场景（just verify 存在才跑）──────────────────────────────────
  if [ "$HAS_VERIFY" = 1 ]; then
    echo "==> just verify ${N}（日志：${EVID_SHOW}/verify.log）"
    run_logged "${EVID_DIR}/verify.log" just verify "$N" || fail_blocked "just verify ${N}" "${EVID_DIR}/verify.log"
    VERIFY_STATE="passed"
    VERIFY_TAIL="$(tail -n 8 "${EVID_DIR}/verify.log" | scrub)"
  else
    echo "⚠ 本仓还没有 just verify：只跑了 ${GATE}。验收场景需按 issue 上写的步骤手工做真机验证并回帖。"
  fi
  # 门禁与 verify 都通过才记：下次树没变就复用。
  printf '%s\n' "$GATE_TAIL" >"${EVID_DIR}/gate.tail"
  printf '%s\n' "$VERIFY_TAIL" >"${EVID_DIR}/verify.tail"
  printf '%s\n%s\n' "$VKEY" "$(date '+%Y-%m-%d %H:%M')" >"$VERIFIED"
fi
REUSE_NOTE=""
[ -z "$REUSED" ] || REUSE_NOTE="（复用 ${REUSED} 的验证：代码没变，树 \`${TREE:0:10}\`）"

# 门禁期间 main 可能又动了：推之前再判一次冲突（pre-push hook 同口径，这里提前给出明白话）。
git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" || die "取不到 origin/main（离线？），没推"
check_main "门禁期间 origin/main 前进了："

# ── 4. 推送（显式 refspec，不依赖上游设置）──────────────────────────────
PUSH_LOG="${EVID_DIR}/push.log"
git push -u origin "HEAD:refs/heads/${BRANCH}" >"$PUSH_LOG" 2>&1 || fail_blocked "git push" "$PUSH_LOG"

# ── 5. 回执（贴到每张卡）────────────────────────────────────────────────
if [ "$VERIFY_STATE" = "passed" ]; then
  LEVEL="E1（${GATE}）+ E3（just verify ${N}）"
else
  LEVEL="E1（${GATE}）；验收场景未经 just verify 自动验证，E3 需手工补"
fi
# 用户看得到的改动：碰界面与文案路径或核心路径（判定口径与 owner-triage.sh 一致，见 acceptance-gate.sh）。
# 这类改动开草稿 PR，验收与 CI、评审并行。只改更新说明（notes）的验收方式是文案确认（#1448）。
KIND="$(printf '%s\n' "$FILES" | bash "${HERE}/acceptance-gate.sh" classify --repo "$TOP")"
VISIBLE=0
[ "$KIND" = none ] || VISIBLE=1
CONFIRM="真机验收"
[ "$KIND" != notes ] || CONFIRM="文案确认"
ACCEPT_LINE=""
DRAFT_ARGS=()
if [ "$VISIBLE" = 1 ] && [ -n "$ACCEPTED" ]; then
  ACCEPT_LINE="产品负责人 ${ACCEPTED} ${CONFIRM}通过"
elif [ "$VISIBLE" = 1 ]; then
  ACCEPT_LINE="待产品负责人${CONFIRM}"
  DRAFT_ARGS=(--draft)
else
  ACCEPT_LINE="用户看不到的改动（工具、测试、文档、内部代码），不需要真机验收"
fi
flow_ensure_review_label
tmp="$(mktemp)"
{
  echo "**worker 已交卡**"
  echo
  if [ "$CARDS" != "$N" ]; then echo "- 关联卡：${CARDS_SHOW}（同一条功能分支，范围取并集）"; fi
  echo "- 分支：\`${BRANCH}\`（已推送）"
  echo "- 提交："
  git log --format='  - `%h` %s' origin/main..HEAD
  echo "- 改动清单（只含范围内文件）："
  echo '```'
  git diff --stat origin/main...HEAD
  echo '```'
  echo "- 门禁：\`${GATE}\` 通过${REUSE_NOTE}。输出末尾："
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
  [ -z "$ACCEPT_LINE" ] || echo "- 真机验收：${ACCEPT_LINE}"
  echo "- 证据等级：${LEVEL}"
  echo "- 证据目录（本机，不进 git）：\`${EVID_SHOW}\`"
  echo
  echo "### 自查结论（推送前按 CI 评审清单自查，树 \`${TREE:0:10}\`）"
  echo
  printf '%s\n' "$SELF_REVIEW_BODY"
} >"$tmp"
for c in $CARDS; do
  flow_comment "$c" "$tmp"
  flow_labels "$c" "status:review" "status:doing,status:blocked"
done
RECEIPT="$tmp"
rm -f "$FAILS_FILE"

echo
echo "✅ ${CARDS_SHOW} 已交卡：${BRANCH} 已推送，标签 → status:review，回执已贴。"
echo "   证据等级：${LEVEL}"

# ── 6. 打印开 PR 的命令（正文 closes 全部卡；用户看得到的改动带 --draft）──────────────
PR_URL="$(gh pr view "$BRANCH" -R "$REPO" --json url --jq .url 2>/dev/null)" || PR_URL=""
if [ -n "$PR_URL" ]; then
  rm -f "$RECEIPT"
  echo "   PR 已存在：${PR_URL}（已推最新提交）"
  [ "${#DRAFT_ARGS[@]}" -eq 0 ] || echo "   ${CONFIRM}后在 PR 正文补「产品负责人 <日期 时间> ${CONFIRM}通过」，再 gh pr ready。"
  exit 0
fi
if [ "$(git rev-list --count origin/main..HEAD)" = 1 ]; then
  PR_TITLE="$(git log -1 --format=%s)"
else
  PR_TITLE="${BRANCH%%/*}: $(printf '%s' "${TITLES[0]}" | sed -e 's/^\[[^]]*\][[:space:]]*//') ($(printf '#%s ' $CARDS | sed 's/ $//'))"
fi
# 不在脚本里开 PR，只把正文写进证据目录、打印开 PR 的命令，由执行者自己运行（#1421）：
# 外壳（如 Claude Desktop 的 PR 监控）只认会话自己直接执行的 gh pr create 为「本会话所开」，
# 藏在脚本里开的 PR 事后只能按分支绑定，开不了自动修 CI / 处理评审意见。
PR_BODY="${EVID_DIR}/pr-body.md"
# 先拼好整份正文，一次写进临时文件，写成功再改名（#1449）：写到一半失败（如磁盘写满）不留半截 pr-body.md，
# 也不打印开 PR 命令，免得用半截或旧正文开 PR。
BODY_TEXT="$(
  for c in $CARDS; do echo "closes #${c}"; done
  echo
  if [ "${#DRAFT_ARGS[@]}" -gt 0 ]; then
    echo "- 真机验收：${ACCEPT_LINE}（草稿 PR；${CONFIRM}后在正文单独补一行「产品负责人 <日期 时间> ${CONFIRM}通过」，再 gh pr ready）"
  elif [ "$VISIBLE" = 1 ]; then
    echo "$ACCEPT_LINE"
  else
    echo "- 真机验收：${ACCEPT_LINE}"
  fi
  sed -n '3,$p' "$RECEIPT" | grep -v '^- 真机验收：'
)"
rm -f "${PR_BODY}.tmp"
if ! printf '%s\n' "$BODY_TEXT" >"${PR_BODY}.tmp" 2>/dev/null || [ -d "$PR_BODY" ] || ! mv -f "${PR_BODY}.tmp" "$PR_BODY" 2>/dev/null; then
  rm -f "${PR_BODY}.tmp" "$RECEIPT"
  die "写 PR 正文失败：${PR_BODY}" "分支已推送、回执已贴；腾出空间或清掉占着这个位置的东西后重跑 just done（不打印命令，免得用半截或旧正文开 PR）"
fi
rm -f "$RECEIPT"
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
PR_CMD="gh pr create -R $(sq "$REPO") --base main --head $(sq "$BRANCH")"
[ "${#DRAFT_ARGS[@]}" -eq 0 ] || PR_CMD="${PR_CMD} --draft"
PR_CMD="${PR_CMD} --title $(sq "$PR_TITLE") --body-file $(sq "$PR_BODY")"
echo "   开 PR：在本目录原样运行下面单独一行的命令（自己运行，单独执行，不接 cd … &&、不包进别的脚本；正文已写好，closes ${CARDS_SHOW}）："
echo
echo "${PR_CMD}"
echo
if [ "${#DRAFT_ARGS[@]}" -gt 0 ]; then
  echo "   草稿 PR：CI 与评审照常并行跑。请产品负责人${CONFIRM}；通过后在正文补验收行，再 gh pr ready。"
fi
echo "   开完之后：本会话负责把这个 PR 推进到合入。外壳有 PR 监控的马上打开（Claude Desktop：set_monitor auto_fix，见 CLAUDE.md），"
echo "     之后被唤醒再修，不手动盯 CI。CI 红、未解决的评审线程、冲突都算没过，修到全清："
echo "     just pr-status <PR号> 列卡点；评审意见逐条判定，改了或不改都用 just pr-thread <线程ID> \"<理由>\" 回复并关闭。"
echo "     然后 just start <下一张卡的 issue号>。"
# 自动合入靠必需检查把关（CI 评审 review/agent 即独立评审，AGENTS.md「独立评审」）：用本会话的身份开
# （GITHUB_TOKEN 开的合入不触发 main 上的 push 流水线）。只在 review/agent 已是 main 的必需检查时提示开：
# 查不到或不在里面就不开（否则 CI 一绿就合，绕过评审），交给 owner。
REQ="$(gh api "repos/${REPO}/branches/main/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null | tr -d '\r')" || REQ=""
if printf '%s\n' "$REQ" | grep -qx 'review/agent'; then
  echo "   自动合入：review/agent 已是必需检查，PR 开出后（草稿的话 gh pr ready 之后）开自动合入，评审与 CI 全过即合"
  echo "   （参数顺序照写，与放行规则一致；单独执行）："
  echo
  echo "gh pr merge --auto --squash <PR号> --repo ${REPO}"
else
  echo "   先不开自动合入：review/agent 还不是 main 的必需检查（或读不到保护设置），开了会绕过评审；交 owner。"
fi
