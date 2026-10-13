#!/usr/bin/env bash
# IOS-06（#313）：在 iOS 模拟器上跑 apps/ios/TransportFFITests。
#
#   tools/ios/test-transport-ffi.sh          # 本机与 CI（ci-ios.yml）同一条命令
#
# 1. tools/build-ios-transport-xcframework.sh → apps/ios/TransportFFITests/Generated/
# 2. 起一个隔离的本机 daemon 给控制面测试连：fake HOME + 临时 PPF_DATA_DIR + 127.0.0.1:0
#    （OS 分配端口，绝不用 41145）+ 无 relay + --ephemeral（本脚本退出 ⇒ stdin 关 ⇒ daemon 退出）。
#    端口用 lsof 从 daemon 进程上读，PeerAddr token = base64url(JSON{id, addrs:[{Ip}]})。
# 3. xcodebuild test，token 经 TEST_RUNNER_ 前缀传进测试进程；PPASS_REQUIRE_DAEMON=1 让
#    「没连上 daemon 就跳过」变成失败。
#
# 模拟器选择、"Unable to find a destination" 的处理同 tools/ios/test.sh。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/apps/ios/TransportFFITests"
cd "$ROOT"

command -v jq >/dev/null || { echo "error: 缺 jq（brew install jq）" >&2; exit 1; }

"$ROOT/tools/build-ios-transport-xcframework.sh" "$PKG/Generated"

# PPASS_DAEMON_PROFILE=dev：CI 用 debug 构建省时间（这里只要一个能答 hello 的 daemon，
# 与发行优化无关）；默认 release 与本机常用产物一致。
case "${PPASS_DAEMON_PROFILE:-release}" in
  release) RELEASE_FLAG=--release; DAEMON="$ROOT/target/release/daemon" ;;
  dev) RELEASE_FLAG=; DAEMON="$ROOT/target/debug/daemon" ;;
  *) echo "error: PPASS_DAEMON_PROFILE 只能是 release / dev" >&2; exit 1 ;;
esac
echo "==> daemon（${PPASS_DAEMON_PROFILE:-release}，宿主机）"
cargo build -q -p daemon ${RELEASE_FLAG:+"$RELEASE_FLAG"}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-ios-ffi.XXXXXX")
DAEMON_PID=
cleanup() {
  exec 4>&- 2>/dev/null || true
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SIM_SHUTDOWN:-}" ]; then
    xcrun simctl shutdown "$SIM_SHUTDOWN" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/home" "$WORK/data"
mkfifo "$WORK/stdin"
HOME="$WORK/home" \
  PPF_DATA_DIR="$WORK/data" \
  PPF_BIND_ADDR="127.0.0.1:0" \
  PPF_RELAY_URLS="" \
  PPF_TELEMETRY_ENABLED=false \
  "$DAEMON" --ephemeral <"$WORK/stdin" >"$WORK/daemon.out" 2>"$WORK/daemon.err" &
DAEMON_PID=$!
exec 4>"$WORK/stdin"

NODE_ID=
for _ in $(seq 1 150); do
  NODE_ID=$(sed -n 's/^NodeId: \([0-9a-f]\{64\}\).*/\1/p' "$WORK/daemon.out" | head -1)
  [ -n "$NODE_ID" ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.2
done
if [ -z "$NODE_ID" ]; then
  echo "error: daemon 没打出 NodeId" >&2
  cat "$WORK/daemon.out" "$WORK/daemon.err" >&2
  exit 1
fi

PORT=
for _ in $(seq 1 50); do
  PORT=$(lsof -nP -a -p "$DAEMON_PID" -iUDP@127.0.0.1 -Fn 2>/dev/null | sed -n 's/^n127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -1)
  [ -n "$PORT" ] && break
  sleep 0.2
done
if [ -z "$PORT" ] || [ "$PORT" = 41145 ]; then
  echo "error: 没拿到 daemon 的 127.0.0.1 UDP 端口（得到「${PORT}」）" >&2
  lsof -nP -a -p "$DAEMON_PID" -i >&2 || true
  exit 1
fi
TOKEN=$(jq -cn --arg id "$NODE_ID" --arg ip "127.0.0.1:$PORT" '{id: $id, addrs: [{Ip: $ip}]}' \
  | base64 | tr -d '\n=' | tr '+/' '-_')
echo "daemon pid=${DAEMON_PID} node=${NODE_ID:0:8}… udp=127.0.0.1:${PORT}"

UDID=$("$ROOT/tools/ios/sim.sh" udid)
STATE=$(xcrun simctl list devices -j | jq -r --arg u "$UDID" '.devices[][] | select(.udid == $u) | .state')
[ "$STATE" = "Booted" ] || SIM_SHUTDOWN="$UDID"
echo "模拟器：${UDID}（运行前状态 ${STATE}）"

cd "$PKG"
if ! TEST_RUNNER_PPASS_DAEMON_TOKEN="$TOKEN" \
  TEST_RUNNER_PPASS_REQUIRE_DAEMON=1 \
  xcodebuild test \
    -scheme TransportFFITests \
    -destination "id=${UDID}" \
    -derivedDataPath "$ROOT/apps/ios/build/TransportFFITests-DerivedData" \
    "$@"; then
  echo "error: xcodebuild test 失败。若是 \"Unable to find a destination\"，见 tools/ios/test.sh 里的说明。" >&2
  echo "--- daemon stderr ---" >&2
  tail -20 "$WORK/daemon.err" >&2 || true
  exit 1
fi
