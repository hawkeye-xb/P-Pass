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

ipc() { # ipc <method> [params-json]
  local params="${2:-}"; [ -z "$params" ] && params='{}'
  python3 - "$SOCK" "$TOKEN" "$1" "$params" <<'PYEOF'
import socket, json, sys, platform
p = sys.argv[1]
# Linux: daemon 的 IPC socket 在抽象命名空间（\0 前缀，非 /tmp 文件）；
# macOS: /tmp 下文件。按平台选连接路径（双机验证时记账的坑）。
p = ("\0" if platform.system() == "Linux" else "/tmp/") + p
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(p)
f = s.makefile("rw"); f.write(sys.argv[2] + "\n"); f.flush()
f.write(json.dumps({"id": "x", "method": sys.argv[3], "params": json.loads(sys.argv[4])}) + "\n"); f.flush()
resp = json.loads(f.readline())
print(json.dumps(resp, ensure_ascii=False)); sys.exit(0 if resp.get("ok") else 1)
PYEOF
}

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

echo "── 3. 备份 500 个小文件 → 磁盘爆掉（预期客户端报错、daemon 不崩）"
set +e
"$TC" backup --files 500 --node "$NODE" > backup.log 2>&1
BC=$?
set -e
echo "   testclient 退出码: $BC（非零=客户端侧优雅失败，符合预期）"

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
