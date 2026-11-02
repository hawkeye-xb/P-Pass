#!/usr/bin/env bash
# 按「CI 检查 → 本地命令」对照表（tools/flow/ci-local-map.tsv）在本机（Mac）跑 CI 的对应步骤。
# just batch-verify 调它；也可以单独对任何检出跑（验证旧提交、只跑某个 job）。说明见 docs/runbook/owner.md。
#
#   tools/flow/owner-ci-local.sh [--repo <检出目录>] [--out <目录>] [--base <ref>] [--only <workflow:job>]...
#
#   --repo   被验证的检出（默认当前目录）。对照表从本脚本所在目录读，命令在 --repo 里跑。
#   --out    日志与结果目录（默认临时目录）：每步一个 .log；rows.md 是报告表格行，
#            ci-only.md 是「只能 CI」项，skipped.md 是 gate 判定不用跑的 job。
#   --base   路径判定的基准（默认 merge-base HEAD origin/main），也是 @BASE@ 占位符的值。
#   --only   只跑这些 job，忽略 gate（可重复），例：--only ci-ios.yml:ios
#
# 任何一步红即停（后面的步骤不跑）。最后一行：CI-LOCAL PASS <步数> 或 CI-LOCAL FAIL <步骤>。
# 退出码：0 全绿 / 1 有一步红 / 2 用法错或判不了。
# 每步套重编译互斥锁（PPASS_HEAVY_LOCK，默认 /tmp/ppass-heavy-build.lock），与别的会话的编译排队。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MAP="${PPASS_CI_LOCAL_MAP:-${HERE}/ci-local-map.tsv}"
HEAVY_LOCK="${PPASS_HEAVY_LOCK:-/tmp/ppass-heavy-build.lock}"
REPO="."
OUT=""
BASE=""
ONLY=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo 要跟目录}"; shift 2 ;;
    --out) OUT="${2:?--out 要跟目录}"; shift 2 ;;
    --base) BASE="${2:?--base 要跟 ref}"; shift 2 ;;
    --only) ONLY+=(--only "${2:?--only 要跟 workflow:job}"); shift 2 ;;
    *) sed -n 2,16p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
REPO="$(cd "$REPO" && git rev-parse --show-toplevel)" || { echo "error: --repo 不是 git 检出" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$(mktemp -d "${TMPDIR:-/tmp}/ppass-ci-local.XXXXXX")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
: >"${OUT}/rows.md"
: >"${OUT}/ci-only.md"
: >"${OUT}/skipped.md"

plan="${OUT}/plan.tsv"
if ! python3 "${HERE}/ci-local-map.py" plan --map "$MAP" --where mac --repo "$REPO" ${BASE:+--base "$BASE"} \
  "${ONLY[@]+"${ONLY[@]}"}" >"$plan" 2>"${OUT}/plan.err"; then
  cat "${OUT}/plan.err" >&2
  echo "CI-LOCAL FAIL 对照表取步骤失败"
  exit 2
fi

lock() {
  if command -v lockf >/dev/null 2>&1; then lockf -k "$HEAVY_LOCK" "$@"; else "$@"; fi
}

echo "仓库：${REPO}（$(git -C "$REPO" rev-parse --short=12 HEAD)）  日志：${OUT}" >&2
n=0
while IFS=$'\t' read -r kind name cmd; do
  case "$kind" in
    CIONLY) printf -- '- %s：%s\n' "$name" "$cmd" >>"${OUT}/ci-only.md"; continue ;;
    SKIP) printf -- '- %s：%s\n' "$name" "$cmd" >>"${OUT}/skipped.md"; continue ;;
    RUN) ;;
    *) continue ;;
  esac
  log="${OUT}/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_').log"
  printf '\n==> %s\n' "$name" >&2
  t0=$(date +%s)
  # 每步一个新的 bash：cd 不串到下一步；stdin 关掉，免得步骤读走计划文件。
  (cd "$REPO" && lock bash -c "set -o pipefail; ${cmd}") >"$log" 2>&1 </dev/null
  rc=$?
  dt=$(($(date +%s) - t0))
  if [ "$rc" -ne 0 ]; then
    printf '| %s | FAIL（退出码 %s） | %ss | %s |\n' "$name" "$rc" "$dt" "$log" >>"${OUT}/rows.md"
    tail -n 40 "$log" >&2
    echo "CI-LOCAL FAIL ${name}"
    exit 1
  fi
  printf '| %s | PASS | %ss | %s |\n' "$name" "$dt" "$log" >>"${OUT}/rows.md"
  printf 'ok: %s（%ss）\n' "$name" "$dt" >&2
  n=$((n + 1))
done <"$plan"
echo "CI-LOCAL PASS ${n}"
