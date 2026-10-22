#!/usr/bin/env bash
# tools/ios/sandbox-desk.sh 的本机自测（不碰手机）：两台沙盒并存且互不相干、配对串可取、
# 自动允许按验证码确认（#1118：A 的客户端码在 codes/ 下 → 配对成功；B 的码没人给 → 不被允许）、
# 暂停时 IPC 不通恢复后通、desk_stop 之后进程与临时库都不在了。
#
#   tools/ios/test-sandbox-desk.sh [daemon 可执行文件]   # 默认 ${CARGO_TARGET_DIR:-target}/release/daemon
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DAEMON="${1:-${CARGO_TARGET_DIR:-$ROOT/target}/release/daemon}"
TC="$(dirname "$DAEMON")/testclient"
[ -x "$TC" ] || { echo "找不到 ${TC}（先 cargo build --release -p testclient）" >&2; exit 1; }
[ -x "$DAEMON" ] || { echo "找不到 ${DAEMON}（先 cargo build --release -p daemon）" >&2; exit 1; }
# shellcheck source=tools/ios/sandbox-desk.sh
source "$ROOT/tools/ios/sandbox-desk.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-desk-test.XXXXXX")
A="$WORK/A"; B="$WORK/B"
TCPID=
trap '[ -n "$TCPID" ] && kill "$TCPID" 2>/dev/null; desk_stop "$A"; desk_stop "$B"; rm -rf "$WORK"' EXIT
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
# #1118：自动允许 = 按客户端打出的 PAIR_CODE 输码。
# 正例：A 的客户端输出放进 <A>/codes/，自动允许读到码 → 配对成功。
mkdir -p "$WORK/tcA" "$WORK/tcB"
desk_qr "$A"
(cd "$WORK/tcA" && "$TC" pair --token "$PAIR_QR" --name "自测客户端A" >"$A/codes/client.log" 2>&1) &
TCPID=$!
check "A：有码的客户端被自动允许，配对成功" wait "$TCPID"
TCPID=
check "A：客户端打出了 PAIR_CODE 行" grep -Eq '^PAIR_CODE=[0-9]{6} node=[0-9a-f]{64}' "$A/codes/client.log"
check "A：客户端报配对成功" grep -q '配对成功' "$A/codes/client.log"
# 反证：B 的客户端输出不在 codes/、也没传给 desk_auto_allow ⇒ 没有码 ⇒ 不许允许。
desk_auto_allow "$B"
desk_qr "$B"
(cd "$WORK/tcB" && "$TC" pair --token "$PAIR_QR" --name "自测客户端B" >"$WORK/B-client.log" 2>&1) &
TCPID=$!
for _ in $(seq 1 50); do
  [ "$(desk_ipc "$B" pairing.pending | jq '.result.pending | length')" = 1 ] && break
  sleep 0.2
done
check "B：申请已到桌面待确认" [ "$(desk_ipc "$B" pairing.pending | jq '.result.pending | length')" = 1 ]
sleep 3 # 自动允许 0.3s 一轮，给它十轮机会
check "B：没有码的行没被允许（仍待确认）" [ "$(desk_ipc "$B" pairing.pending | jq '.result.pending | length')" = 1 ]
check "B：客户端仍在等（没配对成功）" kill -0 "$TCPID"
check "B：客户端没报配对成功" bash -c "! grep -q '配对成功' '$WORK/B-client.log'"
kill "$TCPID" 2>/dev/null || true
wait "$TCPID" 2>/dev/null || true
TCPID=
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
