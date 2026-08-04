#!/usr/bin/env bash
# T-051 live acceptance: spin up a throwaway daemon, then run the JVM
# hello test through the real iroh-ffi stack (desktop natives).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D=$(mktemp -d /tmp/ppf-android-hello.XXXX)
# 失败时保留 daemon 日志尾部（CI 诊断；成功路径不打印）。
# kill $DPID 精确杀自起 daemon（pkill -f "$D" 匹配不到——PPF_DATA_DIR 是
# 环境变量不在命令行里，会残留孤儿 daemon）。
trap 'rc=$?; kill "$DPID" 2>/dev/null || true; if [ "$rc" -ne 0 ] && [ -f "$D/d.log" ]; then echo "=== daemon log (exit $rc) ==="; tail -30 "$D/d.log" || true; fi; rm -rf "$D"' EXIT
mkdir -p "$D/library"
PPF_DATA_DIR="$D/library" PPF_TELEMETRY_ENABLED=false PPF_RELAY_URLS="" \
  PPF_BIND_ADDR="127.0.0.1:0" \
  "$ROOT/target/release/daemon" > "$D/d.log" 2>&1 &
DPID=$!
for _ in $(seq 1 50); do grep -q 'ppf://pair' "$D/d.log" 2>/dev/null && break; sleep 0.2; done
QR=$(grep -o 'ppf://pair[^ ]*' "$D/d.log")
cd "$ROOT/apps/android"
JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk)}" PPF_DAEMON_QR="$QR" \
  ./gradlew :app:testDebugUnitTest --tests '*DaemonHelloTest' --rerun
grep -o "HELLO OK[^<]*" app/build/test-results/testDebugUnitTest/TEST-*DaemonHelloTest.xml
