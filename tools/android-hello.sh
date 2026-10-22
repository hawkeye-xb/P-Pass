#!/usr/bin/env bash
# T-051 live acceptance: spin up a throwaway daemon, then run the JVM
# hello test through the real iroh-ffi stack (desktop natives).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D=$(mktemp -d /tmp/ppf-android-hello.XXXX)
# 失败时保留 daemon 日志尾部（CI 诊断；成功路径不打印）。
# kill $DPID 精确杀自起 daemon（pkill -f 匹配不到，会残留孤儿 daemon）。
trap 'rc=$?; exec 3>&- 2>/dev/null || true; kill "$DPID" 2>/dev/null || true; if [ "$rc" -ne 0 ] && [ -f "$D/d.log" ]; then echo "=== daemon log (exit $rc) ==="; tail -30 "$D/d.log" || true; fi; [ -n "${SANDBOX_DIR:-}" ] && rm -rf "$SANDBOX_DIR"; rm -rf "$D"' EXIT
# #1115：--ephemeral 测试沙盒（库目录由 daemon 自建、stdout 的 SANDBOX: 行给出；不接受
# PPF_DATA_DIR）。stdin 接 FIFO 并保持写端打开：EOF 即退出（UX-07）。
mkfifo "$D/ctl"
PPF_RELAY_URLS="" PPF_BIND_ADDR="127.0.0.1:0" \
  "$ROOT/target/release/daemon" --ephemeral < "$D/ctl" > "$D/d.log" 2>&1 &
DPID=$!
exec 3>"$D/ctl"
for _ in $(seq 1 50); do grep -q 'NodeId:' "$D/d.log" 2>/dev/null && break; sleep 0.2; done
# shellcheck source=./ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"
# SEC-11 (#496)：配对串经 IPC pairing.start 现取（daemon 不再把它打进被重定向的 stdout）
ipc_sandbox_dir "$D/d.log"
ipc_pair_qr "$SANDBOX_DIR/ipc.token"
QR="$PAIR_QR"
cd "$ROOT/apps/android"
source "$ROOT/scripts/java-home.sh"
PPF_DAEMON_QR="$QR" ./gradlew :app:testDebugUnitTest --tests '*DaemonHelloTest' --rerun
grep -o "HELLO OK[^<]*" app/build/test-results/testDebugUnitTest/TEST-*DaemonHelloTest.xml
