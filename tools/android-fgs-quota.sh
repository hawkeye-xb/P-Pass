#!/usr/bin/env bash
# Android 15 dataSync 前台服务配额（生产约 6 小时 / 24h 滚动窗口）的压缩与恢复。
# 让「配额耗尽 → Service.onTimeout」在几分钟内可复现（#409 #397 #414）。
#
#   tools/android-fgs-quota.sh set <秒>   压缩配额（并处理 compat 开关）
#   tools/android-fgs-quota.sh status     打印当前实际生效值
#   tools/android-fgs-quota.sh reset      恢复系统默认
#
# 设备：ANDROID_SERIAL=<serial>（多台设备时必填）；包名：PPASS_PKG（默认 com.hawkeyexb.ppass）。
#
# 已在三星 SM-S9210 / Android 15 上核实（2026-09-29）：
#  - `device_config put activity_manager data_sync_fgs_timeout_duration <ms>` 立即生效，
#    `dumpsys activity settings` 读回即是新值；`device_config delete` 立即回到 21600000。
#  - `am compat enable FGS_INTRODUCE_TIME_LIMITS <pkg>` 对 targetSdk ≥ 35 的包会被拒
#    （ChangeId 317799821 enableSinceTargetSdk=35，默认已开、不允许 override）。所以本脚本只在
#    targetSdk < 35 时才调 compat enable / reset。注意 `am compat reset` 即使没有 override 也会杀掉 App 进程
#    （logcat：`Killing ... PlatformCompat overrides`），所以 targetSdk ≥ 35 时 reset 不调它。
#  - 为防 device_config 被服务端同步回写，set 期间把 sync 模式设为 until_reboot，reset 恢复 set 前的值。
#
# 失败关闭：任何一步读回的值与预期不符都立即退出非零。幂等：重复 set / reset 结果相同。
# 兼容 macOS 自带 bash 3.2。
set -euo pipefail

PKG="${PPASS_PKG:-com.hawkeyexb.ppass}"
NS=activity_manager
KEY=data_sync_fgs_timeout_duration
DEFAULT_MS="${PPASS_FGS_DEFAULT_MS:-21600000}"
CHANGE=FGS_INTRODUCE_TIME_LIMITS
# set 前的 sync 模式记在设备上（换一台 Mac 跑 reset 也能恢复）。
STATE=/data/local/tmp/ppass-fgs-quota.sync-mode

fail() { echo "android-fgs-quota: FAIL: $*" >&2; exit 1; }
say() { echo "android-fgs-quota: $*"; }
sh_() { adb shell "$@" | tr -d '\r'; }

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

preflight() {
  command -v adb >/dev/null 2>&1 || fail "找不到 adb"
  local state
  state=$(adb get-state 2>&1 | tr -d '\r') || fail "adb 连不上设备（多台设备时设 ANDROID_SERIAL）：$state"
  [[ "$state" == "device" ]] || fail "设备状态不是 device：$state"
  SDK=$(sh_ getprop ro.build.version.sdk)
  [[ "$SDK" =~ ^[0-9]+$ ]] || fail "读不到 SDK 版本：$SDK"
  [[ "$SDK" -ge 35 ]] || fail "dataSync 配额是 Android 15（SDK 35）起的行为，这台是 SDK $SDK"
  TARGET=$(sh_ dumpsys package "$PKG" | sed -n 's/.*targetSdk=\([0-9]*\).*/\1/p' | head -1)
  [[ -n "$TARGET" ]] || fail "设备上没装 $PKG"
}

effective_ms() { sh_ dumpsys activity settings | sed -n "s/^ *$KEY=\([0-9]*\)$/\1/p" | head -1; }
config_ms() { sh_ device_config get "$NS" "$KEY"; }
sync_mode() { sh_ device_config get_sync_disabled_for_tests; }
crash_extra_ms() { sh_ dumpsys activity settings | sed -n 's/^ *fgs_crash_extra_wait_duration=\([0-9]*\)$/\1/p' | head -1; }
compat_line() { sh_ dumpsys platform_compat | grep -m1 "name=$CHANGE" || true; }

print_status() {
  say "device        = $(sh_ getprop ro.product.model) / SDK $SDK / serial ${ANDROID_SERIAL:-<default>}"
  say "package       = $PKG targetSdk=$TARGET"
  say "device_config = $NS/$KEY=$(config_ms)   (null = 未覆盖，走系统默认)"
  say "AMS 生效值    = $KEY=$(effective_ms) ms   (系统默认 $DEFAULT_MS)"
  say "onTimeout 后宽限 = fgs_crash_extra_wait_duration=$(crash_extra_ms) ms（超过仍未 stopSelf 即崩溃）"
  say "sync 模式     = $(sync_mode)   (none = 允许服务端同步回写)"
  say "compat        = $(compat_line)"
  if [[ "$TARGET" -ge 35 ]]; then
    say "compat 判定   = targetSdk $TARGET ≥ 35：$CHANGE 默认已开，无需也不允许 override"
  fi
  local saved
  saved=$(sh_ "cat $STATE 2>/dev/null" || true)
  say "set 前备份    = ${saved:-<无>}   ($STATE)"
  say "电池白名单    = $(sh_ dumpsys deviceidle whitelist | grep -c ",$PKG," || true) 条命中（0 = 不在白名单，后台申请 FGS 会被拒，见 #411）"
  say "当前 FGS      = $(sh_ dumpsys activity services "$PKG" | grep -E 'isForeground=true|foregroundServiceType' | tr -s ' ' | tr '\n' ' ')"
}

cmd_set() {
  local secs="${1:-}"
  [[ "$secs" =~ ^[0-9]+$ ]] || fail "set 需要正整数秒数，拿到：'${secs}'"
  [[ "$secs" -ge 1 ]] || fail "配额必须 ≥ 1 秒"
  local ms=$((secs * 1000))

  # 1) compat：targetSdk ≥ 35 默认开且不可 override；低于 35 才需要显式打开。
  if [[ "$TARGET" -ge 35 ]]; then
    say "compat: targetSdk=$TARGET ≥ 35，$CHANGE 默认已开，跳过 enable"
  else
    local out
    out=$(sh_ am compat enable "$CHANGE" "$PKG" 2>&1) || fail "am compat enable 失败：$out"
    say "compat: $out"
  fi

  # 2) 关同步（防回写），只在第一次 set 时记下原模式。
  local prev
  prev=$(sh_ "cat $STATE 2>/dev/null" || true)
  if [[ -z "$prev" ]]; then
    prev=$(sync_mode)
    [[ -n "$prev" ]] || fail "读不到 sync 模式"
    sh_ "echo $prev > $STATE"
    [[ "$(sh_ cat $STATE)" == "$prev" ]] || fail "写不进 $STATE"
  fi
  sh_ device_config set_sync_disabled_for_tests until_reboot >/dev/null
  [[ "$(sync_mode)" == "until_reboot" ]] || fail "sync 模式没变成 until_reboot：$(sync_mode)"
  say "sync: until_reboot（原模式 $prev 已记到 ${STATE}）"

  # 3) 写配额并双重读回。
  sh_ device_config put "$NS" "$KEY" "$ms" >/dev/null
  local got eff
  got=$(config_ms)
  [[ "$got" == "$ms" ]] || fail "device_config 读回 ${got}，期望 $ms"
  eff=$(effective_ms)
  [[ "$eff" == "$ms" ]] || fail "AMS 生效值 ${eff}，期望 ${ms}（device_config 已写但系统没吃进去）"
  say "set: $KEY=$ms ms（${secs}s），AMS 已生效"
  say "提示：前台不计时、切回前台清零（#411）——要让它到点，App 必须在后台跑满 ${secs}s"
}

cmd_reset() {
  sh_ device_config delete "$NS" "$KEY" >/dev/null || true
  local got eff
  got=$(config_ms)
  [[ "$got" == "null" ]] || fail "device_config 仍有值：$got"
  eff=$(effective_ms)
  [[ "$eff" == "$DEFAULT_MS" ]] || fail "AMS 生效值 ${eff}，期望系统默认 $DEFAULT_MS"
  say "reset: $KEY 已删除，AMS 生效值 $eff ms"

  if [[ "$TARGET" -ge 35 ]]; then
    say "compat: targetSdk=$TARGET ≥ 35，set 没有写 override，跳过 am compat reset（它会杀掉 App 进程）"
  else
    local out
    out=$(sh_ am compat reset "$CHANGE" "$PKG" 2>&1) || fail "am compat reset 失败：$out"
    say "compat: $out"
  fi

  local prev
  prev=$(sh_ "cat $STATE 2>/dev/null" || true)
  [[ -n "$prev" ]] || prev=none
  sh_ device_config set_sync_disabled_for_tests "$prev" >/dev/null
  [[ "$(sync_mode)" == "$prev" ]] || fail "sync 模式没恢复成 ${prev}：$(sync_mode)"
  sh_ "rm -f $STATE"
  say "sync: 已恢复为 $prev"
}

[[ $# -ge 1 ]] || usage
case "$1" in
  set) preflight; cmd_set "${2:-}"; print_status ;;
  status) preflight; print_status ;;
  reset) preflight; cmd_reset; print_status ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
