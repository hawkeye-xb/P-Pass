#!/usr/bin/env bash
# iOS 真机端到端（#315 / #347）：真机上的 App（已用 -allowProvisioningUpdates 签名并装好）↔ 本机隔离 daemon。
#
#   tools/ios/e2e-device.sh [devicectl 设备标识]      # 输出在 apps/ios/build/e2e-device/
#
# 与 e2e-sim.sh 的差别：
#   - daemon 监听 0.0.0.0:0（OS 分配端口，绝不用 41145）——手机要从局域网 / relay 发现它；其余隔离不变
#     （fake HOME + 临时库 + --ephemeral，不碰本机已装的 P-Pass）。
#   - 手机里是用户的真照片：只读；只备份「张数最少的非空相册」，超过 PPASS_E2E_MAX_ASSETS（默认 12）就拒绝。
#   - E2EDriver 用环境变量启动（devicectl --environment-variables），状态写进 App 容器 Documents/e2e，
#     本脚本用 devicectl device copy from 拉回；「手机原始字节」的 BLAKE3 由 E2EDriver 经独立只读路径
#     （PHAssetResourceManager）算出，写在 status.json 的 originals 里。
#   - 需要用户在手机上点的系统弹窗（相册权限、本地网络权限）脚本不替点，超时就失败并提示。
# 前置：App 已装在真机上（Debug 构建，见 docs/runbook/ios-device-forensics.md）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
OUT="$IOS/build/e2e-device"
DEV="${1:-B2805351-9CD1-55C7-81B0-DBEAD9E86BD3}"
BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
TIMEOUT="${PPASS_E2E_TIMEOUT:-240}"
RUN="run-$(date +%s)"
cd "$ROOT"
for tool in jq lsof; do command -v "$tool" >/dev/null || { echo "error: 缺 $tool" >&2; exit 1; }; done
rm -rf "$OUT"
mkdir -p "$OUT/status"
exec > >(tee "$OUT/e2e.log") 2>&1

cargo build -q -p daemon --release
DAEMON="${CARGO_TARGET_DIR:-$ROOT/target}/release/daemon"
B3_TARGET="$IOS/build/b3sum-target"
(cd "$ROOT/tools/ios/b3sum" && CARGO_TARGET_DIR="$B3_TARGET" cargo build -q --release)
B3="$B3_TARGET/release/ppass-b3sum"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-ios-dev.XXXXXX")
DAEMON_PID=
OWNER_PID=
cleanup() {
  cp "$WORK/daemon.err" "$OUT/daemon.err" 2>/dev/null || true
  cp "$WORK/daemon.out" "$OUT/daemon.out" 2>/dev/null || true
  [ -n "$OWNER_PID" ] && kill "$OWNER_PID" 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  if [ -n "$DAEMON_PID" ]; then kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/home"
mkfifo "$WORK/stdin"
HOME="$WORK/home" PPF_BIND_ADDR="0.0.0.0:0" PPF_RELAY_URLS="" PPF_TELEMETRY_ENABLED=false \
  RUST_LOG="${PPASS_E2E_RUST_LOG:-info}" "$DAEMON" --ephemeral <"$WORK/stdin" >"$WORK/daemon.out" 2>"$WORK/daemon.err" &
DAEMON_PID=$!
exec 4>"$WORK/stdin"
NODE_ID=
for _ in $(seq 1 150); do
  NODE_ID=$(sed -n 's/^NodeId: \([0-9a-f]\{64\}\).*/\1/p' "$WORK/daemon.out" | head -1)
  [ -n "$NODE_ID" ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.2
done
[ -n "$NODE_ID" ] || { echo "error: daemon 没打出 NodeId" >&2; cat "$WORK/daemon.err" >&2; exit 1; }
sleep 1
PORTS=$(lsof -nP -a -p "$DAEMON_PID" -iUDP -Fn 2>/dev/null | sed -n 's/^n//p' | tr '\n' ' ')
echo "daemon pid=${DAEMON_PID} node=${NODE_ID:0:8}… UDP: ${PORTS}"
case "$PORTS" in *:41145*) echo "error: 用了 41145" >&2; exit 1 ;; esac

# shellcheck source=tools/ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"
# #1115：--ephemeral 是测试沙盒，库目录由 daemon 自建（stdout 的 SANDBOX: 行），不收路径输入。
ipc_sandbox_dir "$WORK/daemon.out"
ipc_pair_qr "$SANDBOX_DIR/ipc.token"
owner_loop() {
  local resp ids n body
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    if resp=$(ipc pairing.pending 2>/dev/null); then
      ids=$(printf '%s' "$resp" | jq -r '.result.pending[]?.node_id // empty')
      for n in $ids; do
        body=$(jq -cn --arg n "$n" '{accept: true, node_id: $n}')
        if ipc pairing.confirm "$body" >/dev/null 2>&1; then echo "owner: 已允许 ${n:0:8}…"; fi
      done
    fi
    sleep 0.3
  done
}
owner_loop &
OWNER_PID=$!

ENVJSON=$(jq -cn --arg d container --arg l "$PAIR_QR" --arg t "$TIMEOUT" --arg r "$RUN" --arg m "${PPASS_E2E_MAX_ASSETS:-12}" \
  '{PPASS_E2E_DIR:$d, PPASS_E2E_PAIR_LINK:$l, PPASS_E2E_TIMEOUT:$t, PPASS_E2E_RUN:$r, PPASS_E2E_ALBUM:"smallest", PPASS_E2E_MAX_ASSETS:$m, PPASS_E2E_RESET:"1"}')
echo "==> 启动真机 App（run=${RUN}）。手机上若出现相册权限 / 本地网络权限弹窗，需要用户点「允许」。"
xcrun devicectl device process launch --device "$DEV" --terminate-existing --environment-variables "$ENVJSON" "$BUNDLE_ID" >"$OUT/launch.log" 2>&1 \
  || { cat "$OUT/launch.log"; exit 1; }

pull_status() {
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/e2e/status.json --destination "$OUT/status/status.json" >/dev/null 2>&1
}
DONE=0
LASTSTEP=
for _ in $(seq 1 $((TIMEOUT / 2 + 30))); do
  if pull_status && [ "$(jq -r '.run // ""' "$OUT/status/status.json" 2>/dev/null)" = "$RUN" ]; then
    STEP=$(jq -r '.step' "$OUT/status/status.json")
    if [ "$STEP" != "$LASTSTEP" ]; then echo "  [$(date +%T)] app step: $STEP"; LASTSTEP="$STEP"; fi
    if [ "$(jq -r '.done // false' "$OUT/status/status.json")" = true ]; then DONE=1; break; fi
  fi
  sleep 2
done
echo "--- App 状态 ---"
jq -c 'del(.timeline_ids)' "$OUT/status/status.json" 2>/dev/null || echo "(无 status.json)"
[ "$DONE" = 1 ] || { echo "FAIL: App 没跑完（卡在 step=${LASTSTEP}；弹窗没点？见 $OUT/daemon.err）" >&2; exit 1; }

FAIL=0
[ "$(jq -r '.ok' "$OUT/status/status.json")" = true ] || { echo "FAIL: App 报告未成功：$(jq -r '.error // .timeline_error' "$OUT/status/status.json")"; FAIL=1; }
find "$SANDBOX_DIR/originals" -type f 2>/dev/null | sort > "$OUT/daemon-files.txt"
: > "$OUT/daemon.b3"
while IFS= read -r f; do "$B3" "$f"; done < "$OUT/daemon-files.txt" | awk '{print $1}' | sort > "$OUT/daemon.b3" || true
echo "--- 手机原始字节 BLAKE3（独立只读路径）↔ daemon 库文件 ↔ 时间线 ---"
N=$(jq '.originals | length' "$OUT/status/status.json")
[ "$N" -gt 0 ] || { echo "FAIL: 没有原始字节哈希"; FAIL=1; }
for i in $(seq 0 $((N - 1))); do
  hash=$(jq -r ".originals[$i].blake3 // \"\"" "$OUT/status/status.json")
  name=$(jq -r ".originals[$i].file" "$OUT/status/status.json")
  size=$(jq -r ".originals[$i].size // -1" "$OUT/status/status.json")
  in_lib=no
  in_tl=no
  if [ -n "$hash" ] && grep -qx "$hash" "$OUT/daemon.b3"; then in_lib=yes; fi
  if jq -e --arg h "$hash" '.timeline_ids | index($h)' "$OUT/status/status.json" >/dev/null 2>&1; then in_tl=yes; fi
  printf '%-16s %10s B  %s…  daemon库=%s  时间线=%s\n' "$name" "$size" "${hash:0:16}" "$in_lib" "$in_tl"
  if [ "$in_lib" != yes ] || [ "$in_tl" != yes ]; then FAIL=1; fi
done
if [ "$FAIL" = 0 ]; then
  echo "PASS: 真机 配对 → 前台备份 → daemon 库 BLAKE3 与手机原始字节一致 → 时间线可见"
else
  echo "FAIL" >&2
  exit 1
fi
