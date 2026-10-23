#!/usr/bin/env bash
# IOS-06（#313）：在 iOS 模拟器上跑 apps/ios/TransportFFITests。
#
#   tools/ios/test-transport-ffi.sh          # 本机与 CI（ci-ios.yml）同一条命令
#
# 1. tools/build-ios-transport-xcframework.sh → apps/ios/TransportFFITests/Generated/
# 2. 起一个隔离的本机 daemon 给控制面测试连：fake HOME + 测试沙盒（--ephemeral 自建临时库）+ 0.0.0.0:0
#    （OS 分配端口，绝不用 41145）+ --ephemeral（本脚本退出 ⇒ stdin 关 ⇒ daemon 退出）。
#    PPF_RELAY_URLS="" 等于不覆盖，daemon 仍用默认 n0 relay（日志里有 home relay）。
#    IPv4 端口用 lsof 从 daemon 进程上读，PeerAddr token = base64url(JSON{id, addrs:[{Ip 127.0.0.1:端口}]})。
#
#    为什么绑 0.0.0.0 而不是 127.0.0.1（#942 / #934）：iroh 的 bind_addr 把这个 v4 socket 当成
#    所有 IPv4 目的地的默认路由。模拟器里的 provider 和 daemon 在同一台宿主上，ticket 只给出宿主
#    局域网地址（如 10.1.151.23）；daemon 从 127.0.0.1 socket 发过去，provider 看到连接来自
#    127.0.0.1，握手在 provider 端始终完不成，daemon 端 15 s 后 path idle、30 s 后 connection lost
#    （fetch_failed）。产品 daemon 不显式绑地址（默认 0.0.0.0 + [::]），不走这条路。
#    绑 0.0.0.0 也没有放大暴露面：以前 iroh 照样另绑 [::]:0 监听所有接口；隔离靠的是 fake HOME、
#    临时库、临时身份与随机端口。
# 3. xcodebuild test，token 经 TEST_RUNNER_ 前缀传进测试进程；PPASS_REQUIRE_DAEMON=1 让
#    「没连上 daemon 就跳过」变成失败。
#
# PPASS_FFI_LOG_DIR=<目录>：退出前把 daemon.out / daemon.err 拷过去（临时目录随后删除），
# 配合 RUST_LOG=info,iroh=debug,noq_proto=debug 取证。
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
  release) RELEASE_FLAG=--release; DAEMON="${CARGO_TARGET_DIR:-$ROOT/target}/release/daemon" ;;
  dev) RELEASE_FLAG=; DAEMON="${CARGO_TARGET_DIR:-$ROOT/target}/debug/daemon" ;;
  *) echo "error: PPASS_DAEMON_PROFILE 只能是 release / dev" >&2; exit 1 ;;
esac
echo "==> daemon（${PPASS_DAEMON_PROFILE:-release}，宿主机）"
cargo build -q -p daemon ${RELEASE_FLAG:+"$RELEASE_FLAG"}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-ios-ffi.XXXXXX")
DAEMON_PID=
OWNER_PID=
SUSPENDER_PID=
cleanup() {
  for bg in "$OWNER_PID" "$SUSPENDER_PID"; do
    if [ -n "$bg" ]; then kill "$bg" 2>/dev/null || true; fi
  done
  # 脚本中途失败时绝不把测试进程留在 SIGSTOP 里。
  if [ -s "${E2E:-/nonexistent}/suspend-request" ]; then
    kill -CONT "$(cat "$E2E/suspend-request")" 2>/dev/null || true
  fi
  exec 4>&- 2>/dev/null || true
  if [ -n "${PPASS_FFI_LOG_DIR:-}" ]; then cp "$WORK"/daemon.* "$PPASS_FFI_LOG_DIR"/ 2>/dev/null || true; fi
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

mkdir -p "$WORK/home"
mkfifo "$WORK/stdin"
HOME="$WORK/home" \
  PPF_BIND_ADDR="0.0.0.0:0" \
  PPF_RELAY_URLS="" \
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

# daemon 只该有一个 IPv4 UDP socket（*:端口）。多于一个就说明假设不成立，宁可失败也不猜。
PORTS=
for _ in $(seq 1 50); do
  PORTS=$(lsof -nP -a -p "$DAEMON_PID" -i4UDP -Fn 2>/dev/null | sed -n 's/^n\*:\([0-9][0-9]*\)$/\1/p' | sort -u)
  [ -n "$PORTS" ] && break
  sleep 0.2
done
PORT="$PORTS"
if [ -z "$PORT" ] || [ "$(printf '%s\n' "$PORTS" | wc -l | tr -d ' ')" != 1 ] || [ "$PORT" = 41145 ]; then
  echo "error: 没拿到 daemon 唯一的 IPv4 UDP 端口（得到「$(printf '%s' "$PORTS" | tr '\n' ' ')」）" >&2
  lsof -nP -a -p "$DAEMON_PID" -i >&2 || true
  exit 1
fi
PEER_TOKEN=$(jq -cn --arg id "$NODE_ID" --arg ip "127.0.0.1:$PORT" '{id: $id, addrs: [{Ip: $ip}]}' \
  | base64 | tr -d '\n=' | tr '+/' '-_')
echo "daemon pid=${DAEMON_PID} node=${NODE_ID:0:8}… udp=127.0.0.1:${PORT}"


# ── G2 模拟器版（IOS-07 #334）：配对串 + 自动「业主同意」+ 挂起助手 ──────────
# 配对串经 IPC pairing.start 现取（SEC-11：不落盘），给测试进程解析与配对。
# shellcheck source=tools/ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"
# #1115：--ephemeral 是测试沙盒，库目录由 daemon 自建（stdout 的 SANDBOX: 行），不收路径输入。
ipc_sandbox_dir "$WORK/daemon.out"
ipc_pair_qr "$SANDBOX_DIR/ipc.token"
E2E="$WORK/e2e"
mkdir -p "$E2E"
# 挂起时长默认 5s（远大于测试里 1s 的 GC 周期）。实测冻 12s 时 xcodebuild 把测试进程当成卡死，
# 重启模拟器并以 SIGKILL 结束它（xcresult 记为 Test crashed with signal kill）——那是测试框架的
# 看门狗，不是被测代码；更长的挂起只能在真机上验（IOS-07 验收 2，E3）。
SUSPEND_SECS="${PPASS_SUSPEND_SECS:-5}"

# 业主：把队列里每一条待确认请求点「允许」（这台 daemon 只给本次测试用）。
owner_loop() {
  local resp ids n body code
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    if resp=$(ipc pairing.pending 2>/dev/null); then
      ids=$(printf '%s' "$resp" | jq -r '.result.pending[]?.node_id // empty')
      for n in $ids; do
        # #1118：允许 = 输入手机显示的验证码。测试进程提交成功后把 `PAIR_CODE=<6 位> node=<手机 NodeId>`
        # 写进 $E2E/pair_code.txt；这里按 node 取最后一行，没有码的请求不动。
        code=$(cat "$E2E/pair_code.txt" 2>/dev/null | sed -n "s/.*PAIR_CODE=\([0-9]\{6\}\) node=$n.*/\1/p" | tail -1)
        [ -n "$code" ] || continue
        body=$(jq -cn --arg n "$n" --arg c "$code" '{accept: true, node_id: $n, code: $c}')
        if ipc pairing.confirm "$body" >/dev/null 2>&1; then echo "owner: 已用验证码允许 $n"; fi
      done
    fi
    sleep 0.3
  done
}

# 挂起助手：测试进程写下自己的 pid 请求挂起 ⇒ SIGSTOP 冻住整个进程（计时器、socket 都停，
# 是 iOS 挂起的进程级模型）⇒ SUSPEND_SECS 秒后 SIGCONT ⇒ 写 resumed。
suspend_loop() {
  local pid state
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    if [ -s "$E2E/suspend-request" ]; then
      pid=$(cat "$E2E/suspend-request")
      kill -STOP "$pid"
      state=$(ps -o stat= -p "$pid" | tr -d ' ')
      echo "suspend: pid ${pid} 已 SIGSTOP（ps stat=${state}），${SUSPEND_SECS}s 后恢复"
      sleep "$SUSPEND_SECS"
      kill -CONT "$pid"
      echo "suspend: pid ${pid} 已 SIGCONT"
      printf '%s\n' "$SUSPEND_SECS" > "$E2E/resumed"
      return
    fi
    sleep 0.1
  done
}
owner_loop &
OWNER_PID=$!
suspend_loop &
SUSPENDER_PID=$!

UDID=$("$ROOT/tools/ios/sim.sh" udid)
STATE=$(xcrun simctl list devices -j | jq -r --arg u "$UDID" '.devices[][] | select(.udid == $u) | .state')
[ "$STATE" = "Booted" ] || SIM_SHUTDOWN="$UDID"
echo "模拟器：${UDID}（运行前状态 ${STATE}）"

cd "$PKG"
if ! TEST_RUNNER_PPASS_DAEMON_TOKEN="$PEER_TOKEN" \
  TEST_RUNNER_PPASS_REQUIRE_DAEMON=1 \
  TEST_RUNNER_PPASS_PAIR_LINK="$PAIR_QR" \
  TEST_RUNNER_PPASS_E2E_DIR="$E2E" \
  TEST_RUNNER_PPASS_DAEMON_LIBRARY="$SANDBOX_DIR" \
  TEST_RUNNER_PPASS_SUSPEND_SECS="$SUSPEND_SECS" \
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
