#!/usr/bin/env bash
# worker 流程三条命令（start / done / stuck）共用的函数。只被 source，不直接运行。
# 说明见 AGENTS.md「交付流程」。gh 调用都集中在这里，测试用假 gh 桩替换。

# 「已采纳」方案解析（adopted_adrs）与 owner 共用一份。
# shellcheck source=decision-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decision-lib.sh"

# 仓库（owner/repo）：PPASS_HOOK_REPO 优先，否则从 origin URL 解析（与 tools/hooks/pre-commit 同口径）。
flow_repo() {
  local r="${PPASS_HOOK_REPO:-}"
  if [ -z "$r" ]; then
    r="$(git config --get remote.origin.url 2>/dev/null |
      sed -E -e 's#/+$##' -e 's#\.git$##' -e 's#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
  fi
  [[ "$r" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "解析不出 GitHub 仓库（origin URL 不认识）；设 PPASS_HOOK_REPO=<owner>/<repo>"
  printf '%s' "$r"
}

die() {
  printf '\n✗ %s\n' "$1" >&2
  shift
  local l
  for l in "$@"; do printf '    %s\n' "$l" >&2; done
  printf '\n' >&2
  exit 1
}

# 把本机路径（家目录）从要贴进公开 issue 的文本里抹掉。
scrub() { sed -e "s#${HOME}#~#g"; }

# 主仓工作区根（不论当前在哪个 worktree 里）。
flow_main_root() {
  local c
  c="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
  dirname "$c"
}

# 卡 worktree 的父目录：<主仓>-wt（P-Pass → P-Pass-wt），可用 PPASS_WT_ROOT 覆盖。
flow_wt_root() {
  if [ -n "${PPASS_WT_ROOT:-}" ]; then
    printf '%s' "$PPASS_WT_ROOT"
  else
    printf '%s-wt' "$(flow_main_root)"
  fi
}

# 读 issue：设置 I_STATE I_TITLE I_LABELS（逗号分隔）I_BODY。读不到就 die。
flow_load_issue() { # flow_load_issue <号>
  local out
  out="$(gh issue view "$1" -R "$REPO" --json state,title,labels,body \
    --jq '"state:" + .state, "title:" + .title, "labels:" + ([.labels[].name] | join(",")), "body:", .body' 2>&1)" ||
    die "读取 ${REPO}#$1 失败（离线、没登录或 issue 不存在）" "gh 输出：$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  out="$(printf '%s\n' "$out" | tr -d '\r')"
  I_STATE="$(printf '%s\n' "$out" | sed -n '1s/^state://p')"
  I_TITLE="$(printf '%s\n' "$out" | sed -n '2s/^title://p')"
  I_LABELS="$(printf '%s\n' "$out" | sed -n '3s/^labels://p')"
  I_BODY="$(printf '%s\n' "$out" | sed '1,4d')"
}

has_label() { case ",${I_LABELS}," in *",$1,"*) return 0 ;; esac; return 1; }

# 「范围」代码块解析：与 tools/hooks/pre-commit 里那段 awk 逐字相同
# （tools/test-flow-worker.sh 会比对两边，漂移即红）。结果放进 GLOBS 数组。
flow_parse_scope() { # flow_parse_scope <issue 正文>
  local scope g
  scope="$(printf '%s\n' "$1" | awk '
  !insec && /^\*\*范围/ { insec = 1; next }
  insec && !infence && /^[[:space:]]*```/ { infence = 1; found = 1; next }
  infence && /^[[:space:]]*```/ { exit }
  infence { print; next }
  insec && (/^\*\*[^*]+\*\*/ || /^#/) { exit }
')"
  GLOBS=()
  while IFS= read -r g; do
    g="$(printf '%s' "$g" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$g" in "" | "#"*) continue ;; esac
    g="${g#./}"
    case "$g" in */) g="${g}**" ;; esac
    GLOBS+=("$g")
  done <<EOF2
$scope
EOF2
}

# 取任务卡正文里 **<字段名>**：的值（到下一个 **字段 或 # 标题为止），去掉 HTML 注释与空行。
flow_field_text() { # flow_field_text <正文> <字段名>
  printf '%s\n' "$1" | awk -v f="$2" '
    index($0, "**" f "**") == 1 { grab = 1; sub(/^[^:：]*[：:]?[[:space:]]*/, ""); }
    grab && /^<!--/ { incomment = 1; if ($0 ~ /-->/) incomment = 0; next }
    grab && incomment { if ($0 ~ /-->/) incomment = 0; next }
    grab && /^[[:space:]]*$/ { next }
    grab && /^\*\*[^*]+\*\*/ { exit }
    grab && /^#/ { exit }
    grab { print }
  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

# 一个文件是否在 GLOBS 里（用 tools/ci-paths.sh hit，与 hook 同一套 glob 语义）。
flow_in_scope() { # flow_in_scope <文件>
  [ "$(printf '%s\n' "$1" | bash "$FLOW_PATHS" hit - "${GLOBS[@]}" 2>/dev/null)" = "true" ]
}

# 改标签，失败返回非 0、不退出：多卡一次处理时，一张失败不能把其余卡撂下。
flow_try_labels() { # flow_try_labels <号> <加> <减>（任一可空，逗号分隔）
  local n="$1" add="$2" del="$3" args=()
  [ -z "$add" ] || args+=(--add-label "$add")
  [ -z "$del" ] || args+=(--remove-label "$del")
  [ "${#args[@]}" -gt 0 ] || return 0
  gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null 2>&1
}

# 改标签：flow_labels <号> <加> <减>（任一可空，逗号分隔）。失败就 die。
flow_labels() {
  local n="$1" add="${2:-}" del="${3:-}" hint=""
  [ -z "$add" ] || hint="${hint} --add-label ${add}"
  [ -z "$del" ] || hint="${hint} --remove-label ${del}"
  flow_try_labels "$n" "$add" "$del" ||
    die "改 #$n 的标签失败（加：${add:-无}；减：${del:-无}）" "手动：gh issue edit $n -R $REPO${hint}"
}

flow_ensure_review_label() {
  gh label create "status:review" -R "$REPO" \
    -d "已交卡，等 PR 的 CI 与放行" -c "5319e7" >/dev/null 2>&1 || true
}

# 贴评论。失败返回非 0（多卡一次处理时由调用方点名是哪张卡）；内容留在文件里，可手动贴。
flow_comment() { # flow_comment <号> <正文文件>
  gh issue comment "$1" -R "$REPO" --body-file "$2" >/dev/null 2>&1 ||
    { printf '⚠ 往 #%s 贴评论失败（离线？）：内容见 %s\n' "$1" "$2" >&2; return 1; }
}
