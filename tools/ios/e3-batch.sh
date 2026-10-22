#!/usr/bin/env bash
# iOS 真机批量取证 + 自动判定（#939）：不等系统调度、不要人点（相册 / 本地网络权限须已授予，手机解锁亮屏）。
#
#   tools/ios/e3-batch.sh [设备标识]      # 输出在 apps/ios/build/e3-batch/<时间>/，结论汇总在 summary.txt
#
# 环境变量：
#   PPASS_DEVICE         devicectl 设备标识（默认 iPhone 16 测试机）
#   PPASS_SKIP_BUILD=1   不重新构建 / 安装（App 已是当前代码的 Debug 包时用）
#   PPASS_E3_PHOTOS      测试照片张数（默认 6，程序生成的噪声图，不可压缩）
#   PPASS_E3_SETTLE      配回老电脑后，等重新确认那一轮收场的秒数（默认 600）
#
# 两台测试沙盒桌面（tools/ios/sandbox-desk.sh，daemon --ephemeral，各自的假 HOME 与临时库）：
#   A =「老电脑」，整轮都在；B =「新电脑」，只在 new-desktop 一例里起。#1115 之后脚本连不上本机正式桌面，
#   「同一台 / 换一台电脑」都在两台沙盒之间演。照片只用脚本生成、写进新建测试相册「PPass BGTest <run>」的那几张，
#   不碰用户的真实相册；手机存储根开跑时清空（PPASS_E2E_RESET，测试机）。
#
# 场景（顺序固定，每个场景 PASS / FAIL 写进 summary.txt）：
#   forensics     设备信息、App 容器目录树、落盘日志能拉回且本进程写了 App Group 存储根行（#347 / #334 验收 1）。
#   seed          配到 A、只选测试相册并写入 N 张照片，等 A 收齐 N 张——后面几例的「开跑前账本」。
#   same-desktop  再配一次 A：账本 owner 不变、orders 一行不少、本进程不重传、A 的照片数不变（同一台电脑重配不重传，#935）。
#   new-desktop   配到 B（范围清空、不传任何照片）：owner 换成 B、orders 清空（换电脑后旧电脑的「已确认」不算给新电脑，
#                 #935 / #339 P-01 / #338 验收 5）；跳过名单保留；B 一张没收到。
#   back-formal   配回 A 并恢复测试相册范围：又一次换电脑 → orders 清空后按现算差集重新确认；等这一轮收场，
#                 CONFIRMED 不少于开跑前，N 张全由 A 答「已有」（offer_reply），没有重新上传（push = 0），A 的照片数仍是 N。
# 账本在 App Group（devicectl 拉不到）：用 DEBUG 驱动 PPASS_BGTEST_DUMP=1 拷进 App 容器再拉回（同 sim-bg-task.sh）。
# 收尾（含中途失败 / Ctrl-C）：两台沙盒都收掉。手机这时配着已退出的沙盒，配回正式桌面要人在桌面 App 里操作
# （打开 P-Pass →「添加设备」→ 手机扫码 → 桌面点「允许」）；开跑前的相册范围导出在 scope-before.json，测试相册用
# tools/ios/delete-test-assets.sh 删。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
DEV="${1:-${PPASS_DEVICE:-B2805351-9CD1-55C7-81B0-DBEAD9E86BD3}}"
OUT="$IOS/build/e3-batch/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
for tool in jq lsof sqlite3 ffmpeg; do command -v "$tool" >/dev/null || { echo "error: 缺 $tool" >&2; exit 1; }; done
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
DAEMON="${CARGO_TARGET_DIR:-$ROOT/target}/release/daemon"
N="${PPASS_E3_PHOTOS:-6}"
SETTLE="${PPASS_E3_SETTLE:-600}"
# shellcheck source=tools/ios/sandbox-desk.sh
source "$ROOT/tools/ios/sandbox-desk.sh"

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
wait_step() { # $1 = run，$2 = 期望 step，$3 = 超时秒，$4 = 输出 status 文件（不要求 done）
  local s=
  for _ in $(seq 1 $(($3 / 2))); do
    if copy_from Documents/e2e/status.json "$4" && [ "$(jq -r '.run // ""' "$4")" = "$1" ]; then
      s=$(jq -r .step "$4")
      [ "$s" = "$2" ] && return 0
      [ "$s" = failed ] && { echo "FAIL: App 驱动报错：$(jq -r .error "$4")"; return 1; }
    fi
    sleep 2
  done
  echo "FAIL: 等 App 到 step=$2 超时（当前 ${s:-无}）"; return 1
}
pair_only() { # $1 = 桌面工作目录，$2 = 名字，$3 = 恢复的范围 JSON（空串 = 保持清空）；配好后 APP_PID = 这个进程
  local run env
  desk_qr "$1"
  run="$2-$(date +%s)"
  env=$(jq -cn --arg l "$PAIR_QR" --arg r "$run" --arg s "$3" \
    '{PPASS_E2E_DIR:"container", PPASS_E2E_PAIR_LINK:$l, PPASS_E2E_RUN:$r, PPASS_BGTEST_PAIR_ONLY:"1"}
     + (if $s == "" then {} else {PPASS_BGTEST_SCOPE_RESTORE:$s, PPASS_BGTEST_ALLOW_TEST_SCOPE:"1"} end)')
  launch "$env" "$2"
  wait_done "$run" 90 "$OUT/status-$2.json" || return 1
  [ "$(jq -r .step "$OUT/status-$2.json")" = paired ] \
    || { echo "配对失败：$(jq -r '.error // .pair_outcome' "$OUT/status-$2.json")"; return 1; }
  if [ -n "$3" ] && [ "$(jq -r '.scope_restored // false' "$OUT/status-$2.json")" != true ]; then
    echo "范围没恢复：$(jq -c '{scope_error, scope_conflict}' "$OUT/status-$2.json")"; return 1
  fi
}

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
  verdict forensics FAIL "设备信息 / 容器树 / 本进程 storage 行有缺（见 ${OUT}）"
fi

# ---- 开跑前：导出用户当前的相册范围（只为收尾提示人怎么恢复，脚本不改回去）----
echo "==> 导出相册范围"
RUN="scope-$(date +%s)"
launch "$(jq -cn --arg r "$RUN" '{PPASS_E2E_DIR:"container", PPASS_E2E_RUN:$r, PPASS_BGTEST_SCOPE_EXPORT:"1"}')" scope
wait_done "$RUN" 60 "$OUT/scope-before.json"
echo "  范围：$(jq -r '.selected | if type == "array" then "\(length) 个相册" else "从未保存" end' "$OUT/scope-before.json")"

# 从这里起会动配对：退出时收掉两台沙盒，并告诉人怎么配回正式桌面。
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3.XXXXXX")
DESK_A="$WORK/A"
DESK_B="$WORK/B"
TOUCHED=
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  for d in "$DESK_A" "$DESK_B"; do
    [ -d "$d" ] || continue
    cp "$d/daemon.err" "$OUT/daemon-$(basename "$d").err" 2>/dev/null || true
    desk_stop "$d"
  done
  rm -rf "$WORK"
  if [ -n "$TOUCHED" ]; then
    echo "==> 手机这时配着已退出的测试沙盒。配回正式桌面：打开 P-Pass 桌面 →「添加设备」→ 手机扫码 → 桌面点「允许」。"
    echo "    开跑前的相册范围在 $OUT/scope-before.json，在手机 App 里按它重新选；测试相册用 tools/ios/delete-test-assets.sh 删。"
  fi
  echo "--- summary（${SUMMARY}）---"; cat "$SUMMARY"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$DESK_A" "$DESK_B" "$WORK/seed"
desk_start "$DESK_A" "$DAEMON"
desk_auto_allow "$DESK_A"
NODE_A=$(desk_node "$DESK_A")
echo "  老电脑 A：${NODE_A:0:8}…"

# ---- seed ----
echo "==> seed：配到 A，只选新建的测试相册，写入 ${N} 张照片，等 A 收齐"
SEED_BASE=$(date +%s)
for i in $(seq 1 "$N"); do
  ffmpeg -loglevel error -f lavfi -i "color=c=gray:s=2000x1500,noise=alls=100:allf=u:all_seed=$((SEED_BASE + i))" \
    -frames:v 1 -q:v 2 "$WORK/seed/$(printf 'p%03d' "$i").jpg"
done
desk_qr "$DESK_A"
RUN="seed-$(date +%s)"
TOUCHED=1
launch "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN" \
  '{PPASS_E2E_DIR:"container", PPASS_E2E_PAIR_LINK:$l, PPASS_E2E_RUN:$r, PPASS_E2E_RESET:"1", PPASS_BGTEST:"1"}')" seed
wait_step "$RUN" ready 120 "$OUT/status-seed.json" || { verdict seed FAIL "没走到 ready"; exit 1; }
for f in "$WORK/seed"/*; do
  xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$f" --destination "Documents/e2e/seed/$(basename "$f")" >/dev/null 2>&1 || { verdict seed FAIL "拷 $(basename "$f") 失败"; exit 1; }
done
: > "$WORK/go"
xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source "$WORK/go" --destination Documents/e2e/seed/go >/dev/null 2>&1
wait_step "$RUN" seeded 120 "$OUT/status-seed.json" || { verdict seed FAIL "照片没写进测试相册"; exit 1; }
# 重开一次 App（APP_FOREGROUND 补捞）把测试相册传给 A。
launch '' backup
GOT=0
for _ in $(seq 1 150); do
  GOT=$(desk_photo_count "$DESK_A" 2>/dev/null || echo 0)
  [ "$GOT" = "$N" ] && break
  sleep 2
done
[ "$GOT" = "$N" ] || { verdict seed FAIL "A 只收到 ${GOT}/${N} 张"; exit 1; }
sleep 5 # 让收尾的那条账本写完
RUN="scope-test-$(date +%s)"
launch "$(jq -cn --arg r "$RUN" '{PPASS_E2E_DIR:"container", PPASS_E2E_RUN:$r, PPASS_BGTEST_SCOPE_EXPORT:"1"}')" scope-test
wait_done "$RUN" 60 "$OUT/scope-test.json"
SCOPE_TEST=$(jq -c '{selected, known}' "$OUT/scope-test.json")
dump_db before
echo "  开跑前账本：$(db_line before)"
OWNER0=$(db_owner before)
if [ "$OWNER0" = "$NODE_A" ] && [ "$(db_confirmed before)" -ge "$N" ] && [ "$(jq -r .selected_test_albums "$OUT/scope-test.json")" = 1 ]; then
  verdict seed PASS "A 收到 ${N} 张；owner=${NODE_A:0:8}…，$(db_line before)"
else
  verdict seed FAIL "owner/计数不对：$(db_line before)，A=${NODE_A:0:8}…"; exit 1
fi

# ---- same-desktop ----
echo "==> same-desktop：再配一次 A"
pair_only "$DESK_A" same "$SCOPE_TEST" || { verdict same-desktop FAIL "配对 / 恢复范围失败"; exit 1; }
SPID=$APP_PID
sleep 15 # 让 PAIRING_REPAIRED 那一轮跑完再导账本
proc_log "$SPID" "$OUT/same-process.log" || true
dump_db same
echo "  账本：$(db_line same)"
STARTS=$(grep -c 'item start' "$OUT/same-process.log" || true)
A_COUNT=$(desk_photo_count "$DESK_A")
if [ "$(db_owner same)" = "$OWNER0" ] && [ "$(db_orders same)" -ge "$(db_orders before)" ] \
  && [ "$(db_confirmed same)" -ge "$(db_confirmed before)" ] && [ "$STARTS" = 0 ] && [ "$A_COUNT" = "$N" ]; then
  verdict same-desktop PASS "owner 不变；orders $(db_orders before)→$(db_orders same)，confirmed $(db_confirmed before)→$(db_confirmed same)；item start ${STARTS} 次；A 仍是 ${A_COUNT} 张"
else
  verdict same-desktop FAIL "before[$(db_line before)] after[$(db_line same)] item start ${STARTS}，A=${A_COUNT}"
fi

# ---- new-desktop ----
echo "==> new-desktop：配到新电脑 B（范围清空，不传照片）"
desk_start "$DESK_B" "$DAEMON"
desk_auto_allow "$DESK_B"
NODE_B=$(desk_node "$DESK_B")
echo "  新电脑 B：${NODE_B:0:8}…"
pair_only "$DESK_B" newdesk "" || { verdict new-desktop FAIL "配对失败"; exit 1; }
sleep 5
dump_db newdesk
echo "  账本：$(db_line newdesk)"
B_COUNT=$(desk_photo_count "$DESK_B")
if [ "$(db_owner newdesk)" = "$NODE_B" ] && [ "$(db_orders newdesk)" = 0 ] && [ "$(db_skips newdesk)" = "$(db_skips before)" ] \
  && [ "$B_COUNT" = 0 ]; then
  verdict new-desktop PASS "owner ${OWNER0:0:8}…→${NODE_B:0:8}…；orders $(db_orders before)→0；skip_list 保留 $(db_skips newdesk)；B 收到 0 张"
else
  verdict new-desktop FAIL "before[$(db_line before)] after[$(db_line newdesk)] 期望 owner=${NODE_B:0:8}… orders=0；B=${B_COUNT}"
fi
desk_stop "$DESK_B"

# ---- back-formal ----
echo "==> back-formal：配回 A 并恢复测试相册范围，等重新确认那一轮收场（最多 ${SETTLE} 秒）"
pair_only "$DESK_A" back "$SCOPE_TEST" || { verdict back-formal FAIL "配对 / 恢复范围失败"; exit 1; }
BPID=$APP_PID
SETTLED=
for _ in $(seq 1 $((SETTLE / 15))); do
  sleep 15
  proc_log "$BPID" "$OUT/back-process.log" || continue
  # 只看配上 A 之后（第一条 PAIRING_REPAIRED 起）的行；配对前那一轮（范围已清空）的 nothing to transfer 不算收场。
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
A_COUNT=$(desk_photo_count "$DESK_A")
if [ -n "$SETTLED" ] && [ "$(db_owner after)" = "$NODE_A" ] && [ "$(db_confirmed after)" -ge "$(db_confirmed before)" ] \
  && [ "$DEDUP" -ge "$N" ] && [ "$PUSHED" = 0 ] && [ "$A_COUNT" = "$N" ]; then
  verdict back-formal PASS "owner→${NODE_A:0:8}…；confirmed $(db_confirmed before)→$(db_confirmed after)；A 答已有 ${DEDUP} 张、重新上传 ${PUSHED} 张；A 仍是 ${A_COUNT} 张"
else
  verdict back-formal FAIL "settled=${SETTLED:-no} before[$(db_line before)] after[$(db_line after)] offer_reply=${DEDUP} push=${PUSHED} A=${A_COUNT}"
fi
FAILS=$(grep -c ' FAIL ' "$SUMMARY" || true)
[ "$FAILS" = 0 ]
