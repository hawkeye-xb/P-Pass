# Android 真机：adb、uiautomator 界面读取、logcat、run-as。
#
# 本机配置（e3.env）：
#   E3_ANDROID_SERIAL      手机序列号（必需）
#   E3_ADB_PORT            adb server 端口；手机插在另一台机器上时是本地转发端口（可选，默认 5037）
#   E3_ADB_TUNNEL_HOST     手机插在哪台 ssh 主机上（可选）；给了就在端口不通时自动开
#                          `ssh -L <E3_ADB_PORT>:127.0.0.1:5037 <主机>` 隧道
# 手机上同时装着别的 App（例如 Immich）：每次点之前 fg_guard 确认前台是 P-Pass 或系统权限框。
# shellcheck shell=bash

PKG="${E3_ANDROID_PKG:-com.hawkeyexb.ppass}"
UI_XML="$E3_STATE/ui-$$.xml"

adb_init() {
  need_cfg E3_ANDROID_SERIAL "三星真机序列号"
  export ANDROID_ADB_SERVER_PORT="${E3_ADB_PORT:-5037}"
  if [ -n "${E3_ADB_TUNNEL_HOST:-}" ] && ! nc -z 127.0.0.1 "$ANDROID_ADB_SERVER_PORT" 2>/dev/null; then
    log "开 adb 隧道 :$ANDROID_ADB_SERVER_PORT → $E3_ADB_TUNNEL_HOST:5037"
    ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
      -L "$ANDROID_ADB_SERVER_PORT:127.0.0.1:5037" "$E3_ADB_TUNNEL_HOST" || die "adb 隧道开不了"
    sleep 1
  fi
  [ "$(T 20 adb -s "$E3_ANDROID_SERIAL" get-state 2>/dev/null)" = device ] \
    || die "adb 看不到手机 ${E3_ANDROID_SERIAL}（端口 ${ANDROID_ADB_SERVER_PORT}）"
}

A() { adb -s "$E3_ANDROID_SERIAL" "$@"; }

# —— 界面 ——
# ui_dump [证据文件]：dump 当前界面到 ${UI_XML}，给了路径就另存一份
ui_dump() {
  local i
  for i in 1 2 3; do
    if A shell uiautomator dump /sdcard/ppui.xml >/dev/null 2>&1 && A pull /sdcard/ppui.xml "$UI_XML" >/dev/null 2>&1; then
      [ -n "${1:-}" ] && cp "$UI_XML" "$1"
      return 0
    fi
    sleep 1
  done
  log "uiautomator dump 失败"
  return 1
}
ui_has() { python3 -I "$E3_LIB/ui.py" has "$UI_XML" "$1"; }
ui_find() { python3 -I "$E3_LIB/ui.py" find "$UI_XML" "$1"; }
ui_texts() { python3 -I "$E3_LIB/ui.py" texts "${1:-$UI_XML}"; }
# 应用内更新框会遮住页面：见到就点「稍后」（绝不点「下载安装」）
dismiss_update() {
  if ui_has "发现新版本" && ui_has "稍后"; then
    fg_guard && tap_xy "$(ui_find "稍后")"
    log "已关掉应用内更新框"
    sleep 1
  fi
  return 0
}
# wait_text <子串> [秒]
wait_text() {
  local end=$((SECONDS + ${2:-20}))
  while [ $SECONDS -lt $end ]; do
    if ui_dump; then
      ui_has "$1" && return 0
      dismiss_update
    fi
    sleep 1
  done
  log "等 ${2:-20}s 没出现：$1"
  return 1
}
fg() { A shell dumpsys window | grep -m1 mCurrentFocus; }
fg_guard() {
  fg | grep -qE "${PKG//./\\.}|permissioncontroller|photopicker|providers.media.module" && return 0
  log "前台不是 P-Pass：$(fg)，不点"
  return 1
}
tap_xy() { [ -n "$1" ] || return 1; # shellcheck disable=SC2086
  A shell input tap $1; sleep 0.8; }
# tap_text <子串>：dump → 找可点位置 → 前台核对 → 点
tap_text() {
  local xy
  ui_dump || return 1
  xy=$(ui_find "$1") || { log "找不到可点的：$1"; return 1; }
  fg_guard && tap_xy "$xy"
}
shot() { A exec-out screencap -p >"$1" 2>/dev/null; }

# —— App ——
app_start() { A shell am start -W -n "$PKG/.MainActivity" >/dev/null; sleep 2; }
app_stop() { A shell am force-stop "$PKG"; }
app_pid() { A shell pidof "$PKG" 2>/dev/null | tr -d '\r'; }
runas() { A shell run-as "$PKG" "$@"; }
logcat_clear() { A logcat -c; }
logcat_save() { A logcat -d -v threadtime >"$1"; }
pkg_info() { A shell dumpsys package "$PKG" | grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime|pkgFlags' | sed 's/^ *//'; }
is_debuggable() { A shell dumpsys package "$PKG" | grep -m1 'pkgFlags' | grep -q DEBUGGABLE; }

# —— 素材 ——
# push_photos <本地目录>：推进相机目录并通知媒体库（否则 App 查不到）
push_photos() {
  local f
  for f in "$1"/*; do
    A push "$f" /sdcard/DCIM/Camera/ >/dev/null || return 1
    A shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
      -d "file:///sdcard/DCIM/Camera/$(basename "$f")" >/dev/null
  done
}
# rm_photos <前缀>：删掉推过的素材
rm_photos() {
  local f
  for f in $(A shell ls /sdcard/DCIM/Camera/ 2>/dev/null | tr -d '\r' | grep "^$1"); do
    A shell rm -f "/sdcard/DCIM/Camera/$f"
    A shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file:///sdcard/DCIM/Camera/$f" >/dev/null
  done
}
