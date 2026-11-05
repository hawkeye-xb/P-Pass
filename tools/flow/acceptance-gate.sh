#!/usr/bin/env bash
# acceptance gate：用户看得到的改动，PR 正文必须有产品负责人真机验收那一行，否则红。
#
#   acceptance-gate.sh check    --files <改动文件列表> --body <PR 正文文件> [--repo <仓库根>]
#   acceptance-gate.sh classify [--repo <仓库根>] < 改动文件列表   打印 core / ui / none
#
# 口径与 owner-triage.sh 一致：碰核心路径（.github/core-paths.txt）或界面与文案路径
# （owner-triage.sh 里的 UI_GLOBS）= 需要验收；其余（自动级）直接绿。
# 验收行的正则与 review.sh 的一份相同（那份已验证过），这里只读不改 review.sh。
# 退出码：0 绿 / 1 红 / 2 用法错误。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# 单独成行：「产品负责人 <日期[ 时间]> [本地]真机验收通过」，允许行首的列表/引用/加粗符号。
ACCEPT_RE='^[*_> -]*产品负责人 ([0-9]{4}-)?[0-9]{2}-[0-9]{2}( +[0-9]{1,2}:[0-9]{2})? *(本地)?真机验收通过([*_ ]*|\*\*.*)$'

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

MODE="${1:-}"
[ -n "$MODE" ] || usage
shift
FILES_F=""
BODY_F=""
REPO="$(cd "${HERE}/../.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --files) FILES_F="${2:-}"; shift 2 || shift ;;
    --body) BODY_F="${2:-}"; shift 2 || shift ;;
    --repo) REPO="${2:-}"; shift 2 || shift ;;
    *) usage ;;
  esac
done

# 界面路径清单与 owner-triage.sh 共用同一份；读不到按需要验收处理（宁严勿松）。
classify() {
  local files core ui_globs ui
  files="$(cat)"
  core="$(printf '%s\n' "$files" | bash "${REPO}/tools/ci-paths.sh" core - "${REPO}/.github/core-paths.txt" 2>/dev/null)"
  if [ "$core" != "false" ]; then echo core; return; fi
  ui_globs="$(sed -n 's/^UI_GLOBS="\(.*\)"$/\1/p' "${REPO}/tools/flow/owner-triage.sh" 2>/dev/null)"
  if [ -z "$ui_globs" ]; then echo ui; return; fi
  set -f
  # shellcheck disable=SC2086 # 清单是空格分隔的 glob，刻意拆开
  ui="$(printf '%s\n' "$files" | bash "${REPO}/tools/ci-paths.sh" hit - $ui_globs 2>/dev/null)"
  set +f
  if [ "$ui" != "false" ]; then echo ui; else echo none; fi
}

case "$MODE" in
  classify) classify ;;
  check)
    [ -f "$FILES_F" ] && [ -f "$BODY_F" ] || usage
    KIND="$(classify <"$FILES_F")"
    if [ "$KIND" = none ]; then
      echo "acceptance gate：不碰界面与核心路径（自动级），不需要真机验收 ✅"
      exit 0
    fi
    if grep -qE "$ACCEPT_RE" "$BODY_F"; then
      echo "acceptance gate：${KIND} 级改动，PR 正文有真机验收记录 ✅"
      exit 0
    fi
    WHAT="界面或文案路径"
    [ "$KIND" != core ] || WHAT="核心路径"
    echo "acceptance gate ❌：改动碰${WHAT}，PR 正文缺验收行。"
    echo "产品负责人真机验收通过后，在 PR 正文单独写一行：「产品负责人 <日期 时间> 真机验收通过」（如 2026-11-05 15:30），再 gh pr ready。"
    exit 1
    ;;
  *) usage ;;
esac
