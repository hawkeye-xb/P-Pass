#!/usr/bin/env bash
# iOS 模拟器选择（#887）。本机与 CI 共用同一套逻辑。
#
#   tools/ios/sim.sh udid                   打印要用的模拟器 UDID（没有就现建一台）
#   tools/ios/sim.sh booted                 列出已开机的模拟器 UDID，一行一个
#   tools/ios/sim.sh shutdown-new <开跑前>   用完即关（#1378）：要用的那台若是本次运行期间才开机的
#                                           （不在「开跑前」的 booted 列表里）就关掉；别的会话正持着模拟器锁时不关
#   tools/ios/sim.sh idle [分钟]            列出开机超过 N 分钟（默认 10）、且没人持模拟器锁的模拟器（just doctor 用）
#   tools/ios/sim.sh lang-args <en|zh>      打印 xcodebuild 的测试语言参数（just ios-test --lang 用）
#
# 选法：在**最新**的已装 iOS runtime 上找名为 $IOS_SIM_NAME（默认 iPhone 17）的
# 可用设备；没有就用同名设备类型现建一台。不写死 runtime 版本——CI runner 与
# 本机装的 runtime 不一样，写死等于在别处必挂。
# 设备类型不存在（老 Xcode）时报错退出，不偷偷换成别的机型。
set -euo pipefail

NAME="${IOS_SIM_NAME:-iPhone 17}"

latest_runtime() {
  xcrun simctl list runtimes available -j \
    | jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty'
}

cmd_udid() {
  local rt udid dt
  rt=$(latest_runtime)
  if [ -z "$rt" ]; then
    echo "error: 没有可用的 iOS 模拟器 runtime（xcrun simctl list runtimes）" >&2
    exit 1
  fi
  udid=$(xcrun simctl list devices available -j \
    | jq -r --arg rt "$rt" --arg n "$NAME" '.devices[$rt] // [] | map(select(.name == $n)) | first | .udid // empty')
  if [ -n "$udid" ]; then
    echo "$udid"
    return
  fi
  dt=$(xcrun simctl list devicetypes -j \
    | jq -r --arg n "$NAME" '.devicetypes[] | select(.name == $n) | .identifier' | head -1)
  if [ -z "$dt" ]; then
    echo "error: 没有名为「${NAME}」的模拟器设备类型；用 IOS_SIM_NAME 指定一个（xcrun simctl list devicetypes）" >&2
    exit 1
  fi
  echo "在 ${rt} 上新建模拟器「${NAME}」" >&2
  xcrun simctl create "$NAME" "$dt" "$rt"
}

booted_udids() {
  xcrun simctl list devices booted -j | jq -r '.devices[][] | .udid' | sort
}

# 模拟器锁（sim-lock.sh）正被一个仍在运行的进程持有就成功
sim_lock_held() {
  local holder
  holder=$(cat "${TMPDIR:-/tmp}/ppass-ios-sim.lock/pid" 2>/dev/null || true)
  [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null
}

cmd_shutdown_new() {
  local before="${1:-}" u
  u=$(cmd_udid 2>/dev/null) || return 0
  booted_udids | grep -qx "$u" || return 0
  printf '%s\n' "$before" | grep -qx "$u" && return 0
  if sim_lock_held; then
    echo "模拟器 ${u} 是本次运行期间开的，但别的会话正持着模拟器锁，不关" >&2
    return 0
  fi
  echo "关掉本次开的模拟器 ${u}" >&2
  xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
}

cmd_idle() {
  local mins="${1:-10}"
  sim_lock_held && return 0
  xcrun simctl list devices booted -j | python3 -I -c '
import datetime, json, sys
mins = int(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        t = d.get("lastBootedAt")
        if not t:
            continue
        up = (now - datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))).total_seconds() / 60
        if up >= mins:
            print("%s（%s）已开机 %d 分钟" % (d["name"], d["udid"], up))' "$mins"
}

# 测试语言：xcodebuild 的 -testLanguage / -testRegion。本机模拟器多是中文、CI 是英文，文案改动两种都跑。
cmd_lang_args() {
  case "${1:-}" in
    en) echo "-testLanguage en -testRegion US" ;;
    zh) echo "-testLanguage zh-Hans -testRegion CN" ;;
    *) echo "error: 语言只能是 en 或 zh（得到「${1:-}」）" >&2; exit 2 ;;
  esac
}

case "${1:-}" in
  udid) cmd_udid ;;
  booted) booted_udids ;;
  shutdown-new) cmd_shutdown_new "${2:-}" ;;
  idle) cmd_idle "${2:-10}" ;;
  lang-args) cmd_lang_args "${2:-}" ;;
  *) echo "usage: $0 udid | booted | shutdown-new <开跑前的 booted 列表> | idle [分钟] | lang-args <en|zh>" >&2; exit 1 ;;
esac
