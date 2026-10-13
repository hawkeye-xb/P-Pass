#!/usr/bin/env bash
# IOS-03（#332）模拟器复现脚本：建专用模拟器 → 灌素材 → 构建安装 spike → 完整授权 → 起本地接收端与日志流
# → 开启后台上传（--enable）→ 主 App 里建一个 job（--create-in-app）→ 施加触发手段 → 等待 → 收集证据。
#
# 用法：tools/run-sim.sh [等待分钟数，默认 30]
# 产物：脚本结束时打印证据目录（在 mktemp 下，不进仓库）：stream.log（unified log）、requests.jsonl（接收端收到的请求）。
# 只动名为 BgUploadSpike-Test 的模拟器；结束时关机（不删，方便追加观察；删用 xcrun simctl delete）。
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "${here}/../.." && pwd)"
wait_min="${1:-30}"
port=8765
bundle="com.hawkeyexb.ppass.bgspike"
sim_name="BgUploadSpike-Test"
out="$(mktemp -d -t bgspike-evidence)"
echo "evidence dir: ${out}"

runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')"
udid="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
for d in json.load(sys.stdin)["devices"].get(runtime, []):
    if d["name"] == name and d["isAvailable"]:
        print(d["udid"]); break' "${sim_name}" "${runtime}")"
[[ -n "${udid}" ]] || udid="$(xcrun simctl create "${sim_name}" "iPhone 17" "${runtime}")"
echo "simulator ${sim_name} ${udid} (${runtime})"

xcrun simctl shutdown "${udid}" >/dev/null 2>&1 || true
xcrun simctl erase "${udid}"
xcrun simctl boot "${udid}"
xcrun simctl bootstatus "${udid}" -b >/dev/null

fixtures="${out}/fixtures"
mkdir -p "${fixtures}"
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x480:rate=1" -frames:v 1 "${fixtures}/a1.jpg"
sips -s format heic "${fixtures}/a1.jpg" --out "${fixtures}/h1.heic" >/dev/null
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x480:rate=1" -t 2 -c:v libx264 -pix_fmt yuv420p "${fixtures}/v1.mp4"
xcrun simctl addmedia "${udid}" "${fixtures}/a1.jpg" "${fixtures}/h1.heic" "${fixtures}/v1.mp4"

(cd "${here}" && xcodegen generate --spec project.yml >/dev/null)
(cd "${here}" && xcodebuild build -project BgUploadSpike.xcodeproj -scheme BgUploadSpike -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "${out}/dd" >"${out}/build.log" 2>&1) || { tail -30 "${out}/build.log"; exit 1; }
xcrun simctl install "${udid}" "${out}/dd/Build/Products/Debug-iphonesimulator/BgUploadSpike.app"
"${repo}/apps/ios/Packages/PPassMedia/scripts/sim-photos-auth.sh" "${udid}" "${bundle}" full

python3 "${here}/tools/recv_server.py" "${port}" "${out}" >"${out}/server.out" 2>&1 &
server_pid=$!
xcrun simctl spawn "${udid}" log stream --level debug --style compact --predicate \
  'subsystem == "com.hawkeyexb.ppass.bgspike" OR category == "BackgroundJobService" OR category == "BackgroundAssetResourceUpload" OR composedMessage CONTAINS "UploadExtensionRunner" OR composedMessage CONTAINS[c] "BackgroundUploadURLBase"' \
  >"${out}/stream.log" 2>&1 &
log_pid=$!
cleanup() {
  kill "${server_pid}" "${log_pid}" >/dev/null 2>&1 || true
  xcrun simctl status_bar "${udid}" clear >/dev/null 2>&1 || true
  xcrun simctl shutdown "${udid}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
sleep 2

echo "==> enable + create a job from the app ($(date +%T))"
xcrun simctl launch "${udid}" "${bundle}" --enable --dump >/dev/null
sleep 3
xcrun simctl launch --terminate-running-process "${udid}" "${bundle}" --create-in-app --dump >/dev/null
sleep 3

echo "==> triggers: background the app, fake charging status bar, simulated uploader launch event ($(date +%T))"
xcrun simctl launch "${udid}" com.apple.Preferences >/dev/null
xcrun simctl status_bar "${udid}" override --batteryState charging --batteryLevel 100
xcrun simctl spawn "${udid}" notifyutil -p com.apple.photos.simulateBackgroundResourceUploaderLaunchEvent

echo "==> waiting ${wait_min} min for process() / uploads"
deadline=$(( $(date +%s) + wait_min * 60 ))
while (( $(date +%s) < deadline )); do
  if grep -q "SPIKE ext process" "${out}/stream.log" 2>/dev/null; then echo "process() observed at $(date +%T)"; break; fi
  sleep 30
done
xcrun simctl launch --terminate-running-process "${udid}" "${bundle}" --dump >/dev/null
sleep 3

echo "==> summary ($(date +%T))"
grep -E "SPIKE|Result: |URLBase|UploadExtensionRunner|launch event" "${out}/stream.log" | cut -c1-300 || true
echo "requests received: $(wc -l < "${out}/requests.jsonl" 2>/dev/null || echo 0)"
echo "evidence dir: ${out}"
