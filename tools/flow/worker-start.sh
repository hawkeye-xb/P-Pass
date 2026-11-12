#!/usr/bin/env bash
# just start <issue号>…：领卡。校验 → 建 worktree 与分支 → status:ready→doing → 打印下一步。
# 用法: tools/flow/worker-start.sh <issue号> [<issue号>…] [--name <功能名>] [--type feat|fix|docs|test|ci]
# 多张卡（同一个功能）领到一条分支上：分支名用第一张卡的号，其余卡号记在
# git config branch.<分支>.ppasscards（本地提交拦截与 just done 读它，范围取并集）。
# 环境: PPASS_WT_ROOT 覆盖 worktree 父目录；PPASS_HOOK_REPO 覆盖仓库；
#       PPASS_FLOW_SKIP_HOOK_INSTALL=1 不自动装本地提交拦截（测试用）。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FLOW_PATHS="${HERE}/../ci-paths.sh"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

CARDS=()
TYPE_OVERRIDE=""
NAME=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --type) TYPE_OVERRIDE="${2:-}"; shift 2 || shift ;;
    --name) NAME="${2:-}"; shift 2 || shift ;;
    *)
      [[ "$1" =~ ^[0-9]+$ ]] || die "用法: just start <issue号> [<issue号>…] [--name <功能名>]   例: just start 1234 1235 --name onboarding"
      case " ${CARDS[*]-} " in *" $1 "*) ;; *) CARDS+=("$1") ;; esac
      shift
      ;;
  esac
done
[ "${#CARDS[@]}" -gt 0 ] || die "用法: just start <issue号> [<issue号>…] [--name <功能名>]   例: just start 1234"
N="${CARDS[0]}"

# 开工前自检：位置、shell、提交拦截、gh、提交身份、磁盘、私仓模式。不过就停，不带病继续。
bash "${HERE}/doctor.sh" || exit 1

command -v gh >/dev/null 2>&1 || die "找不到 gh，查不了 #${N}" "装好并登录：gh auth login"
REPO="$(flow_repo)"

# 每张卡都校验（有一张不合格就整批不领，不留半截）：open、status:ready、有范围。范围取并集。
ALL_GLOBS=()
ITYPES=""
CORE_CARDS=()
TITLES=()
for c in "${CARDS[@]}"; do
  flow_load_issue "$c"
  [ "$I_STATE" = "OPEN" ] || die "#${c} 不是 open（现在是 ${I_STATE:-未知}），不领"
  if ! has_label "status:ready"; then
    die "#${c} 没有 status:ready 标签，不能领（现有标签：${I_LABELS:-无}）" \
      "inbox = 还没写范围与验收；doing = 别人在做；blocked = 卡住；review = 已交卡。" \
      "去找 owner 把范围与验收写好并转 ready。"
  fi
  flow_parse_scope "$I_BODY"
  [ "${#GLOBS[@]}" -gt 0 ] || die "#${c} 没有可读的「范围」代码块，不领" \
    "issue 正文要有「**范围（只许动这些）**：」，下面跟一个 \`\`\` 代码块，一行一个路径或 glob。" \
    "让 owner 先补范围，并保持 status:ready。"
  [ -n "$(flow_field_text "$I_BODY" "验收场景")" ] || die "#${c} 没有可读的「验收场景」，不领" \
    "issue 正文要有「**验收场景**：」，写成 操作 → 期望 → 日志里哪一行算过。" \
    "让 owner 先补验收场景，并保持 status:ready。"
  ALL_GLOBS+=("${GLOBS[@]}")
  has_label core && CORE_CARDS+=("$c")
  TITLES+=("#${c} ${I_TITLE}")
  # type：issue 类型 Feature→feat、Bug→fix（多卡：有 Feature 就 feat，其次有 Bug 就 fix）
  t="$(gh api "repos/${REPO}/issues/${c}" --jq '.type.name // empty' 2>/dev/null | tr -d '\r')"
  if [ -z "$t" ]; then
    if has_label bug; then t="Bug"; elif has_label enhancement; then t="Feature"; else t="Task"; fi
  fi
  case "$t " in
    *"Bug "*)
      repro="$(flow_field_text "$I_BODY" "复现路径")"
      if [ -z "$repro" ] || printf '%s\n' "$repro" | head -1 | grep -qiE '^(无|没有|不涉及|none|无。)$'; then
        die "#${c} 是 Bug 卡，但没有可读的「复现路径」，不领" \
          "issue 正文要有「**复现路径**：」写稳定复现的步骤/命令；复现不了的只加日志/护栏，转 blocked 找人对齐。" \
          "让 owner 先补复现路径，或把卡转 status:blocked。"
      fi
      ;;
  esac
  ITYPES="${ITYPES} ${t}"
  [ "$c" = "$N" ] && { FIRST_TITLE="$I_TITLE"; FIRST_BODY="$I_BODY"; }
done
GLOBS=("${ALL_GLOBS[@]}")

# type：issue 类型 Feature→feat、Bug→fix；Task 按范围推（全在文档里→docs，全在测试里→test，其余→ci）。
# 注意：本地提交拦截只认 feat/fix/docs/test/ci（tools/hooks/pre-commit），所以没有 chore。
TYPE=""
case "$ITYPES " in
  *" Feature "*) TYPE="feat" ;;
  *" Bug "*) TYPE="fix" ;;
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

# slug：--name 给的功能名，否则第一张卡标题去掉 [XXX-NN] 前缀后的 ASCII 单词；没有就用前缀本身；再没有就 task。
I_TITLE="$FIRST_TITLE"
I_BODY="$FIRST_BODY"
tag="$(printf '%s' "$I_TITLE" | sed -n 's/^\[\([A-Za-z0-9-]*\)\].*/\1/p')"
words="$(printf '%s' "${NAME:-$I_TITLE}" | sed -e 's/^\[[^]]*\]//' | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | tr -s '-' | sed -e 's/^-//' -e 's/-$//')"
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

# 多卡：其余卡号记在分支配置里（主卡在分支名里）；本地提交拦截与 just done 读它。
if [ "${#CARDS[@]}" -gt 1 ]; then
  git -C "$DIR" config "branch.${BRANCH}.ppasscards" "${CARDS[*]}" ||
    die "记录关联卡失败：git config branch.${BRANCH}.ppasscards \"${CARDS[*]}\""
fi

# ── 门禁预检（#1651）：这张卡的门禁在本机干净基线上跑不跑得绿 ──────────────
# 目的：worker 领卡前就知道这台机器能不能把卡送到合入；别改完才发现门禁必红（#1392 白做 41 turns）。
# 门禁清单与 just done 共用一份挑选逻辑（flow_pick_gates），这里按卡的「范围」挑：范围里展开得到的文件一起喂进去，
# 展开不到任何文件的 glob 原样当路径（与 done 的 fail-closed 口径一致，挑不出来就是全量 just ci）。
# 只预检能在几分钟内跑完的轻门禁（自包含的 bash 测试、just ci-docs、actionlint、just mobile-static-check）；
# 要编译或先装依赖的（cargo、pnpm、android-test、ios-test、just ci）不预检，只列出来——近三次同族事故
# （#1392 的 test-e3.sh、#1646 的挑选漏项、#1685 的 test-flow-worker.sh）都落在轻门禁里。
# 红了：不领卡——撤掉刚建的 worktree 与分支、卡打 status:blocked、issue 里写评论（哪条门禁红、日志末尾、怎么复跑）。
# 例外：红掉的命令跑的就是卡「范围」里的脚本（修门禁的卡）→ 只警告，照常领卡。
# PPASS_GATE_PRECHECK=off 关掉预检；PPASS_PRECHECK_TIMEOUT 改单条超时（秒，默认 600）。
run_bounded() { # <秒> <日志> <命令>：超时就杀掉并返回 124（不用 timeout 命令：Windows 的 timeout.exe 是另一套语义）
  local secs="$1" log="$2" cmd="$3" pid i=0
  PPASS_GATE_PRECHECK=off bash -c "$cmd" >>"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null
      # 门禁是 `bash -c` 起的壳，真正的测试 / just recipe 是它的子进程：一并收掉，
      # 否则它们会在 worktree 被撤掉后继续跑（Windows 上还会占着目录让删除失败）。
      if command -v pgrep >/dev/null 2>&1; then
        for c in $(pgrep -P "$pid" 2>/dev/null); do kill -TERM "$c" 2>/dev/null; done
      fi
      sleep 1
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    i=$((i + 1))
  done
  wait "$pid"
}
precheck_script_of() { # 命令里引用的仓库路径（bash <路径>）；没有就什么也不打印
  case "$1" in
    bash\ *) set -- $1; [ -n "${2:-}" ] && printf '%s\n' "$2" ;;
  esac
}
if [ "${PPASS_GATE_PRECHECK:-on}" != off ]; then
  PRECHECK_PATHS="$(for g in "${GLOBS[@]}"; do
    m="$(git -C "$DIR" ls-files -z -- "$g" 2>/dev/null | tr '\0' '\n')"
    if [ -n "$m" ]; then printf '%s\n' "$m"; else printf '%s\n' "$g"; fi
  done)"
  PRECHECK_GATES="$( (cd "$DIR" && flow_pick_gates && printf '%s\n' "${GATES[@]}") <<EOF2
$PRECHECK_PATHS
EOF2
)"
  PRECHECK_LOG="$(mktemp "${TMPDIR:-/tmp}/ppass-precheck.XXXXXX")"
  PRECHECK_SECS="${PPASS_PRECHECK_TIMEOUT:-600}"
  case "$PRECHECK_SECS" in
    '' | 0 | *[!0-9]*)
      printf '⚠ PPASS_PRECHECK_TIMEOUT=「%s」不是正整数，按 600 秒算\n' "$PRECHECK_SECS" >&2
      PRECHECK_SECS=600
      ;;
  esac
  PRECHECK_GREEN=()
  PRECHECK_RED=()
  PRECHECK_SKIP=()
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in
      bash\ * | "just ci-docs" | actionlint | "just mobile-static-check") ;;
      *) PRECHECK_SKIP+=("$g"); continue ;;
    esac
    printf '\n==> %s\n' "$g" >>"$PRECHECK_LOG"
    (cd "$DIR" && run_bounded "$PRECHECK_SECS" "$PRECHECK_LOG" "$g")
    rc=$?
    if [ "$rc" -eq 0 ]; then
      PRECHECK_GREEN+=("$g")
    elif [ "$rc" -eq 124 ]; then
      PRECHECK_RED+=("${g}（超时 ${PRECHECK_SECS}s）")
    else
      PRECHECK_RED+=("$g")
    fi
  done <<EOF2
$PRECHECK_GATES
EOF2
  PRECHECK_BLOCK=()
  if [ "${#PRECHECK_RED[@]}" -gt 0 ]; then
    for r in "${PRECHECK_RED[@]}"; do
      s="$(precheck_script_of "$r")"
      if [ -n "$s" ] && flow_in_scope "$s"; then
        printf '⚠ 预检：%s 在干净基线上红，但它是本卡「范围」里的脚本（修门禁的卡），不拦\n' "$r" >&2
      else
        PRECHECK_BLOCK+=("$r")
      fi
    done
  fi
  if [ "${#PRECHECK_BLOCK[@]}" -gt 0 ]; then
    REASON="$(mktemp "${TMPDIR:-/tmp}/ppass-precheck-reason.XXXXXX")"
    {
      echo "**领卡前门禁预检没通过：本机干净基线红，先别做这张卡**"
      echo
      echo "在新建的卡目录（origin/main 干净基线）上按「范围」挑出的门禁跑了一遍，红的："
      for r in "${PRECHECK_BLOCK[@]}"; do echo "- \`${r}\`"; done
      echo
      [ "${#PRECHECK_SKIP[@]}" -eq 0 ] || {
        echo "没预检的重门禁（要编译或先装依赖，不是它们红的）："
        for r in "${PRECHECK_SKIP[@]}"; do echo "- \`${r}\`"; done
        echo
      }
      echo "复跑方式：修好本机环境后重新 \`just start ${N}\`（临时目录已撤掉）；或换一台能把这些门禁跑绿的机器做。"
      echo "确认是本机环境问题、要强行在本机做：\`PPASS_GATE_PRECHECK=off just start ${N}\`。"
      echo
      echo "日志末尾（\`${PRECHECK_LOG}\`）："
      echo '```'
      tail -n 40 "$PRECHECK_LOG" | scrub
      echo '```'
    } >"$REASON"
    BLOCK_NOTE="已打 status:blocked 并写了评论"
    for c in "${CARDS[@]}"; do
      flow_try_labels "$c" "status:blocked" "status:ready" ||
        BLOCK_NOTE="⚠ 改 #${c} 的标签失败；评论内容见 ${REASON}"
      flow_comment "$c" "$REASON" ||
        BLOCK_NOTE="⚠ 往 #${c} 贴评论失败，内容留在 ${REASON}，手动补：gh issue comment ${c} -R ${REPO} --body-file ${REASON}"
    done
    # 刚建的 worktree 是干净的、没改动：撤掉，修好环境后能直接重新 just start。
    if [ -z "$(git -C "$DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      git worktree remove --force "$DIR" >/dev/null 2>&1 ||
        printf '⚠ 撤掉临时 worktree 失败，手动：git worktree remove --force %s\n' "$DIR" >&2
      git branch -D "$BRANCH" >/dev/null 2>&1 ||
        printf '⚠ 删临时分支失败，手动：git branch -D %s\n' "$BRANCH" >&2
    fi
    [ -f "$REASON" ] && [ "$BLOCK_NOTE" = "已打 status:blocked 并写了评论" ] && rm -f "$REASON"
    die "门禁预检红：#${N} 的门禁在本机干净基线上跑不绿，先别做这张卡（${BLOCK_NOTE}）" \
      "红的：$(printf '%s' "${PRECHECK_BLOCK[0]}")$([ "${#PRECHECK_BLOCK[@]}" -gt 1 ] && printf ' 等 %s 条' "$(( ${#PRECHECK_BLOCK[@]} - 1 ))")" \
      "日志：${PRECHECK_LOG}"
  fi
  if [ "${#PRECHECK_GREEN[@]}" -eq 1 ]; then
    echo "✅ 门禁预检（本机干净基线）：${PRECHECK_GREEN[0]} 全绿"
  elif [ "${#PRECHECK_GREEN[@]}" -gt 1 ]; then
    echo "✅ 门禁预检（本机干净基线）：${PRECHECK_GREEN[0]} 等 ${#PRECHECK_GREEN[@]} 条全绿"
  fi
  [ "${#PRECHECK_SKIP[@]}" -eq 0 ] || {
    echo "   未预检（要编译或先装依赖，交卡时才跑）："
    printf '     %s\n' "${PRECHECK_SKIP[@]}"
  }
  # 全绿（没有红项）就不留临时日志；有红的留着，路径在上面打印过。
  [ "${#PRECHECK_RED[@]}" -gt 0 ] || rm -f "$PRECHECK_LOG"
fi

for c in "${CARDS[@]}"; do flow_labels "$c" "status:doing" "status:ready"; done

# #1423 apps/android/local.properties 是本机配置（sdk.dir 等），git 不跟踪，新 worktree 里没有：
# 主副本有就拷进卡目录（卡目录已有不覆盖）；拷不成只提示，不拦领卡。
LOCAL_PROPS="apps/android/local.properties"
LOCAL_PROPS_NOTE=""
MAIN_ROOT="$(flow_main_root 2>/dev/null || true)"
if [ -e "${DIR}/${LOCAL_PROPS}" ]; then
  LOCAL_PROPS_NOTE="卡目录里已有，没动"
elif [ -n "$MAIN_ROOT" ] && [ -f "${MAIN_ROOT}/${LOCAL_PROPS}" ]; then
  if mkdir -p "${DIR}/apps/android" && cp "${MAIN_ROOT}/${LOCAL_PROPS}" "${DIR}/${LOCAL_PROPS}"; then
    LOCAL_PROPS_NOTE="已从主副本拷入"
  else
    LOCAL_PROPS_NOTE="⚠ 从主副本拷 ${LOCAL_PROPS} 失败：安卓构建与 just verify 编不出 APK；手动 cp ${MAIN_ROOT}/${LOCAL_PROPS} ${DIR}/${LOCAL_PROPS}"
  fi
else
  LOCAL_PROPS_NOTE="⚠ 主副本没有 ${LOCAL_PROPS}：本卡目录的安卓构建与 just verify 编不出 APK（找不到 Android SDK）。要编安卓：在主副本建这个文件（写一行 sdk.dir=<本机 Android SDK 路径>，或用 Android Studio 打开 apps/android 自动生成），再拷到 ${DIR}/${LOCAL_PROPS}；不碰安卓可忽略"
fi

# #1375 共享编译缓存：主副本旁的 .env.ppass-dev（没有就建）；卡目录不在它下面时拷一份进卡目录根。
CACHE_ENV=""
if [ -f "${HERE}/../e3/lib/dev-cache.sh" ]; then
  # shellcheck source=../e3/lib/dev-cache.sh
  . "${HERE}/../e3/lib/dev-cache.sh"
  if CACHE_ENV="$(dev_cache_init "$DIR")"; then
    dev_cache_covers "$DIR" || cp "$CACHE_ENV" "${DIR}/${DEV_CACHE_ENV_NAME}" || CACHE_ENV=""
  else
    CACHE_ENV=""
  fi
fi

if [ -z "${PPASS_FLOW_SKIP_HOOK_INSTALL:-}" ] && [ -f "${DIR}/tools/hooks/install.sh" ]; then
  if ! (cd "$DIR" && bash tools/hooks/install.sh --check >/dev/null 2>&1); then
    (cd "$DIR" && bash tools/hooks/install.sh >/dev/null 2>&1) ||
      die "本地提交拦截没装上：范围与核心不会被拦，不能开工" \
        "在 ${DIR} 里跑 bash tools/hooks/install.sh 看原因；装好后重跑 just start ${N}。"
  fi
fi

if [ "${#CARDS[@]}" -gt 1 ]; then
  echo "✅ 已领 ${#CARDS[@]} 张卡到一条功能分支："
  printf '     %s\n' "${TITLES[@]}"
else
  echo "✅ 已领 #${N}：${I_TITLE}"
fi
echo "   分支：${BRANCH}"
echo "   目录：${DIR}"
echo "   标签：status:ready → status:doing"
if [ -n "$CACHE_ENV" ]; then
  echo "   编译缓存：共享（${CACHE_ENV}；just 命令自动用，直接跑 cargo 先 set -a; . ${CACHE_ENV}; set +a）"
else
  echo "   编译缓存：没建成共享配置，本目录单独编（tools/e3/dev cache 看原因）"
fi
echo "   ${LOCAL_PROPS}：${LOCAL_PROPS_NOTE}"
echo "   范围（只许动这些；多卡取并集）："
printf '     %s\n' "${GLOBS[@]}"
echo
# 核心卡：正文引用了 origin/main 上「已采纳」的方案 ⇒ 已定案，按方案实现；
# 没有 ⇒ 还没定案，只写复现、根因和两个修法。
for c in ${CORE_CARDS[@]+"${CORE_CARDS[@]}"}; do
  flow_load_issue "$c"
  ADRS="$(adopted_adrs "$I_BODY")"
  if [ -n "$ADRS" ]; then
    echo "⚠ #${c} 是核心卡（带 core 标签），已引用 origin/main 上「已采纳」的方案：按方案实现，只改「范围」里的文件。"
    printf '%s\n' "$ADRS" | sed 's/^/  方案：/'
    echo "  实现要偏离方案、或方案没覆盖到：just stuck ${c} \"<原因>\"，不自己定。"
  else
    echo "⚠ #${c} 是核心卡（带 core 标签）：只写复现、根因和两个修法，写进 issue 评论；不要自己改代码。"
    echo "  写好后：just stuck ${c} \"命中核心：<一句话根因>；修法 A …；修法 B …\""
  fi
  echo
done
echo "下一步："
echo "  1. cd ${DIR}        （之后所有命令都在这个目录里跑）"
echo "  2. 读 issue：$(printf 'gh issue view %s；' "${CARDS[@]}")按「验收场景」改代码；只改上面「范围」里的文件"
echo "  3. git add <文件> && git commit -s -m \"<type>: <说明>\"        （提交说明末尾需有 Signed-off-by）"
echo "  4. 干完：just done          （跑门禁与验收、推分支、在 issue 里交卡）"
echo "  卡住（命中核心 / 需改范围外文件 / 没有验收场景 / 连红 3 次）：just stuck ${N} \"<原因>\""
