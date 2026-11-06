#!/usr/bin/env bash
# just gate-status：门现在开着还是关着，关着的那扇有没有账。
#
# 输出三块事实加一句结论：
#   1. 被手动停用的 workflow（GitHub 上的 `disabled_manually`），每一个去找一张开着的、标题提到它名字的卡；
#   2. 在发版调用（`workflow_call`）时被 job 级 `if:` 跳过的门禁：同样按 workflow 的 `name:` 找标题带它的开放卡；
#   3. main 的必需检查清单。
#
# 退出码：0 全部有账 / 1 有停用项没卡，或读不出来（fail-closed）/ 2 用法错误。
#
# 为什么要有这条命令：停用 workflow、从必需检查里撤一项，都是仓库设置动作——不进 git、不产生提交、
# 不走 PR，所以没有任何东西会提醒「这扇门关了」。2026-11-05 发生过一次：CI Review 被手动停掉，
# 第二天 AGENTS.md 仍写着它是必需检查，而没人说得清为什么关着。这条命令给停用动作一个可见的出口：
# 停了没卡，`just gate-status` 就红。
#
# 关联卡的判定：开着的 issue 里，**标题**出现该 workflow 的名字（就是 workflow 里 `name:` 那一行）。
# 只认标题不认正文：正文里顺口提到「CI Review」的卡太多了，那样会把不相干的卡算成账（本命令自己的卡就是这样）。
# 把名字写进卡标题是 owner 的义务，见 AGENTS.md「工程纪律」。
#
# 用法: tools/flow/gate-status.sh
# 环境变量: PPASS_HOOK_REPO 覆盖仓库；GATE_STATUS_ISSUE_LIMIT 覆盖读多少张开放卡（默认 300）；
#           GATE_STATUS_WORKFLOW_DIR 覆盖 workflow 目录（测试用），默认 <仓库根>/.github/workflows。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

REPO="$(flow_repo)"
LIMIT="${GATE_STATUS_ISSUE_LIMIT:-300}"
WORKFLOW_DIR="${GATE_STATUS_WORKFLOW_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)/.github/workflows}"

fail=0
no_card=0

printf '==> 门的状态（%s）\n\n' "${REPO}"

# ── 取数据：四处都按 fail-closed 处理 ────────────────────────────────
wf_err=""
wf_list=""
if ! wf_list="$(gh api "repos/${REPO}/actions/workflows?per_page=100" \
  --jq '.workflows[] | select(.state == "disabled_manually") | .name' 2>&1)"; then
  wf_err="${wf_list}"
  wf_list=""
fi

# 发版调用（workflow_call）时被 job 级 if: 跳过的门禁。按 workflow 的 name: 找账。
# 只认 `github.event_name != 'workflow_call'`（跳过发版）；`== 'workflow_call'`（只跑发版）不是停用。
release_skipped=""
release_skip_err=""
if [ -d "${WORKFLOW_DIR}" ]; then
  if ! release_skipped="$(python3 -I -X utf8 - "${WORKFLOW_DIR}" <<'PY' 2>&1
import os, re, sys

root = sys.argv[1]
skip = re.compile(r"github\.event_name\s*!=\s*'workflow_call'")
rows = []
for fn in sorted(os.listdir(root)):
    if not fn.endswith((".yml", ".yaml")):
        continue
    path = os.path.join(root, fn)
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print(f"{fn}: 读不出（{e}）", file=sys.stderr)
        sys.exit(1)
    name = None
    for line in lines:
        m = re.match(r"^name:\s*(.+?)\s*$", line)
        if m:
            name = m.group(1).strip("'\"")
            break
    hits = []
    current = None
    for line in lines:
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            current = m.group(1)
        # job 级 if 缩进 4 个空格；步骤级 if 更深，不算。
        if re.match(r"^    if:\s*", line) and skip.search(line):
            hits.append(current or "?")
    if hits:
        rows.append("\t".join((name or fn, fn, ",".join(hits))))
print("\n".join(rows))
PY
)"; then
    release_skip_err="${release_skipped}"
    release_skipped=""
  fi
else
  release_skip_err="找不到 workflow 目录：${WORKFLOW_DIR}"
fi

issues=""
issues_err=""
if [ -n "${wf_list}" ] || [ -n "${release_skipped}" ]; then
  if ! issues="$(gh issue list -R "${REPO}" --state open --limit "${LIMIT}" \
    --json number,title --jq '.[] | [.number, .title] | @tsv' 2>&1)"; then
    issues_err="${issues}"
    issues=""
  fi
fi

checks=""
chk_err=""
if ! checks="$(gh api "repos/${REPO}/branches/main/protection" \
  --jq '.required_status_checks.contexts // [] | .[]' 2>&1)"; then
  chk_err="${checks}"
  checks=""
fi

# ── 1. 停用的 workflow ──────────────────────────────────────────────
printf '停用的 workflow：\n'
if [ -n "${wf_err}" ]; then
  printf '  ✗ 读不到 workflow 列表，等于不知道有没有门被关着\n'
  printf '    gh 输出：%s\n' "$(printf '%s' "${wf_err}" | head -2 | tr '\n' ' ')"
  fail=1
elif [ -z "${wf_list}" ]; then
  printf '  （没有）\n'
elif [ -n "${issues_err}" ]; then
  while IFS= read -r wf; do
    [ -n "${wf}" ] || continue
    printf '  ✗ %s —— 有停用项，但读不到开放卡列表，无法确认有没有账\n' "${wf}"
    fail=1
    no_card=$((no_card + 1))
  done <<<"${wf_list}"
  printf '    gh 输出：%s\n' "$(printf '%s' "${issues_err}" | head -2 | tr '\n' ' ')"
else
  while IFS= read -r wf; do
    [ -n "${wf}" ] || continue
    card=""
    while IFS=$'\t' read -r num title; do
      [ -n "${num}" ] || continue
      case "${title}" in
        *"${wf}"*) card="${num}"; break ;;
      esac
    done <<<"${issues}"
    if [ -n "${card}" ]; then
      printf '  ✓ %s —— 卡 #%s\n' "${wf}" "${card}"
    else
      printf '  ✗ %s —— 没有开着的卡：停用就要开卡，写明恢复条件与到期日\n' "${wf}"
      no_card=$((no_card + 1))
      fail=1
    fi
  done <<<"${wf_list}"
fi

printf '\n'

# ── 2. 发版调用时被跳过的门禁 ──────────────────────────────────────
printf '发版上被跳过的 job（workflow_call）：\n'
if [ -n "${release_skip_err}" ]; then
  printf '  ✗ 读不到 workflow 定义，等于不知道有没有发版门禁被跳过\n'
  printf '    错误：%s\n' "$(printf '%s' "${release_skip_err}" | head -2 | tr '\n' ' ')"
  fail=1
elif [ -z "${release_skipped}" ]; then
  printf '  （没有）\n'
elif [ -n "${issues_err}" ]; then
  while IFS=$'\t' read -r wf file jobs; do
    [ -n "${wf}" ] || continue
    printf '  ✗ %s —— %s 的 job %s 在发版调用时跳过，但读不到开放卡列表，无法确认有没有账\n' "${wf}" "${file}" "${jobs}"
    fail=1
    no_card=$((no_card + 1))
  done <<<"${release_skipped}"
  printf '    gh 输出：%s\n' "$(printf '%s' "${issues_err}" | head -2 | tr '\n' ' ')"
else
  while IFS=$'\t' read -r wf file jobs; do
    [ -n "${wf}" ] || continue
    card=""
    while IFS=$'\t' read -r num title; do
      [ -n "${num}" ] || continue
      case "${title}" in
        *"${wf}"*) card="${num}"; break ;;
      esac
    done <<<"${issues}"
    if [ -n "${card}" ]; then
      printf '  ✓ %s —— 卡 #%s（%s 的 job %s）\n' "${wf}" "${card}" "${file}" "${jobs}"
    else
      printf '  ✗ %s —— 没有开着的卡：%s 的 job %s 在发版调用时跳过，停用就要开卡，写明恢复条件与到期日\n' \
        "${wf}" "${file}" "${jobs}"
      no_card=$((no_card + 1))
      fail=1
    fi
  done <<<"${release_skipped}"
fi

printf '\n'

# ── 3. main 的必需检查 ──────────────────────────────────────────────
printf 'main 的必需检查：\n'
count=0
if [ -n "${chk_err}" ]; then
  printf '  ✗ 读不到分支保护（需要仓库 admin 权限），等于不知道哪几道门在挡\n'
  printf '    gh 输出：%s\n' "$(printf '%s' "${chk_err}" | head -2 | tr '\n' ' ')"
  fail=1
elif [ -z "${checks}" ]; then
  printf '  （一道都没有：main 没有必需检查，CI 一绿就能合）\n'
else
  joined=""
  while IFS= read -r c; do
    [ -n "${c}" ] || continue
    count=$((count + 1))
    if [ -z "${joined}" ]; then joined="${c}"; else joined="${joined} · ${c}"; fi
  done <<<"${checks}"
  printf '  %s 项：%s\n' "${count}" "${joined}"
fi

printf '\n'

if [ "${fail}" -ne 0 ]; then
  if [ "${no_card}" -gt 0 ]; then
    printf '✗ %s 个停用项没有卡：门开着还是关着，现在没人记账\n' "${no_card}"
  else
    printf '✗ 有项没查成，按 fail-closed 处理\n'
  fi
  exit 1
fi
printf '✓ 停用的门都有卡（含发版调用时跳过的 job）；必需检查 %s 项\n' "${count}"
exit 0
