#!/usr/bin/env bash
# just start <issue号>：领卡。校验 → 建 worktree 与分支 → status:ready→doing → 打印下一步。
# 用法: tools/flow/worker-start.sh <issue号> [--type feat|fix|docs|test|ci]
# 环境: PPASS_WT_ROOT 覆盖 worktree 父目录；PPASS_HOOK_REPO 覆盖仓库；
#       PPASS_FLOW_SKIP_HOOK_INSTALL=1 不自动装本地提交拦截（测试用）。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FLOW_PATHS="${HERE}/../ci-paths.sh"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || die "用法: just start <issue号>   例: just start 1234"
shift
TYPE_OVERRIDE=""
if [ "${1:-}" = "--type" ]; then TYPE_OVERRIDE="${2:-}"; fi

# 开工前自检：位置、shell、提交拦截、gh、提交身份、磁盘、私仓模式。不过就停，不带病继续。
bash "${HERE}/doctor.sh" || exit 1

command -v gh >/dev/null 2>&1 || die "找不到 gh，查不了 #${N}" "装好并登录：gh auth login"
REPO="$(flow_repo)"
flow_load_issue "$N"

[ "$I_STATE" = "OPEN" ] || die "#${N} 不是 open（现在是 ${I_STATE:-未知}），不领"
if ! has_label "status:ready"; then
  die "#${N} 没有 status:ready 标签，不能领（现有标签：${I_LABELS:-无}）" \
    "inbox = 还没写范围与验收；doing = 别人在做；blocked = 卡住；review/batched = 已交卡。" \
    "去找 owner 把范围与验收写好并转 ready。"
fi
flow_parse_scope "$I_BODY"
[ "${#GLOBS[@]}" -gt 0 ] || die "#${N} 没有可读的「范围」代码块，不领" \
  "issue 正文要有「**范围（只许动这些）**：」，下面跟一个 \`\`\` 代码块，一行一个路径或 glob。" \
  "让 owner 先补范围，并保持 status:ready。"

# type：issue 类型 Feature→feat、Bug→fix；Task 按范围推（全在文档里→docs，全在测试里→test，其余→ci）。
# 注意：本地提交拦截只认 feat/fix/docs/test/ci（tools/hooks/pre-commit），所以没有 chore。
itype="$(gh api "repos/${REPO}/issues/${N}" --jq '.type.name // empty' 2>/dev/null | tr -d '\r')"
if [ -z "$itype" ]; then
  if has_label bug; then itype="Bug"; elif has_label enhancement; then itype="Feature"; else itype="Task"; fi
fi
TYPE=""
case "$itype" in
  Feature) TYPE="feat" ;;
  Bug) TYPE="fix" ;;
  *)
    alldocs=1 alltest=1
    for g in "${GLOBS[@]}"; do
      case "$g" in docs/* | *.md | release/notes/*) ;; *) alldocs=0 ;; esac
      case "$g" in tools/test-* | */tests/* | */test/*) ;; *) alltest=0 ;; esac
    done
    if [ "$alldocs" = 1 ]; then TYPE="docs"; elif [ "$alltest" = 1 ]; then TYPE="test"; else TYPE="ci"; fi
    ;;
esac
if [ -n "$TYPE_OVERRIDE" ]; then
  case "$TYPE_OVERRIDE" in feat | fix | docs | test | ci) TYPE="$TYPE_OVERRIDE" ;; *) die "--type 只能是 feat/fix/docs/test/ci" ;; esac
fi

# slug：标题去掉 [XXX-NN] 前缀后的 ASCII 单词；没有就用前缀本身；再没有就 task。
tag="$(printf '%s' "$I_TITLE" | sed -n 's/^\[\([A-Za-z0-9-]*\)\].*/\1/p')"
words="$(printf '%s' "$I_TITLE" | sed -e 's/^\[[^]]*\]//' | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | tr -s '-' | sed -e 's/^-//' -e 's/-$//')"
slug="$words"
[ -n "$slug" ] || slug="$(printf '%s' "$tag" | tr 'A-Z' 'a-z')"
[ -n "$slug" ] || slug="task"
slug="$(printf '%s' "$slug" | cut -c1-40 | sed -e 's/-$//')"
BRANCH="${TYPE}/${N}-${slug}"
DIR="$(flow_wt_root)/${N}-${slug}"

git fetch origin --prune >/dev/null 2>&1 || die "git fetch origin 失败（离线？），领不了卡"
git rev-parse -q --verify "refs/heads/${BRANCH}" >/dev/null &&
  die "本地已有分支 ${BRANCH}" "这张卡可能已经领过：去 ${DIR} 继续干；要重来先让 owner 处理旧分支。"
[ ! -e "$DIR" ] || die "目录 ${DIR} 已存在" "这张卡可能已经领过：去那里继续干。"
mkdir -p "$(dirname "$DIR")"
git worktree add "$DIR" -b "$BRANCH" origin/main >/dev/null 2>&1 ||
  die "建 worktree 失败：git worktree add ${DIR} -b ${BRANCH} origin/main"
# -b 基于 origin/main 会把上游设成 origin/main，裸 git push 会推到 main：解掉，done 用显式 refspec 推。
git -C "$DIR" branch --unset-upstream >/dev/null 2>&1 || true

flow_labels "$N" "status:doing" "status:ready"

if [ -z "${PPASS_FLOW_SKIP_HOOK_INSTALL:-}" ] && [ -f "${DIR}/tools/hooks/install.sh" ]; then
  if ! (cd "$DIR" && bash tools/hooks/install.sh --check >/dev/null 2>&1); then
    (cd "$DIR" && bash tools/hooks/install.sh >/dev/null 2>&1) ||
      die "本地提交拦截没装上：范围与核心不会被拦，不能开工" \
        "在 ${DIR} 里跑 bash tools/hooks/install.sh 看原因；装好后重跑 just start ${N}。"
  fi
fi

echo "✅ 已领 #${N}：${I_TITLE}"
echo "   分支：${BRANCH}"
echo "   目录：${DIR}"
echo "   标签：status:ready → status:doing"
echo "   范围（只许动这些）："
printf '     %s\n' "${GLOBS[@]}"
echo
# 核心卡：正文引用了 origin/main 上「已采纳」的方案 ⇒ 已定案，按方案实现（与 batch-plan 准入同一判据）；
# 没有 ⇒ 还没定案，只写复现、根因和两个修法。
if has_label core; then
  ADRS="$(adopted_adrs "$I_BODY")"
  if [ -n "$ADRS" ]; then
    echo "⚠ 这是核心卡（带 core 标签），已引用 origin/main 上「已采纳」的方案：按方案实现，只改「范围」里的文件。"
    printf '%s\n' "$ADRS" | sed 's/^/  方案：/'
    echo "  实现要偏离方案、或方案没覆盖到：just stuck ${N} \"<原因>\"，不自己定。"
  else
    echo "⚠ 这是核心卡（带 core 标签）：只写复现、根因和两个修法，写进 issue 评论；不要自己改代码。"
    echo "  写好后：just stuck ${N} \"命中核心：<一句话根因>；修法 A …；修法 B …\""
  fi
  echo
fi
echo "下一步："
echo "  1. cd ${DIR}        （之后所有命令都在这个目录里跑）"
echo "  2. 读 issue #${N}：gh issue view ${N}，按「验收场景」改代码；只改上面「范围」里的文件"
echo "  3. git add <文件> && git commit -s -m \"<type>: <说明>\"        （提交说明末尾需有 Signed-off-by）"
echo "  4. 干完：just done          （跑门禁与验收、推分支、在 issue 里交卡）"
echo "  卡住（命中核心 / 需改范围外文件 / 没有验收场景 / 连红 3 次）：just stuck ${N} \"<原因>\""
