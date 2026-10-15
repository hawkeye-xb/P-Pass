#!/usr/bin/env bash
# 真机模拟系统后台任务调度，验收 #958（后台短任务 BGAppRefreshTask）。不等真实时间，可反复跑。
#
#   tools/ios/sim-bg-task.sh short-only [设备标识]   # A：只剩短任务窗口 → 照片逐张传、视频留下
#   tools/ios/sim-bg-task.sh expire     [设备标识]   # B：短任务跑到一半系统喊停 → 在飞的那张保持传输中
#   tools/ios/sim-bg-task.sh budget     [设备标识]   # C：待传照片多 → 20 秒预算到点收尾
#
# 环境变量：
#   PPASS_DEVICE           devicectl 设备标识（默认 iPhone 16 测试机）
#   PPASS_NO_RESTORE=1     跑完不把手机配回正式桌面（默认会配回，并恢复开跑前导出的相册范围）
#   PPASS_SKIP_BUILD=1     不重新构建 / 安装（App 已是当前代码的 Debug 包时用，省几分钟）
#   PPASS_BGTEST_PHOTOS    测试照片张数（默认 A/B 6 张，C 12 张）；PPASS_BGTEST_SIZE 照片尺寸（默认 2000x1500 噪声图，约 2.5 MB，不可压缩）
#   PPASS_BGTEST_MAX_WAKES C 最多叫醒几次短任务（默认 6）：一次传不完就回前台（daemon 暂停、前台只会「桌面不可达」）再切后台叫醒下一次
# 输出：apps/ios/build/sim-bg-task/<场景>-<时间>/（daemon 日志、App 落盘日志、本轮切片 run.log）
#
# 怎么造出「只剩短任务窗口」（细节与实测依据见 sim-bg-task-lldb.py 头注释）：
#   1. 本机起隔离 daemon（fake HOME + 临时库 + --ephemeral，同 e2e-device.sh），App 用 DEBUG 驱动（E2EDriver，PPASS_BGTEST=1）
#      清存储根 → 配对 → 新建空相册「PPass BGTest <run>」并只选它；等选相册那一轮收场。
#   2. daemon SIGSTOP（桌面不可达）→ 测试照片 + 1 段视频写进这个相册（iOS 前台没有图库变化触发，照片留着待传）。
#   3. LLDB 附加 → App 切到后台（前台换成「设置」）→ 跳过「打开宽限期窗口」那一行（系统断言照常申请）
#      → daemon SIGCONT → `_simulateLaunchForTaskWithIdentifier:`。
#   4. 拉回 App 落盘日志，只截本进程、本次短任务之后的行，grep 判定 PASS / FAIL。
# 不需要人参与：照片由脚本生成，不用拍；手机须已解锁亮屏（要把「设置」切到前台），App 已授予完整相册权限与本地网络权限。
# 局限：调试器只能在「已运行的进程」里模拟，所以 `launch origin` 是 foreground，看不到 `launch origin: background (...)`；
#   跑短任务的系统执行时间借的是宽限期的断言（被调试器从窗口里抹掉），不是 dasd 真实拉起给的时间。
#   验的是 ExecutionWindow / 20 秒预算 / 系统喊停的逻辑；新进程后台启动与系统给的真实时长仍要真实调度（锁屏、充电、等待）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
MODE="${1:-}"
DEV="${2:-${PPASS_DEVICE:-B2805351-9CD1-55C7-81B0-DBEAD9E86BD3}}"

pull_log() { # $1 = 目标文件
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Library/Logs/ppass.log --destination "$1" >/dev/null 2>&1
}
if [ "$MODE" = _log ]; then # 内部用：给 lldb 那一侧轮询日志
  T=$(mktemp "${TMPDIR:-/tmp}/ppass-log.XXXXXX"); pull_log "$T" && cat "$T"; rm -f "$T"; exit 0
fi
case "$MODE" in
  short-only) N_DEFAULT=6;  SIZE_DEFAULT=2000x1500 ;;
  expire)     N_DEFAULT=6;  SIZE_DEFAULT=2000x1500 ;;
  budget)     N_DEFAULT=12; SIZE_DEFAULT=2000x1500 ;;
  *) sed -n '2,6p' "$0"; exit 64 ;;
esac
N="${PPASS_BGTEST_PHOTOS:-$N_DEFAULT}"
SIZE="${PPASS_BGTEST_SIZE:-$SIZE_DEFAULT}"
RUN="$MODE-$(date +%Y%m%d-%H%M%S)"
OUT="$IOS/build/sim-bg-task/$RUN"
mkdir -p "$OUT"
for tool in jq lsof ffmpeg sqlite3; do command -v "$tool" >/dev/null || { echo "error: 缺 $tool" >&2; exit 1; }; done
exec > >(tee "$OUT/sim.log") 2>&1
echo "==> 场景 ${MODE}（run=${RUN}，设备 ${DEV}，照片 ${N} 张 ${SIZE} + 视频 1 段）"

# ---- 构建、安装 ----
if [ "${PPASS_SKIP_BUILD:-}" != 1 ]; then
  echo "==> 构建 Debug 包并安装"
  if [ ! -d "$IOS/TransportFFITests/Generated/TransportFFI.xcframework" ]; then
    "$ROOT/tools/build-ios-transport-xcframework.sh" "$IOS/TransportFFITests/Generated"
  fi
  (cd "$IOS" && xcodegen generate --quiet)
  xcodebuild build -project "$IOS/PPass.xcodeproj" -scheme PPass -configuration Debug -destination "generic/platform=iOS" \
    -allowProvisioningUpdates -derivedDataPath "$IOS/build/derived-device" >"$OUT/xcodebuild.log" 2>&1 \
    || { tail -30 "$OUT/xcodebuild.log"; exit 1; }
  xcrun devicectl device install app --device "$DEV" "$IOS/build/derived-device/Build/Products/Debug-iphoneos/PPass.app" \
    >"$OUT/install.log" 2>&1 || { cat "$OUT/install.log"; exit 1; }
fi
cargo build -q -p daemon --release
DAEMON="$ROOT/target/release/daemon"

# ---- 隔离 daemon + 自动允许配对（同 e2e-device.sh）----
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-bgsim.XXXXXX")
DAEMON_PID=
OWNER_PID=
TOUCHED_PAIRING= # App 带 PPASS_E2E_RESET 启动之后置 1：从这一刻起手机可能配着临时 daemon，退出时必须配回
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$DAEMON_PID" ] && kill -CONT "$DAEMON_PID" 2>/dev/null || true
  cp "$WORK/daemon.err" "$OUT/daemon.err" 2>/dev/null || true
  [ -n "$OWNER_PID" ] && kill "$OWNER_PID" 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  if [ -n "$DAEMON_PID" ]; then kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
  # 手机这时配着刚杀掉的临时 daemon：配回本机正式桌面，并恢复开跑前导出的相册范围
  # （所选相册里有测试资源就不恢复、保持空范围，测试照片不会进真实照片库）。
  # 正常结束、判 FAIL、中途出错、Ctrl-C 都走这里。
  if [ -n "$TOUCHED_PAIRING" ] && [ "${PPASS_NO_RESTORE:-}" != 1 ]; then
    echo "==> 把手机配回正式桌面（tools/ios/restore-desktop-pairing.sh，日志在 apps/ios/build/restore-pairing/）"
    if "$ROOT/tools/ios/restore-desktop-pairing.sh" "$OUT/scope-before.json" "$DEV" >"$OUT/restore-pairing.log" 2>&1; then
      grep -E '范围已恢复|桌面一侧' "$OUT/restore-pairing.log" || true
      tail -1 "$OUT/restore-pairing.log"
    else
      tail -8 "$OUT/restore-pairing.log"
      echo "WARN: 恢复失败！手机可能还配着已经不存在的临时 daemon / 范围为空。处理后手动跑："
      echo "      tools/ios/restore-desktop-pairing.sh $OUT/scope-before.json"
      [ "$rc" = 0 ] && rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$WORK/home" "$WORK/data" "$WORK/seed"
mkfifo "$WORK/stdin"
HOME="$WORK/home" PPF_DATA_DIR="$WORK/data" PPF_BIND_ADDR="0.0.0.0:0" PPF_RELAY_URLS="" PPF_TELEMETRY_ENABLED=false \
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
# shellcheck source=tools/ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"
ipc_pair_qr "$WORK/data/ipc.token"
owner_loop() {
  local resp ids n body
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    if resp=$(ipc pairing.pending 2>/dev/null); then
      ids=$(printf '%s' "$resp" | jq -r '.result.pending[]?.node_id // empty')
      for n in $ids; do
        body=$(jq -cn --arg n "$n" '{accept: true, node_id: $n}')
        ipc pairing.confirm "$body" >/dev/null 2>&1 && echo "  owner: 已允许 ${n:0:8}…"
      done
    fi
    sleep 0.3
  done
}
owner_loop &
OWNER_PID=$!
echo "  daemon pid=${DAEMON_PID} node=${NODE_ID:0:8}…"

# ---- 测试照片（噪声图，不可压缩；每轮不同字节）与 1 段视频 ----
SEED_BASE=$(date +%s)
for i in $(seq 1 "$N"); do
  ffmpeg -loglevel error -f lavfi -i "color=c=gray:s=${SIZE},noise=alls=100:allf=u:all_seed=$((SEED_BASE + i))" \
    -frames:v 1 -q:v 2 "$WORK/seed/$(printf 'p%03d' "$i").jpg"
done
ffmpeg -loglevel error -f lavfi -i "testsrc2=s=640x480:d=3:r=30,noise=alls=30:allf=t:all_seed=${SEED_BASE}" \
  -c:v libx264 -pix_fmt yuv420p "$WORK/seed/v001.mov"
echo "  已生成 $(find "$WORK/seed" -type f | wc -l | tr -d ' ') 个文件，$(du -sh "$WORK/seed" | cut -f1)"

# ---- 启动 App：清存储根 → 配对 → 新建空相册并只选它 ----
STATUS="$OUT/status.json"
pull_status() {
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/e2e/status.json --destination "$STATUS" >/dev/null 2>&1 && [ "$(jq -r '.run // ""' "$STATUS")" = "$RUN" ]
}
wait_step() { # $1 = 期望 step，$2 = 超时秒
  local s=
  for _ in $(seq 1 $(($2 / 2))); do
    if pull_status; then
      s=$(jq -r .step "$STATUS")
      [ "$s" = "$1" ] && return 0
      [ "$s" = failed ] && { echo "FAIL: App 驱动报错：$(jq -r .error "$STATUS")"; exit 1; }
    fi
    sleep 2
  done
  echo "FAIL: 等 App 到 step=$1 超时（当前 ${s:-无}；相册 / 本地网络权限弹窗没点？手机锁了？）"; exit 1
}
# ---- 先导出用户当前的相册范围（收尾时原样恢复）----
# 备份同时存一份在 apps/ios/build/sim-bg-task/scope-backup.json：这一轮万一没恢复成，下次可以手动
# tools/ios/restore-desktop-pairing.sh apps/ios/build/sim-bg-task/scope-backup.json。
SCOPE_BACKUP="$IOS/build/sim-bg-task/scope-backup.json"
REAL_RUN="$RUN"
RUN="$REAL_RUN-scope"
echo "==> 导出手机当前的相册范围"
xcrun devicectl device process launch --device "$DEV" --terminate-existing \
  --environment-variables "$(jq -cn --arg r "$RUN" '{PPASS_E2E_DIR:"container", PPASS_E2E_RUN:$r, PPASS_BGTEST_SCOPE_EXPORT:"1"}')" \
  "$BUNDLE_ID" >"$OUT/launch-scope.log" 2>&1 || { cat "$OUT/launch-scope.log"; exit 1; }
wait_step scope 60
cp "$STATUS" "$OUT/scope-before.json"
jq -e '.selected | type == "array"' "$OUT/scope-before.json" >/dev/null \
  || { echo "FAIL: 手机从未保存过相册范围（selected=null），恢复不回这个状态；先在 App 里选好相册再跑"; exit 1; }
if [ "$(jq -r .selected_test_albums "$OUT/scope-before.json")" != 0 ]; then
  echo "FAIL: 当前范围里有测试相册（上一轮没恢复？）。不覆盖备份；先跑"
  echo "      tools/ios/restore-desktop-pairing.sh $SCOPE_BACKUP"
  exit 1
fi
cp "$OUT/scope-before.json" "$SCOPE_BACKUP"
echo "  已备份：$(jq -r '.selected | length' "$SCOPE_BACKUP") 个相册（$SCOPE_BACKUP）"
RUN="$REAL_RUN"

ENVJSON=$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN" \
  '{PPASS_E2E_DIR:"container", PPASS_E2E_PAIR_LINK:$l, PPASS_E2E_RUN:$r, PPASS_E2E_RESET:"1", PPASS_BGTEST:"1"}')
echo "==> 启动 App（前台）"
TOUCHED_PAIRING=1
xcrun devicectl device process launch --device "$DEV" --terminate-existing --environment-variables "$ENVJSON" \
  --json-output "$OUT/launch.json" "$BUNDLE_ID" >"$OUT/launch.log" 2>&1 || { cat "$OUT/launch.log"; exit 1; }
APP_PID=$(jq -r '.result.process.processIdentifier' "$OUT/launch.json")
echo "  App pid=${APP_PID}"
wait_step ready 120
echo "  已配对，空相册已选"
proc_log() { # 本进程（process start: pid=<APP_PID>）的日志行
  pull_log "$OUT/ppass.log" && awk -v p="pid=${APP_PID} " 'index($0,"process start:") {on = index($0,p) > 0} on' "$OUT/ppass.log"
}
# 选相册那一轮（SCOPE_ADDED，相册是空的 → nothing to transfer）先跑完再停 daemon；
# 否则 SIGSTOP 落在它的探测中途，15 秒 hello 超时会跨进后台，把短任务那一轮也合并成「不可达」。
SETTLED=
for _ in $(seq 1 30); do
  if proc_log | grep -qE 'cycle \[[^]]*"SCOPE_ADDED"[^]]*\]: nothing to transfer'; then SETTLED=1; break; fi
  sleep 2
done
[ -n "$SETTLED" ] || { echo "FAIL: 选相册那一轮 60 秒内没收场（见 $OUT/ppass.log）"; exit 1; }

# ---- 桌面不可达 → 写入测试照片 ----
kill -STOP "$DAEMON_PID"
echo "==> daemon 已暂停（SIGSTOP）；把测试照片 / 视频拷进 App 容器并写入相册"
for f in "$WORK/seed"/*; do
  xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$f" --destination "Documents/e2e/seed/$(basename "$f")" >/dev/null 2>&1 || { echo "FAIL: 拷 $(basename "$f") 失败"; exit 1; }
done
: > "$WORK/go"
xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source "$WORK/go" --destination Documents/e2e/seed/go >/dev/null 2>&1
wait_step seeded 120
echo "  相册已写入：$(jq -r '"\(.photos) 张照片 + \(.videos) 段视频"' "$STATUS")"
# ---- 调试器：后台（不开宽限期窗口）→ 叫醒短任务 ----
echo "==> LLDB：附加、切后台（不开宽限期窗口），再模拟拉起短任务（${MODE}）"
PYTHONPATH="$(xcrun lldb -P)" xcrun python3 "$ROOT/tools/ios/sim-bg-task-lldb.py" "$DEV" "$APP_PID" "$DAEMON_PID" "$MODE" "$0 _log $DEV" "$N" \
  || { echo "FAIL: 调试器一侧失败（见上）"; exit 1; }

# ---- 拉日志、只截本次 ----
# 拉当前与上一份滚动（ppass.log.1，约 1 MB 换一次），按时间顺序拼起来，免得本进程的开头落在旧文件里。
pull_log "$OUT/ppass.log.cur" || { echo "FAIL: 拉不到 App 日志"; exit 1; }
xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source Library/Logs/ppass.log.1 --destination "$OUT/ppass.log.1" >/dev/null 2>&1 || : > "$OUT/ppass.log.1"
cat "$OUT/ppass.log.1" "$OUT/ppass.log.cur" > "$OUT/ppass.log"
# run.log = 本进程（process start: pid=<APP_PID>）里第一次 `short task: woken` 起的全部行（budget 会叫醒多次，中间夹着回前台）；
# short.log = 只取每次短任务 woken … finished 之间的行（「短任务里不跑对账」只判这些，前台那一轮本来就对账）。
awk -v p="pid=${APP_PID} " 'index($0,"process start:") {on = index($0,p) > 0} on' "$OUT/ppass.log" > "$OUT/process.log"
awk '/short task: woken/ {on = 1} on' "$OUT/process.log" > "$OUT/run.log"
awk '/short task: woken/ {on = 1} on {print} /short task: finished/ {on = 0}' "$OUT/process.log" > "$OUT/short.log"
echo "--- 本次短任务日志（$OUT/run.log）---"
cat "$OUT/run.log"
echo "---"

FAIL=0
must() { # $1 = 说明，$2 = ERE
  local line; line=$(grep -E -m1 -- "$2" "$OUT/run.log" || true)
  if [ -n "$line" ]; then echo "  ok   $1"; echo "       $line"; else echo "  FAIL $1（没找到 /$2/）"; FAIL=1; fi
}
must_not() { # 只看短任务窗口内的行
  local line; line=$(grep -E -m1 -- "$2" "$OUT/short.log" || true)
  if [ -z "$line" ]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "       $line"; FAIL=1; fi
}
echo "==> 判定"
must "短任务被叫醒时没有其他窗口（others=[]）" 'short task: woken \(budget 20s, others=\[\]\)'
must_not "短任务里不跑全量对账（source_missing）" 'source_missing:'
must_not "短任务里不跑全量对账（reconcile scan）" 'reconcile scan'
case "$MODE" in
  short-only)
    must "这一轮只传照片" 'round .* open \(desktop reachable; photos only\)'
    must "照片逐张开始" 'item start: '
    must "照片逐张送达" 'item end: .* result=next'
    must "视频留给别的窗口" 'video\(s\) left for another window \(photos only\)'
    must "自己跑完收尾" 'short task: finished \(finish=done '
    DELIVERED=$(grep -c 'item end: .* result=next' "$OUT/run.log" || true)
    if [ "$DELIVERED" -eq "$N" ]; then echo "  ok   ${N} 张照片全部送达"; else echo "  FAIL 送达张数 ${DELIVERED} ≠ ${N}"; FAIL=1; fi
    ;;
  expire)
    must "系统喊停" 'short task: expired by the system'
    must "在飞的那张被打断" 'item end: .* result=aborted'
    must_not "没有被当成失败" 'result=failed'
    # 「保持传输中」看账本：被打断那张的 order 行应仍是 TRANSFERRING（下一轮按遗留续传最先取）。
    ORDER=$(sed -n 's/.*item end: order \([0-9]*\) .*result=aborted.*/\1/p' "$OUT/run.log" | head -1)
    # 账本在 App Group 容器里（devicectl 拉不到）：先停掉 daemon（下一次启动连不上桌面，不会接着传这张），
    # 再用 DEBUG 驱动（PPASS_BGTEST_DUMP=1）把账本拷进 App 容器，拉回来查。
    kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; DAEMON_PID=
    RUN="$RUN-dump"
    xcrun devicectl device process launch --device "$DEV" --terminate-existing \
      --environment-variables "$(jq -cn --arg r "$RUN" '{PPASS_E2E_DIR:"container", PPASS_E2E_RUN:$r, PPASS_BGTEST_DUMP:"1"}')" \
      "$BUNDLE_ID" >"$OUT/launch-dump.log" 2>&1 || cat "$OUT/launch-dump.log"
    wait_step dumped 30
    mkdir -p "$OUT/db"
    for f in backup-orders.db backup-orders.db-wal backup-orders.db-shm; do
      xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "Documents/e2e/db/$f" --destination "$OUT/db/$f" >/dev/null 2>&1 || true
    done
    STATE=$( [ -n "$ORDER" ] && sqlite3 -readonly "$OUT/db/backup-orders.db" "SELECT state FROM orders WHERE id = $ORDER" 2>&1 || true)
    if [ "$STATE" = TRANSFERRING ]; then echo "  ok   账本里 order $ORDER 仍是 TRANSFERRING"; else echo "  FAIL 账本里 order ${ORDER:-?} 的状态是 '${STATE}'，应为 TRANSFERRING"; FAIL=1; fi
    ;;
  budget)
    must "照片逐张开始" 'item start: '
    must "20 秒预算到点" 'short task: budget reached; finishing'
    must "以预算收尾" 'short task: finished \(finish=budget '
    WAKES=$(grep -c 'short task: woken' "$OUT/run.log" || true)
    echo "  ..   共叫醒短任务 ${WAKES} 次"
    # 下一次从断点接着传：预算到点时被打断（aborted）的那张，后面要以 result=next 送达。
    ABORTED=$(sed -n 's/.*item end: order [0-9]* hash=\([0-9a-f]*\) .*result=aborted.*/\1/p' "$OUT/run.log" | sort -u)
    for h in $ABORTED; do
      if grep -qE "item end: order [0-9]+ hash=$h .*result=next" "$OUT/run.log"; then echo "  ok   预算到点时在飞的 $h 下一次接着送达"
      else echo "  FAIL 预算到点时在飞的 $h 后来没有送达"; FAIL=1; fi
    done
    # 最终全部送达、不重复：送达行数 = 不同 hash 数 = N。
    NEXT_LINES=$(grep -c 'item end: .* result=next' "$OUT/run.log" || true)
    NEXT_DISTINCT=$(sed -n 's/.*item end: order [0-9]* hash=\([0-9a-f]*\) .*result=next.*/\1/p' "$OUT/run.log" | sort -u | wc -l | tr -d ' ')
    if [ "$NEXT_DISTINCT" -eq "$N" ] && [ "$NEXT_LINES" -eq "$N" ]; then echo "  ok   ${N} 张全部送达、没有重复（${NEXT_LINES} 行 / ${NEXT_DISTINCT} 个 hash）"
    else echo "  FAIL 送达 ${NEXT_LINES} 行 / ${NEXT_DISTINCT} 个不同 hash，应都是 ${N}"; FAIL=1; fi
    must_not "没有被当成失败" 'result=failed'
    ;;
esac
echo "（launch origin：调试器附加在已运行的前台进程上模拟，本进程的启动来源是 foreground，不判 background。）"
if [ "$FAIL" = 0 ]; then echo "PASS: ${MODE}（日志 $OUT）"; else echo "FAIL: ${MODE}（日志 $OUT）"; exit 1; fi
