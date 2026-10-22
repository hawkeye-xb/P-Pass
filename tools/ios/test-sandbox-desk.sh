#!/usr/bin/env bash
# tools/ios/sandbox-desk.sh 的本机自测（不碰手机）：两台沙盒并存且互不相干、配对串可取、
# 暂停时 IPC 不通恢复后通、desk_stop 之后进程与临时库都不在了。
#
#   tools/ios/test-sandbox-desk.sh [daemon 可执行文件]   # 默认 ${CARGO_TARGET_DIR:-target}/release/daemon
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DAEMON="${1:-${CARGO_TARGET_DIR:-$ROOT/target}/release/daemon}"
[ -x "$DAEMON" ] || { echo "找不到 ${DAEMON}（先 cargo build --release -p daemon）" >&2; exit 1; }
# shellcheck source=tools/ios/sandbox-desk.sh
source "$ROOT/tools/ios/sandbox-desk.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-desk-test.XXXXXX")
A="$WORK/A"; B="$WORK/B"
trap 'desk_stop "$A"; desk_stop "$B"; rm -rf "$WORK"' EXIT
FAIL=0
check() { # $1 = 说明，其余 = 命令
  local what="$1"; shift
  if "$@"; then echo "  ok   $what"; else echo "  FAIL $what"; FAIL=1; fi
}
mkdir -p "$A" "$B"
desk_start "$A" "$DAEMON"
desk_start "$B" "$DAEMON"
desk_auto_allow "$A"
SA=$(cat "$A/sandbox"); SB=$(cat "$B/sandbox"); PA=$(cat "$A/pid"); PB=$(cat "$B/pid")
check "两台 NodeId 不同" [ "$(desk_node "$A")" != "$(desk_node "$B")" ]
check "两台各自的临时库" [ "$SA" != "$SB" ]
check "A 的库是空的" [ "$(desk_photo_count "$A")" = 0 ]
check "B 的库是空的" [ "$(desk_photo_count "$B")" = 0 ]
desk_qr "$A"; QA="$PAIR_QR"
check "A 的配对串指向 A" grep -q "node=$(desk_node "$A")" <<<"$QA"
desk_qr "$B"
check "B 的配对串指向 B" grep -q "node=$(desk_node "$B")" <<<"$PAIR_QR"
desk_pause "$A"
# 暂停时请求发得出去但没人答：2 秒后它应仍卡着（本机没有 timeout 命令，不能拿「失败」当「卡住」）。
desk_ipc "$A" status >/dev/null 2>&1 &
PROBE=$!
sleep 2
check "A 暂停时 IPC 不答" kill -0 "$PROBE"
check "A 暂停不影响 B" [ "$(desk_photo_count "$B")" = 0 ]
desk_resume "$A"
check "A 恢复后卡着的那次请求答上了" wait "$PROBE"
check "A 恢复后 IPC 通" [ "$(desk_photo_count "$A")" = 0 ]
desk_stop "$A"; desk_stop "$B"
check "A 进程已退出" bash -c "! kill -0 $PA 2>/dev/null"
check "B 进程已退出" bash -c "! kill -0 $PB 2>/dev/null"
check "A 的临时库已删" [ ! -e "$SA" ]
check "B 的临时库已删" [ ! -e "$SB" ]
check "再调一次 desk_stop 不出错（幂等）" desk_stop "$A"
if [ "$FAIL" != 0 ]; then echo "sandbox-desk 自测失败"; exit 1; fi
echo "sandbox-desk 自测通过"
