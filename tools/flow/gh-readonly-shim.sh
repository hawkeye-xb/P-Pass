#!/usr/bin/env bash
# 只读 gh 垫片（供 V3 执行会话前置到 PATH）：
#   - 放行：gh issue view / gh issue list / gh pr create / gh pr view / gh pr checks / gh pr status / gh release view
#   - 拦截：gh issue edit / close / reopen / delete / comment（防改卡面范围、标签与锁定哈希）及其他写操作，并记入审计日志
#
# 环境变量：
#   PPASS_GH_REAL        真实 gh 二进制路径（未设时自动在 PATH 中跳过本目录查找）
#   PPASS_GH_AUDIT_LOG   被拦截命令的审计日志路径（可选）
#   PPASS_V3_TASK_STORE  本地离线模拟任务目录（设置时 `gh issue view <id>` 直接读 `<dir>/<id>.json`）

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
args=("$@")
sub1="${1:-}"
sub2="${2:-}"

log_blocked() {
  if [ -n "${PPASS_GH_AUDIT_LOG:-}" ]; then
    mkdir -p "$(dirname "${PPASS_GH_AUDIT_LOG}")"
    printf '%s\n' "${args[*]}" >>"${PPASS_GH_AUDIT_LOG}"
  fi
  printf 'PERMISSION_DENIED: worker session cannot mutate GitHub issues, labels, or seals (%s)\n' "${args[*]}" >&2
  exit 1
}

allow=0
case "${sub1}:${sub2}" in
  issue:view | issue:list | pr:view | pr:checks | pr:status | pr:list | pr:diff | pr:create | release:view | release:list | auth:status)
    allow=1
    ;;
  api:*)
    # gh api 仅允许默认 GET（不含 -X/--method 写动词或 -f/-F/--input 表单写载荷）
    allow=1
    prev=""
    for a in "${args[@]:1}"; do
      if [ "${prev}" = "-X" ] || [ "${prev}" = "--method" ]; then
        case "${a}" in GET | get) ;; *) allow=0 ;; esac
      fi
      case "${a}" in
        -X* | --method=* | -f | -f* | --raw-field* | -F | -F* | --field* | --input | --input=*)
          case "${a}" in -XGET | -Xget | --method=GET | --method=get) ;; *) allow=0 ;; esac
          ;;
      esac
      prev="${a}"
    done
    ;;
esac

if [ "${allow}" -ne 1 ]; then
  log_blocked
fi

# 模拟演练场模式：直接从本地任务存储返回只读元数据（不暴露锁定文件源路径）
if [ -n "${PPASS_V3_TASK_STORE:-}" ] && [ "${sub1}" = "issue" ] && [ "${sub2}" = "view" ]; then
  tid="${3:-}"
  tf="${PPASS_V3_TASK_STORE}/${tid}.json"
  if [ -f "${tf}" ]; then
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(json.dumps({"id": d["id"], "title": d["title"], "goal": d["goal"]}, ensure_ascii=False))' "${tf}"
    exit 0
  fi
fi

real_gh="${PPASS_GH_REAL:-}"
if [ -z "${real_gh}" ]; then
  IFS=':' read -r -a parts <<<"${PATH:-}"
  for p in "${parts[@]}"; do
    [ -n "${p}" ] || continue
    p_abs="$(cd "${p}" 2>/dev/null && pwd || true)"
    [ "${p_abs}" = "${HERE}" ] && continue
    if [ -x "${p}/gh" ]; then
      real_gh="${p}/gh"
      break
    fi
  done
fi

[ -n "${real_gh}" ] && [ -x "${real_gh}" ] || {
  echo "gh-readonly-shim: real gh binary not found in PATH" >&2
  exit 127
}
exec "${real_gh}" "${args[@]}"
