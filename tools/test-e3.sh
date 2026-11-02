#!/usr/bin/env bash
# tools/e3 自测（离线，不碰设备）：脚本语法、场景接口齐全、判定回放（fixtures 的 pass 必须过、fail 必须红）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E3="$ROOT/tools/e3"
fails=0
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

for f in "$E3"/run "$E3"/verify "$E3"/lock "$E3"/dev "$E3"/restore "$E3"/lib/*.sh "$E3"/scenarios/*/*.sh; do
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
  "$E3/run" judge "$id" "$d/pass" >/dev/null || bad "${id}：pass fixture 没判过"
  "$E3/run" judge "$id" "$d/fail" >/dev/null && bad "${id}：fail fixture 没判红"
done

# #1311 数据快照：服务在跑不存；存 → 候选改库（新迁移、新文件）→ 恢复后库回到快照，照片原件不动
(
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  MAC_APP="$d/none.app" E3_MAC_DATA_DIR="$d/as" E3_STATE="$d/state"
  log() { :; }
  running=1
  svc_any_pid() { [ "$running" = 1 ] && echo 123; return 0; }
  # shellcheck source=e3/lib/mac-install.sh
  source "$E3/lib/mac-install.sh"
  mkdir -p "$d/as/libraries/x" "$d/lib/.ppf" "$d/lib/originals"
  printf 'data_dir = "%s"\n' "$d/lib" >"$d/as/config.toml"
  echo v13 >"$d/as/libraries/x/index.sqlite"
  echo id >"$d/lib/.ppf/library-id"
  echo a >"$d/lib/originals/a.jpg"
  mac_data_save "$d/snap" && { echo "服务在跑时存了快照"; exit 1; }
  running=0
  mac_data_save "$d/snap" || { echo "存快照失败"; exit 1; }
  echo v14 >"$d/as/libraries/x/index.sqlite"
  echo n >"$d/as/libraries/x/new-thumb"
  echo n >"$d/lib/.ppf/extra"
  echo b >"$d/lib/originals/b.jpg"
  mac_data_restore "$d/snap" || { echo "恢复失败"; exit 1; }
  [ "$(cat "$d/as/libraries/x/index.sqlite")" = v13 ] || { echo "库索引没回到快照"; exit 1; }
  [ ! -e "$d/as/libraries/x/new-thumb" ] && [ ! -e "$d/lib/.ppf/extra" ] || { echo "候选新写的文件残留"; exit 1; }
  [ -f "$d/lib/originals/b.jpg" ] || { echo "照片原件被动了"; exit 1; }
  [ "$(mac_library_dir "$d/as")" = "$d/lib" ] || { echo "库目录读错"; exit 1; }
) || bad "mac 数据快照存/恢复"

# 设备锁：第二个持锁者要等第一个释放（/usr/bin/lockf 只有 macOS 有）
if [ "$(uname)" = Darwin ]; then
lockdir="$(mktemp -d)"
E3_STATE="$lockdir" "$E3/lock" ios sh -c 'sleep 2' &
sleep 0.5
t0=$SECONDS
E3_STATE="$lockdir" "$E3/lock" ios true 2>/dev/null
[ $((SECONDS - t0)) -ge 1 ] || bad "设备锁没有排队"
wait
rm -rf "$lockdir"
fi

[ "$fails" -eq 0 ] && echo "ok: tools/e3 自测通过" || { echo "$fails 项失败"; exit 1; }
