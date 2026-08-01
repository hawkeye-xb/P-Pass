#!/usr/bin/env bash
# T-070 崩溃恢复剧本：备份进行中 SIGKILL daemon → 重启（同 data_dir）→
# 重跑收敛（missing 现算、零损坏、幂等）。验证崩溃安全与索引可重建语义。
# 用法: tools/scenarios/crash_recovery.sh [工作目录]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${1:-/tmp/ppf-scenario-crash}"
SIZE="${PPF_SCENARIO_SIZE_CRASH:-512M}"
DAEMON="$ROOT/target/release/daemon"
TC="$ROOT/target/release/testclient"

[ -x "$DAEMON" ] || { echo "先构建: cargo build --release -p daemon -p testclient"; exit 1; }

case "$SIZE" in
  *G) BYTES=$(( ${SIZE%G} * 1024 * 1024 * 1024 ));;
  *M) BYTES=$(( ${SIZE%M} * 1024 * 1024 ));;
  *)  BYTES=$SIZE;;
esac

rm -rf "$WORK" && mkdir -p "$WORK/library" && cd "$WORK"

start_daemon() {
  PPF_DATA_DIR="$WORK/library" PPF_TELEMETRY_ENABLED=false PPF_RELAY_URLS="" \
    "$DAEMON" > daemon.log 2> daemon.err &
  DAEMON_PID=$!
  for _ in $(seq 1 50); do grep -q 'ppf://pair' daemon.log 2>/dev/null && break; sleep 0.2; done
  QR=$(grep -o 'ppf://pair[^ ]*' daemon.log)
  NODE=$(grep -o 'NodeId: .*' daemon.log | awk '{print $2}')
  SOCK=$(sed -n 1p library/ipc.token); TOKEN=$(sed -n 2p library/ipc.token)
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

echo "── 1. 首启 + 配对"
start_daemon
"$TC" pair --token "$QR" --name "崩溃剧本" > pair.log 2>&1 &
PAIR_PID=$!; sleep 3; ipc pairing.confirm '{"accept": true}'; wait "$PAIR_PID" && grep -q '配对成功' pair.log

echo "── 2. 启动 ${SIZE} 备份，进行中 SIGKILL daemon"
"$TC" backup --files 1 --file-size "$BYTES" --node "$NODE" > backup1.log 2>&1 &
BACKUP_PID=$!
sleep 2   # 让传输跑起来（本机回环 ~1-2s/GB，512M 足够窗口）
kill -9 "$DAEMON_PID" 2>/dev/null || true
wait "$BACKUP_PID" 2>/dev/null || true
echo "   daemon 已 SIGKILL（backup1 退出码 $?）"

echo "── 3. 同 data_dir 重启"
start_daemon   # 同一 library 目录 → 同一索引
ipc status > /dev/null   # daemon 活着且 IPC 就绪

echo "── 4. 重跑备份 → 收敛（missing 按当前索引现算）"
OUT=$("$TC" backup --files 1 --file-size "$BYTES" --node "$NODE")
echo "$OUT" | tail -2
echo "$OUT" | grep -q "实收 1 个新 blob" || { echo "FAIL: 重启后应补齐缺失"; exit 1; }

echo "── 5. 幂等重跑（期望缺 0）"
RERUN=$("$TC" backup --files 1 --file-size "$BYTES" --node "$NODE")
echo "$RERUN" | grep -q "实收 0 个新 blob" || { echo "FAIL: 收敛后应缺 0"; exit 1; }

echo "── 6. 索引与磁盘一致（rebuild 守护测试的进程级复现）"
DISK=$(find library/originals -name 'BIG_0000.bin' | head -1)
[ -n "$DISK" ] || { echo "FAIL: 落盘缺失"; exit 1; }
echo "   ✅ 落盘存在: $DISK"

kill "$DAEMON_PID" 2>/dev/null || true
echo "CRASH RECOVERY SCENARIO: ALL GREEN"
