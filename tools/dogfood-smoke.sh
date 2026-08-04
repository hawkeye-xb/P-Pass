#!/usr/bin/env bash
# P-Pass 狗粮冒烟：daemon 全接口剧本，agent 可无人化执行。
# 用法: tools/dogfood-smoke.sh [工作目录]   （默认 /tmp/ppf-dogfood）
#
# 剧本: 起 daemon → 配对(QR+IPC确认) → backup 50 → 幂等重跑 →
#       browse → IPC 吊销 → revoke-check → logs.export 脱敏抽查。
# 全部通过输出 "DOGFOOD SMOKE: ALL GREEN"，任一步失败即退出非零。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-/tmp/ppf-dogfood}"
DAEMON="$ROOT/target/release/daemon"
TC="$ROOT/target/release/testclient"

[ -x "$DAEMON" ] || { echo "先构建: cargo build --release -p daemon -p testclient"; exit 1; }

rm -rf "$WORK" && mkdir -p "$WORK/library" && cd "$WORK"
# UX-07: --ephemeral + FIFO 控制 stdin——脚本收尾时关闭 FIFO 写端（EOF）
# daemon 自己 3 秒内退出，不再需要 kill（杜绝 A 类孤儿）。
mkfifo "$WORK/daemon-ctl"
cleanup() {
  exec 3>&- 2>/dev/null || true   # 关 FIFO 写端 → daemon EOF 自退
  wait "$DAEMON_PID" 2>/dev/null || true
}
trap cleanup EXIT

PPF_DATA_DIR="$WORK/library" PPF_TELEMETRY_ENABLED=false PPF_RELAY_URLS="${PPF_RELAY_URLS:-}" \
  "$DAEMON" --ephemeral < "$WORK/daemon-ctl" > daemon.log 2> daemon.err &
DAEMON_PID=$!
exec 3>"$WORK/daemon-ctl"   # 保持写端打开——daemon 不会立即 EOF

for _ in $(seq 1 50); do grep -q 'ppf://pair' daemon.log 2>/dev/null && break; sleep 0.2; done
QR=$(grep -o 'ppf://pair[^ ]*' daemon.log)
NODE=$(grep -o 'NodeId: .*' daemon.log | awk '{print $2}')
SOCK=$(sed -n 1p library/ipc.token)
TOKEN=$(sed -n 2p library/ipc.token)
echo "daemon up: $NODE (ipc: $SOCK)"
# shellcheck source=./ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"

echo "── 1. 配对（QR + IPC owner 确认）"
"$TC" pair --token "$QR" --name "冒烟agent" > pair.log 2>&1 &
PAIR_PID=$!
sleep 3
ipc pairing.confirm '{"accept": true}'
wait "$PAIR_PID" && grep -q '配对成功' pair.log
cat pair.log | tail -1

echo "── 2. backup 50 个混合文件"
"$TC" backup --files 50 --node "$NODE"

echo "── 3. 幂等重跑（期望缺 0）"
# 注意不能 `tee | grep -q`：-q 命中即关管道，tee 吃 SIGPIPE，
# pipefail 下整个脚本静默退出（重试改动加长输出后必现的竞态）。
RERUN=$("$TC" backup --files 50 --node "$NODE")
echo "$RERUN"
echo "$RERUN" | grep -q '缺 0 个'

echo "── 4. browse（分页无重复 + 缩略图）"
"$TC" browse --limit 7 --node "$NODE"

echo "── 5. 索引与磁盘一致"
DISK=$(find library/originals -type f | wc -l | tr -d ' ')
echo "磁盘文件数: ${DISK}（46 = 50 去重后）"
[ "$DISK" = "46" ]

echo "── 6. IPC 吊销 → 门卫验证"
DEV=$(ipc devices.list | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['devices'][0]['node_id'])")
ipc device.revoke "{\"node_id\": \"$DEV\"}"
"$TC" revoke-check --node "$NODE"

echo "── 7. logs.export 脱敏抽查"
ipc logs.export
unzip -p library/ppf-logs.zip devices.json | grep -q node_id_prefix
! unzip -p library/ppf-logs.zip diag_events.json | grep -q "$HOME"

echo "DOGFOOD SMOKE: ALL GREEN"
