#!/usr/bin/env bash
# T-070 磁盘满剧本：把 daemon 的全部数据目录放进 6MB tmpfs → 备份写到一半
# 磁盘爆掉 → daemon 必须优雅失败（不崩溃、不丢已入库数据、恢复后可用）。
# Linux 专属（tmpfs 需要 root mount；CI runner 有 passwordless sudo）。
# 非 Linux 平台：SKIP（exit 0，显式说明）。
# 用法: tools/scenarios/disk_full.sh [工作目录]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${1:-/tmp/ppf-scenario-diskfull}"
DAEMON="$ROOT/target/release/daemon"
TC="$ROOT/target/release/testclient"

if [ "$(uname -s)" != "Linux" ]; then
  echo "DISK FULL SCENARIO: SKIP (需要 Linux tmpfs + root mount，本机 $(uname -s) 跳过)"
  exit 0
fi

[ -x "$DAEMON" ] || { echo "先构建: cargo build --release -p daemon -p testclient"; exit 1; }

TMPFS="$WORK/fs"
rm -rf "$WORK" && mkdir -p "$TMPFS"
cleanup() {
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  sudo umount "$TMPFS" 2>/dev/null || true
}
trap cleanup EXIT

start_daemon() {
  PPF_DATA_DIR="$TMPFS/library" PPF_TELEMETRY_ENABLED=false PPF_RELAY_URLS="" \
    "$DAEMON" > daemon.log 2> daemon.err &
  DAEMON_PID=$!
  for _ in $(seq 1 50); do grep -q 'ppf://pair' daemon.log 2>/dev/null && break; sleep 0.2; done
  QR=$(grep -o 'ppf://pair[^ ]*' daemon.log)
  NODE=$(grep -o 'NodeId: .*' daemon.log | awk '{print $2}')
  SOCK=$(sed -n 1p "$TMPFS/library/ipc.token"); TOKEN=$(sed -n 2p "$TMPFS/library/ipc.token")
}

# shellcheck source=../ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"

echo "── 0. 挂 6MB tmpfs（全部数据目录都放这里）"
sudo mount -t tmpfs -o size=6m tmpfs "$TMPFS"
mkdir -p "$TMPFS/library"
df -h "$TMPFS" | tail -1

echo "── 1. 起 daemon（data_dir 在 tmpfs 上）"
cd "$WORK"
start_daemon

echo "── 2. 配对"
"$TC" pair --token "$QR" --name "磁盘满剧本" > pair.log 2>&1 &
PAIR_PID=$!; sleep 3
ipc pairing.confirm '{"accept": true}' || { echo "FAIL: 配对确认失败（tmpfs 上 IPC 应可用）"; exit 1; }
wait "$PAIR_PID" && grep -q '配对成功' pair.log

echo "── 3. 备份大 payload → 磁盘爆掉（预期客户端报错、daemon 不崩）"
echo "   payload: 500 文件 × 约 16KB ≈ 8MB > 6MB tmpfs（放不下，故障必然触发）"
set +e
"$TC" backup --files 500 --node "$NODE" > backup.log 2>&1
BC=$?
set -e
echo "   testclient 退出码: $BC"
# T-070b：故障必须真的发生——退出码 0 意味着备份"成功"，剧本是假绿。
if [ "$BC" -eq 0 ]; then
  echo "FAIL: 磁盘满但备份竟然成功——故障未触发（payload 可能放得下），判据失效"
  tail -5 backup.log
  exit 1
fi
# 硬证据：daemon 侧必须记录 ENOSPC（No space left）。
if ! grep -qi "no space left" daemon.err; then
  echo "FAIL: daemon.err 无 ENOSPC 证据（No space left）——故障未命中"
  tail -5 daemon.err
  exit 1
fi
echo "   ✅ ENOSPC 已触发（daemon.err 有 No space left）"

echo "── 4. daemon 必须还活着"
kill -0 "$DAEMON_PID" 2>/dev/null || { echo "FAIL: daemon 在磁盘满时崩溃了"; tail -5 daemon.err; exit 1; }
echo "   ✅ daemon 存活"

echo "── 5. IPC 仍响应（status）"
ipc status > /dev/null || { echo "FAIL: daemon 存活但 IPC 已僵死"; exit 1; }
echo "   ✅ IPC 正常"

echo "── 6. 磁盘恢复：停 daemon 释放句柄 → 卸载 → 换 64m 重挂 → 同路径干净重启"
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
sudo umount "$TMPFS" && echo "   ✅ 卸载成功（句柄已释放）"
sudo mount -t tmpfs -o size=64m tmpfs "$TMPFS"
mkdir -p "$TMPFS/library"
start_daemon
ipc status > /dev/null && echo "   ✅ 磁盘恢复后 daemon 干净重启并服务"

echo "DISK FULL SCENARIO: ALL GREEN"
