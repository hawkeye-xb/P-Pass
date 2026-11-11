#!/usr/bin/env bash
# iOS 界面回归（#1458）：XCUITest 走真实界面、系统弹窗由测试点，按 App 落盘日志逐例判 PASS/FAIL。
#
#   tools/ios/ui-regress.sh sim    [选项]      # 模拟器（tools/ios/sim.sh 选的那台）
#   tools/ios/ui-regress.sh device [选项]      # 真机（持 tools/e3/lock ios；just ios-ui-regress device 已带锁）
#   tools/ios/ui-regress.sh judge <规则表> <用例> <ppass.log> <开跑时刻 epoch 秒>   # 只做判定（自测用）
# 选项：
#   --only A,B        只跑这几例（默认全部，顺序见 CASES）
#   --invert <用例>   反证：该例的系统弹窗故意点反向选项，判定期望不变 ⇒ 这一例必须 FAIL
#   --skip-build      复用上次 build-for-testing 的产物
#   --build-only      只跑 build-for-testing 就退出（真机在锁外先编，见 justfile 的 device 分支）
#   --device <标识>   真机 devicectl 标识（默认 $PPASS_DEVICE、e3.env 的 E3_IOS_UDID、或唯一一台在线 iPhone）
# 输出：apps/ios/build/ui-regress/<时间>/，汇总 summary.txt；有 FAIL 退出 1。
#
# 做法：起一台隔离配对桩（tools/ios/sandbox-desk.sh，daemon --ephemeral，不碰本机 P-Pass）；
# build-for-testing 一次；模拟器每例 test-without-building、真机每例 xcodebuild test（见 run_case 注释），
# 每次给新配对串（TEST_RUNNER_UIREG_PAIR_LINK）。
# App 用 DEBUG 门控键（PPASS_E2E_RESET / PPASS_ROUTE=manual / PPASS_PAIR_CODE）从欢迎页手动配对；测试把界面上的
# 验证码打成 `UIREG PAIR_CODE=<6 位>`，本脚本据此允许唯一的待确认请求（扮演桌面主人）。
# 通知授权 iOS 只问一次、没有重置 API：开跑前与 NotifyDeny 之前各卸载重装一次。
# 会清掉设备上 P-Pass 的数据并卸载重装（测试机）；跑完 App 配着已退出的配对桩，要配回正式桌面得重新扫码。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
RULES_DEFAULT="$ROOT/tools/ios/ui-regress-rules.tsv"

# ---- 判定：本例 App 进程的日志切片里，规则的通过行按顺序都出现 ----
judge() { # $1 规则表 $2 用例 $3 日志 $4 开跑 epoch
  python3 -I -X utf8 - "$@" <<'PY'
import re, sys
from datetime import datetime
rules_path, case, log_path, since = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
rule = None
for line in open(rules_path, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    cols = line.rstrip("\n").split("\t")
    if cols[0] == case:
        rule = [p.strip() for p in cols[1].split(" >> ")]
if rule is None:
    print(f"FAIL\t判定表里没有用例 {case}"); sys.exit(0)
try:
    lines = open(log_path, encoding="utf-8", errors="replace").read().splitlines()
except OSError as e:
    print(f"FAIL\t拉不回 App 日志（{e}）"); sys.exit(0)
def ts(l):
    try:
        return datetime.fromisoformat(l.split(" ", 1)[0]).timestamp()
    except ValueError:
        return None
# 本例的进程：最后一个时间不早于开跑时刻（留 5 秒时钟误差）的 `process start: pid=`。
start = None
for i, l in enumerate(lines):
    t = ts(l)
    if "process start: pid=" in l and t is not None and t >= since - 5:
        start = i
if start is None:
    print("FAIL\t日志里没有本例开跑之后的 App 启动行（process start）"); sys.exit(0)
pid = re.search(r"pid=(\d+)", lines[start]).group(1)
seg = lines[start:]
pos = 0
for p in rule:
    rx = re.compile(p)
    hit = next((k for k in range(pos, len(seg)) if rx.search(seg[k])), None)
    if hit is None:
        print(f"FAIL\t缺通过行「{p}」（本例进程 pid={pid}，{len(seg)} 行）"); sys.exit(0)
    pos = hit + 1
print(f"PASS\t{seg[pos - 1].split(' ', 1)[1][:120]}")
PY
}

if [ "${1:-}" = judge ]; then
  shift
  judge "$@"
  exit 0
fi

TARGET="${1:-}"
case "$TARGET" in sim | device) shift ;; *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
CASES="DecisionScopeFull DecisionPick SettingsRuleFull SettingsRuleLimited SettingsRuleDenied SettingsPick NotifyAllow NotifyDeny"
ONLY=""
INVERT=""
SKIP_BUILD=0
BUILD_ONLY=0
DEV="${PPASS_DEVICE:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) ONLY="$(echo "${2:?}" | tr ',' ' ')"; shift 2 ;;
    --invert) INVERT="${2:?}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --device) DEV="${2:?}"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
[ -z "$ONLY" ] || CASES="$ONLY"
for c in $CASES $INVERT; do
  grep -q "^${c}	" "$RULES_DEFAULT" || { echo "未知用例：$c（见 $RULES_DEFAULT）" >&2; exit 2; }
done
for tool in jq xcodegen python3; do command -v "$tool" >/dev/null || { echo "error: 缺 $tool" >&2; exit 1; }; done

BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
OUT="$IOS/build/ui-regress/$(date +%Y%m%d-%H%M%S)-$TARGET"
DERIVED="$IOS/build/ui-regress-derived-$TARGET"
mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1
SUMMARY="$OUT/summary.txt"
: >"$SUMMARY"
cd "$ROOT"

# ---- 设备 ----
if [ "$TARGET" = sim ]; then
  UDID=$("$ROOT/tools/ios/sim.sh" udid)
  # shellcheck source=tools/ios/sim-lock.sh
  . "$ROOT/tools/ios/sim-lock.sh"
  sim_lock_acquire
  BOOTED_BEFORE="$("$ROOT/tools/ios/sim.sh" booted)"
  # 不用 `simctl bootstatus -b`：本机实测它在已开机的模拟器上也会一直挂着（2026-11-05，Xcode 26.6）。
  xcrun simctl boot "$UDID" 2>/dev/null || true
  for _ in $(seq 1 120); do
    [ "$(xcrun simctl list devices -j | jq -r --arg u "$UDID" '.devices[][] | select(.udid == $u) | .state')" = Booted ] && break
    sleep 1
  done
  DEST="id=$UDID"
  BUILD_DEST="platform=iOS Simulator,id=$UDID"
  SIGN=()
else
  SIGN=(-allowProvisioningUpdates)
  if [ -z "$DEV" ]; then
    # 本机 e3.env（tools/e3/lib/common.sh 同一个文件）里的 E3_IOS_UDID。
    DEV="$(sed -n 's/^E3_IOS_UDID=//p' "${E3_ENV:-$HOME/.config/ppass/e3.env}" 2>/dev/null | tail -1 | tr -d '"'"'"'"' || true)"
  fi
  if [ -z "$DEV" ]; then
    xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1 || true
    DEV=$(jq -r '[.result.devices[]? | select(.hardwareProperties.platform == "iOS" and .connectionProperties.tunnelState != "unavailable")] | if length == 1 then .[0].identifier else empty end' "$OUT/devices.json" 2>/dev/null || true)
  fi
  [ -n "$DEV" ] || { echo "error: 找不到唯一一台在线 iPhone；用 --device 或 PPASS_DEVICE 指定" >&2; exit 1; }
  # --build-only 在锁外编：不要求持锁（构建按设备 destination，产出的包才认得出这台手机）。
  if [ "$BUILD_ONLY" = 0 ] && [ -z "${E3_LOCKED_IOS:-}" ]; then
    echo "error: 真机要先持设备锁：tools/e3/lock ios $0 device …（just ios-ui-regress device 已带）" >&2
    exit 1
  fi
  # xcodebuild 要硬件 UDID；devicectl 的标识是 CoreDevice UUID，两者都换算一次。
  xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1
  HW_UDID=$(jq -r --arg d "$DEV" '.result.devices[] | select(.identifier == $d or .hardwareProperties.udid == $d or .deviceProperties.name == $d) | .hardwareProperties.udid' "$OUT/devices.json" | head -1)
  DEV=$(jq -r --arg d "$DEV" '.result.devices[] | select(.identifier == $d or .hardwareProperties.udid == $d or .deviceProperties.name == $d) | .identifier' "$OUT/devices.json" | head -1)
  [ -n "$HW_UDID" ] || { echo "error: devicectl 里找不到设备 $DEV" >&2; exit 1; }
  DEST="id=$HW_UDID"
  BUILD_DEST="id=$HW_UDID"
fi

DESK="$OUT/desk"
cleanup() {
  [ -n "${ALLOW_PID:-}" ] && kill "$ALLOW_PID" 2>/dev/null || true
  desk_stop "$DESK" 2>/dev/null || true
  if [ "$TARGET" = sim ]; then
    "$ROOT/tools/ios/sim.sh" shutdown-new "$BOOTED_BEFORE" 2>/dev/null || true
    sim_lock_release
  fi
}
trap cleanup EXIT

HEAD_SHA=$(git rev-parse --short HEAD)
DIRTY=$(git status --porcelain -- apps/ios | head -1)
echo "==> iOS 界面回归 $TARGET，代码 ${HEAD_SHA}${DIRTY:+（apps/ios 有未提交改动）}，用例：$CASES${INVERT:+，反证：$INVERT}"
echo "commit ${HEAD_SHA}${DIRTY:+ dirty} target=$TARGET${INVERT:+ invert=$INVERT}" >>"$SUMMARY"

# ---- 构建 ----
if [ "$SKIP_BUILD" != 1 ]; then
  echo "==> 构建配对桩（daemon）与 App + UI 测试（build-for-testing）"
  cargo build -q -p daemon --release
  if [ ! -d "$IOS/TransportFFITests/Generated/TransportFFI.xcframework" ] || [ ! -f "$IOS/TransportFFITests/Generated/swift/transport.swift" ]; then
    "$ROOT/tools/build-ios-transport-xcframework.sh" "$IOS/TransportFFITests/Generated"
  fi
  (cd "$IOS" && xcodegen generate --quiet)
  xcodebuild build-for-testing -project "$IOS/PPass.xcodeproj" -scheme PPassUI -configuration Debug \
    -destination "$BUILD_DEST" -derivedDataPath "$DERIVED" ${SIGN[@]+"${SIGN[@]}"} >"$OUT/build.log" 2>&1 \
    || { tail -40 "$OUT/build.log"; echo "FAIL: build-for-testing（见 $OUT/build.log）" | tee -a "$SUMMARY"; exit 1; }
fi
if [ "$BUILD_ONLY" = 1 ]; then
  echo "==> 构建完成（--build-only），没跑用例；接着持锁跑 --skip-build。证据：$OUT"
  exit 0
fi
DAEMON="${CARGO_TARGET_DIR:-$ROOT/target}/release/daemon"
# shellcheck disable=SC2012 # 文件名由 xcodebuild 生成，没有特殊字符；取最新的一份
XCTESTRUN=$(ls -t "$DERIVED"/Build/Products/PPassUI_*"$([ "$TARGET" = sim ] && echo iphonesimulator || echo iphoneos)"*.xctestrun 2>/dev/null | head -1)
# 只有模拟器吃 .xctestrun；真机每例走 xcodebuild test，会自己按需构建。
if [ "$TARGET" = sim ]; then
  [ -n "$XCTESTRUN" ] || { echo "error: 没有 .xctestrun（先不带 --skip-build 跑一次）" >&2; exit 1; }
fi
APP_PATH="$DERIVED/Build/Products/Debug-$([ "$TARGET" = sim ] && echo iphonesimulator || echo iphoneos)/PPass.app"

# ---- 设备操作 ----
# 模拟器图库是空的（别人 erase 过）时造一张：选照片的用例不能依赖残留状态。
ensure_sim_photos() {
  local dcim="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/DCIM"
  if [ -n "$(find "$dcim" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' \) 2>/dev/null | head -1)" ]; then
    return 0
  fi
  echo "  模拟器图库是空的：造一张测试照片"
  python3 -I - "$OUT/seed.png" <<'PY'
import struct, sys, zlib
w = h = 64
raw = b"".join(b"\x00" + bytes([200, 120, 60]) * w for _ in range(h))
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
  xcrun simctl addmedia "$UDID" "$OUT/seed.png"
  sleep 2
}

reinstall() {
  echo "  重装 App（清通知授权与数据）"
  if [ "$TARGET" = sim ]; then
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$UDID" "$APP_PATH"
  else
    xcrun devicectl device uninstall app --device "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun devicectl device install app --device "$DEV" "$APP_PATH" >"$OUT/install.log" 2>&1 || { tail -5 "$OUT/install.log"; exit 1; }
  fi
}
pull_log() { # $1 目标文件；拉不到不算脚本错误（判定会报 FAIL「拉不回 App 日志」）
  rm -f "$1"
  if [ "$TARGET" = sim ]; then
    local c
    c=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null) && cp "$c/Library/Logs/ppass.log" "$1" 2>/dev/null || true
  else
    xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source Library/Logs/ppass.log --destination "$1" >/dev/null 2>&1 || true
  fi
  return 0
}

# 设置页按显示文字找的控件：文字取自 App 的 Localizable.strings（中英都给，测试哪个找到用哪个）。
str() { sed -n "s/^\"$1\" = \"\(.*\)\";/\1/p" "$IOS"/PPass/Resources/*.lproj/Localizable.strings | sort -u | paste -sd'|' -; }
SETTINGS_TAB="$(str tab_settings)"
NOTIFY_LABEL="$(str rule_notify)"

# ---- 配对桩 ----
# shellcheck source=tools/ios/sandbox-desk.sh
source "$ROOT/tools/ios/sandbox-desk.sh"
desk_start "$DESK" "$DAEMON"
echo "  配对桩 node=$(desk_node "$DESK" | cut -c1-8)…"

# 扮演桌面主人：读本例 xcodebuild 输出里测试打出的验证码，允许唯一的待确认请求。
allow_loop() { # $1 本例 xcodebuild 日志
  local resp nodes code used=""
  while true; do
    code=$(sed -n 's/.*UIREG PAIR_CODE=\([0-9]\{6\}\).*/\1/p' "$1" 2>/dev/null | tail -1)
    if [ -n "$code" ] && [ "$code" != "$used" ] && resp=$(desk_ipc "$DESK" pairing.pending 2>/dev/null); then
      nodes=$(printf '%s' "$resp" | jq -r '.result.pending[]?.node_id // empty')
      if [ "$(printf '%s\n' "$nodes" | grep -c .)" = 1 ]; then
        if desk_ipc "$DESK" pairing.confirm "$(jq -cn --arg n "$nodes" --arg c "$code" '{accept: true, node_id: $n, code: $c}')" >/dev/null 2>&1; then
          echo "  桌面：已用验证码允许 ${nodes:0:8}…"
          used="$code"
        fi
      fi
    fi
    sleep 0.3
  done
}

FAILS=0
run_case() { # $1 用例
  local c="$1" xlog="$OUT/$1.xcodebuild.log" since rc verdict reason
  desk_qr "$DESK" >/dev/null
  since=$(date +%s)
  : >"$xlog"
  allow_loop "$xlog" &
  ALLOW_PID=$!
  echo "==> [$c]$([ "$c" = "$INVERT" ] && echo "（反证：故意点反向选项）")"
  rc=0
  # 真机用 test（不是 test-without-building）：本机实测 iPhone test（iOS 27.3）+ Xcode 26.6 上，
  # test-without-building 启动被测 App 必报「process identifier ... could not be determined」，
  # 同一份 xctestrun 换 test 就能起来（2026-11-11）。构建已由 build-for-testing 预热，这里只做增量检查。
  if [ "$TARGET" = sim ]; then
    TEST_RUNNER_UIREG_PAIR_LINK="$PAIR_QR" TEST_RUNNER_UIREG_INVERT="$INVERT" \
      TEST_RUNNER_UIREG_SETTINGS_TAB="$SETTINGS_TAB" TEST_RUNNER_UIREG_NOTIFY_LABEL="$NOTIFY_LABEL" \
      xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "$DEST" \
      -only-testing "PPassUITests/RegressionTests/test$c" -resultBundlePath "$OUT/$c.xcresult" >"$xlog" 2>&1 || rc=$?
  else
    TEST_RUNNER_UIREG_PAIR_LINK="$PAIR_QR" TEST_RUNNER_UIREG_INVERT="$INVERT" \
      TEST_RUNNER_UIREG_SETTINGS_TAB="$SETTINGS_TAB" TEST_RUNNER_UIREG_NOTIFY_LABEL="$NOTIFY_LABEL" \
      xcodebuild test -project "$IOS/PPass.xcodeproj" -scheme PPassUI -configuration Debug \
      -destination "$DEST" -derivedDataPath "$DERIVED" ${SIGN[@]+"${SIGN[@]}"} \
      -only-testing "PPassUITests/RegressionTests/test$c" -resultBundlePath "$OUT/$c.xcresult" >"$xlog" 2>&1 || rc=$?
  fi
  kill "$ALLOW_PID" 2>/dev/null || true
  wait "$ALLOW_PID" 2>/dev/null || true
  ALLOW_PID=
  grep -E '^UIREG ' "$xlog" | grep -v 'DUMP_' | sed 's/^/    /' || true
  pull_log "$OUT/$c.ppass.log"
  IFS=$'\t' read -r verdict reason < <(judge "$RULES_DEFAULT" "$c" "$OUT/$c.ppass.log" "$since")
  if [ "$rc" != 0 ]; then
    local why
    why=$(grep -E "error: -\[|XCTAssert|failed:|: error:" "$xlog" | grep -v '^UIREG' | head -1 | sed 's/^.*error: //' | cut -c1-200)
    if [ "$verdict" = PASS ]; then verdict=FAIL; reason="日志通过但界面操作失败：${why:-xcodebuild 退出 $rc}"; else reason="$reason；界面操作失败：${why:-xcodebuild 退出 $rc}"; fi
  fi
  printf '%-20s %s  %s\n' "$c" "$verdict" "$reason" | tee -a "$SUMMARY"
  [ "$verdict" = PASS ] || FAILS=$((FAILS + 1))
}

if [ "$TARGET" = sim ]; then ensure_sim_photos; fi
reinstall
for c in $CASES; do
  # 通知授权只问一次：NotifyDeny 前（且前面跑过 NotifyAllow 时）重装。
  if [ "$c" = NotifyDeny ] && echo " $CASES " | grep -q " NotifyAllow "; then reinstall; fi
  run_case "$c"
done

N=$(echo "$CASES" | wc -w | tr -d ' ')
echo "----" | tee -a "$SUMMARY"
if [ -n "$INVERT" ]; then
  if grep -q "^${INVERT} .* FAIL " "$SUMMARY"; then
    echo "反证：$INVERT 故意点反向选项 → FAIL（符合预期，判据能区分）" | tee -a "$SUMMARY"
  else
    echo "反证不成立：$INVERT 点了反向选项仍然 PASS（判据区分不了）" | tee -a "$SUMMARY"
  fi
fi
echo "合计 $N 例，FAIL $FAILS 例。证据：$OUT" | tee -a "$SUMMARY"
[ "$FAILS" = 0 ]
