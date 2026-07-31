#!/usr/bin/env bash
# T-054 real-device acceptance against the RESIDENT daemon:
# 1. ask the resident daemon for a pairing QR (IPC)
# 2. run the instrumented test on the adb-attached phone with that QR
# 3. auto-allow the pairing from the owner side (IPC), in parallel
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
DATA_DIR="${PPF_DATA_DIR:-$HOME/ppf-library}"

ipc() {
  python3 - "$DATA_DIR/ipc.token" "$1" "${2:-{}}" <<'PYEOF'
import socket, json, sys
lines = open(sys.argv[1]).read().splitlines()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/' + lines[0].strip())
f = s.makefile('rw')
f.write(lines[1].strip() + '\n'); f.flush()
f.write(json.dumps({"id": "x", "method": sys.argv[2], "params": json.loads(sys.argv[3])}) + '\n'); f.flush()
print(f.readline().strip())
PYEOF
}

QR=$(ipc pairing.start | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['qr'])")
echo "QR from resident daemon: ${QR:0:60}…"

# Owner auto-allow loop (backgrounds; dies with the script).
(
  for _ in $(seq 1 60); do
    sleep 2
    OUT=$(ipc pairing.confirm '{"accept": true}' 2>/dev/null || true)
    if echo "$OUT" | grep -q '"ok":true'; then
      echo "owner allowed: $OUT"
      break
    fi
  done
) &
ALLOW_PID=$!
trap 'kill $ALLOW_PID 2>/dev/null || true' EXIT

cd "$ROOT/apps/android"
JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk)}" \
  ./gradlew -q :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.qr="$QR" \
  --info 2>&1 | grep -E "DEVICE BACKUP OK|FAILED|AssertionError" | head -5 || true

# The truth is on disk: report the library delta.
echo "--- resident library now ---"
find "$DATA_DIR/originals" -type f -newer "$DATA_DIR/ipc.token" 2>/dev/null | head -12
