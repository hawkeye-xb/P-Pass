#!/usr/bin/env bash
# 发版前验收门禁：整体模式下先合入的 PR，对应模块卡都要有验收记录。
#
#   release-acceptance.sh <上一个正式 tag> [<head-ref，默认 origin/main>]
#
# 判据：
#   1. 范围 = git log --first-parent <tag>..<head> 的提交；本仓 squash 合入，提交标题末尾是「(#<PR号>)」，
#      据此取 PR 号（标题末尾没有 PR 号的提交不算 PR，跳过）。
#   2. 每个 PR 的正文（gh pr view --json body）里，单独成行的「随模块验收 #<模块卡号>」是整体模式标记
#      （行首可有列表/引用/加粗符号；嵌在句子中间的不算）；同一模块卡去重，记下来自哪些 PR。
#   3. 每张模块卡的正文与全部评论拼成一份文本，交给 acceptance-gate.sh record 判有没有验收记录
#      （验收行口径只在 acceptance-gate.sh 一份）。
# 输出：缺验收的模块卡每张一行「#M 没有验收记录（来自 PR #a、#b）」。
# 退出码：0 全部有验收记录（或范围内没有随模块验收的 PR）/ 1 有缺的，或 gh 读不到 PR / issue（fail-closed，不当通过）
#         / 2 用法错误、tag 或 head-ref 不存在。
#
# 接进 release.yml 的 release 模式属于更新链（核心），按 AGENTS.md 红线 6 另立方案，不在本卡（#1452）；
# 在那之前由 owner 发版前手动跑：tools/flow/release-acceptance.sh <上一个正式 tag>。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

TAG="${1:-}"
HEAD_REF="${2:-origin/main}"
[ -n "$TAG" ] || usage
[ "$#" -le 2 ] || usage
case "$TAG" in -*) usage ;; esac

if ! git rev-parse -q --verify "refs/tags/${TAG}^{commit}" >/dev/null 2>&1; then
  printf '✗ tag %s 不存在（先 git fetch --tags；要填上一个正式版的 tag）\n' "$TAG" >&2
  exit 2
fi
if ! git rev-parse -q --verify "${HEAD_REF}^{commit}" >/dev/null 2>&1; then
  printf '✗ head-ref %s 不存在\n' "$HEAD_REF" >&2
  exit 2
fi

REPO="$(flow_repo)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 标记行：单独成行，行首可有列表/引用/加粗符号，卡号后只允许收尾的加粗/空白。
MARK_RE='^[*_> -]*随模块验收 #[0-9]+[*_ ]*$'

subjects="$(git log --first-parent --format=%s "${TAG}..${HEAD_REF}")" ||
  die "git log ${TAG}..${HEAD_REF} 失败"
prs="$(printf '%s\n' "$subjects" | sed -n -E 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p' | sort -n -u)"

# pairs：每行「<模块卡> <PR>」
: >"${TMP}/pairs"
READ_FAIL=0
for pr in $prs; do
  if ! gh pr view "$pr" -R "$REPO" --json body --jq '.body' >"${TMP}/pr-body" 2>"${TMP}/err"; then
    printf '✗ 读不到 PR #%s 的正文：%s\n' "$pr" "$(head -3 "${TMP}/err" | tr '\n' ' ')" >&2
    READ_FAIL=1
    continue
  fi
  tr -d '\r' <"${TMP}/pr-body" | grep -E "$MARK_RE" | sed -E 's/.*#([0-9]+).*/\1/' |
    awk -v pr="$pr" '{ print $0 " " pr }' >>"${TMP}/pairs"
done

modules="$(awk '{ print $1 }' "${TMP}/pairs" | awk '!seen[$0]++')"
MISSING=0
CHECKED=0
for m in $modules; do
  srcs="$(awk -v m="$m" '$1 == m { print "#" $2 }' "${TMP}/pairs" | awk '!seen[$0]++ { s = s (s == "" ? "" : "、") $0 } END { print s }')"
  if ! gh issue view "$m" -R "$REPO" --json body,comments --jq '.body, (.comments[].body)' >"${TMP}/issue" 2>"${TMP}/err"; then
    printf '✗ 读不到模块卡 #%s（来自 PR %s）：%s\n' "$m" "$srcs" "$(head -3 "${TMP}/err" | tr '\n' ' ')" >&2
    READ_FAIL=1
    continue
  fi
  tr -d '\r' <"${TMP}/issue" >"${TMP}/issue-text"
  CHECKED=$((CHECKED + 1))
  bash "${HERE}/acceptance-gate.sh" record --body "${TMP}/issue-text" >/dev/null 2>"${TMP}/err"
  rc=$?
  case "$rc" in
    0) ;;
    1)
      printf '#%s 没有验收记录（来自 PR %s）\n' "$m" "$srcs"
      MISSING=1
      ;;
    *)
      printf '✗ acceptance-gate.sh record 判不了 #%s（退出 %s）：%s\n' "$m" "$rc" "$(head -3 "${TMP}/err" | tr '\n' ' ')" >&2
      READ_FAIL=1
      ;;
  esac
done

if [ "$MISSING" = 1 ] || [ "$READ_FAIL" = 1 ]; then
  [ "$READ_FAIL" = 1 ] && printf '✗ 有 PR 或模块卡读不到 / 判不了，不能当通过\n' >&2
  printf '✗ 发版前验收门禁不通过（%s..%s）\n' "$TAG" "$HEAD_REF" >&2
  exit 1
fi
NPR="$(printf '%s\n' "$prs" | grep -c .)"
if [ "$CHECKED" = 0 ]; then
  printf '✓ 发版前验收门禁通过（%s..%s）：%s 个 PR，都没有标随模块验收\n' "$TAG" "$HEAD_REF" "$NPR"
else
  printf '✓ 发版前验收门禁通过（%s..%s）：%s 个 PR，%s 张随模块验收的模块卡都有验收记录\n' "$TAG" "$HEAD_REF" "$NPR" "$CHECKED"
fi
exit 0
