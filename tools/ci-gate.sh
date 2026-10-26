#!/usr/bin/env bash
# #1187：每条 CI 末尾的汇总 job 调它，分支保护只要求这个汇总检查。
#
#   NEEDS='${{ toJSON(needs) }}' tools/ci-gate.sh
#
# 上游任一 job 是 failure / cancelled ⇒ 退出 1；success 与 skipped（按需跳过）⇒ 通过。
# 汇总 job 必须写 `if: always()`：否则上游一红它就被跳过，而 skipped 对必过项算通过，
# 等于没设门。读不懂 NEEDS（空、不是 JSON、一个 job 都没有）一律判失败。

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::找不到 jq，无法判定 → 失败"
  exit 1
fi

if ! rows="$(printf '%s' "${NEEDS:-}" | jq -er 'to_entries | if length == 0 then error("empty") else .[] | "\(.key) \(.value.result)" end' 2>/dev/null)"; then
  echo "::error::NEEDS 读不懂或为空（${NEEDS:-<未设置>}）→ 失败"
  exit 1
fi

bad=0
while read -r job result; do
  case "$result" in
    success | skipped) echo "OK    ${job}: ${result}" ;;
    *)
      echo "::error::${job}: ${result}"
      bad=1
      ;;
  esac
done <<EOF
$rows
EOF

exit "$bad"
