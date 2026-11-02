#!/usr/bin/env bash
# just stuck <issue号> "<原因>"：四种必须停下的情况的统一出口
# （命中核心 / 需改范围外文件 / 没有可用的验收场景 / 同一处连红 3 次）。
# 在 issue 里写评论 + 打 status:blocked（去掉 doing/ready/review），然后去做下一张卡。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FLOW_PATHS="${HERE}/../ci-paths.sh"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

N="${1:-}"
REASON="${2:-}"
[[ "$N" =~ ^[0-9]+$ ]] && [ -n "$(printf '%s' "$REASON" | tr -d '[:space:]')" ] ||
  die "用法: just stuck <issue号> \"<原因>\"" \
    "原因写清：属于哪种（命中核心 / 需改范围外文件 / 没有验收场景 / 连红 3 次）、停在哪、还剩什么。"
command -v gh >/dev/null 2>&1 || die "找不到 gh"
REPO="$(flow_repo)"
flow_load_issue "$N"

branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
  echo "**worker 停下，等 owner 处理**"
  echo
  printf '%s\n' "$REASON" | scrub
  echo
  [ -z "$branch" ] || echo "当前分支：\`${branch}\`（改动不会推送）"
} >"$tmp"
flow_comment "$N" "$tmp"
flow_labels "$N" "status:blocked" "status:doing,status:ready,status:review"
echo "已在 #${N} 记录原因并打 status:blocked。现在去领下一张卡：just start <下一个 issue号>"
