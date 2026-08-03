#!/usr/bin/env bash
# T-070 大文件剧本：4GB 级单文件走完整备份管线（稀疏文件技巧控制 CI 时长）。
# 用法: PPF_SCENARIO_SIZE=2G tools/scenarios/huge_file.sh [工作目录]
# 默认 2G（峰值磁盘 ≈ 3×size：blob store + staging + originals）；
# 卡面 4G 在磁盘充足机器上用 PPF_SCENARIO_SIZE=4G。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${1:-/tmp/ppf-scenario-huge}"
SIZE="${PPF_SCENARIO_SIZE:-2G}"
DAEMON="$ROOT/target/release/daemon"
TC="$ROOT/target/release/testclient"

[ -x "$DAEMON" ] || { echo "先构建: cargo build --release -p daemon -p testclient"; exit 1; }

case "$SIZE" in
  *G) BYTES=$(( ${SIZE%G} * 1024 * 1024 * 1024 ));;
  *M) BYTES=$(( ${SIZE%M} * 1024 * 1024 ));;
  *)  BYTES=$SIZE;;
esac
echo "==> 大文件剧本：${SIZE}（${BYTES} 字节），稀疏文件，峰值磁盘 ~3×size"

rm -rf "$WORK" && mkdir -p "$WORK/library" && cd "$WORK"
cleanup() { kill "$DAEMON_PID" 2>/dev/null || true; }
trap cleanup EXIT

PPF_DATA_DIR="$WORK/library" PPF_TELEMETRY_ENABLED=false PPF_RELAY_URLS="" \
  "$DAEMON" > daemon.log 2> daemon.err &
DAEMON_PID=$!
for _ in $(seq 1 50); do grep -q 'ppf://pair' daemon.log 2>/dev/null && break; sleep 0.2; done
QR=$(grep -o 'ppf://pair[^ ]*' daemon.log)
NODE=$(grep -o 'NodeId: .*' daemon.log | awk '{print $2}')
SOCK=$(sed -n 1p library/ipc.token); TOKEN=$(sed -n 2p library/ipc.token)
# shellcheck source=./ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"

echo "── 1. 配对"
"$TC" pair --token "$QR" --name "大文件剧本" > pair.log 2>&1 &
PAIR_PID=$!; sleep 3; ipc pairing.confirm '{"accept": true}'; wait "$PAIR_PID" && grep -q '配对成功' pair.log

echo "── 2. 单个 ${SIZE} 稀疏文件备份"
START=$(date +%s)
"$TC" backup --files 1 --file-size "$BYTES" --node "$NODE" 2>&1 | tail -2
DUR=$(( $(date +%s) - START ))
echo "   （耗时 ${DUR}s）"

echo "── 3. 落盘校验：逻辑大小 = ${SIZE}"
LANDED=$(find library/originals -name 'BIG_0000.bin' -exec stat -f%z {} \; 2>/dev/null | head -1)
[ -z "$LANDED" ] && LANDED=$(find library/originals -name 'BIG_0000.bin' -exec stat -c%s {} \; 2>/dev/null | head -1)
[ "$LANDED" = "$BYTES" ] || { echo "FAIL: 落盘大小 $LANDED ≠ $BYTES"; exit 1; }
echo "   ✅ 落盘大小正确"

echo "── 4. 幂等重跑（期望缺 0）"
RERUN=$("$TC" backup --files 1 --file-size "$BYTES" --node "$NODE")
echo "$RERUN" | grep -q "实收 0 个新 blob" || { echo "FAIL: 幂等重跑应缺 0"; echo "$RERUN"; exit 1; }

echo "HUGE FILE SCENARIO: ALL GREEN"
