#!/usr/bin/env bash
# CI-11 (#255) / CI-17 (#373) / #2089: 判定一次改动要不要跑「重型门禁」（Rust 全量 / 桌面壳）。
#
# 统一委托给仓库静态依赖图引擎 tools/ci/impact.py，保持 CLI 契约不变：
#   tools/ci-needs-full-lane.sh <base-sha>                  # 默认 lane (default)
#   tools/ci-needs-full-lane.sh <base-sha> rust-workspace   # 宽 lane
#   cat filelist | tools/ci-needs-full-lane.sh - [lane]      # stdin（测试用）
#
# stdout 恒为一行 `true` / `false`（true = 要跑）。理由写 stderr。
# 退出码恒为 0；任何异常（缺失引擎、未知 lane、空列表、git 失败）全部 fail-closed 判 true。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPACT_PY="${SCRIPT_DIR}/ci/impact.py"
BASE="${1:-}"
LANE="${2:-default}"

say() { printf '%s\n' "$*" >&2; }

if [ ! -f "$IMPACT_PY" ]; then
  say "缺少依赖图引擎「${IMPACT_PY}」→ 保守判定：要跑"
  printf 'true\n'
  exit 0
fi

PY=""
for cand in python3 python py; do
  if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    PY="$cand"
    break
  fi
done

if [ -z "$PY" ]; then
  say "找不到可用的 Python 3 解释器 → 保守判定：要跑"
  printf 'true\n'
  exit 0
fi

out="$("$PY" -B -I "$IMPACT_PY" ci --base "$BASE" --lane "$LANE")"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  say "impact.py 执行异常（rc=${rc}）→ 保守判定：要跑"
  printf 'true\n'
  exit 0
fi

case "$out" in
  true | false) printf '%s\n' "$out" ;;
  *)
    say "impact.py 输出非预期值「${out}」→ 保守判定：要跑"
    printf 'true\n'
    ;;
esac
exit 0
