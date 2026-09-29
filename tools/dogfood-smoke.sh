#!/usr/bin/env bash
# P-Pass 狗粮冒烟：daemon 全接口剧本，agent 可无人化执行。
# 用法: tools/dogfood-smoke.sh [工作目录]   （默认 /tmp/ppf-dogfood）
#       也可从 dogfood release 资产目录直接跑: ./dogfood-smoke.sh [工作目录]
#
# 布局（REL-08 #510）：脚本只认「自己所在目录」——
#   - helper：同目录的 ipc-lib.sh（仓库里两者都在 tools/，资产里两者平铺）；
#   - 二进制：同目录有 daemon 就用它（release 资产布局），否则回落仓库的
#     target/release/（`just verify-m1` 从仓库直接跑）。
# 资产清单的唯一来源是 tools/stage-dogfood-scripts.sh，门禁见
# tools/test-dogfood-assets.sh。
#
# 剧本: 起 daemon → 配对(QR+IPC确认) → backup 50 → 幂等重跑 →
#       browse → IPC 吊销 → revoke-check → logs.export 脱敏抽查。
# 全部通过输出 "DOGFOOD SMOKE: ALL GREEN"，任一步失败即退出非零。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./ipc-lib.sh
source "$HERE/ipc-lib.sh"

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -euo/{/^#/p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

WORK="${1:-/tmp/ppf-dogfood}"
if [ -x "$HERE/daemon" ]; then
  BIN="$HERE"                          # release 资产布局：与脚本平铺
else
  BIN="$HERE/../target/release"        # 仓库布局：tools/ 的上一级
fi
DAEMON="$BIN/daemon"
TC="$BIN/testclient"

if [ ! -x "$DAEMON" ] || [ ! -x "$TC" ]; then
  echo "找不到 daemon/testclient（查过 $HERE/ 与 $HERE/../target/release/）"
  echo "仓库里先构建: cargo build --release -p daemon -p testclient；release 资产记得 chmod +x"
  exit 1
fi

# 断言写法约定：set -e 对 `a && b` 里非末项的失败、对 `! cmd` 都不生效
# （SC2251）——那样写的断言失败了也照样往下跑。一律拆成独立命令，
# 或 `if …; then echo 原因 >&2; exit 1; fi` 显式失败。门禁
# tools/test-dogfood-assets.sh 用 shellcheck SC2251 兜底。
rm -rf "$WORK"
mkdir -p "$WORK/library"
cd "$WORK"
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

for _ in $(seq 1 50); do grep -q 'NodeId:' daemon.log 2>/dev/null && break; sleep 0.2; done
# grep 落空时别让 pipefail 静默退出：daemon 没起来要把原因亮出来
NODE=$(grep -o 'NodeId: .*' daemon.log 2>/dev/null | awk '{print $2}' || true)
if [ -z "$NODE" ]; then
  echo "daemon 10 秒内没打出 NodeId，daemon.err 末尾：" >&2
  tail -5 daemon.err >&2 || true
  ps -o pid,stat,etime,command -p "$DAEMON_PID" >&2 || echo "daemon 进程已退出" >&2
  exit 1
fi
# SEC-11 (#496)：配对串经 IPC pairing.start 现取（daemon 不再把它打进被重定向的 stdout）
ipc_pair_qr library/ipc.token
QR="$PAIR_QR"
echo "daemon up: $NODE (ipc: $SOCK)"

echo "── 1. 配对（QR + IPC owner 确认）"
"$TC" pair --token "$QR" --name "冒烟agent" > pair.log 2>&1 &
PAIR_PID=$!
sleep 3
ipc pairing.confirm '{"accept": true}'
wait "$PAIR_PID"
grep -q '配对成功' pair.log
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
if [ "$DISK" != "46" ]; then echo "磁盘文件数 $DISK ≠ 46" >&2; exit 1; fi

echo "── 6. IPC 吊销 → 门卫验证"
DEV=$(ipc devices.list | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['devices'][0]['node_id'])")
ipc device.revoke "{\"node_id\": \"$DEV\"}"
"$TC" revoke-check --node "$NODE"

echo "── 7. logs.export 脱敏抽查"
ipc logs.export
unzip -p library/ppf-logs.zip devices.json | grep -q node_id_prefix
# 隐私断言：诊断事件里不许出现本机 $HOME 路径。先单独解出来——解压失败 /
# 内容为空必须红，不能让「没读到」冒充「没泄漏」。
DIAG=$(unzip -p library/ppf-logs.zip diag_events.json)
if [ -z "$DIAG" ]; then echo "logs.export 里 diag_events.json 为空" >&2; exit 1; fi
# 纯 shell 子串匹配：不经管道，判定只取决于内容，不受 pipefail / grep -q
# 提前关管道之类时序影响（第 3 步注释里那类坑）。
case "$DIAG" in
  *"$HOME"*)
    echo "脱敏失败：diag_events.json 泄漏了 \$HOME（$HOME）" >&2
    exit 1 ;;
esac

echo "DOGFOOD SMOKE: ALL GREEN"
