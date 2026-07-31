#!/usr/bin/env bash
# T-054 live acceptance: full phone backup pipeline (pair → manifest →
# push → commit → idempotent rerun) against a throwaway daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D=$(mktemp -d /tmp/ppf-android-backup.XXXX)
trap 'pkill -f "$D" 2>/dev/null || true; rm -rf "$D"' EXIT
mkdir -p "$D/library"
PPF_DATA_DIR="$D/library" PPF_TELEMETRY_ENABLED=false PPF_RELAY_URLS="" \
  "$ROOT/target/release/daemon" > "$D/d.log" 2>&1 &
for _ in $(seq 1 50); do grep -q 'ppf://pair' "$D/d.log" 2>/dev/null && break; sleep 0.2; done
QR=$(grep -o 'ppf://pair[^ ]*' "$D/d.log")
cd "$ROOT/apps/android"
JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk)}" \
  PPF_DAEMON_QR="$QR" PPF_DAEMON_IPC="$D/library/ipc.token" \
  ./gradlew -q :app:testDebugUnitTest --tests '*DaemonBackupTest' --rerun
grep -o "BACKUP OK[^<]*" app/build/test-results/testDebugUnitTest/TEST-*DaemonBackupTest.xml
