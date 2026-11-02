#!/usr/bin/env bash
# tools/e3 自测（离线，不碰设备）：脚本语法、场景接口齐全、判定回放（fixtures 的 pass 必须过、fail 必须红）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E3="$ROOT/tools/e3"
fails=0
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

for f in "$E3"/run "$E3"/verify "$E3"/lock "$E3"/lib/*.sh "$E3"/scenarios/*/*.sh; do
  bash -n "$f" || bad "语法：$f"
done
for f in "$E3"/scenarios/*/*.sh; do
  grep -q '^DESC="' "$f" || bad "缺 DESC：$f"
  grep -q '^judge()' "$f" "$E3"/lib/android-*.sh 2>/dev/null || bad "缺 judge：$f"
  if grep -q '^COUNTER=on' "$f" && ! grep -q '^counter()' "$f"; then
    # 共享库里定义 counter 的（android-thumb.sh）也算
    grep -q 'source "$E3_LIB/android-thumb.sh"' "$f" || bad "COUNTER=on 却没有 counter：$f"
  fi
done
[ "$("$E3/run" list | wc -l | tr -d ' ')" -ge 8 ] || bad "run list 列不全"

# 判定回放：fixtures/<场景 id 的 / 换成 ->/{pass,fail}
for d in "$E3"/fixtures/*/; do
  id="$(basename "$d")"
  id="${id/-//}"
  "$E3/run" judge "$id" "$d/pass" >/dev/null || bad "$id：pass fixture 没判过"
  "$E3/run" judge "$id" "$d/fail" >/dev/null && bad "$id：fail fixture 没判红"
done

# 设备锁：第二个持锁者要等第一个释放
lockdir="$(mktemp -d)"
E3_STATE="$lockdir" "$E3/lock" ios sh -c 'sleep 2' &
sleep 0.5
t0=$SECONDS
E3_STATE="$lockdir" "$E3/lock" ios true 2>/dev/null
[ $((SECONDS - t0)) -ge 1 ] || bad "设备锁没有排队"
wait
rm -rf "$lockdir"

[ "$fails" -eq 0 ] && echo "ok: tools/e3 自测通过" || { echo "$fails 项失败"; exit 1; }
