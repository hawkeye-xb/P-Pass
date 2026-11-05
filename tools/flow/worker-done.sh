#!/usr/bin/env bash
# just done [--accepted "<时间>"]：在卡 worktree 里交卡。
#   门禁（just ci / 纯文档 just ci-docs）→ just verify <号>（命令存在才跑）→ 核对改动只含范围内文件
#   → 全绿才 git push → 在每张卡贴回执 → status:doing→status:review → 开 PR（正文 closes 全部卡）。
# 多卡分支（just start <号> <号>…）：卡号读 git config branch.<分支>.ppasscards，范围取并集。
# 用户看得到的改动（apps/**、assets/**、核心路径）：要先由产品负责人真机验收，交卡时给
# --accepted "<时间>"，PR 正文写「产品负责人 <时间> 真机验收通过」；没给就只推分支、不开 PR。
# 任何一步红：不推送，在 issue 写明停在哪并贴错误末尾，打 status:blocked，退出码非 0。
# 前置不满足（不在卡 worktree、没提交、工作区不干净、落后 main）只报错退出，不打 blocked。
# 环境: PPASS_NO_LOCK=1 不套 lockf；PPASS_HOOK_REPO 覆盖仓库。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

ACCEPTED=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --accepted) ACCEPTED="${2:-}"; shift 2 || shift ;;
    *) die "用法: just done [--accepted \"<产品负责人真机验收通过的时间>\"]" ;;
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

echo "==> ${GATE}（日志：${EVID_SHOW}/gate.log）"
: >"${EVID_DIR}/gate.log"
for g in "${GATES[@]}"; do
  printf '\n==> %s\n' "$g" >>"${EVID_DIR}/gate.log"
  # shellcheck disable=SC2086 # 刻意按空格拆成命令与参数
  run_logged "${EVID_DIR}/gate.log" $g || fail_blocked "${g}" "${EVID_DIR}/gate.log"
done
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

# ── 5. 回执（贴到每张卡）────────────────────────────────────────────────
if [ "$VERIFY_STATE" = "passed" ]; then
  LEVEL="E1（${GATE}）+ E3（just verify ${N}）"
else
  LEVEL="E1（${GATE}）；验收场景未经 just verify 自动验证，E3 需手工补"
fi
# 用户看得到的改动：App 与共享资源（apps/**、assets/**）或核心路径。要产品负责人真机验收后才开 PR。
VISIBLE=0
[ "$CORE" = "false" ] || VISIBLE=1
[ "$(printf '%s\n' "$FILES" | bash "$FLOW_PATHS" hit - 'apps/**' 'assets/**' 2>/dev/null)" = "true" ] && VISIBLE=1
ACCEPT_LINE=""
if [ "$VISIBLE" = 1 ] && [ -n "$ACCEPTED" ]; then
  ACCEPT_LINE="产品负责人 ${ACCEPTED} 真机验收通过"
elif [ "$VISIBLE" = 0 ]; then
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
  [ -z "$ACCEPT_LINE" ] || echo "- 真机验收：${ACCEPT_LINE}"
  echo "- 证据等级：${LEVEL}"
  echo "- 证据目录（本机，不进 git）：\`${EVID_SHOW}\`"
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

# ── 6. 开 PR（正文 closes 全部卡）──────────────────────────────────────
if [ -z "$ACCEPT_LINE" ]; then
  rm -f "$RECEIPT"
  echo "   用户看得到的改动：没开 PR。先把改动装到真机，请产品负责人验收；"
  echo "   通过后重跑：just done --accepted \"<验收时间，如 2026-11-04 15:30>\""
  exit 0
fi
PR_URL="$(gh pr view "$BRANCH" -R "$REPO" --json url --jq .url 2>/dev/null)" || PR_URL=""
if [ -n "$PR_URL" ]; then
  rm -f "$RECEIPT"
  echo "   PR 已存在：${PR_URL}（已推最新提交）"
  exit 0
fi
if [ "$(git rev-list --count origin/main..HEAD)" = 1 ]; then
  PR_TITLE="$(git log -1 --format=%s)"
else
  PR_TITLE="${BRANCH%%/*}: $(printf '%s' "${TITLES[0]}" | sed -e 's/^\[[^]]*\][[:space:]]*//') ($(printf '#%s ' $CARDS | sed 's/ $//'))"
fi
PR_BODY="$(mktemp)"
{
  for c in $CARDS; do echo "closes #${c}"; done
  echo
  echo "- 真机验收：${ACCEPT_LINE}"
  sed -n '3,$p' "$RECEIPT" | grep -v '^- 真机验收：'
} >"$PR_BODY"
rm -f "$RECEIPT"
PR_URL="$(gh pr create -R "$REPO" --base main --head "$BRANCH" --title "$PR_TITLE" --body-file "$PR_BODY" 2>&1)" || {
  rm -f "$PR_BODY"
  die "开 PR 失败：$(printf '%s' "$PR_URL" | tail -2 | tr '\n' ' ')" "分支已推送、回执已贴；手动开：gh pr create --head ${BRANCH}，正文 closes ${CARDS_SHOW}"
}
rm -f "$PR_BODY"
echo "   PR：${PR_URL}"
echo "   下一步：CI 红了修到绿；然后 just start <下一张卡的 issue号>。"
