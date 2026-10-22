#!/usr/bin/env bash
# #1124 真机冒烟：Android 控制面经共享 Rust 核心（uniffi CtrlClient）对着本机测试沙盒 daemon 跑一遍。
#
#   tools/android-ctrl-smoke.sh [设备序列号]      # 默认取 ANDROID_SERIAL；输出在 apps/android/build/ctrl-smoke/<时间>/
#
# 步骤（全部自动，不点界面）：
#   1. 起一台测试沙盒桌面（tools/ios/sandbox-desk.sh：--ephemeral、假 HOME、自建临时库），自动允许配对；
#      用 testclient 配对并预置 3 张照片（取原图要有东西可取）。
#   2. 装 debug 包与 androidTest 包；跑 C1124CtrlSmokeTest（-e qr <新配对串>）：配对 → 请求 / 探测 →
#      取原图 → 订阅挂着。
#   3. 测试打出 `C1124 READY_FOR_REVOKE node=<手机 NodeId>` 后：关掉配对窗口（pairing.stop），经 IPC 删掉
#      这台手机（device.revoke ⇒ 电脑以 410 关掉它的全部连接）。测试判定 410 立刻到达关闭监听、订阅结束、
#      之后的请求被拒，以及从没申请过的新身份在握手时被 401 拒（有类型的关闭码 + 回调）。
# 不碰手机上 App 自己的身份与配对（测试用一次性随机身份）；debug 包与已装包签名不同时会先卸载已装包（测试机）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERIAL="${1:-${ANDROID_SERIAL:-}}"
ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")
OUT="$ROOT/apps/android/build/ctrl-smoke/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
BIN="${CARGO_TARGET_DIR:-$ROOT/target}/release"

(cd "$ROOT" && cargo build -q --release -p daemon -p testclient)
# shellcheck source=tools/ios/sandbox-desk.sh
source "$ROOT/tools/ios/sandbox-desk.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-ctrl-smoke.XXXXXX")
DESK="$WORK/desk"
INSTR_PID=
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$INSTR_PID" ] && kill "$INSTR_PID" 2>/dev/null || true
  cp "$DESK/daemon.err" "$OUT/daemon.err" 2>/dev/null || true
  desk_stop "$DESK"
  rm -rf "$WORK"
  echo "日志：$OUT"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$DESK"
desk_start "$DESK" "$BIN/daemon"
desk_auto_allow "$DESK"
NODE=$(desk_node "$DESK")
echo "==> 沙盒桌面 ${NODE:0:8}…"

echo "==> testclient 配对并预置 3 张照片"
desk_qr "$DESK"
(cd "$WORK" && "$BIN/testclient" pair --token "$PAIR_QR" --name "smoke-seed" >"$OUT/seed-pair.log" 2>&1)
(cd "$WORK" && "$BIN/testclient" backup --files 3 --node "$NODE" >"$OUT/seed-backup.log" 2>&1)
COUNT=$(desk_photo_count "$DESK")
[ "$COUNT" -ge 1 ] || { echo "预置照片失败（photo_count=${COUNT}）" >&2; exit 1; }
echo "  桌面照片数：$COUNT"

echo "==> 构建并安装 debug 包与 androidTest 包"
(cd "$ROOT/apps/android" && bash -c 'source ../../scripts/java-home.sh >/dev/null && ./gradlew -q :app:assembleDebug :app:assembleDebugAndroidTest')
APK=$(find "$ROOT/apps/android/app/build/outputs/apk/debug" -name 'P-Pass_*.apk' | head -1)
TEST_APK=$(find "$ROOT/apps/android/app/build/outputs/apk/androidTest/debug" -name '*.apk' | head -1)
if ! "${ADB[@]}" install -r "$APK" >"$OUT/install.log" 2>&1; then
  if grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE" "$OUT/install.log"; then
    echo "  已装包签名不同（正式包）：先卸载再装 debug 包"
    "${ADB[@]}" uninstall com.hawkeyexb.ppass >>"$OUT/install.log" 2>&1
    "${ADB[@]}" install -r "$APK" >>"$OUT/install.log" 2>&1 || { cat "$OUT/install.log"; exit 1; }
  else
    cat "$OUT/install.log"; exit 1
  fi
fi
"${ADB[@]}" install -r "$TEST_APK" >>"$OUT/install.log" 2>&1 || { cat "$OUT/install.log"; exit 1; }

echo "==> 真机跑 C1124CtrlSmokeTest"
desk_qr "$DESK"
"${ADB[@]}" logcat -c
"${ADB[@]}" logcat -s C1124:I >"$OUT/logcat.txt" 2>&1 &
LOGCAT_PID=$!
"${ADB[@]}" shell "am instrument -w -e class com.hawkeyexb.ppass.C1124CtrlSmokeTest -e qr '$PAIR_QR' com.hawkeyexb.ppass.test/androidx.test.runner.AndroidJUnitRunner" \
  >"$OUT/instrument.txt" 2>&1 &
INSTR_PID=$!
PHONE=
for _ in $(seq 1 300); do
  PHONE=$(sed -n 's/.*READY_FOR_REVOKE node=\([0-9a-f]\{64\}\).*/\1/p' "$OUT/logcat.txt" | head -1)
  [ -n "$PHONE" ] && break
  kill -0 "$INSTR_PID" 2>/dev/null || break
  sleep 0.2
done
if [ -n "$PHONE" ]; then
  echo "  手机 ${PHONE:0:8}… 已订阅：关配对窗口并删掉这台设备"
  desk_ipc "$DESK" pairing.stop >"$OUT/pairing-stop.json" 2>&1 || true
  desk_ipc "$DESK" device.revoke "{\"node_id\": \"$PHONE\"}" >"$OUT/revoke.json"
fi
wait "$INSTR_PID" || true
INSTR_PID=
kill "$LOGCAT_PID" 2>/dev/null || true
wait "$LOGCAT_PID" 2>/dev/null || true
echo "--- logcat（C1124）---"
grep -o 'C1124: .*' "$OUT/logcat.txt" || true
echo "--- instrument ---"
tail -5 "$OUT/instrument.txt"
if grep -q "ALL GREEN" "$OUT/logcat.txt" && grep -q "^OK (1 test)" "$OUT/instrument.txt"; then
  echo "ANDROID CTRL SMOKE: ALL GREEN"
else
  echo "ANDROID CTRL SMOKE: FAILED" >&2
  exit 1
fi
