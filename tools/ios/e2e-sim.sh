#!/usr/bin/env bash
# iOS 模拟器端到端（#315 App 集成）：真 App（Live 真实现）↔ 本机隔离 daemon，一路走完
#   配对 → 选相册 → 前台备份 → daemon 库里的文件与原始字节 BLAKE3 一致 → 时间线可见。
#
#   tools/ios/e2e-sim.sh            # 输出与截图在 apps/ios/build/e2e/
#
# 隔离（与 tools/ios/test-transport-ffi.sh 同一套）：
#   - daemon：fake HOME + 测试沙盒（--ephemeral 自建临时库）+ 0.0.0.0:0（OS 分配端口，绝不用 41145；不能绑 127.0.0.1——实测绑回环时首次拉取固定卡约 30 秒后失败，绑 0.0.0.0 则 0.07 秒，见 docs/runbook/ios-device-forensics.md）+ 无 relay +
#     --ephemeral（脚本退出 ⇒ stdin 关 ⇒ daemon 退出）。不碰本机已装的 P-Pass。
#   - 模拟器：专用设备 PPassE2E（不存在就建，每轮先 erase），不碰别的模拟器；结束时关掉（本脚本启动的才关）。
#   - 照片：ffmpeg / sips 现造（jpg / heic / mp4），simctl addmedia 灌进图库；相册授权用
#     apps/ios/Packages/PPassMedia/scripts/sim-photos-auth.sh（simctl 写的 TCC 行 auth_version=1 会被当成「未决定」，
#     必须改成 2，见该脚本头注释）。
#
# UI 驱动：不用 XCUITest，而是 App 里仅 DEBUG 的 E2EDriver（PPass/Debug/E2EDriver.swift，环境变量
# PPASS_E2E_DIR / PPASS_E2E_PAIR_LINK 启用）。它调的是界面背后的同一批端口（AppModel / Backend），
# 配对串直接交给配对端口，等价于「手动粘贴配对串」；省掉的只是坐标点击（授权弹窗 / 扫码 / 选相册在模拟器上
# 脆，且验的不是我们的代码）。最终界面用 simctl 截图留证。
#
# 校验：独立的 BLAKE3（tools/ios/b3sum，Rust blake3 crate）逐个比对 ① 原始 fixtures ② daemon 库里落地的文件，
# 并要求 App 时间线（timeline.page）返回的内容哈希集合 ⊇ fixtures 的哈希集合。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/apps/ios"
OUT="$IOS/build/e2e"
DERIVED="$IOS/build/DerivedData"
BUNDLE_ID=$(sed -n 's/^PPASS_BUNDLE_ID *= *//p' "$IOS/Config/Base.xcconfig" | head -1)
SIM_NAME="${PPASS_E2E_SIM_NAME:-PPassE2E}"
TIMEOUT="${PPASS_E2E_TIMEOUT:-180}"
cd "$ROOT"

for tool in jq xcodegen ffmpeg sips sqlite3 lsof; do
  command -v "$tool" >/dev/null || { echo "error: 缺 $tool" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT"
LOG="$OUT/e2e.log"
exec > >(tee "$LOG") 2>&1

# ── 构建 ────────────────────────────────────────────────────────────────────
if [ ! -d "$IOS/TransportFFITests/Generated/TransportFFI.xcframework" ] || [ ! -f "$IOS/TransportFFITests/Generated/swift/transport.swift" ]; then
  "$ROOT/tools/build-ios-transport-xcframework.sh" "$IOS/TransportFFITests/Generated"
fi
(cd "$IOS" && xcodegen generate --quiet)

echo "==> 构建 App（Debug，模拟器）"
xcodebuild build -project "$IOS/PPass.xcodeproj" -scheme PPass -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED" >"$OUT/xcodebuild.log" 2>&1 \
  || { tail -30 "$OUT/xcodebuild.log"; exit 1; }
APP="$DERIVED/Build/Products/Debug-iphonesimulator/PPass.app"
[ -d "$APP" ] || { echo "error: 没找到 $APP" >&2; exit 1; }

echo "==> 工具：daemon（release）与 b3sum"
cargo build -q -p daemon --release
DAEMON="${CARGO_TARGET_DIR:-$ROOT/target}/release/daemon"
B3_TARGET="$IOS/build/b3sum-target"
(cd "$ROOT/tools/ios/b3sum" && CARGO_TARGET_DIR="$B3_TARGET" cargo build -q --release)
B3="$B3_TARGET/release/ppass-b3sum"

# ── fixtures ────────────────────────────────────────────────────────────────
FIX="$OUT/fixtures"
mkdir -p "$FIX"
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x480:rate=1" -frames:v 1 "$FIX/a1.jpg"
ffmpeg -loglevel error -y -f lavfi -i "smptebars=size=320x240:rate=1" -frames:v 1 "$FIX/a2.jpg"
sips -s format heic "$FIX/a1.jpg" --out "$FIX/h1.heic" >/dev/null
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x480:rate=1" -f lavfi -i "sine=frequency=440:duration=2" \
  -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac "$FIX/v1.mp4"
"$B3" "$FIX"/* | sed "s#$FIX/##" > "$OUT/fixtures.b3"
echo "原始 fixtures 的 BLAKE3："; cat "$OUT/fixtures.b3"

# ── daemon（隔离） ──────────────────────────────────────────────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-ios-e2e.XXXXXX")
DAEMON_PID=
OWNER_PID=
SIM_UDID=
SIM_WAS_BOOTED=0
cleanup() {
  cp "$WORK/daemon.err" "$OUT/daemon.err" 2>/dev/null || true; cp "$WORK/daemon.out" "$OUT/daemon.out" 2>/dev/null || true
  [ -n "$OWNER_PID" ] && kill "$OWNER_PID" 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  if [ -n "$DAEMON_PID" ]; then kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; fi
  if [ -n "$SIM_UDID" ] && [ "$SIM_WAS_BOOTED" = 0 ]; then xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/home"
mkfifo "$WORK/stdin"
HOME="$WORK/home" PPF_BIND_ADDR="${PPASS_E2E_BIND:-0.0.0.0:0}" PPF_RELAY_URLS="" PPF_TELEMETRY_ENABLED=false \
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
[ -n "$NODE_ID" ] || { echo "error: daemon 没打出 NodeId" >&2; cat "$WORK/daemon.out" "$WORK/daemon.err" >&2; exit 1; }
PORT=
for _ in $(seq 1 50); do
  PORT=$(lsof -nP -a -p "$DAEMON_PID" -iUDP -Fn 2>/dev/null | sed -n "s/^n[^:]*:\([0-9][0-9]*\)$/\1/p" | head -1)
  [ -n "$PORT" ] && break
  sleep 0.2
done
if [ -z "$PORT" ] || [ "$PORT" = 41145 ]; then echo "error: 没拿到 daemon 端口（得到「${PORT}」）" >&2; exit 1; fi
echo "daemon pid=${DAEMON_PID} node=${NODE_ID:0:8}… udp=127.0.0.1:${PORT}（隔离：HOME=$WORK/home）"

# shellcheck source=tools/ipc-lib.sh
source "$ROOT/tools/ipc-lib.sh"
# #1115：--ephemeral 是测试沙盒，库目录由 daemon 自建（stdout 的 SANDBOX: 行），不收路径输入。
ipc_sandbox_dir "$WORK/daemon.out"
ipc_pair_qr "$SANDBOX_DIR/ipc.token"

# 业主：把队列里每一条待确认的配对请求点「允许」（这台 daemon 只给本次测试用）。
owner_loop() {
  local resp ids n body
  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    if resp=$(ipc pairing.pending 2>/dev/null); then
      ids=$(printf '%s' "$resp" | jq -r '.result.pending[]?.node_id // empty')
      for n in $ids; do
        body=$(jq -cn --arg n "$n" '{accept: true, node_id: $n}')
        if ipc pairing.confirm "$body" >/dev/null 2>&1; then echo "owner: 已允许 ${n:0:8}…"; fi
      done
    fi
    sleep 0.3
  done
}
owner_loop &
OWNER_PID=$!

# ── 模拟器（专用） ──────────────────────────────────────────────────────────
RT=$(xcrun simctl list runtimes available -j \
  | jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty')
[ -n "$RT" ] || { echo "error: 没有可用的 iOS runtime" >&2; exit 1; }
SIM_UDID=$(xcrun simctl list devices available -j | jq -r --arg rt "$RT" --arg n "$SIM_NAME" '.devices[$rt] // [] | map(select(.name == $n)) | first | .udid // empty')
[ -n "$SIM_UDID" ] || SIM_UDID=$(xcrun simctl create "$SIM_NAME" "iPhone 17" "$RT")
echo "模拟器：${SIM_NAME} ${SIM_UDID}（${RT}）：erase → boot → 灌照片 → 授权"
xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$SIM_UDID"
xcrun simctl boot "$SIM_UDID"
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
xcrun simctl addmedia "$SIM_UDID" "$FIX/a1.jpg" "$FIX/a2.jpg" "$FIX/h1.heic" "$FIX/v1.mp4"
xcrun simctl install "$SIM_UDID" "$APP"
"$IOS/Packages/PPassMedia/scripts/sim-photos-auth.sh" "$SIM_UDID" "$BUNDLE_ID" full

# ── 跑 ──────────────────────────────────────────────────────────────────────
mkdir -p "$OUT/status"
echo "==> 启动 App（E2EDriver）"
SIMCTL_CHILD_PPASS_E2E_DIR="$OUT/status" SIMCTL_CHILD_PPASS_E2E_PAIR_LINK="$PAIR_QR" \
  SIMCTL_CHILD_PPASS_E2E_TIMEOUT="$TIMEOUT" xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >"$OUT/launch.log" 2>&1 || {
  cat "$OUT/launch.log"; exit 1; }

DONE=0
LASTSTEP=
for _ in $(seq 1 $((TIMEOUT * 2 + 20))); do
  if [ -s "$OUT/status/status.json" ]; then
    STEP=$(jq -r '.step' "$OUT/status/status.json" 2>/dev/null || true)
    if [ "$STEP" != "$LASTSTEP" ]; then echo "  app step: $STEP"; LASTSTEP="$STEP"; fi
    if [ "$(jq -r '.done // false' "$OUT/status/status.json" 2>/dev/null)" = true ]; then DONE=1; break; fi
  fi
  sleep 0.5
done
sleep 4
xcrun simctl io "$SIM_UDID" screenshot "$OUT/app-final.png" >/dev/null 2>&1 || true
echo "--- App 状态 ---"
cat "$OUT/status/status.json" 2>/dev/null || echo "(无 status.json)"
[ "$DONE" = 1 ] || { echo "FAIL: App 没跑完（见上面状态、$OUT/daemon.err）" >&2; cp "$WORK/daemon.err" "$OUT/daemon.err" 2>/dev/null || true; cp "$WORK/daemon.out" "$OUT/daemon.out" 2>/dev/null || true; exit 1; }
cp "$WORK/daemon.err" "$OUT/daemon.err" 2>/dev/null || true
cp "$WORK/daemon.out" "$OUT/daemon.out" 2>/dev/null || true

# ── 校验 ────────────────────────────────────────────────────────────────────
FAIL=0
[ "$(jq -r '.ok' "$OUT/status/status.json")" = true ] || { echo "FAIL: App 报告未成功：$(jq -r '.error // .timeline_error' "$OUT/status/status.json")"; FAIL=1; }

# daemon 库里落地的全部媒体文件（HOME 与数据目录之下，排除 daemon 自己的索引 / 缩略图 / 临时目录）。
find "$WORK/home" "$SANDBOX_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.mp4' -o -iname '*.mov' \) \
  ! -path '*/thumbs/*' ! -path '*/.thumbs/*' ! -path '*/tmp/*' 2>/dev/null | sort > "$OUT/daemon-files.txt"
echo "--- daemon 库里的媒体文件 ---"; cat "$OUT/daemon-files.txt"
: > "$OUT/daemon.b3"
while IFS= read -r f; do "$B3" "$f"; done < "$OUT/daemon-files.txt" | awk '{print $1}' | sort > "$OUT/daemon.b3" || true

echo "--- BLAKE3 逐个比对（原始 fixture ↔ daemon 库文件 ↔ App 时间线） ---"
while read -r hash name; do
  in_lib=no; in_tl=no
  grep -qx "$hash" "$OUT/daemon.b3" && in_lib=yes
  jq -e --arg h "$hash" '.timeline_ids | index($h)' "$OUT/status/status.json" >/dev/null 2>&1 && in_tl=yes
  printf '%-8s %s  daemon库=%s  时间线=%s\n' "$name" "${hash:0:16}…" "$in_lib" "$in_tl"
  { [ "$in_lib" = yes ] && [ "$in_tl" = yes ]; } || FAIL=1
done < "$OUT/fixtures.b3"

if [ "$FAIL" = 0 ]; then
  echo "PASS: 配对 → 选相册 → 前台备份 → daemon 库 BLAKE3 与原始一致 → 时间线可见。截图：$OUT/app-final.png"
else
  echo "FAIL: 见上面逐项结果（daemon.err：$OUT/daemon.err）" >&2
  exit 1
fi
