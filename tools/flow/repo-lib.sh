#!/usr/bin/env bash
# 极简公共辅助：供保留的发版台账（release-scope）、发版测试（owner-release-test）、想法记录（owner-idea）、
# 门状态（gate-status）、PR 卡点（pr-status）共用。不再包含任何旧文件白名单或填表逻辑。

FLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=decision-lib.sh
. "${FLOW_DIR}/decision-lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
COMMON_DIR="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .git)" && pwd -P)"
STATE_DIR="${PPASS_OWNER_STATE_DIR:-${COMMON_DIR}/ppass-batch}"
JUST="${PPASS_OWNER_JUST:-just}"

say() { printf '%s\n' "$*" >&2; }
step() { printf '\n==> %s\n' "$*" >&2; }
okmsg() { printf 'ok: %s\n' "$*" >&2; }
scrub() { sed -e "s#${HOME}#~#g"; }
today() { printf '%s\n' "${PPASS_OWNER_TODAY:-$(date +%Y-%m-%d)}"; }

die() {
  printf '\n✗ %s\n' "$1" >&2
  shift
  local l
  for l in "$@"; do printf '    %s\n' "$l" >&2; done
  printf '\n' >&2
  exit 1
}

refuse() {
  printf '\n✗ 拒绝：%s\n' "$1" >&2
  shift
  local l
  for l in "$@"; do printf '    %s\n' "$l" >&2; done
  exit 2
}

flow_repo() {
  local r="${PPASS_HOOK_REPO:-${PPASS_OWNER_REPO:-}}"
  if [ -z "$r" ]; then
    r="$(git config --get remote.origin.url 2>/dev/null |
      sed -E -e 's#/+$##' -e 's#\.git$##' -e 's#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
  fi
  [[ "$r" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "解析不出 GitHub 仓库（origin URL 不认识）；设 PPASS_HOOK_REPO=<owner>/<repo>"
  printf '%s' "$r"
}

REPO="${PPASS_HOOK_REPO:-${PPASS_OWNER_REPO:-}}"
if [ -z "$REPO" ]; then
  REPO="$(git config --get remote.origin.url 2>/dev/null |
    sed -E -e 's#/+$##' -e 's#\.git$##' -e 's#^.*[:/]([^/:]+/[^/:]+)$#\1#' || true)"
fi

need_gh() {
  command -v gh >/dev/null 2>&1 || refuse "找不到 gh" "装好并登录 gh（gh auth login）后重跑。"
}

fetch_origin() {
  git fetch -q --prune origin 2>/dev/null || die "git fetch origin 失败（离线或凭据问题）"
}

die_stuck() {
  local reason="$1"
  shift
  printf '\n✗ 停下：%s\n' "$reason" >&2
  python3 -B -I "${FLOW_DIR}/flow.py" owner-stuck "$reason" "$@" >&2 || true
  exit 1
}

flow_main_root() {
  local c
  c="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
  dirname "$c"
}

flow_load_issue() {
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

has_label() { case ",${I_LABELS:-}," in *",$1,"*) return 0 ;; esac; return 1; }

flow_parse_scope() {
  local scope g
  scope="$(printf '%s\n' "$1" | awk '
  !insec && /^\*\*范围/ { insec = 1; next }
  insec && !infence && /^[[:space:]]*```/ { infence = 1; next }
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
