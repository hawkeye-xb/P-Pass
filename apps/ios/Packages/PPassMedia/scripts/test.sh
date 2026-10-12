#!/usr/bin/env bash
# PPassMedia 全量测试：包内单测（fake）+ 真 PhotoKit 集成测试（模拟器 + 宿主 App）。
#
# 用法：scripts/test.sh [--keep]
#   --keep  跑完不关模拟器（调试用）；默认跑完 shutdown。
#
# 做的事（每一步都可重复，结果不依赖上一轮残留）：
#   1. 用一台**专用**模拟器（名字 ${PPASS_MEDIA_SIM_NAME:-PPassMedia-Test}，最新已装 iOS runtime 上的 iPhone 17）；
#      没有就建。每轮先 erase，图库从系统自带样例照片起步。不碰任何别的模拟器。
#   2. 用 ffmpeg / sips 现造 a1.jpg、h1.heic、v1.mp4（不用任何真实照片），`simctl addmedia` 灌进图库。
#   3. 宿主 App 的相册授权设成完整（scripts/sim-photos-auth.sh，见其中关于 auth_version 的说明）。
#   4. 包内单测：xcodebuild test -scheme PPassMedia（SwiftPM 包直接在模拟器上跑）。
#   5. 集成测试：xcodegen 生成 IntegrationHost 工程，xcodebuild test，素材目录经 TEST_RUNNER_ 前缀传给测试进程。
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
keep=0
[[ "${1:-}" == "--keep" ]] && keep=1

sim_name="${PPASS_MEDIA_SIM_NAME:-PPassMedia-Test}"
host_bundle="com.hawkeyexb.ppass.mediatest.host"
work="$(mktemp -d -t ppassmedia-test)"
trap 'rm -rf "${work}"' EXIT

for tool in xcodegen ffmpeg sips sqlite3; do
  command -v "${tool}" >/dev/null || { echo "missing tool: ${tool}" >&2; exit 1; }
done

runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')"
[[ -n "${runtime}" ]] || { echo "no iOS simulator runtime installed" >&2; exit 1; }

udid="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
for d in json.load(sys.stdin)["devices"].get(runtime, []):
    if d["name"] == name and d["isAvailable"]:
        print(d["udid"]); break' "${sim_name}" "${runtime}")"
if [[ -z "${udid}" ]]; then
  udid="$(xcrun simctl create "${sim_name}" "iPhone 17" "${runtime}")"
  echo "created simulator ${sim_name} (${udid}) on ${runtime}"
fi

echo "==> simulator ${sim_name} ${udid} (${runtime}): erase + boot"
xcrun simctl shutdown "${udid}" >/dev/null 2>&1 || true
xcrun simctl erase "${udid}"
xcrun simctl boot "${udid}"
xcrun simctl bootstatus "${udid}" -b >/dev/null
cleanup_sim() {
  if [[ "${keep}" == 0 ]]; then xcrun simctl shutdown "${udid}" >/dev/null 2>&1 || true; fi
  rm -rf "${work}"
}
trap cleanup_sim EXIT

echo "==> fixtures"
fixtures="${work}/fixtures"
mkdir -p "${fixtures}"
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x480:rate=1" -frames:v 1 "${fixtures}/a1.jpg"
sips -s format heic "${fixtures}/a1.jpg" --out "${fixtures}/h1.heic" >/dev/null
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x480:rate=1" -f lavfi -i "sine=frequency=440:duration=2" \
  -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac "${fixtures}/v1.mp4"
xcrun simctl addmedia "${udid}" "${fixtures}/a1.jpg" "${fixtures}/h1.heic" "${fixtures}/v1.mp4"
ls -l "${fixtures}"

"${here}/scripts/sim-photos-auth.sh" "${udid}" "${host_bundle}" full

dest="platform=iOS Simulator,id=${udid}"

echo "==> unit tests (SwiftPM package, fakes)"
(cd "${here}" && xcodebuild test -scheme PPassMedia -destination "${dest}" \
  -derivedDataPath "${work}/dd-unit" >"${work}/unit.log" 2>&1) || { tail -60 "${work}/unit.log"; exit 1; }
grep -E "Executed [0-9]+ tests?|\*\* TEST" "${work}/unit.log" | tail -3

echo "==> integration tests (real PhotoKit, hosted)"
(cd "${here}/IntegrationHost" && xcodegen generate --spec project.yml >/dev/null)
(cd "${here}/IntegrationHost" && TEST_RUNNER_PPASS_MEDIA_FIXTURE_DIR="${fixtures}" \
  xcodebuild test -project PPassMediaIntegrationHost.xcodeproj -scheme PPassMediaIntegration \
  -destination "${dest}" -derivedDataPath "${work}/dd-it" >"${work}/it.log" 2>&1) || {
  grep -E "IT-|error:|failed|Test Case" "${work}/it.log" | tail -80; exit 1; }
grep -E "IT-" "${work}/it.log" || true
grep -E "Test Case .*(passed|failed)|Executed [0-9]+ tests?|\*\* TEST" "${work}/it.log" | tail -40
