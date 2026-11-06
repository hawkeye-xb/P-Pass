#!/usr/bin/env bash
# 按版本验收（#1471）：验收单位是「候选版相对上一个正式版、用户看得见的改动」，范围从 git 算。
#
#   release-scope.sh [--since <tag>] [--to <ref>]
#       列出验收范围：<since>..<to>（默认：<to> 往前最近的正式 tag .. origin/main）里 squash 合入的 PR，
#       逐个用 acceptance-gate.sh classify（带该提交的 diff）判级，ui / core / notes 进范围，每项带关联卡的「验收场景」。
#       --since 可给任何 tag（例如上一个 test 包，数「自上个 test 包以来用户可见 PR 数」）。
#   release-scope.sh --ledger <台账 issue 号> --pkg <test 包 tag> [--since <tag>] [--dry-run]
#       出新 test 包时更新台账（每个版本一张 issue，标题「[验收] v<版本>」，清单只存在 issue 里）：
#         新增的用户可见 PR → 待验；
#         已验项（[x] @<验过的包>）若该 PR 改过的文件在「验过的包..新包」之间又被改动 → 待重验，没被改动 → 沿用；
#         判不了（tag 不存在、git 失败、勾了却没有包号）一律待重验（fail-closed）。
#       台账第一次写入时记下 since（--since，默认 <pkg> 往前最近的正式 tag），之后以台账里记的为准。
#       --dry-run 只打印，不改 issue。
#   release-scope.sh --check --ledger <台账 issue 号> [--to <候选 ref，默认 origin/main>]
#       发版前检查（release-acceptance.sh 调它）：重新算 since..候选版的范围，逐个 PR 核对「在台账里、已勾、
#       且文件在验过的包..候选版之间没再改过」；台账里还有没勾的项也算红。
#
# 台账块（脚本维护；人只做一件事：按 SOP 验过、owner 判日志通过后，把那一项的 [ ] 勾成 [x]，可在行尾补「| 结论：…」）：
#   <!-- release-ledger:begin since=<tag> -->
#   - [ ] #<PR> <级别> | 待验 @<包> | 场景：<关联卡的验收场景>
#   - [x] #<PR> <级别> | 已验 @<包> | 场景：… | 结论：…
#   <!-- release-ledger:end -->
#   勾 [x] 的含义：在这一项写着的 @<包> 上验过。
# 退出码：0 绿 / 1 红（发版检查有待验项，或 gh / git 读不到，fail-closed）/ 2 用法错误、tag 或 ref 不存在。
#
# 接进 release.yml 属更新链（核心），另立方案，不在本卡；在那之前 owner 发版前手动跑 just release-acceptance <台账号>。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

SINCE=""
TO=""
LEDGER=""
PKG=""
CHECK=0
DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; [ -n "$SINCE" ] || usage; shift 2 ;;
    --to) TO="${2:-}"; [ -n "$TO" ] || usage; shift 2 ;;
    --ledger) LEDGER="${2:-}"; [[ "$LEDGER" =~ ^[0-9]+$ ]] || usage; shift 2 ;;
    --pkg) PKG="${2:-}"; [ -n "$PKG" ] || usage; shift 2 ;;
    --check) CHECK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
if [ "$CHECK" = 1 ]; then
  [ -n "$LEDGER" ] && [ -z "$PKG" ] || usage
elif [ -n "$LEDGER" ]; then
  [ -n "$PKG" ] && [ -z "$TO" ] || usage
else
  [ -z "$PKG" ] || usage
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
READ_FAIL=0
# 读失败记成文件：scene_of 在 $(…) 子 shell 里跑，变量带不回来。
mark_fail() { READ_FAIL=1; : >"${TMP}/read-fail"; }
failed() { [ "$READ_FAIL" = 1 ] || [ -e "${TMP}/read-fail" ]; }
LEDGER_BEGIN_RE='^<!-- release-ledger:begin since=([^ ]+) -->$'
LEDGER_END='<!-- release-ledger:end -->'

commit_of() { git rev-parse -q --verify "${1}^{commit}" 2>/dev/null; }
need_ref() { commit_of "$1" >/dev/null || { printf '✗ %s 不存在（先 git fetch --tags）\n' "$1" >&2; exit 2; }; }
# <ref> 往前最近的正式 tag（正式版 tag 不带「-」，test 包是 v<版本>-test.<N>）。
last_formal() { git describe --tags --abbrev=0 --match 'v*' --exclude '*-*' "$1" 2>/dev/null; }

# 读 issue / PR 正文（gh 失败返回非 0）。
read_issue() { gh issue view "$1" -R "$REPO" --json body --jq '.body' 2>"${TMP}/err" | tr -d '\r'; }
read_pr() { gh pr view "$1" -R "$REPO" --json body --jq '.body' 2>"${TMP}/err" | tr -d '\r'; }

# 卡正文里的验收场景：任务卡字段「**验收场景**：…」（到下一个加粗字段 / 标题 / 注释为止），没有就取「## 验收…」标题下的段落；
# 压成一行、截到 160 字，「|」换成全角，免得拆坏台账字段。
scene_field() {
  python3 -c '
import re, sys
t = sys.stdin.read()
m = re.search(r"^\*\*验收场景\*\*[：:]?(.*?)(?=^\*\*[^*\n]+\*\*|^#|^<!--|\Z)", t, re.S | re.M) or \
    re.search(r"^#+[ \t]*验收[^\n]*\n(.*?)(?=^#|^<!--|\Z)", t, re.S | re.M)
s = re.sub(r"\s+", " ", m.group(1)).strip().replace("|", "｜") if m else ""
print(s[:160] + ("…（全文见卡）" if len(s) > 160 else ""))
'
}

# compute_scope <since> <to>：写 ${TMP}/scope（每行「<PR> <级别>」，按合入先后）与 ${TMP}/files/<PR>（该 PR 改过的文件）。
compute_scope() {
  local since="$1" to="$2" sha subj pr kind
  # 浅克隆的历史可能被浅边界截断（主线上缺 PR、合并分支上缺提交），范围与重验都算不全：直接拒绝（fail-closed）。
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != false ]; then
    printf '✗ 当前是浅克隆（或判不了），历史可能不全，算不出完整的验收范围；先 git fetch --unshallow --tags 再跑\n' >&2
    exit 1
  fi
  mkdir -p "${TMP}/files"
  : >"${TMP}/scope"
  : >"${TMP}/allprs"
  git log --first-parent --reverse --format='%H %s' "${since}..${to}" >"${TMP}/log" 2>"${TMP}/err" || {
    printf '✗ git log %s..%s 失败：%s\n' "$since" "$to" "$(head -3 "${TMP}/err" | tr '\n' ' ')" >&2
    exit 1
  }
  while IFS=' ' read -r sha subj; do
    # 本仓 squash 合入，提交标题末尾是「(#<PR号>)」；没有 PR 号的提交不算 PR。
    pr="$(printf '%s\n' "$subj" | sed -n -E 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p')"
    [ -n "$pr" ] || continue
    echo "$pr" >>"${TMP}/allprs"
    git -c core.quotepath=false diff-tree -r --no-commit-id --name-only --no-renames "$sha" >"${TMP}/files/${pr}" 2>/dev/null ||
      { printf '✗ 读不到 PR #%s 的改动文件（%s）\n' "$pr" "$sha" >&2; mark_fail; continue; }
    git -c core.quotepath=false show --format= --no-color --no-renames --no-ext-diff --no-textconv \
      --src-prefix=a/ --dst-prefix=b/ "$sha" >"${TMP}/diff" 2>/dev/null ||
      { printf '✗ 读不到 PR #%s 的 diff（%s）\n' "$pr" "$sha" >&2; mark_fail; continue; }
    kind="$(bash "${HERE}/acceptance-gate.sh" classify --diff "${TMP}/diff" <"${TMP}/files/${pr}" 2>/dev/null)"
    case "$kind" in
      ui | core | notes) echo "$pr $kind" >>"${TMP}/scope" ;;
      none | core-hidden) ;;
      *) printf '✗ 判不了 PR #%s 的级别，按用户看得见处理\n' "$pr" >&2; mark_fail; echo "$pr ui" >>"${TMP}/scope" ;;
    esac
  done <"${TMP}/log"
}

# scene_of <PR>：PR 正文 closes / fixes / resolves / refs 的卡上的验收场景，「#卡：场景；#卡：场景」。读不到记 READ_FAIL。
scene_of() {
  local pr="$1" body cards c ibody s out=""
  if ! body="$(read_pr "$pr")"; then
    printf '✗ 读不到 PR #%s 的正文：%s\n' "$pr" "$(head -3 "${TMP}/err" | tr '\n' ' ')" >&2
    mark_fail
    echo "（读不到 PR 正文）"
    return
  fi
  cards="$(printf '%s\n' "$body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?|refs?)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+$' | awk '!seen[$0]++')"
  [ -n "$cards" ] || { echo "（PR 没关联卡，按 PR 改动验）"; return; }
  for c in $cards; do
    if ! ibody="$(read_issue "$c")"; then
      printf '✗ 读不到卡 #%s：%s\n' "$c" "$(head -3 "${TMP}/err" | tr '\n' ' ')" >&2
      mark_fail
      s="（读不到卡）"
    else
      s="$(printf '%s\n' "$ibody" | scene_field)"
      [ -n "$s" ] || s="（卡上没写验收场景）"
    fi
    out="${out}${out:+；}#${c}：${s}"
  done
  echo "$out"
}

# changed_since <验过的包> <新 ref> <PR>：PR 改过的文件在两者之间又被改过（内容有差异，或中间有提交碰过）就打印这些文件；判不了打印「?」。
changed_since() {
  local from="$1" to="$2" pr="$3"
  { [ -n "$from" ] && commit_of "$from" >/dev/null; } || { echo "?"; return; }
  # 验过的包要是新 ref 的祖先，区间历史才完整，不是就判不了 → 待重验（浅克隆在 compute_scope 就拒绝了）。
  git merge-base --is-ancestor "$from" "$to" 2>/dev/null || { echo "?"; return; }
  # 两头内容的差异 + 中间提交历史里碰过的文件（改了又改回也算「又被改动」，宁严勿松）。
  { git -c core.quotepath=false diff --name-only --no-renames "$from" "$to" &&
    git -c core.quotepath=false log --format= --name-only --no-renames "${from}..${to}"; } >"${TMP}/moved" 2>/dev/null ||
    { echo "?"; return; }
  sort -u "${TMP}/moved" | grep -Fxf "${TMP}/files/${pr}" | head -n 5
}

# 读台账：${TMP}/ledger-body（整份正文），${TMP}/items（块内每项一行原文），LEDGER_SINCE。
LEDGER_SINCE=""
load_ledger() {
  if ! read_issue "$LEDGER" >"${TMP}/ledger-body"; then
    printf '✗ 读不到台账 #%s：%s\n' "$LEDGER" "$(head -3 "${TMP}/err" | tr '\n' ' ')" >&2
    exit 1
  fi
  LEDGER_SINCE="$(sed -n -E "s/${LEDGER_BEGIN_RE}/\1/p" "${TMP}/ledger-body" | head -n 1)"
  awk -v end="$LEDGER_END" '
    /^<!-- release-ledger:begin / { on = 1; next }
    $0 == end { on = 0 }
    on && /^- \[[ xX]\] #[0-9]+ / { print }
  ' "${TMP}/ledger-body" >"${TMP}/items"
}
item_of() { grep -E "^- \[[ xX]\] #${1} " "${TMP}/items" | head -n 1; }
item_checked() { printf '%s\n' "$1" | grep -qE '^- \[[xX]\]'; }
# 第二栏「待验 @<包>（…）」里的包号（全角括号用 index 找，不放进正则方括号：C locale 下会被拆成字节）。
item_pkg() {
  printf '%s\n' "$1" | awk -F' [|] ' '{ f = $2; i = index(f, "@"); if (!i) exit; f = substr(f, i + 1)
    j = index(f, "（"); if (j) f = substr(f, 1, j - 1); sub(/[ (].*/, "", f); print f }'
}
item_tail() { printf '%s\n' "$1" | awk -F' [|] ' '{ for (i = 4; i <= NF; i++) if ($i ~ /^结论：/) print " | " $i }'; }

REPO="$(flow_repo)"

# ── 发版前检查 ───────────────────────────────────────────────────────────
if [ "$CHECK" = 1 ]; then
  [ -n "$TO" ] || TO="origin/main"
  need_ref "$TO"
  load_ledger
  [ -n "$LEDGER_SINCE" ] || { printf '✗ 台账 #%s 里没有台账块（先 just release-scope --ledger %s --pkg <test 包>）\n' "$LEDGER" "$LEDGER" >&2; exit 1; }
  need_ref "$LEDGER_SINCE"
  compute_scope "$LEDGER_SINCE" "$TO"
  PENDING=0
  while read -r pr kind; do
    it="$(item_of "$pr")"
    if [ -z "$it" ]; then
      printf '#%s（%s）待验：不在台账里（最后一个 test 包之后合入？出新 test 包并更新台账）\n' "$pr" "$kind"
      PENDING=1
      continue
    fi
    if ! item_checked "$it"; then
      printf '#%s（%s）%s\n' "$pr" "$kind" "$(printf '%s\n' "$it" | awk -F' [|] ' '{ print $2 }')"
      PENDING=1
      continue
    fi
    v="$(item_pkg "$it")"
    moved="$(changed_since "$v" "$TO" "$pr")"
    if [ -n "$moved" ]; then
      if [ "$moved" = "?" ]; then
        printf '#%s（%s）待重验：判不了验过的包 @%s 与候选版之间的改动\n' "$pr" "$kind" "${v:-（没写包号）}"
      else
        printf '#%s（%s）待重验：验过 @%s 之后又改了 %s\n' "$pr" "$kind" "$v" "$(printf '%s\n' "$moved" | paste -sd ' ' -)"
      fi
      PENDING=1
    fi
  done <"${TMP}/scope"
  # 台账里还有没勾的项（不论还在不在范围里）也不放行。
  while read -r it; do
    pr="$(printf '%s\n' "$it" | sed -n -E 's/^- \[ \] #([0-9]+) .*/\1/p')"
    [ -n "$pr" ] || continue
    grep -qE "^${pr} " "${TMP}/scope" && continue
    printf '#%s 台账里没勾：%s\n' "$pr" "$(printf '%s\n' "$it" | awk -F' [|] ' '{ print $2 }')"
    PENDING=1
  done <"${TMP}/items"
  if [ "$PENDING" = 1 ] || failed; then
    failed && printf '✗ 有提交读不到 / 判不了，不能当通过\n' >&2
    printf '✗ 发版前验收不通过（台账 #%s，%s..%s）：上面的项清零才出正式版\n' "$LEDGER" "$LEDGER_SINCE" "$TO" >&2
    exit 1
  fi
  printf '✓ 发版前验收通过（台账 #%s，%s..%s）：%s 项用户可见改动都已验，验过之后相关文件没再改\n' \
    "$LEDGER" "$LEDGER_SINCE" "$TO" "$(grep -c . "${TMP}/scope")"
  exit 0
fi

# ── 更新台账 ─────────────────────────────────────────────────────────────
if [ -n "$LEDGER" ]; then
  need_ref "$PKG"
  load_ledger
  if [ -n "$LEDGER_SINCE" ]; then
    if [ -n "$SINCE" ] && [ "$SINCE" != "$LEDGER_SINCE" ]; then
      printf '✗ 台账 #%s 记的起点是 %s，和 --since %s 不一致（一个版本一张台账）\n' "$LEDGER" "$LEDGER_SINCE" "$SINCE" >&2
      exit 2
    fi
    SINCE="$LEDGER_SINCE"
  fi
  [ -n "$SINCE" ] || SINCE="$(last_formal "$PKG")"
  [ -n "$SINCE" ] || { printf '✗ %s 往前找不到正式 tag，用 --since 指定\n' "$PKG" >&2; exit 2; }
  need_ref "$SINCE"
  compute_scope "$SINCE" "$PKG"
  : >"${TMP}/new-items"
  N_NEW=0 N_RE=0 N_KEEP=0 N_WAIT=0
  while read -r pr kind; do
    it="$(item_of "$pr")"
    if [ -z "$it" ]; then
      printf -- '- [ ] #%s %s | 待验 @%s | 场景：%s\n' "$pr" "$kind" "$PKG" "$(scene_of "$pr")" >>"${TMP}/new-items"
      printf '新增  #%s（%s）\n' "$pr" "$kind"
      N_NEW=$((N_NEW + 1))
      continue
    fi
    scene="$(printf '%s\n' "$it" | awk -F' [|] ' '{ print $3 }')"
    tail_="$(item_tail "$it")"
    v="$(item_pkg "$it")"
    if item_checked "$it"; then
      moved="$(changed_since "$v" "$PKG" "$pr")"
      if [ -z "$moved" ]; then
        printf -- '- [x] #%s %s | 已验 @%s | %s%s\n' "$pr" "$kind" "$v" "$scene" "$tail_" >>"${TMP}/new-items"
        N_KEEP=$((N_KEEP + 1))
      else
        why="又改了 $(printf '%s\n' "$moved" | paste -sd ' ' -)"
        [ "$moved" != "?" ] || why="判不了改动"
        printf -- '- [ ] #%s %s | 待重验 @%s（上次验过 @%s，%s） | %s%s\n' "$pr" "$kind" "$PKG" "${v:-?}" "$why" "$scene" "$tail_" >>"${TMP}/new-items"
        printf '待重验 #%s（%s）：上次验过 @%s，%s\n' "$pr" "$kind" "${v:-?}" "$why"
        N_RE=$((N_RE + 1))
      fi
    else
      # 还没验的：待验包更新成新包，「待验 / 待重验」原样保留。
      word="$(printf '%s\n' "$it" | awk -F' [|] ' '{ print $2 }' | grep -oE '^待重?验')"
      [ -n "$word" ] || word="待验"
      printf -- '- [ ] #%s %s | %s @%s | %s%s\n' "$pr" "$kind" "$word" "$PKG" "$scene" "$tail_" >>"${TMP}/new-items"
      N_WAIT=$((N_WAIT + 1))
    fi
  done <"${TMP}/scope"
  # 台账里有、这次范围里没有的项（不该发生）原样保留，不悄悄丢。
  while read -r it; do
    pr="$(printf '%s\n' "$it" | sed -n -E 's/^- \[[ xX]\] #([0-9]+) .*/\1/p')"
    grep -qE "^${pr} " "${TMP}/scope" || printf '%s\n' "$it" >>"${TMP}/new-items"
  done <"${TMP}/items"
  {
    printf '<!-- release-ledger:begin since=%s -->\n' "$SINCE"
    cat "${TMP}/new-items"
    printf '%s\n' "$LEDGER_END"
  } >"${TMP}/block"
  if [ -n "$LEDGER_SINCE" ]; then
    awk -v blk="${TMP}/block" -v end="$LEDGER_END" '
      /^<!-- release-ledger:begin / { while ((getline l < blk) > 0) print l; skip = 1; next }
      skip && $0 == end { skip = 0; next }
      !skip { print }
    ' "${TMP}/ledger-body" >"${TMP}/new-body"
  else
    { cat "${TMP}/ledger-body"; printf '\n'; cat "${TMP}/block"; } >"${TMP}/new-body"
  fi
  printf '台账 #%s（%s..%s）：新增 %s，待重验 %s，仍待验 %s，沿用 %s\n' "$LEDGER" "$SINCE" "$PKG" "$N_NEW" "$N_RE" "$N_WAIT" "$N_KEEP"
  if failed; then
    printf '✗ 有 PR 或卡读不到，台账没改（fail-closed）\n' >&2
    exit 1
  fi
  if [ "$DRY" = 1 ]; then
    cat "${TMP}/block"
    exit 0
  fi
  gh issue edit "$LEDGER" -R "$REPO" --body-file "${TMP}/new-body" >/dev/null 2>"${TMP}/err" || {
    printf '✗ 写台账 #%s 失败：%s\n' "$LEDGER" "$(head -3 "${TMP}/err" | tr '\n' ' ')" >&2
    exit 1
  }
  exit 0
fi

# ── 只列范围 ─────────────────────────────────────────────────────────────
[ -n "$TO" ] || TO="origin/main"
need_ref "$TO"
[ -n "$SINCE" ] || SINCE="$(last_formal "$TO")"
[ -n "$SINCE" ] || { printf '✗ %s 往前找不到正式 tag，用 --since 指定\n' "$TO" >&2; exit 2; }
need_ref "$SINCE"
compute_scope "$SINCE" "$TO"
printf '验收范围 %s..%s：%s 个 PR 里 %s 个用户看得见\n' "$SINCE" "$TO" "$(grep -c . "${TMP}/allprs")" "$(grep -c . "${TMP}/scope")"
while read -r pr kind; do
  printf -- '- #%s %s | 场景：%s\n' "$pr" "$kind" "$(scene_of "$pr")"
done <"${TMP}/scope"
if failed; then
  printf '✗ 有 PR 或卡读不到，范围可能不全（fail-closed）\n' >&2
  exit 1
fi
exit 0
