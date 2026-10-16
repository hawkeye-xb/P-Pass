#!/usr/bin/env bash
# iOS 真机批量取证 + 自动判定（#939）：不等系统调度、不要人点（相册 / 本地网络权限须已授予，手机解锁亮屏）。
#
#   tools/ios/e3-batch.sh [设备标识]      # 输出在 apps/ios/build/e3-batch/<时间>/，结论汇总在 summary.txt
#
# 环境变量：
#   PPASS_DEVICE         devicectl 设备标识（默认 iPhone 16 测试机）
#   PPASS_SKIP_BUILD=1   不重新构建 / 安装（App 已是当前代码的 Debug 包时用）
#   PPASS_E3_SETTLE      换回正式桌面后，等重新确认那一轮收场的秒数（默认 1800）
#
# 场景（顺序固定，每个场景 PASS / FAIL 写进 summary.txt）：
#   forensics     设备信息、App 容器目录树、落盘日志能拉回且本进程写了 App Group 存储根行（#347 / #334 验收 1）。
#   same-desktop  配回同一台正式桌面：账本 owner 不变、orders 一行不少（同一台电脑重配不重传，#935）。
#   new-desktop   配到本机临时 daemon（--ephemeral，范围清空、不传任何照片）：owner 换成临时 daemon、orders 清空
#                 （换电脑后旧电脑的「已确认」不算给新电脑，#935 / #339 P-01 / #338 验收 5）；跳过名单保留。
#   back-formal   配回正式桌面并恢复相册范围：又一次换电脑 → orders 清空后按现算差集重新确认；
#                 等这一轮收场，CONFIRMED 不少于开跑前（重新备份），并统计桌面已有（offer_reply）与新收（push）。
# 账本在 App Group（devicectl 拉不到）：用 DEBUG 驱动 PPASS_BGTEST_DUMP=1 拷进 App 容器再拉回（同 sim-bg-task.sh）。
# 收尾（含中途失败 / Ctrl-C）：只要动过配对就配回正式桌面并恢复开跑前导出的范围（restore-desktop-pairing.sh）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
DEV="${1:-${PPASS_DEVICE:-B2805351-9CD1-55C7-81B0-DBEAD9E86BD3}}"
SETTLE="${PPASS_E3_SETTLE:-1800}"
OUT="$IOS/build/e3-batch/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
for tool in jq lsof sqlite3; do command -v "$tool" >/dev/null || { echo "error: 缺 $tool" >&2; exit 1; }; done
exec > >(tee "$OUT/e3.log") 2>&1
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
verdict() { # $1 = 场景，$2 = PASS|FAIL，$3 = 依据
  printf '%-13s %s  %s\n' "$1" "$2" "$3" | tee -a "$SUMMARY"
}

cd "$ROOT"
HEAD_SHA=$(git rev-parse HEAD)
DIRTY=$(git status --porcelain -- apps/ios crates | head -1)
echo "==> 代码 ${HEAD_SHA}${DIRTY:+（apps/ios 或 crates 有未提交改动）}，设备 ${DEV}"
echo "commit ${HEAD_SHA}${DIRTY:+ dirty}" >> "$SUMMARY"

# ---- 构建、安装（同 sim-bg-task.sh）----
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
  echo "installed $(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$SUMMARY"
fi
cargo build -q -p daemon --release
DAEMON="$ROOT/target/release/daemon"

copy_from() { # $1 = 容器内路径，$2 = 本地文件
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$1" --destination "$2" >/dev/null 2>&1
}
pull_log() { # 拼上一份滚动 + 当前，按时间顺序 → $1
  copy_from Library/Logs/ppass.log "$1.cur" || return 1
  copy_from Library/Logs/ppass.log.1 "$1.prev" || : > "$1.prev"
  cat "$1.prev" "$1.cur" > "$1"; rm -f "$1.prev" "$1.cur"
}
proc_log() { # $1 = pid，$2 = 输出：本进程（process start: pid=<pid>）的日志行
  pull_log "$OUT/ppass.log" && awk -v p="pid=$1 " 'index($0,"process start:") {on = index($0,p) > 0} on' "$OUT/ppass.log" > "$2"
}
APP_PID=
launch() { # $1 = 环境变量 JSON（空串 = 不带，devicectl 不收 {}），$2 = 名字
  local envargs=()
  [ -n "$1" ] && envargs=(--environment-variables "$1")
  xcrun devicectl device process launch --device "$DEV" --terminate-existing ${envargs[@]+"${envargs[@]}"} \
    --json-output "$OUT/launch-$2.json" "$BUNDLE_ID" >"$OUT/launch-$2.log" 2>&1 || { cat "$OUT/launch-$2.log"; exit 1; }
  APP_PID=$(jq -r '.result.process.processIdentifier' "$OUT/launch-$2.json")
}
wait_done() { # $1 = run，$2 = 超时秒，$3 = 输出 status 文件
  for _ in $(seq 1 $(($2 / 2))); do
    if copy_from Documents/e2e/status.json "$3" && [ "$(jq -r '.run // ""' "$3")" = "$1" ] \
      && [ "$(jq -r '.done // false' "$3")" = true ]; then return 0; fi
    sleep 2
  done
  echo "FAIL: 等 App 驱动（run=$1）超时（手机锁了？权限弹窗没点？）"; return 1
}
dump_db() { # $1 = 名字 → $OUT/db-<名字>/，并打印 owner / 各状态计数
  local run d="$OUT/db-$1"
  run="dump-$1-$(date +%s)"
  launch "$(jq -cn --arg r "$run" '{PPASS_E2E_DIR:"container", PPASS_E2E_RUN:$r, PPASS_BGTEST_DUMP:"1"}')" "dump-$1"
  wait_done "$run" 30 "$OUT/status-dump-$1.json"
  mkdir -p "$d"
  for f in backup-orders.db backup-orders.db-wal backup-orders.db-shm; do copy_from "Documents/e2e/db/$f" "$d/$f" || true; done
  [ -s "$d/backup-orders.db" ] || { echo "FAIL: 账本没拉回来"; return 1; }
}
q() { sqlite3 -readonly "$OUT/db-$1/backup-orders.db" "$2"; }
db_owner() { q "$1" "SELECT value FROM meta WHERE key='owner'"; }
db_orders() { q "$1" "SELECT COUNT(*) FROM orders"; }
# 只数源还在的（source_missing=0）：已移出范围 / 已删的照片换电脑后本来就不该重新确认。
db_confirmed() { q "$1" "SELECT COUNT(DISTINCT media_id) FROM orders WHERE state='CONFIRMED' AND source_missing=0"; }
db_skips() { q "$1" "SELECT COUNT(*) FROM skip_list"; }
db_line() { echo "owner=$(db_owner "$1" | cut -c1-8)… orders=$(db_orders "$1") confirmed=$(db_confirmed "$1") skip_list=$(db_skips "$1")"; }
newest_restore_dir() { find "$IOS/build/restore-pairing" -mindepth 1 -maxdepth 1 -type d | sort | tail -1; }

# ---- forensics ----
echo "==> forensics：设备信息 / 容器目录树 / 落盘日志"
xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1 || true
jq -r --arg d "$DEV" '.result.devices[] | select(.identifier == $d)
  | "device \(.deviceProperties.name) | \(.hardwareProperties.marketingName) \(.hardwareProperties.productType) | iOS \(.deviceProperties.osVersionNumber) (\(.deviceProperties.osBuildUpdate)) | udid \(.hardwareProperties.udid) | \(.connectionProperties.transportType) \(.connectionProperties.tunnelState)"' \
  "$OUT/devices.json" | tee "$OUT/device.txt"
xcrun devicectl device info files --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  >"$OUT/container-tree.txt" 2>&1 || true
launch '' forensics
FPID=$APP_PID
sleep 6
proc_log "$FPID" "$OUT/forensics-process.log" || true
STORAGE=$(grep -m1 'storage: using' "$OUT/forensics-process.log" || true)
if [ -s "$OUT/device.txt" ] && grep -q 'Library/Logs/ppass.log' "$OUT/container-tree.txt" && [ -n "$STORAGE" ]; then
  verdict forensics PASS "pid=${FPID}: ${STORAGE#* }；容器 $(grep -c . "$OUT/container-tree.txt") 行"
else
  verdict forensics FAIL "设备信息 / 容器树 / 本进程 storage 行有缺（见 $OUT）"
fi

# ---- 导出范围 + 开跑前账本 ----
echo "==> 导出相册范围"
RUN="scope-$(date +%s)"
launch "$(jq -cn --arg r "$RUN" '{PPASS_E2E_DIR:"container", PPASS_E2E_RUN:$r, PPASS_BGTEST_SCOPE_EXPORT:"1"}')" scope
wait_done "$RUN" 60 "$OUT/scope-before.json"
jq -e '.selected | type == "array"' "$OUT/scope-before.json" >/dev/null \
  || { echo "FAIL: 手机从未保存过相册范围，恢复不回这个状态；不跑"; exit 1; }
[ "$(jq -r .selected_test_albums "$OUT/scope-before.json")" = 0 ] \
  || { echo "FAIL: 当前范围里有测试相册，先 tools/ios/restore-desktop-pairing.sh 恢复"; exit 1; }
echo "  范围：$(jq -r '.selected | length' "$OUT/scope-before.json") 个相册"
dump_db before
echo "  开跑前账本：$(db_line before)"
OWNER0=$(db_owner before)

# 从这里起会动配对：退出时一律配回正式桌面并恢复范围。
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3.XXXXXX")
DAEMON_PID=
OWNER_PID=
RESTORED=
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$OWNER_PID" ] && kill "$OWNER_PID" 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  if [ -n "$DAEMON_PID" ]; then kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
  if [ -z "$RESTORED" ]; then
    echo "==> 收尾：配回正式桌面并恢复范围"
    if "$ROOT/tools/ios/restore-desktop-pairing.sh" "$OUT/scope-before.json" "$DEV" >"$OUT/restore-final.log" 2>&1; then
      tail -1 "$OUT/restore-final.log"
    else
      tail -8 "$OUT/restore-final.log"; echo "WARN: 恢复失败，手动跑 tools/ios/restore-desktop-pairing.sh $OUT/scope-before.json"; rc=1
    fi
  fi
  echo "--- summary（$SUMMARY）---"; cat "$SUMMARY"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- same-desktop ----
echo "==> same-desktop：配回同一台正式桌面"
"$ROOT/tools/ios/restore-desktop-pairing.sh" "$OUT/scope-before.json" "$DEV" >"$OUT/restore-same.log" 2>&1 \
  || { tail -8 "$OUT/restore-same.log"; verdict same-desktop FAIL "restore-desktop-pairing.sh 失败"; exit 1; }
RD=$(newest_restore_dir)
cp "$RD/process.log" "$OUT/same-process.log" 2>/dev/null || true
sleep 10 # 让 PAIRING_REPAIRED 那一轮跑完再导账本
proc_log "$(sed -n 's/.*App pid=\([0-9]*\).*/\1/p' "$OUT/restore-same.log" | head -1)" "$OUT/same-process.log" || true
dump_db same
echo "  账本：$(db_line same)"
STARTS=$(grep -c 'item start' "$OUT/same-process.log" || true)
if [ "$(db_owner same)" = "$OWNER0" ] && [ "$(db_orders same)" -ge "$(db_orders before)" ] \
  && [ "$(db_confirmed same)" -ge "$(db_confirmed before)" ] && [ "$STARTS" = 0 ]; then
  verdict same-desktop PASS "owner 不变；orders $(db_orders before)→$(db_orders same)，confirmed $(db_confirmed before)→$(db_confirmed same)；本进程 item start ${STARTS} 次"
else
  verdict same-desktop FAIL "owner/计数变了或有重传：before[$(db_line before)] after[$(db_line same)] item start ${STARTS}"
fi

# ---- new-desktop ----
echo "==> new-desktop：配到本机临时 daemon（范围清空，不传照片）"
mkdir -p "$WORK/home" "$WORK/data"
mkfifo "$WORK/stdin"
HOME="$WORK/home" PPF_DATA_DIR="$WORK/data" PPF_BIND_ADDR="0.0.0.0:0" PPF_RELAY_URLS="" PPF_TELEMETRY_ENABLED=false \
  RUST_LOG=info "$DAEMON" --ephemeral <"$WORK/stdin" >"$WORK/daemon.out" 2>"$WORK/daemon.err" &
DAEMON_PID=$!
exec 4>"$WORK/stdin"
NODE_ID=
for _ in $(seq 1 150); do
  NODE_ID=$(sed -n 's/^NodeId: \([0-9a-f]\{64\}\).*/\1/p' "$WORK/daemon.out" | head -1)
  [ -n "$NODE_ID" ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.2
done
[ -n "$NODE_ID" ] || { echo "error: 临时 daemon 没打出 NodeId" >&2; cat "$WORK/daemon.err" >&2; exit 1; }
sleep 1
# shellcheck source=tools/ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"
ipc_pair_qr "$WORK/data/ipc.token"
owner_loop() {
  local resp n
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    if resp=$(ipc pairing.pending 2>/dev/null); then
      for n in $(printf '%s' "$resp" | jq -r '.result.pending[]?.node_id // empty'); do
        ipc pairing.confirm "$(jq -cn --arg n "$n" '{accept: true, node_id: $n}')" >/dev/null 2>&1 && echo "  临时 daemon：已允许 ${n:0:8}…"
      done
    fi
    sleep 0.3
  done
}
owner_loop &
OWNER_PID=$!
RESTORED=0 # 从这一刻起手机可能配着临时 daemon
RUN="newdesk-$(date +%s)"
launch "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN" '{PPASS_E2E_DIR:"container", PPASS_E2E_PAIR_LINK:$l, PPASS_E2E_RUN:$r, PPASS_BGTEST_PAIR_ONLY:"1"}')" newdesk
wait_done "$RUN" 90 "$OUT/status-newdesk.json"
[ "$(jq -r .step "$OUT/status-newdesk.json")" = paired ] \
  || { verdict new-desktop FAIL "配对失败：$(jq -r '.error // .pair_outcome' "$OUT/status-newdesk.json")"; exit 1; }
sleep 5
dump_db newdesk
echo "  账本：$(db_line newdesk)（临时 daemon ${NODE_ID:0:8}…）"
if [ "$(db_owner newdesk)" = "$NODE_ID" ] && [ "$(db_orders newdesk)" = 0 ] && [ "$(db_skips newdesk)" = "$(db_skips before)" ]; then
  verdict new-desktop PASS "owner ${OWNER0:0:8}…→${NODE_ID:0:8}…；orders $(db_orders before)→0；skip_list 保留 $(db_skips newdesk)"
else
  verdict new-desktop FAIL "before[$(db_line before)] after[$(db_line newdesk)] 期望 owner=${NODE_ID:0:8}… orders=0"
fi
kill "$OWNER_PID" 2>/dev/null || true; OWNER_PID=
kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; DAEMON_PID=

# ---- back-formal ----
echo "==> back-formal：配回正式桌面并恢复范围，等重新确认那一轮收场（最多 ${SETTLE} 秒）"
"$ROOT/tools/ios/restore-desktop-pairing.sh" "$OUT/scope-before.json" "$DEV" >"$OUT/restore-back.log" 2>&1 \
  || { tail -8 "$OUT/restore-back.log"; verdict back-formal FAIL "restore-desktop-pairing.sh 失败"; exit 1; }
RESTORED=1
BPID=$(sed -n 's/.*App pid=\([0-9]*\).*/\1/p' "$OUT/restore-back.log" | head -1)
SETTLED=
for _ in $(seq 1 $((SETTLE / 15))); do
  sleep 15
  proc_log "$BPID" "$OUT/back-process.log" || continue
  # 只看配上正式桌面之后（第一条 PAIRING_REPAIRED 起）的行；配对前那一轮（范围已清空）的 nothing to transfer 不算收场。
  awk '/PAIRING_REPAIRED/ {on = 1} on' "$OUT/back-process.log" > "$OUT/back-run.log"
  S=$(grep -c 'item start' "$OUT/back-run.log" || true); E=$(grep -c 'item end' "$OUT/back-run.log" || true)
  # 收场 = 开始的都结束了，且最后一条进度行是「对账扫描收尾」或「没有可传的」
  LAST=$(grep -E 'item (start|end)|reconcile scan finished|cycle \[.*\]: nothing to transfer' "$OUT/back-run.log" | tail -1)
  if [ "$S" = "$E" ] && printf '%s' "$LAST" | grep -qE 'reconcile scan finished|nothing to transfer'; then SETTLED=1; break; fi
  echo "  已送达 ${E} 张…"
done
dump_db after
echo "  账本：$(db_line after)"
DEDUP=$(grep -c 'Flow resolved by=offer_reply' "$OUT/back-run.log" || true)
PUSHED=$(grep -c 'Flow resolved by=push' "$OUT/back-run.log" || true)
FORMAL=$(sed -n 's/.*node \([0-9a-f]\{8\}\)….*/\1/p' "$OUT/restore-back.log" | head -1)
if [ -n "$SETTLED" ] && [ "$(db_owner after | cut -c1-8)" = "$FORMAL" ] && [ "$(db_confirmed after)" -ge "$(db_confirmed before)" ]; then
  verdict back-formal PASS "owner→${FORMAL}…；confirmed $(db_confirmed before)→$(db_confirmed after)；桌面已有 ${DEDUP} 张（offer_reply）、新收 ${PUSHED} 张（push）"
else
  verdict back-formal FAIL "settled=${SETTLED:-no} before[$(db_line before)] after[$(db_line after)] formal=${FORMAL}"
fi
FAILS=$(grep -c ' FAIL ' "$SUMMARY" || true)
[ "$FAILS" = 0 ]
