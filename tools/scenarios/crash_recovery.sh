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

cleanup() {
  # ${VAR:-}: trap 可能在 DAEMON_PID 赋值前触发（set -u 下裸引用会二次报错）
  kill "${DAEMON_PID:-}" 2>/dev/null || true
  wait "${DAEMON_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

start_daemon() {
  # PPF_BIND_ADDR=0.0.0.0:0：开发机上用户 config 固定 41145，临时 daemon
  # 不显式覆盖会与常驻 daemon 撞端口（bind 失败），CI 无用户配置不炸。
  PPF_DATA_DIR="$WORK/library" PPF_TELEMETRY_ENABLED=false PPF_RELAY_URLS="" \
    PPF_BIND_ADDR="0.0.0.0:0" \
    "$DAEMON" > daemon.log 2> daemon.err &
  DAEMON_PID=$!
  for _ in $(seq 1 50); do grep -q 'ppf://pair' daemon.log 2>/dev/null && break; sleep 0.2; done
  QR=$(grep -o 'ppf://pair[^ ]*' daemon.log)
  NODE=$(grep -o 'NodeId: .*' daemon.log | awk '{print $2}')
  SOCK=$(sed -n 1p library/ipc.token); TOKEN=$(sed -n 2p library/ipc.token)
}

# shellcheck source=../ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"

echo "── 1. 首启 + 配对"
start_daemon
"$TC" pair --token "$QR" --name "崩溃剧本" > pair.log 2>&1 &
PAIR_PID=$!; sleep 3; ipc pairing.confirm '{"accept": true}'; wait "$PAIR_PID" && grep -q '配对成功' pair.log

echo "── 2. 启动 ${SIZE} 备份，进行中 SIGKILL daemon"
"$TC" backup --files 1 --file-size "$BYTES" --node "$NODE" > backup1.log 2>&1 &
BACKUP_PID=$!
# 轮询等待传输真正开始再 kill——不再 sleep 赌时序（T-070b review 两连修：
# ① sleep 2 在慢机器上可能 kill 时传输没开始、在回环上 512M 又常常已经
#   commit 完，双向 flaky；② 首版轮询盯的 library/daemon-blobs/ 是进程内
#   测试 harness 的目录，生产 daemon 的 blob 目录是 data_dir/.ppf/blobs
#   （main.rs），且 FsStore 启动即建 blobs.db/data/temp——"目录非空"在
#   传输前就为真。正确信号 = .ppf/blobs 的字节数较配对后的基线显著增长。
BLOBS_DIR="library/.ppf/blobs"
BASE=$(du -sk "$BLOBS_DIR" 2>/dev/null | awk '{print $1}'); BASE=${BASE:-0}
GROWN=""
for _ in $(seq 1 150); do
  CUR=$(du -sk "$BLOBS_DIR" 2>/dev/null | awk '{print $1}'); CUR=${CUR:-0}
  if [ $(( CUR - BASE )) -ge 1024 ]; then GROWN=1; break; fi   # ≥1MB 增长
  sleep 0.2
done
if [ -z "$GROWN" ]; then
  echo "FAIL: 30s 内 $BLOBS_DIR 无明显增长（基线 ${BASE}K）——传输未开始就 kill 会让剧本失去意义"
  tail -5 backup1.log
  exit 1
fi
echo "   ✅ blob 数据增长中（基线 ${BASE}K → ${CUR}K，传输进行中）"
kill -9 "$DAEMON_PID" 2>/dev/null || true
set +e
wait "$BACKUP_PID"
BC=$?
set -e
# ${BC} 必须带花括号：macOS bash 3.2 下 $VAR 紧跟全角字符会误并入变量名
# （dogfood-smoke 的 ${DISK} 同款教训）。
echo "   daemon 已 SIGKILL（backup1 退出码 ${BC}）"

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
