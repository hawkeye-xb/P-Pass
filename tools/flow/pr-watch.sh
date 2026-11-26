#!/usr/bin/env bash
# just pr-watch：仓库级多 PR 边沿触发监视器（0 空转 token，状态跃迁才退出）。
#
# 复用 tools/flow/pr-status.sh（可通过 PR_WATCH_STATUS_BIN 覆盖）与 gh（可通过 PR_WATCH_GH_BIN 覆盖）。
#
# 用法:
#   tools/flow/pr-watch.sh [--interval <秒>] [--state-file <路径>] [--ignore-key <pr:sha:status>]... [PR号...]
#
# 退出码:
#   0  有跟踪中的 PR 变为 MERGED / 全清，或仓库当前无任何 open PR
#   1  有未忽略的 PR 出现卡点（CI 失败 / 冲突 / 未解决评审线程 / 已关闭）
#   2  参数错误或读取 GitHub 状态失败

set -uo pipefail

FLOW_DIR="${PR_WATCH_FLOW_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=repo-lib.sh
. "${FLOW_DIR}/repo-lib.sh"

STATUS_BIN="${PR_WATCH_STATUS_BIN:-${FLOW_DIR}/pr-status.sh}"
GH_BIN="${PR_WATCH_GH_BIN:-gh}"

INTERVAL="45"
STATE_FILE=""
IGNORE_KEYS=""
EXPLICIT_PRS=""

usage() {
  cat <<'EOF'
用法: just pr-watch [--interval <秒>] [--state-file <路径>] [--ignore-key <pr:sha:status>]... [PR号...]

选项:
  --interval <秒>          轮询间隔秒数（默认 45）
  --state-file <路径>      去重状态文件（每行记录已处理的 pr:sha:status 键）
  --ignore-key <键>        忽略指定 pr:sha:status 键（可重复传入）
  -h, --help               显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --interval)
      [ $# -ge 2 ] || { printf '✗ --interval 缺少参数\n' >&2; exit 2; }
      INTERVAL="$2"
      shift 2
      ;;
    --interval=*)
      INTERVAL="${1#--interval=}"
      shift
      ;;
    --state-file)
      [ $# -ge 2 ] || { printf '✗ --state-file 缺少参数\n' >&2; exit 2; }
      STATE_FILE="$2"
      shift 2
      ;;
    --state-file=*)
      STATE_FILE="${1#--state-file=}"
      shift
      ;;
    --ignore-key)
      [ $# -ge 2 ] || { printf '✗ --ignore-key 缺少参数\n' >&2; exit 2; }
      IGNORE_KEYS="${IGNORE_KEYS}${2}"$'\n'
      shift 2
      ;;
    --ignore-key=*)
      IGNORE_KEYS="${IGNORE_KEYS}${1#--ignore-key=}"$'\n'
      shift
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        [[ "$1" =~ ^[0-9]+$ ]] || { printf '✗ PR 号必须是数字：%s\n' "$1" >&2; exit 2; }
        EXPLICIT_PRS="${EXPLICIT_PRS}${1}"$'\n'
        shift
      done
      ;;
    -*)
      printf '✗ 未知选项：%s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ "$1" =~ ^[0-9]+$ ]] || { printf '✗ PR 号必须是数字：%s\n' "$1" >&2; exit 2; }
      EXPLICIT_PRS="${EXPLICIT_PRS}${1}"$'\n'
      shift
      ;;
  esac
done

[[ "${INTERVAL}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  printf '✗ --interval 必须是非负数字：%s\n' "${INTERVAL}" >&2
  exit 2
}

command -v "${GH_BIN}" >/dev/null 2>&1 || [ -x "${GH_BIN}" ] || {
  printf '✗ 找不到 gh：%s\n' "${GH_BIN}" >&2
  exit 2
}
[ -x "${STATUS_BIN}" ] || [ -f "${STATUS_BIN}" ] || {
  printf '✗ 找不到 pr-status 脚本：%s\n' "${STATUS_BIN}" >&2
  exit 2
}

REPO="$(flow_repo 2>&1)" || {
  printf '%s\n' "${REPO}" >&2
  exit 2
}

has_key() {
  local key="$1"
  if [ -n "${IGNORE_KEYS}" ]; then
    if printf '%s' "${IGNORE_KEYS}" | grep -Fxq -- "${key}"; then
      return 0
    fi
  fi
  if [ -n "${STATE_FILE}" ] && [ -f "${STATE_FILE}" ]; then
    if grep -Fxq -- "${key}" "${STATE_FILE}"; then
      return 0
    fi
  fi
  return 1
}

record_key() {
  local key="$1"
  [ -n "${STATE_FILE}" ] || return 0
  if ! mkdir -p "$(dirname "${STATE_FILE}")"; then
    printf '✗ 创建状态文件目录失败：%s\n' "${STATE_FILE}" >&2
    return 1
  fi
  if [ -f "${STATE_FILE}" ] && grep -Fxq -- "${key}" "${STATE_FILE}"; then
    return 0
  fi
  if ! printf '%s\n' "${key}" >>"${STATE_FILE}"; then
    printf '✗ 写入状态文件失败：%s\n' "${STATE_FILE}" >&2
    return 1
  fi
}

add_tracked_pr() {
  local pr="$1"
  if [ -n "${TRACKED_PRS}" ] && printf '%s' "${TRACKED_PRS}" | grep -Fxq -- "${pr}"; then
    return 0
  fi
  TRACKED_PRS="${TRACKED_PRS}${pr}"$'\n'
}

parse_pr_list_tsv() {
  python3 -B -I -c '
import json, sys
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(2)
for item in data:
    num = item.get("number")
    if num is None:
        continue
    state = (item.get("state") or "OPEN").replace("\t", " ").replace("\n", " ").strip()
    sha = (item.get("headRefOid") or "unknown").replace("\t", " ").replace("\n", " ").strip() or "unknown"
    title = (item.get("title") or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()
    print(f"{num}\t{state}\t{sha}\t{title}")
'
}

parse_pr_view_tsv() {
  python3 -B -I -c '
import json, sys
item = json.load(sys.stdin)
if not isinstance(item, dict) or item.get("number") is None:
    sys.exit(2)
num = item.get("number")
state = (item.get("state") or "OPEN").replace("\t", " ").replace("\n", " ").strip()
sha = (item.get("headRefOid") or "unknown").replace("\t", " ").replace("\n", " ").strip() or "unknown"
title = (item.get("title") or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()
print(f"{num}\t{state}\t{sha}\t{title}")
'
}

sleep_interval() {
  case "${INTERVAL}" in
    0 | 0.0 | 0.00) return 0 ;;
  esac
  sleep "${INTERVAL}"
}

TRACKED_PRS=""
EXPLICIT_MODE=0
if [ -n "${EXPLICIT_PRS}" ]; then
  EXPLICIT_MODE=1
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    add_tracked_pr "${p}"
  done <<EOF_PRS
${EXPLICIT_PRS}
EOF_PRS
fi

poll_num=0
consec_gh_err=0

while true; do
  poll_num=$((poll_num + 1))
  open_tsv=""

  if [ "${EXPLICIT_MODE}" -eq 0 ]; then
    if ! list_json="$("${GH_BIN}" pr list -R "${REPO}" --state open --limit 1000 --json number,title,headRefOid,state 2>&1)"; then
      consec_gh_err=$((consec_gh_err + 1))
      if [ "${poll_num}" -eq 1 ] || [ "${consec_gh_err}" -ge 3 ]; then
        printf '✗ 读取 %s 的 open PR 列表失败：\n%s\n' "${REPO}" "${list_json}" >&2
        exit 2
      fi
      sleep_interval
      continue
    fi
    if ! open_tsv="$(printf '%s' "${list_json}" | parse_pr_list_tsv 2>&1)"; then
      consec_gh_err=$((consec_gh_err + 1))
      if [ "${poll_num}" -eq 1 ] || [ "${consec_gh_err}" -ge 3 ]; then
        printf '✗ 解析 open PR 列表 JSON 失败：\n%s\n' "${open_tsv}" >&2
        exit 2
      fi
      sleep_interval
      continue
    fi
    consec_gh_err=0

    open_count=0
    while IFS=$'\t' read -r num _st _sha _title; do
      [ -n "${num}" ] || continue
      open_count=$((open_count + 1))
      add_tracked_pr "${num}"
    done <<EOF_OPEN
${open_tsv}
EOF_OPEN
    if [ "${open_count}" -ge 1000 ]; then
      printf '⚠ %s 的 open PR 数量达到上限 1000，仅跟踪前 1000 个\n' "${REPO}" >&2
    fi

    if [ -z "${TRACKED_PRS}" ]; then
      printf '✅ 当前仓库（%s）无任何 open PR，已清零\n' "${REPO}"
      exit 0
    fi
  fi

  block_summaries=""
  block_keys=""
  ready_summaries=""
  ready_keys=""
  still_open_count=0
  poll_read_err=0

  while IFS= read -r pr; do
    [ -n "${pr}" ] || continue

    gh_state=""
    sha=""
    title=""

    if [ -n "${open_tsv}" ]; then
      matched_row="$(printf '%s\n' "${open_tsv}" | awk -F'\t' -v p="${pr}" '$1 == p { print; exit }')"
      if [ -n "${matched_row}" ]; then
        IFS=$'\t' read -r _n gh_state sha title <<EOF_ROW
${matched_row}
EOF_ROW
      fi
    fi

    if [ -z "${gh_state}" ]; then
      if ! view_json="$("${GH_BIN}" pr view "${pr}" -R "${REPO}" --json number,title,state,headRefOid 2>&1)"; then
        printf '✗ 读取 %s#%s 详情失败：\n%s\n' "${REPO}" "${pr}" "${view_json}" >&2
        poll_read_err=1
        break
      fi
      if ! view_row="$(printf '%s' "${view_json}" | parse_pr_view_tsv 2>&1)"; then
        printf '✗ 解析 %s#%s 详情 JSON 失败：\n%s\n' "${REPO}" "${pr}" "${view_row}" >&2
        poll_read_err=1
        break
      fi
      IFS=$'\t' read -r _n gh_state sha title <<EOF_VROW
${view_row}
EOF_VROW
    fi

    [ -n "${sha}" ] || sha="unknown"

    status_out="$("${STATUS_BIN}" "${pr}" 2>&1)"
    status_rc=$?

    if [ "${status_rc}" -eq 2 ]; then
      printf '✗ 检查 PR #%s 状态失败：\n%s\n' "${pr}" "${status_out}" >&2
      poll_read_err=1
      break
    elif [ "${status_rc}" -eq 3 ]; then
      still_open_count=$((still_open_count + 1))
    elif [ "${status_rc}" -eq 0 ] || [ "${status_rc}" -eq 1 ]; then
      if ! post_json="$("${GH_BIN}" pr view "${pr}" -R "${REPO}" --json number,title,state,headRefOid 2>&1)"; then
        printf '✗ 复核 %s#%s 详情失败：\n%s\n' "${REPO}" "${pr}" "${post_json}" >&2
        poll_read_err=1
        break
      fi
      if ! post_row="$(printf '%s' "${post_json}" | parse_pr_view_tsv 2>&1)"; then
        printf '✗ 解析 %s#%s 复核 JSON 失败：\n%s\n' "${REPO}" "${pr}" "${post_row}" >&2
        poll_read_err=1
        break
      fi
      IFS=$'\t' read -r _pn post_state post_sha post_title <<EOF_POST
${post_row}
EOF_POST
      [ -n "${post_sha}" ] || post_sha="unknown"
      if [ "${post_sha}" != "${sha}" ]; then
        still_open_count=$((still_open_count + 1))
        continue
      fi
      gh_state="${post_state}"
      title="${post_title}"

      if [ "${status_rc}" -eq 0 ]; then
        if [ "${gh_state}" = "CLOSED" ]; then
          still_open_count=$((still_open_count + 1))
          continue
        fi
        ev_status="clear"
        ev_label="CLEAR"
        if [ "${gh_state}" = "MERGED" ]; then
          ev_status="merged"
          ev_label="MERGED"
        fi
        key="${pr}:${sha}:${ev_status}"
        if has_key "${key}"; then
          if [ "${ev_status}" != "merged" ] && [ "${gh_state}" = "OPEN" ]; then
            still_open_count=$((still_open_count + 1))
          fi
        else
          ready_keys="${ready_keys}${key}"$'\n'
          summary="✅ PR #${pr} [${ev_label}] ${title} (sha=${sha}, key=${key})"
          if [ -n "${status_out}" ]; then
            summary="${summary}"$'\n'"${status_out}"
          fi
          ready_summaries="${ready_summaries}${summary}"$'\n'
        fi
      else
        if [ "${gh_state}" = "MERGED" ]; then
          still_open_count=$((still_open_count + 1))
          continue
        fi
        ev_status="failed"
        ev_label="FAILED"
        if [ "${gh_state}" = "CLOSED" ]; then
          ev_status="closed"
          ev_label="CLOSED"
        fi
        key="${pr}:${sha}:${ev_status}"
        if has_key "${key}"; then
          if [ "${ev_status}" != "closed" ] && [ "${gh_state}" = "OPEN" ]; then
            still_open_count=$((still_open_count + 1))
          fi
        else
          block_keys="${block_keys}${key}"$'\n'
          summary="✗ PR #${pr} [${ev_label}] ${title} (sha=${sha}, key=${key})"
          if [ -n "${status_out}" ]; then
            summary="${summary}"$'\n'"${status_out}"
          fi
          block_summaries="${block_summaries}${summary}"$'\n'
        fi
      fi
    else
      printf '✗ pr-status 返回未预期退出码 %s（PR #%s）：\n%s\n' "${status_rc}" "${pr}" "${status_out}" >&2
      poll_read_err=1
      break
    fi
  done <<EOF_TRACKED
${TRACKED_PRS}
EOF_TRACKED

  if [ "${poll_read_err}" -ne 0 ]; then
    exit 2
  fi

  if [ -n "${block_keys}" ] || [ -n "${ready_keys}" ]; then
    while IFS= read -r k; do
      [ -n "${k}" ] || continue
      if ! record_key "${k}"; then
        exit 2
      fi
    done <<EOF_KEYS
${block_keys}${ready_keys}
EOF_KEYS

    if [ -n "${ready_summaries}" ]; then
      printf '%s' "${ready_summaries}"
    fi
    if [ -n "${block_summaries}" ]; then
      printf '%s' "${block_summaries}"
      exit 1
    fi
    exit 0
  fi

  if [ "${still_open_count}" -eq 0 ]; then
    printf '✅ 当前所有跟踪 PR 已完结，无待盯 open PR（%s）\n' "${REPO}"
    exit 0
  fi

  sleep_interval
done
